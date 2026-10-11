-- =====================================================================
-- Loy Krathong KDS 2026 · ตรวจสอบก่อน/หลังติดตั้งหน้า Admin (อ่านอย่างเดียว ไม่แก้ ไม่ลบอะไร)
-- วิธีใช้: Supabase Dashboard → SQL Editor → วางทีละบล็อก (A–E) กด Run → ส่งผลลัพธ์ให้ผมดู
-- ไม่แสดงรหัสนักเรียน อีเมล หรือ user id ใด ๆ (แสดงเฉพาะจำนวน/สถานะ)
-- =====================================================================

-- A) ฟังก์ชันที่หน้า Admin ใช้: มีอยู่จริงไหม + ใครเรียกได้
--    ผลที่ถูกต้อง: anon_can_execute = false ทุกแถวที่ขึ้นต้นด้วย admin_ และ is_contest_admin ; authenticated_can_execute = true
--    ถ้าแถว admin_list_krathongs / admin_delete_krathong / admin_students_summary / admin_import_students ยังไม่ขึ้น = ยังไม่ได้รัน royal_contest_admin_tools.sql
select p.proname,
       pg_get_function_identity_arguments(p.oid)               as args,
       p.prosecdef                                             as security_definer,
       has_function_privilege('anon',          p.oid, 'execute') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_can_execute
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('is_contest_admin','admin_list_contestants','admin_save_contestant','admin_delete_contestant',
                     'admin_restore_contestant','admin_list_krathongs','admin_delete_krathong',
                     'admin_students_summary','admin_import_students',
                     'add_krathong','get_krathongs','get_contest_config','get_results','get_contestants','cast_vote','get_my_votes')
 order by p.proname;

-- B) RLS ต้องเปิดทุกตาราง (rls_enabled = true) และ anon/authenticated ต้องไม่มีสิทธิ์ตารางโดยตรง (ทุกช่อง false)
select c.relname                                                   as table_name,
       c.relrowsecurity                                            as rls_enabled,
       has_table_privilege('anon',          c.oid, 'select,insert,update,delete') as anon_any_direct_access,
       has_table_privilege('authenticated', c.oid, 'select,insert,update,delete') as authenticated_any_direct_access
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
   and c.relname in ('contest_admins','students','votes','contestants','contest_settings','krathongs')
 order by c.relname;

-- C) มีผู้ดูแลกี่คนในตาราง contest_admins (นับเฉพาะจำนวน ถ้า = 0 จะล็อกอินเข้าหน้า Admin ไม่ได้)
select count(*) as admin_count from public.contest_admins;

-- D) สถานะระบบโหวต (หน้า Admin ไม่แตะค่านี้ — ควรเป็น false จนกว่าจะถึงเวลาเปิดเอง)
select voting_open, require_pin from public.contest_settings where id;

-- E) ตารางกระทง: โครงสร้างต้องมี 5 คอลัมน์ id, owner, wish, design, created_at และจำนวนแถวปัจจุบัน
select (select string_agg(column_name, ', ' order by ordinal_position)
          from information_schema.columns
         where table_schema = 'public' and table_name = 'krathongs') as krathongs_columns,
       (select count(*) from public.krathongs)                       as krathongs_rows,
       (select count(*) from public.students)                        as students_rows;
