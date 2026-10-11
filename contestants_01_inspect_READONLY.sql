-- =====================================================================
-- Loy Krathong KDS 2026 · ตรวจสอบผู้เข้าประกวดตัวอย่าง 9 คน (อ่านอย่างเดียว ไม่แก้ ไม่ลบอะไร)
--
-- วิธีใช้: Supabase Dashboard → โปรเจกต์ vnunuryoqyhuendcvopm → SQL Editor
--          วางทีละบล็อก (A–G) กด Run แล้วส่งผลลัพธ์ทั้งหมดให้ผม
-- ทุกบล็อกเป็น SELECT ล้วน ๆ และไม่แสดงรหัสนักเรียน (แสดงเฉพาะจำนวน)
-- ใช้ to_jsonb(c) เพื่อให้รันได้แม้ยังไม่ได้รัน admin migration (คอลัมน์ใหม่จะขึ้นเป็น null)
-- =====================================================================

-- A) ผู้เข้าประกวดทุกแถวในตาราง พร้อมเทียบกับข้อมูลตัวอย่างจาก royal_contest_schema.sql
--    matches_original_seed = true  แปลว่า id/เวที/หมายเลข/ชื่อ/ห้อง ตรงกับที่ SQL เดิมใส่ไว้ทุกช่อง
with seed(id, category, number, name, class_name) as (values
  (1,'nn',1,'พิมพ์ชนก','ม.5/1'), (2,'nn',2,'ณัฐรดา','ม.4/2'),  (3,'nn',3,'ธัญญ์ชนก','ม.6/3'),
  (4,'nt',1,'กัญญ์วรา','ม.5/4'), (5,'nt',2,'ปวีณ์ธิดา','ม.4/1'), (6,'nt',3,'ศศิธร','ม.6/2'),
  (7,'tk',1,'ภูมิพัฒน์','ม.5/2'), (8,'tk',2,'ธีรภัทร','ม.6/1'),  (9,'tk',3,'กวินภพ','ม.4/3'))
select c.id, c.category, c.number, c.name, c.class_name,
       (s.id is not null)                                   as matches_original_seed,
       to_jsonb(c)->>'is_published'                         as is_published,
       to_jsonb(c)->>'voting_enabled'                       as voting_enabled,
       to_jsonb(c)->>'deleted_at'                           as deleted_at,
       to_jsonb(c)->>'created_at'                           as created_at,
       to_jsonb(c)->>'updated_at'                           as updated_at,
       (to_jsonb(c)->>'photo_path')                         as photo_path,
       (to_jsonb(c)->>'bio') is not null
         or (to_jsonb(c)->>'insp') is not null
         or (to_jsonb(c)->>'extra') is not null
         or (to_jsonb(c)->>'nickname') is not null          as has_extra_text
  from public.contestants c
  left join seed s on s.id = c.id and s.category = c.category and s.number = c.number
                  and s.name = c.name and s.class_name is not distinct from c.class_name
 order by c.id;

-- B) สรุปว่ามีแถวตัวอย่างกี่แถว และมีแถวอื่นที่ "ไม่ใช่" ตัวอย่างอยู่ด้วยหรือไม่
with seed(id, category, number, name, class_name) as (values
  (1,'nn',1,'พิมพ์ชนก','ม.5/1'), (2,'nn',2,'ณัฐรดา','ม.4/2'),  (3,'nn',3,'ธัญญ์ชนก','ม.6/3'),
  (4,'nt',1,'กัญญ์วรา','ม.5/4'), (5,'nt',2,'ปวีณ์ธิดา','ม.4/1'), (6,'nt',3,'ศศิธร','ม.6/2'),
  (7,'tk',1,'ภูมิพัฒน์','ม.5/2'), (8,'tk',2,'ธีรภัทร','ม.6/1'),  (9,'tk',3,'กวินภพ','ม.4/3'))
select (select count(*) from public.contestants)                                   as total_contestants,
       (select count(*) from public.contestants c join seed s
           on s.id=c.id and s.category=c.category and s.number=c.number
          and s.name=c.name and s.class_name is not distinct from c.class_name)    as rows_matching_original_seed,
       (select count(*) from public.contestants c where not exists (select 1 from seed s
           where s.id=c.id and s.category=c.category and s.number=c.number
             and s.name=c.name and s.class_name is not distinct from c.class_name)) as rows_NOT_matching_seed;

-- C) คะแนนโหวตที่ผูกกับผู้เข้าประกวดแต่ละคน (นับจากตาราง votes จริง)
select c.id, c.category, c.number, c.name,
       count(v.*)                     as vote_rows,
       min(v.created_at)              as first_vote_at,
       max(v.created_at)              as last_vote_at
  from public.contestants c
  left join public.votes v on v.contestant_id = c.id
 group by c.id, c.category, c.number, c.name
 order by c.id;

-- D) ภาพรวมการโหวตทั้งระบบ (เฉพาะจำนวน ไม่แสดงรหัสนักเรียน)
select (select count(*) from public.votes)                          as votes_total,
       (select count(distinct student_code) from public.votes)      as distinct_students_who_voted,
       (select count(*) from public.votes
         where contestant_id not between 1 and 9)                   as votes_for_contestants_outside_1_to_9,
       (select count(*) from public.students)                       as students_rows,
       (select voting_open  from public.contest_settings where id)  as voting_open,
       (select require_pin  from public.contest_settings where id)  as require_pin;

-- E) ตารางไหนอ้างอิง (foreign key) มาที่ contestants บ้าง และถ้าลบผู้เข้าประกวดจะเกิดอะไรขึ้น
--    on_delete: a = NO ACTION (ลบไม่ได้ถ้ายังมีแถวอ้างอิง) · c = CASCADE (ลบตามอัตโนมัติ) · r = RESTRICT · n = SET NULL
select con.conrelid::regclass  as referencing_table,
       con.conname,
       con.confdeltype         as on_delete,
       pg_get_constraintdef(con.oid) as definition
  from pg_constraint con
 where con.contype = 'f' and con.confrelid = 'public.contestants'::regclass;

-- F) ไฟล์รูปใน Storage ที่อาจผูกกับผู้เข้าประกวด (ถ้ามี bucket contestant-photos จาก admin migration)
select (select count(*) from storage.objects where bucket_id = 'contestant-photos')           as photo_objects_in_bucket,
       (select count(*) from public.contestants
         where to_jsonb(contestants)->>'photo_path' is not null)                              as contestants_with_photo_path;

-- G) สถานะตัวนับ id สำหรับผู้เข้าประกวดใหม่ (ข้อมูลประกอบ ไม่กระทบการตัดสินใจ)
--    หลังลบตัวอย่าง คนใหม่จะเริ่มที่ id ถัดจาก last_value นี้ (ไม่ย้อนกลับไป 1) ซึ่งไม่มีผลต่อการใช้งาน
select schemaname, sequencename, last_value
  from pg_sequences
 where schemaname = 'public' and sequencename = 'contestants_id_seq';
