-- =====================================================================
-- Loy Krathong KDS 2026 · ขั้นที่ 2: ตาราง + ฟังก์ชันของ "กระทง" (ไม่ลบ ไม่แก้ข้อมูลเดิม)
--
-- วิธีใช้: รันหลังตรวจผลจากไฟล์ krathong_01_inspect_READONLY.sql แล้วเท่านั้น
--          Supabase Dashboard → SQL Editor → วางทั้งไฟล์ → Run   (รันซ้ำได้)
--
-- หลักการเดียวกับระบบโหวต: เบราว์เซอร์ไม่มีสิทธิ์อ่าน/เขียนตารางโดยตรง
-- เรียกได้เฉพาะ RPC 2 ตัว: add_krathong (ลอยกระทง) และ get_krathongs (ดึงรายการ + จำนวนรวม)
-- ไม่แตะตาราง students / votes / contestants / contest_settings เลย
-- =====================================================================

-- กันชนกับตารางเดิม: ถ้ามี public.krathongs อยู่แล้วแต่โครงสร้างไม่ตรง ให้หยุดทันที (ไม่แก้ทับ)
do $guard$
begin
  if to_regclass('public.krathongs') is not null then
    if (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'krathongs'
           and column_name in ('id','owner','wish','design','created_at')) < 5 then
      raise exception 'มีตาราง public.krathongs อยู่แล้วแต่โครงสร้างไม่ตรงกับที่ระบบนี้ต้องการ — หยุดการทำงาน กรุณาส่งผลลัพธ์จากไฟล์ตรวจสอบ (ขั้นที่ 1) ให้ผู้พัฒนาก่อน';
    end if;
  end if;
end
$guard$;

create table if not exists public.krathongs (
  id         text        primary key check (id ~ '^k[a-z0-9]{6,40}$'),          -- รหัสที่เบราว์เซอร์สร้าง (ใช้กันบันทึกซ้ำเวลากดซ้ำ/เน็ตสะดุด)
  owner      text        not null check (char_length(owner) between 1 and 30),
  wish       text        not null check (char_length(wish)  between 1 and 160),
  design     jsonb       not null check (jsonb_typeof(design) = 'object'),
  created_at timestamptz not null default now()
);
create index if not exists krathongs_created_at_idx on public.krathongs (created_at desc);

alter table public.krathongs enable row level security;
revoke all on table public.krathongs from anon, authenticated;       -- ไม่มี policy = เบราว์เซอร์อ่าน/เขียนตรงไม่ได้

-- ---------------------------------------------------------------------
-- ลอยกระทง: ตรวจทุกอย่างในฐานข้อมูล แล้วคืน ok:true เฉพาะเมื่อแถวถูกบันทึกจริง (หรือเคยบันทึกด้วย id เดียวกันแล้ว)
-- ---------------------------------------------------------------------
create or replace function public.add_krathong(
  p_id     text,
  p_owner  text,
  p_wish   text,
  p_design jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ws     constant text := E' \t\r\n';
  v_owner  text := btrim(coalesce(p_owner, ''), v_ws);
  v_wish   text := btrim(coalesce(p_wish,  ''), v_ws);
  v_t text; v_f text; v_c text; v_a text; v_d text;
  v_design jsonb;
  v_n      integer;
  v_total  bigint;
begin
  if p_id is null or p_id !~ '^k[a-z0-9]{6,40}$' then
    return json_build_object('ok', false, 'error', 'invalid_id');
  end if;

  -- บันทึกไปแล้วด้วย id เดียวกัน (กดซ้ำ/ลองใหม่) = สำเร็จ ไม่เพิ่มแถวซ้ำ
  if exists (select 1 from public.krathongs where id = p_id) then
    select count(*) into v_total from public.krathongs;
    return json_build_object('ok', true, 'duplicate', true, 'total', v_total);
  end if;

  if char_length(v_owner) not between 1 and 30 then
    return json_build_object('ok', false, 'error', 'invalid_owner');
  end if;
  if char_length(v_wish) not between 1 and 160 then
    return json_build_object('ok', false, 'error', 'invalid_wish');
  end if;

  if p_design is null or jsonb_typeof(p_design) <> 'object' then
    return json_build_object('ok', false, 'error', 'invalid_design');
  end if;
  v_t := p_design->>'t';  v_f := p_design->>'f';  v_c := p_design->>'c';
  v_a := coalesce(p_design->>'a', 'dense');
  v_d := coalesce(p_design->>'d', 'none');
  if v_t is null or v_t not in ('banana','lotus','plate','lanna','bread','min')
     or v_f is null or v_f not in ('lotus','jasmine','marigold','rose','orchid','white','plumeria','plumeriaP','mix')
     or v_c is null or v_c not in ('gold','ivory','red','ornate')
     or v_a !~ '^[a-z_-]{1,20}$' or v_d !~ '^[a-z_-]{1,20}$' then
    return json_build_object('ok', false, 'error', 'invalid_design');
  end if;
  v_design := jsonb_build_object('t', v_t, 'f', v_f, 'c', v_c, 'a', v_a, 'd', v_d);   -- เก็บเฉพาะคีย์ที่รู้จัก

  -- กันถูกยิงรัว: รับได้สูงสุด 300 รายการ/นาที (ทั้งระบบ) ปรับตัวเลขได้ถ้างานใหญ่กว่านี้
  if (select count(*) from public.krathongs where created_at > now() - interval '1 minute') >= 300 then
    return json_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into public.krathongs (id, owner, wish, design)
  values (p_id, v_owner, v_wish, v_design)
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;

  select count(*) into v_total from public.krathongs;
  return json_build_object('ok', true, 'duplicate', (v_n = 0), 'total', v_total);
end;
$fn$;

-- ---------------------------------------------------------------------
-- ดึงรายการล่าสุด + จำนวนรวมจริง (นับจากตารางโดยตรง) — ไม่ส่งข้อมูลอื่นนอกจากชื่อ/คำอธิษฐาน/ดีไซน์ที่แสดงบนหน้าเว็บอยู่แล้ว
-- ---------------------------------------------------------------------
create or replace function public.get_krathongs(p_limit integer default 30)
returns json
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_lim integer := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  return json_build_object(
    'ok', true,
    'total', (select count(*) from public.krathongs),
    'items', coalesce(
      (select json_agg(json_build_object('id', x.id, 'owner', x.owner, 'text', x.wish, 'design', x.design)
                       order by x.created_at desc, x.id)
         from (select id, owner, wish, design, created_at
                 from public.krathongs
                order by created_at desc, id
                limit v_lim) x),
      '[]'::json));
end;
$fn$;

revoke all on function public.add_krathong(text, text, text, jsonb) from public;
revoke all on function public.get_krathongs(integer)                from public;
grant execute on function public.add_krathong(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.get_krathongs(integer)                to anon, authenticated;

-- =====================================================================
-- ใช้งานจริง (ผู้ดูแล รันใน SQL Editor เท่านั้น)
-- ลบกระทงที่ไม่เหมาะสมรายการเดียว:   delete from public.krathongs where id = 'รหัสกระทง';
-- ดูรายการล่าสุด:                     select id, owner, wish, created_at from public.krathongs order by created_at desc limit 50;
-- นับจำนวน:                           select count(*) from public.krathongs;
-- =====================================================================
