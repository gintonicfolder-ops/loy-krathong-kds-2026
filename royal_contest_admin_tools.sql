-- =====================================================================
-- Loy Krathong KDS 2026 · ADMIN TOOLS · ฟังก์ชันผู้ดูแลสำหรับหน้า /admin/ (ส่วนต่อขยาย)
--   - admin_list_krathongs   ดูรายการกระทง (ค้นหา + แบ่งหน้า)
--   - admin_delete_krathong  ลบกระทงที่ไม่เหมาะสม (ลบถาวร 1 รายการ)
--   - admin_students_summary ดูจำนวนนักเรียนในระบบ (เฉพาะตัวเลข ไม่คืนรหัสนักเรียน)
--   - admin_import_students  นำเข้ารหัสนักเรียน (เพิ่มรหัสใหม่เท่านั้น)
--
-- ลำดับการรัน: 1) royal_contest_schema.sql  2) royal_contest_admin_migration.sql
--              3) krathong_02_schema.sql    4) ไฟล์นี้
-- วิธีใช้: Supabase Dashboard → SQL Editor → วางทั้งไฟล์ → Run   (รันซ้ำได้)
--
-- หลักการเดิมยังอยู่:
--   * ไม่ปิด RLS / ไม่แตะนโยบายใด ๆ / ไม่เปิดสิทธิ์ตารางให้เบราว์เซอร์
--   * ทุกฟังก์ชันตรวจ public.is_contest_admin() ในฐานข้อมูลก่อนทำงาน (ผู้ที่ล็อกอินแต่ไม่ใช่แอดมินได้ 'forbidden')
--   * ถอนสิทธิ์ anon ทั้งหมด เหลือเฉพาะผู้ที่ล็อกอินแล้ว (authenticated) เรียกได้
--   * ไม่เปิด/ปิดระบบโหวต ไม่แก้ contest_settings ไม่แก้ตาราง votes / contestants
-- =====================================================================

-- กันรันผิดลำดับ: ถ้าของที่ต้องใช้ยังไม่มี ให้หยุดทันที (ไม่สร้างอะไรเลย)
do $guard$
begin
  if to_regprocedure('public.is_contest_admin()') is null then
    raise exception 'ไม่พบ public.is_contest_admin() — กรุณารัน royal_contest_admin_migration.sql ก่อน';
  end if;
  if to_regclass('public.krathongs') is null then
    raise exception 'ไม่พบตาราง public.krathongs — กรุณารัน krathong_02_schema.sql ก่อน';
  end if;
  if to_regclass('public.students') is null or to_regclass('public.votes') is null then
    raise exception 'ไม่พบตาราง students/votes — กรุณารัน royal_contest_schema.sql ก่อน';
  end if;
end
$guard$;

-- ---------------------------------------------------------------------
-- 1) รายการกระทง (ผู้ดูแล)
-- ---------------------------------------------------------------------
create or replace function public.admin_list_krathongs(
  p_limit  integer default 25,
  p_offset integer default 0,
  p_search text    default null)
returns json
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_lim     integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_off     integer := least(greatest(coalesce(p_offset, 0), 0), 1000000);
  v_q       text    := nullif(btrim(left(coalesce(p_search, ''), 100)), '');
  v_pat     text;
  v_total   bigint;
  v_matched bigint;
begin
  if not public.is_contest_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;

  v_pat := case when v_q is null then null
                else '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%' end;

  select count(*) into v_total from public.krathongs;
  select count(*) into v_matched
    from public.krathongs k
   where v_pat is null
      or k.owner ilike v_pat escape '\'
      or k.wish  ilike v_pat escape '\'
      or k.id    ilike v_pat escape '\';

  return json_build_object(
    'ok', true,
    'total', v_total,
    'matched', v_matched,
    'items', coalesce(
      (select json_agg(json_build_object('id', x.id, 'owner', x.owner, 'wish', x.wish,
                                         'design', x.design, 'created_at', x.created_at)
                       order by x.created_at desc, x.id)
         from (select k.id, k.owner, k.wish, k.design, k.created_at
                 from public.krathongs k
                where v_pat is null
                   or k.owner ilike v_pat escape '\'
                   or k.wish  ilike v_pat escape '\'
                   or k.id    ilike v_pat escape '\'
                order by k.created_at desc, k.id
                limit v_lim offset v_off) x),
      '[]'::json));
end;
$fn$;

-- ---------------------------------------------------------------------
-- 2) ลบกระทง 1 รายการ (ลบถาวร — ตาราง krathongs ไม่มีระบบเก็บประวัติ)
-- ---------------------------------------------------------------------
create or replace function public.admin_delete_krathong(p_id text)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n     integer;
  v_total bigint;
begin
  if not public.is_contest_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_id is null or p_id !~ '^k[a-z0-9]{6,40}$' then
    return json_build_object('ok', false, 'error', 'invalid_id');
  end if;

  delete from public.krathongs where id = p_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;

  select count(*) into v_total from public.krathongs;
  return json_build_object('ok', true, 'deleted', p_id, 'total', v_total);
end;
$fn$;

-- ---------------------------------------------------------------------
-- 3) สรุปจำนวนนักเรียน (เฉพาะตัวเลข ไม่คืนรหัสนักเรียน/PIN)
-- ---------------------------------------------------------------------
create or replace function public.admin_students_summary()
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
    'total',    (select count(*) from public.students),
    'active',   (select count(*) from public.students where is_active),
    'inactive', (select count(*) from public.students where not is_active),
    'with_pin', (select count(*) from public.students where pin_hash is not null),
    'voted',    (select count(distinct student_code) from public.votes));
end;
$fn$;

-- ---------------------------------------------------------------------
-- 4) นำเข้ารหัสนักเรียน
--    - ปรับรหัสเป็นตัวพิมพ์ใหญ่ + ตัดช่องว่างหัวท้าย (ตรงกับที่ verify_student ใช้ตรวจ)
--    - ใช้ได้เฉพาะรหัสยาว 3–32 ตัวอักษร ไม่มีช่องว่าง/อักขระควบคุมในรหัส
--    - "เพิ่มเฉพาะรหัสใหม่": รหัสที่มีอยู่แล้วไม่ถูกแตะ (ไม่รีเซ็ต PIN ไม่เปลี่ยน is_active ไม่ล้างสถานะล็อก)
--    - ไม่แตะ votes และไม่เปิดระบบโหวต
--    - คืนเฉพาะจำนวน (+ ตัวอย่างรหัสที่รูปแบบผิดไม่เกิน 10 ค่า เพื่อให้ผู้ดูแลแก้ไฟล์)
-- ---------------------------------------------------------------------
create or replace function public.admin_import_students(p_codes text[])
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ws       constant text    := E' \t\r\n';
  v_max      constant integer := 2000;          -- ต่อหนึ่งคำขอ (หน้าเว็บแบ่งส่งทีละ 500)
  v_received integer;
  v_valid    text[];
  v_invalid  text[];
  v_inserted integer;
begin
  if not public.is_contest_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_codes is null or coalesce(array_length(p_codes, 1), 0) = 0 then
    return json_build_object('ok', false, 'error', 'empty');
  end if;
  if array_length(p_codes, 1) > v_max then
    return json_build_object('ok', false, 'error', 'too_many', 'max', v_max);
  end if;

  select count(*)::int,
         coalesce(array_agg(distinct c) filter (where ok), '{}'::text[]),
         coalesce(array_agg(distinct left(c, 40)) filter (where not ok), '{}'::text[])
    into v_received, v_valid, v_invalid
    from (select s.c,
                 (char_length(s.c) between 3 and 32
                  and s.c ~ '^[^[:space:][:cntrl:]]+$'
                  and s.c = upper(s.c)) as ok
            from (select upper(btrim(x, v_ws)) as c from unnest(p_codes) as x) s
           where s.c is not null and s.c <> '') t;

  with ins as (
    insert into public.students (student_code)
    select unnest(v_valid)
    on conflict (student_code) do nothing
    returning 1)
  select count(*)::int into v_inserted from ins;

  return json_build_object(
    'ok', true,
    'received',       v_received,                                   -- รหัสที่ไม่ว่างทั้งหมดที่ส่งมา
    'valid_unique',   coalesce(array_length(v_valid, 1), 0),        -- รหัสถูกรูปแบบ (ไม่ซ้ำกัน)
    'inserted',       v_inserted,                                   -- เพิ่มใหม่จริง
    'already_exist',  coalesce(array_length(v_valid, 1), 0) - v_inserted,
    'invalid_count',  coalesce(array_length(v_invalid, 1), 0),
    'invalid_sample', to_json(coalesce(v_invalid[1:10], '{}'::text[])));
end;
$fn$;

-- ---------------------------------------------------------------------
-- 5) สิทธิ์การเรียกใช้: ถอนจาก public/anon/authenticated ก่อน แล้วให้เฉพาะ authenticated
--    (ฟังก์ชันตรวจ is_contest_admin() ซ้ำอีกชั้นเสมอ)
-- ---------------------------------------------------------------------
revoke all on function public.admin_list_krathongs(integer, integer, text) from public, anon, authenticated;
revoke all on function public.admin_delete_krathong(text)                  from public, anon, authenticated;
revoke all on function public.admin_students_summary()                     from public, anon, authenticated;
revoke all on function public.admin_import_students(text[])                from public, anon, authenticated;

grant execute on function public.admin_list_krathongs(integer, integer, text) to authenticated;
grant execute on function public.admin_delete_krathong(text)                  to authenticated;
grant execute on function public.admin_students_summary()                     to authenticated;
grant execute on function public.admin_import_students(text[])                to authenticated;
