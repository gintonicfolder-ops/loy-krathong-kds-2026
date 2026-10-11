-- =====================================================================
-- Loy Krathong KDS 2026 · ROYAL CONTEST · ระบบโหวตส่วนกลาง (Supabase / PostgreSQL)
--
-- วิธีใช้: Supabase Dashboard → SQL Editor → วางทั้งไฟล์แล้วกด Run
-- (รันซ้ำได้ ไม่ทำลายข้อมูลเดิม)
--
-- หลักการ: เบราว์เซอร์ไม่มีสิทธิ์อ่าน/เขียนตารางโดยตรงเลย
--          ทำได้เฉพาะเรียกฟังก์ชัน 4 ตัวด้านล่างผ่าน RPC และทุกกติกาถูกตรวจในฐานข้อมูล
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists contest_private;           -- ฟังก์ชันภายใน ไม่เปิดให้เบราว์เซอร์เรียก
revoke all on schema contest_private from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 1) ตาราง
-- ---------------------------------------------------------------------

-- ผู้เข้าประกวด (id ตรงกับ id 1-9 ในหน้าเว็บ)
create table if not exists public.contestants (
  id          integer primary key,
  category    text    not null check (category in ('nn','nt','tk')),
  number      integer not null check (number between 1 and 99),   -- หมายเลขในเวที (NO. ที่แสดงบนการ์ด)
  name        text    not null,
  class_name  text,
  unique (category, number),
  unique (id, category)                                  -- ให้ votes อ้างอิงคู่ (id, category) ได้
);

-- รายชื่อนักเรียนที่มีสิทธิ์โหวต (ผู้ดูแลนำเข้าเอง)
create table if not exists public.students (
  student_code     text primary key
                   check (student_code = upper(btrim(student_code)) and length(student_code) between 3 and 32),
  pin_hash         text,                                  -- ใช้เมื่อเปิด require_pin (ดู README)
  failed_pin_count integer     not null default 0,
  locked_until     timestamptz,
  is_active        boolean     not null default true
);

-- การโหวต: 1 รหัสนักเรียน + 1 เวที = 1 แถวเท่านั้น (กันโหวตซ้ำที่ระดับ PRIMARY KEY)
create table if not exists public.votes (
  student_code  text    not null references public.students(student_code) on delete restrict,
  category      text    not null,
  contestant_id integer not null,
  created_at    timestamptz not null default now(),
  primary key (student_code, category),
  foreign key (contestant_id, category) references public.contestants(id, category)   -- ผู้เข้าประกวดต้องอยู่เวทีนั้นจริง
);
create index if not exists votes_contestant_idx on public.votes (contestant_id);

-- ตั้งค่าเปิด/ปิดโหวต (แถวเดียว)
create table if not exists public.contest_settings (
  id          boolean primary key default true check (id),
  voting_open boolean not null default false,             -- เริ่มต้น "ปิด" จนกว่าผู้ดูแลจะเปิดเอง
  require_pin boolean not null default false
);
insert into public.contest_settings (id) values (true) on conflict (id) do nothing;

-- ผู้เข้าประกวดตามที่แสดงในหน้าเว็บตอนนี้
insert into public.contestants (id, category, number, name, class_name) values
  (1,'nn',1,'พิมพ์ชนก','ม.5/1'), (2,'nn',2,'ณัฐรดา','ม.4/2'),  (3,'nn',3,'ธัญญ์ชนก','ม.6/3'),
  (4,'nt',1,'กัญญ์วรา','ม.5/4'), (5,'nt',2,'ปวีณ์ธิดา','ม.4/1'), (6,'nt',3,'ศศิธร','ม.6/2'),
  (7,'tk',1,'ภูมิพัฒน์','ม.5/2'), (8,'tk',2,'ธีรภัทร','ม.6/1'),  (9,'tk',3,'กวินภพ','ม.4/3')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2) ปิดการเข้าถึงตารางโดยตรง (RLS เปิด + ไม่มี policy + ถอนสิทธิ์)
-- ---------------------------------------------------------------------
alter table public.contestants      enable row level security;
alter table public.students         enable row level security;
alter table public.votes            enable row level security;
alter table public.contest_settings enable row level security;

revoke all on table public.contestants, public.students, public.votes, public.contest_settings
  from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) ฟังก์ชันภายใน: ตรวจรหัสนักเรียน (+ รหัสผ่านถ้าเปิด require_pin)
--    คืน NULL = ผ่าน, ไม่เช่นนั้นคืนรหัสข้อผิดพลาด
--    ไม่ใช้ RAISE เพื่อให้ตัวนับพิมพ์ผิดถูกบันทึกจริง (RAISE จะ rollback)
-- ---------------------------------------------------------------------
create or replace function contest_private.verify_student(p_code text, p_pin text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s   public.students%rowtype;
  req boolean;
begin
  -- FOR UPDATE: คำขอของนักเรียนคนเดียวกันที่เข้ามาพร้อมกันจะถูกจัดคิวทีละคำขอ
  select * into s
    from public.students
   where student_code = upper(btrim(coalesce(p_code, '')))
   for update;

  if not found or not s.is_active then
    return 'invalid_credentials';
  end if;

  select require_pin into req from public.contest_settings where id;

  if coalesce(req, false) then
    if s.locked_until is not null and s.locked_until > now() then
      return 'locked';
    end if;

    if s.pin_hash is null
       or p_pin is null
       or extensions.crypt(p_pin, s.pin_hash) <> s.pin_hash then
      update public.students
         set failed_pin_count = case when failed_pin_count + 1 >= 5 then 0 else failed_pin_count + 1 end,
             locked_until     = case when failed_pin_count + 1 >= 5 then now() + interval '15 minutes' else locked_until end
       where student_code = s.student_code;
      return 'invalid_credentials';
    end if;

    if s.failed_pin_count <> 0 or s.locked_until is not null then
      update public.students
         set failed_pin_count = 0, locked_until = null
       where student_code = s.student_code;
    end if;
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- 4) ฟังก์ชันที่เบราว์เซอร์เรียกได้ (RPC)
-- ---------------------------------------------------------------------

-- 4.1 สถานะระบบ
create or replace function public.get_contest_config()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object('voting_open', voting_open, 'require_pin', require_pin)
    from public.contest_settings
   where id;
$$;

-- 4.2 คะแนนรวมทุกคน (นับจากตาราง votes โดยตรง จึงตรงกับข้อมูลที่บันทึกจริงเสมอ)
create or replace function public.get_results()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           json_agg(json_build_object('contestant_id', c.id, 'category', c.category, 'votes', coalesce(v.n, 0))
                    order by c.id),
           '[]'::json)
    from public.contestants c
    left join (select contestant_id, count(*)::int as n
                 from public.votes
                group by contestant_id) v on v.contestant_id = c.id;
$$;

-- 4.3 สถานะการโหวตของนักเรียนคนนั้น (เวทีไหนโหวตใครไปแล้ว)
create or replace function public.get_my_votes(p_student_code text, p_pin text default null)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(btrim(coalesce(p_student_code, '')));
  v_err  text;
begin
  v_err := contest_private.verify_student(v_code, p_pin);
  if v_err is not null then
    return json_build_object('ok', false, 'error', v_err);
  end if;

  return json_build_object(
    'ok', true,
    'votes', coalesce((select json_object_agg(category, contestant_id)
                         from public.votes
                        where student_code = v_code), '{}'::json));
end;
$$;

-- 4.4 โหวต
create or replace function public.cast_vote(
  p_student_code  text,
  p_pin           text,
  p_category      text,
  p_contestant_id integer)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code  text := upper(btrim(coalesce(p_student_code, '')));
  v_open  boolean;
  v_err   text;
  v_n     integer;
  v_mine  json;
begin
  select voting_open into v_open from public.contest_settings where id;
  if not coalesce(v_open, false) then
    return json_build_object('ok', false, 'error', 'voting_closed');
  end if;

  v_err := contest_private.verify_student(v_code, p_pin);
  if v_err is not null then
    return json_build_object('ok', false, 'error', v_err);
  end if;

  if not exists (select 1 from public.contestants
                  where id = p_contestant_id and category = p_category) then
    return json_build_object('ok', false, 'error', 'invalid_contestant');
  end if;

  -- เส้นแบ่งความถูกต้อง: PRIMARY KEY (student_code, category) ทำให้แทรกซ้ำไม่ได้
  -- แม้มีคำขอเข้ามาพร้อมกันกี่ตัวก็ตาม จะมีเพียงตัวเดียวที่แทรกสำเร็จ
  insert into public.votes (student_code, category, contestant_id)
  values (v_code, p_category, p_contestant_id)
  on conflict (student_code, category) do nothing;
  get diagnostics v_n = row_count;

  select coalesce(json_object_agg(category, contestant_id), '{}'::json)
    into v_mine
    from public.votes
   where student_code = v_code;

  if v_n = 0 then
    return json_build_object('ok', false, 'error', 'already_voted', 'votes', v_mine);
  end if;

  return json_build_object('ok', true, 'votes', v_mine);
end;
$$;

-- ---------------------------------------------------------------------
-- 5) สิทธิ์การเรียกใช้
-- ---------------------------------------------------------------------
revoke all on function contest_private.verify_student(text, text) from public, anon, authenticated;

revoke all on function public.get_contest_config()                      from public;
revoke all on function public.get_results()                             from public;
revoke all on function public.get_my_votes(text, text)                  from public;
revoke all on function public.cast_vote(text, text, text, integer)      from public;

grant execute on function public.get_contest_config()                   to anon, authenticated;
grant execute on function public.get_results()                          to anon, authenticated;
grant execute on function public.get_my_votes(text, text)               to anon, authenticated;
grant execute on function public.cast_vote(text, text, text, integer)   to anon, authenticated;

-- =====================================================================
-- คำสั่งสำหรับผู้ดูแล (รันใน SQL Editor เท่านั้น — เบราว์เซอร์ทำไม่ได้)
-- =====================================================================
-- นำเข้ารายชื่อนักเรียน (รหัสต้องเป็นตัวพิมพ์ใหญ่):
--   insert into public.students (student_code) values ('KDS69001'), ('KDS69002') on conflict do nothing;
--   หรือใช้ Table Editor → students → Import data from CSV (คอลัมน์ student_code)
--
-- เปิด / ปิดรับโหวต:
--   update public.contest_settings set voting_open = true;
--   update public.contest_settings set voting_open = false;
--
-- เปิดใช้รหัสผ่าน (แนะนำ ดู README หัวข้อความปลอดภัย):
--   update public.students set pin_hash = extensions.crypt('รหัสของนักเรียน', extensions.gen_salt('bf')) where student_code = 'KDS69001';
--   update public.contest_settings set require_pin = true;
--
-- ดูคะแนนรวมแยกเวที:
--   select c.category, c.number, c.name, count(v.*) as votes
--     from public.contestants c left join public.votes v on v.contestant_id = c.id
--    group by c.category, c.number, c.name order by c.category, c.number;
-- =====================================================================
