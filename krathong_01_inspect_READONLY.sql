-- =====================================================================
-- Loy Krathong KDS 2026 · ขั้นที่ 1: ตรวจสอบฐานข้อมูล (อ่านอย่างเดียว ไม่แก้ ไม่ลบอะไร)
--
-- วิธีใช้: Supabase Dashboard → เลือกโปรเจกต์ (ต้องเป็นโปรเจกต์ vnunuryoqyhuendcvopm)
--          → SQL Editor → วางทีละบล็อก (A, B, C, D) กด Run → ส่งผลลัพธ์ให้ผมดู
-- ทุกบล็อกเป็น SELECT ล้วน ๆ
-- =====================================================================

-- A) ยืนยันว่าอยู่ฐานข้อมูลไหน (เทียบกับชื่อโปรเจกต์ที่มุมซ้ายบนของ Dashboard)
select current_database() as db, current_user as db_user, now() as checked_at;

-- B) จำนวนแถวจริงของ "ทุกตาราง" ในสคีมา public (นับแบบตรง ๆ ไม่ใช่ค่าประมาณ)
select table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint as row_count
  from information_schema.tables
 where table_schema = 'public' and table_type = 'BASE TABLE'
 order by table_name;

-- C) หาตาราง/คอลัมน์ที่น่าจะเก็บกระทงหรือคำอธิษฐาน (ทุกสคีมาที่ไม่ใช่ของระบบ)
select table_schema, table_name, column_name, data_type
  from information_schema.columns
 where table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','extensions','vault','graphql','graphql_public','pgsodium','supabase_migrations','net','pgbouncer','_realtime')
   and (table_name ilike '%krathong%' or table_name ilike '%wish%' or table_name ilike '%float%'
        or column_name ilike '%krathong%' or column_name ilike '%wish%')
 order by table_schema, table_name, ordinal_position;

-- D) สถานะระบบประกวด/โหวต (เพื่อดูว่า SQL ชุดก่อนหน้ารันไปแล้วหรือยัง) — ไม่แสดงรหัสนักเรียน
select
  (select count(*) from information_schema.tables where table_schema='public' and table_name='students')            as has_students_table,
  (select count(*) from public.students)                                                                           as students_rows,
  (select count(*) from public.votes)                                                                              as votes_rows,
  (select voting_open from public.contest_settings where id)                                                       as voting_open,
  exists (select 1 from information_schema.columns where table_schema='public' and table_name='contestants' and column_name='is_published') as admin_migration_applied,
  (select count(*) from public.contestants)                                                                        as contestants_rows,
  (select string_agg(routine_name, ', ' order by routine_name) from information_schema.routines
    where routine_schema='public' and routine_name in ('get_contest_config','get_results','get_my_votes','cast_vote','get_contestants','add_krathong','get_krathongs')) as rpc_present;
