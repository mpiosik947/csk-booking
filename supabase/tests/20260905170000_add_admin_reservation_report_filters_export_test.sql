\set ON_ERROR_STOP on
\pset format unaligned

select '1..34';
begin;

create temporary table test_results(n integer primary key,name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $f$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$f$;
create function pg_temp.set_client(p_role text,p_uid uuid) returns void language plpgsql as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_uid,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end $f$;
create function pg_temp.report(p_uid uuid,p_from date,p_to date,p_resource uuid default null,p_status text default null,p_payment text default null,p_type text default null,p_limit integer default 50,p_offset integer default 0) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.set_client('authenticated',p_uid);
  select public.admin_get_reservation_report_v2(p_from,p_to,p_resource,p_status,p_payment,p_type,p_limit,p_offset) into r;
  reset role; return r;
exception when others then reset role; raise;
end $f$;
create function pg_temp.export_rows(p_uid uuid,p_from date,p_to date,p_resource uuid default null,p_status text default null,p_payment text default null,p_type text default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.set_client('authenticated',p_uid);
  select public.admin_get_reservation_report_export_v1(p_from,p_to,p_resource,p_status,p_payment,p_type) into r;
  reset role; return r;
exception when others then reset role; raise;
end $f$;

do $tests$
declare
  a uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); i uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
  root_id uuid:=gen_random_uuid(); child_id uuid:=gen_random_uuid(); sibling_id uuid:=gen_random_uuid(); standalone_id uuid:=gen_random_uuid();
  pr uuid:=gen_random_uuid(); pc uuid:=gen_random_uuid(); ps uuid:=gen_random_uuid(); pst uuid:=gen_random_uuid();
  run_id text:=replace(gen_random_uuid()::text,'-',''); r jsonb; x jsonb; p1 jsonb; p2 jsonb; v1_hash text;
begin
  select encode(digest(pg_get_functiondef('public.admin_get_reservation_report_v1(date,date,integer,integer)'::regprocedure),'sha256'),'hex') into v1_hash;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
    (a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','reports6b-admin-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now()),
    (e,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','reports6b-employee-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now()),
    (i,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','reports6b-instructor-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now()),
    (u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','reports6b-user-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
  select v.uid,v.role,'[TEST]',v.label,'[TEST][REPORTS-6B] '||v.label,v.email
  from (values(a,'admin','Admin','reports6b-admin-'||run_id||'@example.invalid'),(e,'pracownik','Employee','reports6b-employee-'||run_id||'@example.invalid'),(i,'instruktor','Instructor','reports6b-instructor-'||run_id||'@example.invalid'),(u,'user','User','reports6b-user-'||run_id||'@example.invalid')) v(uid,role,label,email)
  where not exists(select 1 from public.profiles p where p.user_id=v.uid);
  update public.profiles p set role=v.role,first_name='[TEST]',last_name=v.label,full_name='[TEST][REPORTS-6B] '||v.label,email=v.email
  from (values(a,'admin','Admin','reports6b-admin-'||run_id||'@example.invalid'),(e,'pracownik','Employee','reports6b-employee-'||run_id||'@example.invalid'),(i,'instruktor','Instructor','reports6b-instructor-'||run_id||'@example.invalid'),(u,'user','User','reports6b-user-'||run_id||'@example.invalid')) v(uid,role,label,email)
  where p.user_id=v.uid;

  insert into public.shooting_lanes(id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values
    (root_id,'[TEST][REPORTS-6B] Root','shooting',true,2,60,9800,'lane',null,true,true),
    (child_id,'=SUM(A1:A2); "Pozycja"','shooting',true,1,60,9801,'position',root_id,false,false),
    (sibling_id,'[TEST][REPORTS-6B] Sibling','shooting',true,1,60,9802,'position',root_id,false,false),
    (standalone_id,'[TEST][REPORTS-6B] Standalone','shooting',true,1,60,9803,'lane',null,true,false);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online) values(root_id,true,2),(child_id,true,1),(sibling_id,true,1),(standalone_id,true,1);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price) values
    (pr,root_id,'mon_thu',1,2,'Root',100),(pc,child_id,'mon_thu',1,1,'Child',50),(ps,sibling_id,'mon_thu',1,1,'Sibling',70),(pst,standalone_id,'mon_thu',1,1,'Standalone',40);

  insert into public.reservations(id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,checked_in_at,completed_at,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id) values
    (gen_random_uuid(),u,root_id,'[TEST] Root','root-'||run_id||'@example.invalid','1',date '2099-03-29',time '08:00',time '10:00',120,100,'confirmed','paid','planned',null,null,2,pr,'mon_thu','[TEST][REPORTS-6B] Root','Root',50,100,'PLN',gen_random_uuid()),
    (gen_random_uuid(),u,child_id,'[TEST] Child','child-'||run_id||'@example.invalid','2',date '2099-03-29',time '09:00',time '10:00',60,50,'confirmed','unpaid','planned',null,null,1,pc,'mon_thu','=SUM(A1:A2); "Pozycja"','Child',50,50,'PLN',gen_random_uuid()),
    (gen_random_uuid(),u,sibling_id,'[TEST] Sibling','sibling-'||run_id||'@example.invalid','3',date '2099-03-29',time '10:00',time '11:00',60,70,'completed','paid_on_site','completed',now(),now(),1,ps,'mon_thu','[TEST][REPORTS-6B] Sibling','Sibling',70,70,'PLN',gen_random_uuid()),
    (gen_random_uuid(),u,standalone_id,'[TEST] Cancelled','cancelled-'||run_id||'@example.invalid','4',date '2099-03-29',time '11:00',time '12:00',60,0,'cancelled_by_user','free','planned',null,null,1,pst,'mon_thu','[TEST][REPORTS-6B] Standalone','Free',0,0,'PLN',gen_random_uuid()),
    (gen_random_uuid(),u,child_id,'[TEST] No show','noshow-'||run_id||'@example.invalid','5',date '2099-03-29',time '12:00',time '13:00',60,80,'no_show','voucher','no_show',null,null,1,pc,'mon_thu','=SUM(A1:A2); "Pozycja"','Voucher',80,80,'PLN',gen_random_uuid());

  perform pg_temp.ok(1,'exact signatures',to_regprocedure('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)') is not null and to_regprocedure('public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)') is not null,'v2 and export must exist');
  perform pg_temp.ok(2,'security properties',not exists(select 1 from pg_proc p join pg_roles o on o.oid=p.proowner where p.oid in('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)'::regprocedure,'public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)'::regprocedure) and not(p.prosecdef and p.provolatile='s' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and o.rolname='postgres')),'security properties differ');
  perform pg_temp.ok(3,'least privilege ACL',pg_catalog.has_function_privilege('authenticated','public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','EXECUTE') and pg_catalog.has_function_privilege('authenticated','public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','EXECUTE'),'ACL differs');
  perform pg_temp.ok(4,'private helper not executable',not pg_catalog.has_function_privilege('authenticated','public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text)','EXECUTE'),'helper exposed');
  perform pg_temp.ok(5,'admin allowed',pg_temp.report(a,date '2099-03-29',date '2099-03-29')->>'code'='ok','admin denied');
  perform pg_temp.ok(6,'employee denied',pg_temp.report(e,date '2099-03-29',date '2099-03-29')->>'code'='not_allowed','employee allowed');
  perform pg_temp.ok(7,'instructor denied',pg_temp.report(i,date '2099-03-29',date '2099-03-29')->>'code'='not_allowed','instructor allowed');
  perform pg_temp.ok(8,'user denied',pg_temp.report(u,date '2099-03-29',date '2099-03-29')->>'code'='not_allowed','user allowed');

  r:=pg_temp.report(a,date '2099-03-29',date '2099-03-29');
  perform pg_temp.ok(9,'unfiltered total and canonical KPI',(r->'pagination'->>'total')::integer=5 and (r->'summary'->>'active_reservation_count')::integer=2 and (r->'summary'->>'planned_revenue')::numeric=220,'unfiltered result differs');
  perform pg_temp.ok(10,'720 minute and DST safe',(r->'range'->>'days')::integer=1 and (r->'range'->>'opening_minutes_per_day')::integer=720,'range differs');
  x:=pg_temp.report(a,date '2099-03-29',date '2099-03-29',root_id);
  perform pg_temp.ok(11,'parent includes root and children',(x->'pagination'->>'total')::integer=4 and (x->'summary'->>'effective_capacity')::integer=2,'parent filter differs');
  x:=pg_temp.report(a,date '2099-03-29',date '2099-03-29',child_id);
  perform pg_temp.ok(12,'child is exact',(x->'pagination'->>'total')::integer=2 and (x->'summary'->>'effective_capacity')::integer=1 and not exists(select 1 from jsonb_array_elements(x->'details') d where d->>'lane_id'<>child_id::text),'child filter differs');
  perform pg_temp.ok(13,'standalone exact',(pg_temp.report(a,date '2099-03-29',date '2099-03-29',standalone_id)->'pagination'->>'total')::integer=1,'standalone filter differs');
  perform pg_temp.ok(14,'whole lane type',(pg_temp.report(a,date '2099-03-29',date '2099-03-29',null,null,null,'whole_lane')->'pagination'->>'total')::integer=2,'whole type differs');
  perform pg_temp.ok(15,'position type',(pg_temp.report(a,date '2099-03-29',date '2099-03-29',null,null,null,'single_position')->'pagination'->>'total')::integer=3,'position type differs');
  perform pg_temp.ok(16,'confirmed status',(pg_temp.report(a,date '2099-03-29',date '2099-03-29',null,'confirmed')->'pagination'->>'total')::integer=2,'status filter differs');
  perform pg_temp.ok(17,'cancelled category',(pg_temp.report(a,date '2099-03-29',date '2099-03-29',null,'cancelled')->'pagination'->>'total')::integer=1,'cancelled category differs');
  perform pg_temp.ok(18,'payment status',(pg_temp.report(a,date '2099-03-29',date '2099-03-29',null,null,'paid')->'pagination'->>'total')::integer=1,'payment filter differs');
  x:=pg_temp.report(a,date '2099-03-29',date '2099-03-29',root_id,'confirmed','paid','whole_lane');
  perform pg_temp.ok(19,'combined filters keep KPI and details aligned',(x->'pagination'->>'total')::integer=1 and jsonb_array_length(x->'details')=1 and (x->'summary'->>'active_reservation_count')::integer=1 and (x->'summary'->>'planned_revenue')::numeric=100,'combined filters differ');
  perform pg_temp.ok(20,'empty result complete',(pg_temp.report(a,date '2099-04-01',date '2099-04-01')->'pagination'->>'total')::integer=0 and jsonb_array_length(pg_temp.report(a,date '2099-04-01',date '2099-04-01')->'details')=0,'empty result differs');
  perform pg_temp.ok(21,'invalid filters controlled',pg_temp.report(a,date '2099-03-29',date '2099-03-29',null,'bad')->>'code'='invalid_input' and pg_temp.report(a,date '2099-03-29',date '2099-03-29',gen_random_uuid())->>'code'='invalid_input','invalid filters accepted');
  perform pg_temp.ok(22,'filter echo exact',x->'filters'=jsonb_build_object('start_date',date '2099-03-29','end_date',date '2099-03-29','resource_id',root_id,'reservation_status','confirmed','payment_status','paid','booking_type','whole_lane'),'filter echo differs');
  perform pg_temp.ok(23,'resource options retain hierarchy',exists(select 1 from jsonb_array_elements(r->'filter_options'->'resources') o where o->>'id'=child_id::text and o->>'parent_lane_id'=root_id::text and o->>'display_name' like '% — =SUM%'),'resource options differ');

  x:=pg_temp.export_rows(a,date '2099-03-29',date '2099-03-29');
  perform pg_temp.ok(24,'export all filtered rows',(x->>'total')::integer=5 and jsonb_array_length(x->'rows')=5,'export total differs');
  perform pg_temp.ok(25,'export exact PII-minimal shape',not(x::text~*'(customer|email|phone|address|token|admin_note|user_id)') and not exists(select 1 from jsonb_array_elements(x->'rows') row where (select array_agg(k order by k) from jsonb_object_keys(row) k)<>array['booking_type','end_time','payment_status','reservation_date','reservation_status','resource_label','start_time','total_price']::text[]),'export exposes extra fields');
  x:=pg_temp.export_rows(a,date '2099-03-29',date '2099-03-29',child_id,'confirmed','unpaid','single_position');
  perform pg_temp.ok(26,'export respects combined filters',(x->>'total')::integer=1 and x->'rows'->0->>'booking_type'='single_position' and x->'rows'->0->>'payment_status'='unpaid','export filters differ');
  perform pg_temp.ok(27,'export empty result',(pg_temp.export_rows(a,date '2099-04-01',date '2099-04-01')->>'total')::integer=0,'empty export differs');
  perform pg_temp.ok(28,'export roles denied',pg_temp.export_rows(e,date '2099-03-29',date '2099-03-29')->>'code'='not_allowed' and pg_temp.export_rows(i,date '2099-03-29',date '2099-03-29')->>'code'='not_allowed' and pg_temp.export_rows(u,date '2099-03-29',date '2099-03-29')->>'code'='not_allowed','export role allowed');

  insert into public.reservations(id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  select gen_random_uuid(),u,standalone_id,'[TEST] Bulk','bulk-'||g||'-'||run_id||'@example.invalid','9',date '2099-05-01',time '14:00',time '15:00',60,0,'cancelled','free','planned',1,pst,'mon_thu','[TEST][REPORTS-6B] Standalone','Bulk',0,0,'PLN',gen_random_uuid() from generate_series(1,500) g;
  x:=pg_temp.export_rows(a,date '2099-05-01',date '2099-05-01');
  perform pg_temp.ok(29,'500 row export succeeds',x->>'code'='ok' and (x->>'total')::integer=500 and jsonb_array_length(x->'rows')=500,'500 row export differs');
  insert into public.reservations(id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  select gen_random_uuid(),u,standalone_id,'[TEST] Bulk','bulk-'||g||'-'||run_id||'@example.invalid','9',date '2099-05-01',time '14:00',time '15:00',60,0,'cancelled','free','planned',1,pst,'mon_thu','[TEST][REPORTS-6B] Standalone','Bulk',0,0,'PLN',gen_random_uuid() from generate_series(501,5000) g;
  x:=pg_temp.export_rows(a,date '2099-05-01',date '2099-05-01');
  perform pg_temp.ok(30,'5000 row export succeeds',x->>'code'='ok' and (x->>'total')::integer=5000 and jsonb_array_length(x->'rows')=5000,'5000 row export differs');
  insert into public.reservations(id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values(gen_random_uuid(),u,standalone_id,'[TEST] Bulk','bulk-5001-'||run_id||'@example.invalid','9',date '2099-05-01',time '14:00',time '15:00',60,0,'cancelled','free','planned',1,pst,'mon_thu','[TEST][REPORTS-6B] Standalone','Bulk',0,0,'PLN',gen_random_uuid());
  x:=pg_temp.export_rows(a,date '2099-05-01',date '2099-05-01');
  perform pg_temp.ok(31,'export above 5000 fails closed',x->>'code'='export_too_large' and (x->>'total')::integer=5001 and (x->>'max_rows')::integer=5000 and not(x?'rows'),'large export not bounded');
  p1:=pg_temp.report(a,date '2099-05-01',date '2099-05-01',null,null,null,null,50,0);
  p2:=pg_temp.report(a,date '2099-05-01',date '2099-05-01',null,null,null,null,50,50);
  perform pg_temp.ok(32,'pagination stable and KPI page independent',jsonb_array_length(p1->'details')=50 and jsonb_array_length(p2->'details')=50 and p1->'summary'=p2->'summary' and not exists(select 1 from jsonb_array_elements(p1->'details') q1 join jsonb_array_elements(p2->'details') q2 on q1->>'id'=q2->>'id'),'pagination differs');
  perform pg_temp.ok(33,'REPORTS-6A v1 unchanged',v1_hash=encode(digest(pg_get_functiondef('public.admin_get_reservation_report_v1(date,date,integer,integer)'::regprocedure),'sha256'),'hex'),'v1 changed');
  perform pg_temp.ok(34,'no RLS widening',not exists(select 1 from pg_policies where schemaname='public' and policyname like '%REPORTS-6B%'),'RLS widened');
end
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||n||' - '||name||case when passed then '' else E'\n# '||result end from pg_temp.test_results order by n;
do $assert$
declare failed text;
begin
  select string_agg(n||'. '||name||': '||result,E'\n' order by n) into failed from pg_temp.test_results where not passed;
  if (select count(*) from pg_temp.test_results)<>34 then raise exception 'REPORTS-6B expected 34 checks'; end if;
  if failed is not null then raise exception E'REPORTS-6B failures:\n%',failed; end if;
end
$assert$;
rollback;
