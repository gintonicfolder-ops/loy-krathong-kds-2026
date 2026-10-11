-- =====================================================================
-- Loy Krathong KDS 2026 · ROYAL CONTEST · ระบบจัดการผู้เข้าประกวด (ส่วนต่อขยาย)
--
-- ลำดับการรัน:  1) royal_contest_schema.sql (ที่รันไปแล้ว)   2) ไฟล์นี้
-- วิธีใช้: Supabase Dashboard → SQL Editor → วางทั้งไฟล์แล้วกด Run
-- รันซ้ำได้: ไม่ลบข้อมูลเดิม ไม่ทำให้คะแนนหาย ไม่เปลี่ยนสถานะที่ผู้ดูแลตั้งไว้
--
-- หลักการเดิมยังอยู่: เบราว์เซอร์ไม่มีสิทธิ์อ่าน/เขียนตารางโดยตรง ทำได้เฉพาะเรียก RPC
-- ส่วนที่เพิ่ม: ฟังก์ชันของผู้ดูแล (admin_*) ที่ตรวจสิทธิ์ในฐานข้อมูลทุกครั้ง
-- =====================================================================

create schema if not exists contest_private;
revoke all on schema contest_private from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 1) ผู้ดูแลระบบ: ใช้ Supabase Auth (อีเมล+รหัสผ่าน) + รายชื่อผู้มีสิทธิ์ในตาราง contest_admins
--    ต่อให้มีคนสมัครบัญชีเข้ามา ก็ไม่มีสิทธิ์อะไรเลยจนกว่าจะถูกเพิ่มในตารางนี้
-- ---------------------------------------------------------------------
create table if not exists public.contest_admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  note       text,
  created_at timestamptz not null default now()
);
alter table public.contest_admins enable row level security;
revoke all on table public.contest_admins from anon, authenticated;

create or replace function public.is_contest_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (select 1 from public.contest_admins a where a.user_id = auth.uid());
$fn$;

revoke all on function public.is_contest_admin() from public, anon;
grant execute on function public.is_contest_admin() to authenticated;

-- ---------------------------------------------------------------------
-- 2) ขยายตาราง contestants (id เดิมคือรหัสที่คะแนนผูกอยู่ ไม่เปลี่ยนแปลง)
-- ---------------------------------------------------------------------
alter table public.contestants
  add column if not exists nickname       text,
  add column if not exists bio            text,                       -- แนะนำตัว / ประวัติสั้น ๆ
  add column if not exists insp           text,                       -- แรงบันดาลใจ
  add column if not exists extra          text,                       -- ข้อมูลเพิ่มเติม
  add column if not exists photo_path     text,                       -- ที่อยู่ไฟล์ใน Storage (bucket contestant-photos)
  add column if not exists voting_enabled boolean     not null default true,   -- เปิดรับโหวตเฉพาะคนนี้
  add column if not exists deleted_at     timestamptz,                -- ลบแบบเก็บประวัติ (soft delete) คะแนนเดิมไม่หาย
  add column if not exists created_at     timestamptz not null default now(),
  add column if not exists updated_at     timestamptz not null default now();

-- is_published: แถวเดิมทั้งหมด = เผยแพร่ต่อ / แถวที่เพิ่มใหม่ = ซ่อนไว้ก่อน (ฉบับร่าง)
-- ทำเฉพาะครั้งแรก เพื่อไม่ให้การรันซ้ำไปเผยแพร่คนที่ผู้ดูแลตั้งใจซ่อนไว้
do $do$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'contestants'
                    and column_name = 'is_published') then
    alter table public.contestants add column is_published boolean not null default true;
    alter table public.contestants alter column is_published set default false;
  end if;
end
$do$;

-- id รันอัตโนมัติสำหรับผู้เข้าประกวดใหม่ (ต่อจาก id สูงสุดที่มีอยู่)
create sequence if not exists public.contestants_id_seq;
alter sequence public.contestants_id_seq owned by public.contestants.id;
do $do$
declare
  v_max    integer;
  v_last   bigint;
  v_called boolean;
begin
  select coalesce(max(id), 0) into v_max from public.contestants;
  select last_value, is_called into v_last, v_called from public.contestants_id_seq;
  if v_max > 0 and (v_max > v_last or (v_max = v_last and not v_called)) then
    perform setval('public.contestants_id_seq', v_max, true);
  end if;
end
$do$;
alter table public.contestants alter column id set default nextval('public.contestants_id_seq');
revoke all on sequence public.contestants_id_seq from anon, authenticated;

-- หมายเลขในเวทีต้องไม่ซ้ำเฉพาะ "คนที่ยังไม่ถูกลบ" (คนที่ถูกลบคืนหมายเลขให้คนใหม่ใช้ได้)
do $do$
declare
  r record;
begin
  for r in
    select c.conname
      from pg_constraint c
     where c.conrelid = 'public.contestants'::regclass
       and c.contype = 'u'
       and (select array_agg(a.attname::text order by a.attname::text)
              from pg_attribute a
             where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) = array['category', 'number']
  loop
    execute format('alter table public.contestants drop constraint %I', r.conname);
  end loop;
end
$do$;
create unique index if not exists contestants_category_number_active_uidx
  on public.contestants (category, number) where deleted_at is null;

-- ตรวจข้อมูลที่ระดับตารางอีกชั้น (นอกเหนือจากที่ฟังก์ชันตรวจ)
do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.contestants'::regclass and conname = 'contestants_text_lengths_chk') then
    alter table public.contestants add constraint contestants_text_lengths_chk check (
          char_length(btrim(name)) between 1 and 120
      and (nickname   is null or char_length(nickname)   <= 60)
      and (class_name is null or char_length(class_name) <= 80)
      and (bio        is null or char_length(bio)        <= 1000)
      and (insp       is null or char_length(insp)       <= 500)
      and (extra      is null or char_length(extra)      <= 1000));
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.contestants'::regclass and conname = 'contestants_photo_path_chk') then
    alter table public.contestants add constraint contestants_photo_path_chk check (
      photo_path is null or photo_path ~ '^photos/[a-z0-9_-]{6,64}\.(jpg|png|webp)$');
  end if;
end
$do$;

-- ---------------------------------------------------------------------
-- 3) ฟังก์ชันภายใน (เบราว์เซอร์เรียกตรงไม่ได้)
-- ---------------------------------------------------------------------
create or replace function contest_private.contestant_json(c public.contestants, p_votes integer default null)
returns json
language sql
stable
as $fn$
  select json_build_object(
    'id', c.id, 'category', c.category, 'number', c.number,
    'name', c.name, 'nickname', c.nickname, 'class_name', c.class_name,
    'bio', c.bio, 'insp', c.insp, 'extra', c.extra, 'photo_path', c.photo_path,
    'is_published', c.is_published, 'voting_enabled', c.voting_enabled,
    'deleted_at', c.deleted_at, 'votes', p_votes, 'updated_at', c.updated_at);
$fn$;
revoke all on function contest_private.contestant_json(public.contestants, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) ฟังก์ชันสาธารณะ (ผู้เข้าชมทั่วไปเรียกได้)
-- ---------------------------------------------------------------------

-- 4.1 รายชื่อผู้เข้าประกวดที่ "เผยแพร่และยังไม่ถูกลบ" เท่านั้น
create or replace function public.get_contestants()
returns json
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(
           json_agg(json_build_object(
                      'id', c.id, 'category', c.category, 'number', c.number,
                      'name', c.name, 'nickname', c.nickname, 'class_name', c.class_name,
                      'bio', c.bio, 'insp', c.insp, 'extra', c.extra,
                      'photo_path', c.photo_path, 'voting_enabled', c.voting_enabled)
                    order by c.category, c.number, c.id),
           '[]'::json)
    from public.contestants c
   where c.is_published and c.deleted_at is null;
$fn$;

-- 4.2 คะแนนรวม: แสดงเฉพาะผู้เข้าประกวดที่เผยแพร่อยู่ (ถ้าซ่อน คะแนนยังเก็บไว้ใน votes ครบ แค่ไม่แสดง)
create or replace function public.get_results()
returns json
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(
           json_agg(json_build_object('contestant_id', c.id, 'category', c.category, 'votes', coalesce(v.n, 0))
                    order by c.id),
           '[]'::json)
    from public.contestants c
    left join (select contestant_id, count(*)::int as n
                 from public.votes
                group by contestant_id) v on v.contestant_id = c.id
   where c.is_published and c.deleted_at is null;
$fn$;

-- 4.3 โหวต: กติกาเดิมทั้งหมด + รับเฉพาะผู้เข้าประกวดที่เผยแพร่ ไม่ถูกลบ และยังเปิดรับโหวต
create or replace function public.cast_vote(
  p_student_code  text,
  p_pin           text,
  p_category      text,
  p_contestant_id integer)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_code    text := upper(btrim(coalesce(p_student_code, '')));
  v_open    boolean;
  v_err     text;
  v_enabled boolean;
  v_n       integer;
  v_mine    json;
begin
  select voting_open into v_open from public.contest_settings where id;
  if not coalesce(v_open, false) then
    return json_build_object('ok', false, 'error', 'voting_closed');
  end if;

  v_err := contest_private.verify_student(v_code, p_pin);
  if v_err is not null then
    return json_build_object('ok', false, 'error', v_err);
  end if;

  -- ผู้เข้าประกวดต้องอยู่เวทีนั้นจริง + เผยแพร่อยู่ + ยังไม่ถูกลบ
  -- (FOR SHARE: ถ้าผู้ดูแลกำลังซ่อน/ลบ/ปิดรับโหวตคนนี้ในจังหวะเดียวกัน คำขอจะเรียงคิวกัน ไม่มีช่องว่างให้โหวตเล็ดลอด)
  select c.voting_enabled into v_enabled
    from public.contestants c
   where c.id = p_contestant_id and c.category = p_category
     and c.is_published and c.deleted_at is null
     for share;
  if not found then
    return json_build_object('ok', false, 'error', 'invalid_contestant');
  end if;
  if not v_enabled then
    return json_build_object('ok', false, 'error', 'contestant_closed');
  end if;

  -- เส้นแบ่งความถูกต้องเดิม: PRIMARY KEY (student_code, category) กันโหวตซ้ำแม้มีคำขอพร้อมกัน
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
$fn$;

-- ---------------------------------------------------------------------
-- 5) ฟังก์ชันของผู้ดูแล: ทุกตัวตรวจ is_contest_admin() ในฐานข้อมูลก่อนทำงาน
--    (นอกจากนี้ถอนสิทธิ์ anon ออก เหลือเฉพาะผู้ที่ล็อกอินแล้วเรียกได้)
-- ---------------------------------------------------------------------

-- 5.1 รายการทั้งหมด รวมที่ซ่อน/ถูกลบ พร้อมจำนวนโหวตจริงจากตาราง votes
create or replace function public.admin_list_contestants()
returns json
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not public.is_contest_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  return json_build_object(
    'ok', true,
    'contestants', coalesce(
      (select json_agg(contest_private.contestant_json(c, coalesce(v.n, 0))
                       order by c.category, (c.deleted_at is not null), c.number, c.id)
         from public.contestants c
         left join (select contestant_id, count(*)::int as n
                      from public.votes
                     group by contestant_id) v on v.contestant_id = c.id),
      '[]'::json));
end;
$fn$;

-- 5.2 เพิ่ม (p_id = null) หรือแก้ไข (ระบุ p_id) — แก้เฉพาะคีย์ที่ส่งมาใน p_data
--     แก้ชื่อ/รูป/หมายเลข/สถานะ ได้โดยไม่แตะตาราง votes จึงไม่กระทบคะแนนเดิม
create or replace function public.admin_save_contestant(p_id integer, p_data jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ws      constant text := E' \t\r\n';
  r         public.contestants%rowtype;
  v_new     boolean := (p_id is null);
  v_cat     text;
  v_num     integer;
  v_numeric numeric;
  v_name    text;
  v_nick    text;
  v_class   text;
  v_bio     text;
  v_insp    text;
  v_extra   text;
  v_photo   text;
  v_pub     boolean;
  v_vote    boolean;
  v_other   text;
  v_votes   integer;
begin
  if not public.is_contest_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    return json_build_object('ok', false, 'error', 'invalid_data');
  end if;

  if v_new then
    v_pub  := false;   -- คนใหม่เริ่มเป็นฉบับร่าง จนกว่าผู้ดูแลจะสั่งเผยแพร่
    v_vote := true;
  else
    select * into r from public.contestants where id = p_id for update;
    if not found then
      return json_build_object('ok', false, 'error', 'not_found');
    end if;
    if r.deleted_at is not null then
      return json_build_object('ok', false, 'error', 'is_deleted');
    end if;
    v_cat := r.category;  v_num := r.number;   v_name := r.name;      v_nick := r.nickname;
    v_class := r.class_name; v_bio := r.bio;   v_insp := r.insp;      v_extra := r.extra;
    v_photo := r.photo_path; v_pub := r.is_published; v_vote := r.voting_enabled;
  end if;

  -- ทับด้วยค่าที่ส่งมา (เฉพาะคีย์ที่มีใน p_data; ส่งค่าว่าง/null = ล้างค่า)
  if p_data ? 'category'   then v_cat   := p_data->>'category'; end if;
  if p_data ? 'name'       then v_name  := nullif(btrim(p_data->>'name', v_ws), ''); end if;
  if p_data ? 'nickname'   then v_nick  := nullif(btrim(p_data->>'nickname', v_ws), ''); end if;
  if p_data ? 'class_name' then v_class := nullif(btrim(p_data->>'class_name', v_ws), ''); end if;
  if p_data ? 'bio'        then v_bio   := nullif(btrim(p_data->>'bio', v_ws), ''); end if;
  if p_data ? 'insp'       then v_insp  := nullif(btrim(p_data->>'insp', v_ws), ''); end if;
  if p_data ? 'extra'      then v_extra := nullif(btrim(p_data->>'extra', v_ws), ''); end if;
  if p_data ? 'photo_path' then v_photo := nullif(btrim(p_data->>'photo_path', v_ws), ''); end if;

  if p_data ? 'is_published' then
    if jsonb_typeof(p_data->'is_published') is distinct from 'boolean' then
      return json_build_object('ok', false, 'error', 'invalid_flag');
    end if;
    v_pub := (p_data->>'is_published')::boolean;
  end if;
  if p_data ? 'voting_enabled' then
    if jsonb_typeof(p_data->'voting_enabled') is distinct from 'boolean' then
      return json_build_object('ok', false, 'error', 'invalid_flag');
    end if;
    v_vote := (p_data->>'voting_enabled')::boolean;
  end if;

  -- ตรวจความถูกต้อง
  if v_cat is null or v_cat not in ('nn', 'nt', 'tk') then
    return json_build_object('ok', false, 'error', 'invalid_category');
  end if;

  if p_data ? 'number' then
    if jsonb_typeof(p_data->'number') is distinct from 'number' then
      return json_build_object('ok', false, 'error', 'invalid_number');
    end if;
    v_numeric := (p_data->>'number')::numeric;
    if v_numeric <> trunc(v_numeric) or v_numeric < 1 or v_numeric > 99 then
      return json_build_object('ok', false, 'error', 'invalid_number');
    end if;
    v_num := v_numeric::integer;
  end if;
  if v_num is null then        -- เพิ่มคนใหม่โดยไม่ระบุหมายเลข: ใช้เลขว่างน้อยที่สุดของประเภทนั้น
    select g.n into v_num
      from generate_series(1, 99) as g(n)
     where not exists (select 1 from public.contestants c
                        where c.category = v_cat and c.number = g.n and c.deleted_at is null)
     order by g.n
     limit 1;
    if v_num is null then
      return json_build_object('ok', false, 'error', 'invalid_number');
    end if;
  end if;

  if v_name is null then
    return json_build_object('ok', false, 'error', 'invalid_name');
  end if;
  if char_length(v_name) > 120 then
    return json_build_object('ok', false, 'error', 'too_long', 'field', 'name');
  end if;
  if char_length(v_nick) > 60 then
    return json_build_object('ok', false, 'error', 'too_long', 'field', 'nickname');
  end if;
  if char_length(v_class) > 80 then
    return json_build_object('ok', false, 'error', 'too_long', 'field', 'class_name');
  end if;
  if char_length(v_bio) > 1000 then
    return json_build_object('ok', false, 'error', 'too_long', 'field', 'bio');
  end if;
  if char_length(v_insp) > 500 then
    return json_build_object('ok', false, 'error', 'too_long', 'field', 'insp');
  end if;
  if char_length(v_extra) > 1000 then
    return json_build_object('ok', false, 'error', 'too_long', 'field', 'extra');
  end if;
  if v_photo is not null and v_photo !~ '^photos/[a-z0-9_-]{6,64}\.(jpg|png|webp)$' then
    return json_build_object('ok', false, 'error', 'invalid_photo');
  end if;

  -- ย้ายประเภทได้เฉพาะคนที่ยังไม่มีคะแนน (ไม่งั้นโหวตเดิมจะไปอยู่ผิดเวที)
  if not v_new and v_cat <> r.category then
    select count(*)::int into v_votes from public.votes where contestant_id = p_id;
    if v_votes > 0 then
      return json_build_object('ok', false, 'error', 'category_locked');
    end if;
  end if;

  -- หมายเลขซ้ำในประเภทเดียวกัน (บอกชื่อคนที่ใช้อยู่ เพื่อให้ผู้ดูแลแก้ถูกจุด)
  select c.name into v_other
    from public.contestants c
   where c.category = v_cat and c.number = v_num and c.deleted_at is null
     and c.id is distinct from p_id
   limit 1;
  if found then
    return json_build_object('ok', false, 'error', 'number_taken', 'conflict_name', v_other);
  end if;

  begin
    if v_new then
      insert into public.contestants
             (category, number, name, nickname, class_name, bio, insp, extra, photo_path, is_published, voting_enabled)
      values (v_cat, v_num, v_name, v_nick, v_class, v_bio, v_insp, v_extra, v_photo, v_pub, v_vote)
      returning * into r;
    else
      update public.contestants
         set category = v_cat, number = v_num, name = v_name, nickname = v_nick, class_name = v_class,
             bio = v_bio, insp = v_insp, extra = v_extra, photo_path = v_photo,
             is_published = v_pub, voting_enabled = v_vote, updated_at = now()
       where id = p_id
      returning * into r;
    end if;
  exception when unique_violation then   -- กันกรณีมีผู้ดูแลสองคนบันทึกหมายเลขเดียวกันพร้อมกัน
    return json_build_object('ok', false, 'error', 'number_taken');
  end;

  return json_build_object(
    'ok', true,
    'contestant', contest_private.contestant_json(
                    r, (select count(*)::int from public.votes where contestant_id = r.id)));
end;
$fn$;

-- 5.3 ลบ = ซ่อนจากทุกหน้าและหยุดรับโหวต แต่เก็บแถวและคะแนนไว้ครบ (กู้คืนได้)
create or replace function public.admin_delete_contestant(p_id integer)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r public.contestants%rowtype;
begin
  if not public.is_contest_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  select * into r from public.contestants where id = p_id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;
  if r.deleted_at is null then
    update public.contestants set deleted_at = now(), updated_at = now()
     where id = p_id returning * into r;
  end if;
  return json_build_object(
    'ok', true,
    'contestant', contest_private.contestant_json(
                    r, (select count(*)::int from public.votes where contestant_id = r.id)));
end;
$fn$;

-- 5.4 กู้คืน: กลับมาเป็น "ซ่อน" ก่อนเสมอ (ผู้ดูแลตรวจแล้วค่อยสั่งเผยแพร่) ถ้าหมายเลขเดิมถูกใช้ไปแล้วจะให้เลขว่างถัดไป
create or replace function public.admin_restore_contestant(p_id integer)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r     public.contestants%rowtype;
  v_num integer;
begin
  if not public.is_contest_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  select * into r from public.contestants where id = p_id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;
  if r.deleted_at is not null then
    v_num := r.number;
    if exists (select 1 from public.contestants c
                where c.category = r.category and c.number = v_num
                  and c.deleted_at is null and c.id <> r.id) then
      select g.n into v_num
        from generate_series(1, 99) as g(n)
       where not exists (select 1 from public.contestants c
                          where c.category = r.category and c.number = g.n and c.deleted_at is null)
       order by g.n
       limit 1;
      if v_num is null then
        return json_build_object('ok', false, 'error', 'no_free_number');
      end if;
    end if;
    begin
      update public.contestants
         set deleted_at = null, is_published = false, number = v_num, updated_at = now()
       where id = p_id
      returning * into r;
    exception when unique_violation then
      return json_build_object('ok', false, 'error', 'number_taken');
    end;
  end if;
  return json_build_object(
    'ok', true,
    'contestant', contest_private.contestant_json(
                    r, (select count(*)::int from public.votes where contestant_id = r.id)));
end;
$fn$;

-- ---------------------------------------------------------------------
-- 6) ที่เก็บรูป: Supabase Storage bucket (อ่านได้สาธารณะ / เขียน-แก้-ลบ ได้เฉพาะผู้ดูแล)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contestant-photos', 'contestant-photos', true, 5242880,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
   set public             = excluded.public,
       file_size_limit    = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "contest photos: admin select" on storage.objects;
create policy "contest photos: admin select" on storage.objects
  for select to authenticated
  using (bucket_id = 'contestant-photos' and public.is_contest_admin());

drop policy if exists "contest photos: admin insert" on storage.objects;
create policy "contest photos: admin insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'contestant-photos' and public.is_contest_admin());

drop policy if exists "contest photos: admin update" on storage.objects;
create policy "contest photos: admin update" on storage.objects
  for update to authenticated
  using (bucket_id = 'contestant-photos' and public.is_contest_admin())
  with check (bucket_id = 'contestant-photos' and public.is_contest_admin());

drop policy if exists "contest photos: admin delete" on storage.objects;
create policy "contest photos: admin delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'contestant-photos' and public.is_contest_admin());

-- ---------------------------------------------------------------------
-- 7) สิทธิ์การเรียกใช้
-- ---------------------------------------------------------------------
revoke all on function public.get_contestants()                         from public;
revoke all on function public.get_results()                             from public;
revoke all on function public.cast_vote(text, text, text, integer)      from public;
grant execute on function public.get_contestants()                      to anon, authenticated;
grant execute on function public.get_results()                          to anon, authenticated;
grant execute on function public.cast_vote(text, text, text, integer)   to anon, authenticated;

revoke all on function public.admin_list_contestants()                  from public, anon;
revoke all on function public.admin_save_contestant(integer, jsonb)     from public, anon;
revoke all on function public.admin_delete_contestant(integer)          from public, anon;
revoke all on function public.admin_restore_contestant(integer)         from public, anon;
grant execute on function public.admin_list_contestants()               to authenticated;
grant execute on function public.admin_save_contestant(integer, jsonb)  to authenticated;
grant execute on function public.admin_delete_contestant(integer)       to authenticated;
grant execute on function public.admin_restore_contestant(integer)      to authenticated;

-- =====================================================================
-- ขั้นตอนเพิ่มผู้ดูแล (ทำใน Dashboard + SQL Editor เท่านั้น)
-- =====================================================================
-- 1) Authentication → Users → Add user → Create new user
--    กรอกอีเมล + รหัสผ่านที่คาดเดายาก และติ๊ก "Auto Confirm User"
-- 2) รันคำสั่งนี้ (เปลี่ยนอีเมลให้ตรงกับข้อ 1):
--      insert into public.contest_admins (user_id, note)
--      select id, 'ผู้ดูแลหลัก' from auth.users where email = 'admin@example.com'
--      on conflict (user_id) do nothing;
-- 3) แนะนำ: Authentication → Sign In / Providers → ปิด "Allow new users to sign up"
--    (ต่อให้เปิดไว้ คนสมัครใหม่ก็ไม่มีสิทธิ์ใด ๆ แต่ปิดไว้จะปลอดภัยกว่า)
--
-- ถอนสิทธิ์ผู้ดูแล:
--      delete from public.contest_admins where user_id = (select id from auth.users where email = 'admin@example.com');
--
-- ลบข้อมูลตัวอย่าง 9 คนทิ้งถาวร (เฉพาะที่ไม่มีใครโหวต) ก่อนใช้งานจริง ถ้าต้องการ:
--      delete from public.contestants c
--       where c.id between 1 and 9
--         and not exists (select 1 from public.votes v where v.contestant_id = c.id);
-- =====================================================================
