\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..33';
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
create function pg_temp.report(p_uid uuid,p_resource uuid default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.set_client('authenticated',p_uid);
  select public.admin_get_reservation_report_v2(date '2099-06-01',date '2099-06-01',p_resource,null,null,null,50,0) into r;
  reset role; return r;
exception when others then reset role; raise;
end $f$;
create function pg_temp.export_rows(p_uid uuid,p_resource uuid default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.set_client('authenticated',p_uid);
  select public.admin_get_reservation_report_export_v1(date '2099-06-01',date '2099-06-01',p_resource,null,null,null) into r;
  reset role; return r;
exception when others then reset role; raise;
end $f$;

do $tests$
declare
  tenant_a uuid:=public.active_single_tenant_id_v1();
  tenant_b uuid:=gen_random_uuid();
  admin_a uuid:=gen_random_uuid();
  employee_a uuid:=gen_random_uuid();
  pending_a uuid:=gen_random_uuid();
  suspended_a uuid:=gen_random_uuid();
  global_admin uuid:=gen_random_uuid();
  ordinary_user uuid:=gen_random_uuid();
  lane_a uuid:=gen_random_uuid();
  lane_b uuid:=gen_random_uuid();
  price_a uuid:=gen_random_uuid();
  price_b uuid:=gen_random_uuid();
  run_id text:=replace(gen_random_uuid()::text,'-','');
  report_a jsonb;
  export_a jsonb;
  audit_before bigint;
begin
  insert into public.tenants(id,name,slug,status)
  values(tenant_b,'[TEST][SAAS-9D-4A] Tenant B','saas9d4a-'||run_id,'dormant');

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select actor.id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
         actor.label||'-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values
    (admin_a,'admin-a'),(employee_a,'employee-a'),(pending_a,'pending-a'),
    (suspended_a,'suspended-a'),(global_admin,'global-admin'),(ordinary_user,'user-a')
  ) actor(id,label);

  insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
  select actor.id,actor.legacy_role,'[TEST]',actor.label,
         '[TEST][SAAS-9D-4A] '||actor.label,
         actor.email
  from (values
    (admin_a,'admin','Admin A','admin-a-'||run_id||'@example.invalid'),
    (employee_a,'pracownik','Employee A','employee-a-'||run_id||'@example.invalid'),
    (pending_a,'admin','Pending A','pending-a-'||run_id||'@example.invalid'),
    (suspended_a,'admin','Suspended A','suspended-a-'||run_id||'@example.invalid'),
    (global_admin,'admin','Global Admin','global-admin-'||run_id||'@example.invalid'),
    (ordinary_user,'user','User A','user-a-'||run_id||'@example.invalid')
  ) actor(id,legacy_role,label,email);

  update public.profiles profile
  set role=actor.legacy_role,first_name='[TEST]',last_name=actor.label,
      full_name='[TEST][SAAS-9D-4A] '||actor.label,
      email=actor.label||'-'||run_id||'@example.invalid'
  from (values
    (admin_a,'admin','Admin A'),(employee_a,'pracownik','Employee A'),
    (pending_a,'admin','Pending A'),(suspended_a,'admin','Suspended A'),
    (global_admin,'admin','Global Admin'),(ordinary_user,'user','User A')
  ) actor(id,legacy_role,label)
  where profile.user_id=actor.id;

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_a,admin_a,'admin','active'),
    (tenant_a,employee_a,'employee','active'),
    (tenant_a,pending_a,'admin','pending'),
    (tenant_a,suspended_a,'admin','suspended'),
    (tenant_a,ordinary_user,'user','active')
  on conflict (tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships
  where tenant_id=tenant_a and user_id=global_admin;

  insert into public.shooting_lanes(
    id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,
    display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable
  ) values
    (lane_a,tenant_a,'[TEST][SAAS-9D-4A] Lane A','shooting',true,2,60,9700,'lane',null,true,false),
    (lane_b,tenant_b,'[TEST][SAAS-9D-4A] Lane B','shooting',true,2,60,9701,'lane',null,true,false);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)
  values(lane_a,true,2),(lane_b,true,2);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
  values(price_a,lane_a,'mon_thu',1,2,'A',100),(price_b,lane_b,'mon_thu',1,2,'B',900);

  insert into public.reservations(
    id,tenant_id,user_id,lane_id,customer_name,customer_email,customer_phone,
    reservation_date,start_time,end_time,duration_minutes,price,
    reservation_status,payment_status,attendance_status,shooters_count,
    pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,
    pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,
    creation_request_id
  ) values
    (gen_random_uuid(),tenant_a,ordinary_user,lane_a,'[TEST] Tenant A One','a1-'||run_id||'@example.invalid','111',date '2099-06-01',time '08:00',time '09:00',60,100,'confirmed','paid','planned',1,price_a,'mon_thu','[TEST] Lane A','A',100,100,'PLN',gen_random_uuid()),
    (gen_random_uuid(),tenant_a,ordinary_user,lane_a,'[TEST] Tenant A Two','a2-'||run_id||'@example.invalid','222',date '2099-06-01',time '09:00',time '10:00',60,100,'confirmed','unpaid','planned',1,price_a,'mon_thu','[TEST] Lane A','A',100,100,'PLN',gen_random_uuid()),
    (gen_random_uuid(),tenant_b,ordinary_user,lane_b,'[TEST] TENANT B SECRET','tenant-b-secret-'||run_id||'@example.invalid','999',date '2099-06-01',time '10:00',time '11:00',60,900,'confirmed','paid','planned',1,price_b,'mon_thu','[TEST] Lane B Secret','B',900,900,'PLN',gen_random_uuid());

  select count(*) into audit_before from public.audit_logs;
  report_a:=pg_temp.report(admin_a);
  export_a:=pg_temp.export_rows(admin_a);

  perform pg_temp.ok(1,'exact active signatures',
    to_regprocedure('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)') is not null
    and to_regprocedure('public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)') is not null,
    'active signatures differ');
  perform pg_temp.ok(2,'active RPC metadata',not exists(
    select 1 from pg_proc p join pg_roles owner on owner.oid=p.proowner
    where p.oid in(
      'public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)'::regprocedure,
      'public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)'::regprocedure
    ) and not(p.prosecdef and p.provolatile='s' and owner.rolname='postgres'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])),
    'metadata differs');
  perform pg_temp.ok(3,'active RPC ACL minimal',
    pg_catalog.has_function_privilege('authenticated','public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','EXECUTE'),
    'active RPC ACL differs');
  perform pg_temp.ok(4,'legacy v1 ACL closed',not exists(
    select 1 from (values('public'::name),('anon'::name),('authenticated'::name),('service_role'::name)) role(name)
    where pg_catalog.has_function_privilege(role.name,'public.admin_get_reservation_report_v1(date,date,integer,integer)','EXECUTE')),
    'legacy v1 is executable');
  perform pg_temp.ok(5,'legacy v1 body unchanged',
    md5(replace(replace(pg_get_functiondef('public.admin_get_reservation_report_v1(date,date,integer,integer)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='f0285e0b1f48aba18b2a83d40eda6c44',
    'legacy v1 body drifted');
  perform pg_temp.ok(6,'tenant core closed invoker',exists(
    select 1 from pg_proc p join pg_roles owner on owner.oid=p.proowner
    where p.oid='public._admin_reservation_report_rows_v2__saas9d4a_core(uuid,date,date,uuid,text,text,text)'::regprocedure
      and not p.prosecdef and owner.rolname='postgres'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      and not pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role',p.oid,'EXECUTE')),
    'tenant core metadata/ACL differs');
  perform pg_temp.ok(7,'old helper remains closed',not exists(
    select 1 from (values('public'::name),('anon'::name),('authenticated'::name),('service_role'::name)) role(name)
    where pg_catalog.has_function_privilege(role.name,'public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text)','EXECUTE')),
    'old helper exposed');
  perform pg_temp.ok(8,'SECURITY DEFINER count is 95 after Phase 2',
    (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)=95,
    'definer count differs');
  perform pg_temp.ok(9,'compatibility defaults remain 7/7',
    (select count(*) from information_schema.columns where table_schema='public'
      and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')=7,
    'compatibility defaults differ');
  perform pg_temp.ok(10,'active Tenant A admin allowed',report_a->>'code'='ok','Tenant A admin denied');
  perform pg_temp.ok(11,'global admin without membership denied',pg_temp.report(global_admin)->>'code'='not_allowed','global admin bypassed membership');
  perform pg_temp.ok(12,'pending membership denied',pg_temp.report(pending_a)->>'code'='not_allowed','pending member allowed');
  perform pg_temp.ok(13,'suspended membership denied',pg_temp.report(suspended_a)->>'code'='not_allowed','suspended member allowed');
  perform pg_temp.ok(14,'ordinary user denied',pg_temp.report(ordinary_user)->>'code'='not_allowed','ordinary user allowed');
  perform pg_temp.ok(15,'employee denied by current admin-only contract',pg_temp.report(employee_a)->>'code'='not_allowed','employee scope widened');
  perform pg_temp.ok(16,'Tenant A total excludes Tenant B',(report_a->'pagination'->>'total')::integer=2,'tenant total mixed');
  perform pg_temp.ok(17,'Tenant B PII absent from report',report_a::text not like '%TENANT B SECRET%' and report_a::text not like '%tenant-b-secret-%','Tenant B PII leaked');
  perform pg_temp.ok(18,'resource options contain Tenant A only',
    exists(select 1 from jsonb_array_elements(report_a->'filter_options'->'resources') item where item->>'id'=lane_a::text)
    and not exists(select 1 from jsonb_array_elements(report_a->'filter_options'->'resources') item where item->>'id'=lane_b::text),
    'resource options crossed tenant');
  perform pg_temp.ok(19,'KPI and revenue are Tenant A only',
    (report_a->'summary'->>'active_reservation_count')::integer=2
    and (report_a->'summary'->>'completed_reservation_count')::integer=0
    and (report_a->'summary'->>'planned_revenue')::numeric=200,
    'KPI/revenue mixed tenants');
  perform pg_temp.ok(20,'capacity and occupancy are Tenant A only',
    (report_a->'summary'->>'effective_capacity')::integer=1
    and (report_a->'summary'->>'occupied_minutes')::integer=120,
    'capacity/occupancy mixed tenants');
  perform pg_temp.ok(21,'export contains Tenant A only',(export_a->>'total')::integer=2 and export_a::text not like '%Lane B%' and export_a::text not like '%900%','export mixed tenants');
  perform pg_temp.ok(22,'export remains PII-minimal',export_a::text!~*'(customer|email|phone|address|token|admin_note|user_id)','export contains forbidden PII/internal field');
  perform pg_temp.ok(23,'foreign resource fails closed',pg_temp.report(admin_a,lane_b)->>'code'='invalid_input','foreign resource accepted');
  perform pg_temp.ok(24,'foreign and nonexistent resource are indistinguishable',
    pg_temp.report(admin_a,lane_b)->>'code'=pg_temp.report(admin_a,gen_random_uuid())->>'code',
    'resource existence leaked');
  perform pg_temp.ok(25,'export foreign resource fails closed',pg_temp.export_rows(admin_a,lane_b)->>'code'='invalid_input','foreign export resource accepted');
  perform pg_temp.ok(26,'global role source removed from active report bodies',not exists(
    select 1 from pg_proc p where p.oid in(
      'public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)'::regprocedure,
      'public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)'::regprocedure
    ) and p.prosrc~'profile[.]role'),
    'active report still reads profiles.role');
  perform pg_temp.ok(27,'membership helper present in both active bodies',
    (select count(*) from pg_proc p where p.oid in(
      'public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)'::regprocedure,
      'public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)'::regprocedure
    ) and strpos(p.prosrc,'get_my_tenant_role_v1(v_tenant_id)')>0)=2,
    'membership authorization missing');
  perform pg_temp.ok(28,'active single tenant bridge exact',tenant_a is not null and (select count(*) from public.tenants where status='active')=1,'active-single bridge differs');
  perform pg_temp.ok(29,'profile administration follows approved 4B-2C closure',
    exists(select 1 from pg_proc where oid='public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure and prosrc~'\mget_my_tenant_role_v1\M' and prosrc~'\mtenant_user_admin_notes\M' and prosrc!~'profile[.]admin_note')
    and md5(replace(replace(pg_get_functiondef('public.update_profile_verification(uuid,text,text)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='022baa5652409d2246cd5e66642e884e',
    '4B-1A list or closed verification contract drifted.');
  perform pg_temp.ok(30,'account lifecycle contract untouched',
    md5(replace(replace(pg_get_functiondef('public.export_my_data_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='d159b7d0a14f7ffc9d6c3e5088d18dc5'
    and md5(replace(replace(pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='70b5f590399aa3f3a147935459b7f085',
    '4C account-wide contract drifted');
  perform pg_temp.ok(31,'report reads create no audit',(select count(*) from public.audit_logs)=audit_before,'read-only report created audit');
  perform pg_temp.ok(32,'no report RLS policy added',not exists(select 1 from pg_policies where schemaname='public' and policyname like '%SAAS-9D-4A%'),'RLS widened');
  perform pg_temp.ok(33,'tenant core has explicit reservation and lane predicates',exists(
    select 1 from pg_proc p
    where p.oid='public._admin_reservation_report_rows_v2__saas9d4a_core(uuid,date,date,uuid,text,text,text)'::regprocedure
      and strpos(p.prosrc,'reservation.tenant_id=p_tenant_id')>0
      and strpos(p.prosrc,'resource.tenant_id=p_tenant_id')>0),
    'tenant predicates missing');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||n||' - '||name||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by n;
do $assert$
declare failed text;
begin
  select string_agg(n||'. '||name||': '||result,E'\n' order by n) into failed from pg_temp.test_results where not passed;
  if (select count(*) from pg_temp.test_results)<>33 then raise exception 'SAAS-9D-4A expected 33 checks'; end if;
  if failed is not null then raise exception E'SAAS-9D-4A failures:\n%',failed; end if;
end;
$assert$;
rollback;
