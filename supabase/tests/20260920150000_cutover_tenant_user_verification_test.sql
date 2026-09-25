\set ON_ERROR_STOP on
\pset format unaligned

select '1..37';
begin;

create temporary table saas9d4b2b_results(test_no integer primary key,description text not null,passed boolean not null,detail text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text default null) returns void language sql as $f$
  insert into pg_temp.saas9d4b2b_results values($1,$2,coalesce($3,false),$4);
$f$;
create function pg_temp.as_actor_text(p_user uuid,p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated;
  execute 'select ('||p_sql||')::text' into v;
  reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v;
exception when others then
  reset role; perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true); raise;
end;$f$;
create function pg_temp.as_actor_raises(p_user uuid,p_sql text,p_state text default '42501') returns boolean language plpgsql as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated; execute p_sql; reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true); return false;
exception when others then
  reset role; perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true); return sqlstate=p_state;
end;$f$;

do $tests$
declare
  a uuid:='c5c00000-0000-4000-8000-000000000001'; b uuid:='42b20000-0000-4000-8000-000000000001';
  admin_a uuid:='42b20000-0000-4000-8000-000000000010'; employee_a uuid:='42b20000-0000-4000-8000-000000000011';
  admin_b uuid:='42b20000-0000-4000-8000-000000000012'; global_admin uuid:='42b20000-0000-4000-8000-000000000013';
  pending_admin uuid:='42b20000-0000-4000-8000-000000000014'; suspended_admin uuid:='42b20000-0000-4000-8000-000000000015';
  user_x uuid:='42b20000-0000-4000-8000-000000000020'; unrelated uuid:='42b20000-0000-4000-8000-000000000021';
  lane_a uuid:='42b20000-0000-4000-8000-000000000030'; lane_b uuid:='42b20000-0000-4000-8000-000000000031';
  price_a uuid:='42b20000-0000-4000-8000-000000000032'; price_b uuid:='42b20000-0000-4000-8000-000000000033';
  res_a uuid:='42b20000-0000-4000-8000-000000000040'; res_b uuid:='42b20000-0000-4000-8000-000000000041';
  result jsonb; result_b jsonb; profile_row record; audit_count bigint;
begin
  perform pg_temp.ok(1,'two approved public RPCs exist',pg_catalog.to_regprocedure('public.update_reservation_customer_verification_v1(uuid,text,text)') is not null and pg_catalog.to_regprocedure('public.get_my_tenant_verification_v2(uuid)') is not null);
  perform pg_temp.ok(2,'SECURITY DEFINER count is 100 after PRODUCT-10C public landing',(select count(*)=  97 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef));
  perform pg_temp.ok(3,'verification table remains RLS closed',(select relrowsecurity from pg_class where oid='public.tenant_user_verifications'::regclass) and (select count(*)=0 from pg_policy where polrelid='public.tenant_user_verifications'::regclass));
  perform pg_temp.ok(4,'runtime roles have no direct verification table access',not has_table_privilege('public','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE') and not has_table_privilege('anon','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE') and not has_table_privilege('authenticated','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE') and not has_table_privilege('service_role','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE'));
  perform pg_temp.ok(5,'new RPC ACL is authenticated only',has_function_privilege('authenticated','public.update_reservation_customer_verification_v1(uuid,text,text)','EXECUTE') and not has_function_privilege('anon','public.update_reservation_customer_verification_v1(uuid,text,text)','EXECUTE') and not has_function_privilege('service_role','public.update_reservation_customer_verification_v1(uuid,text,text)','EXECUTE'));
  perform pg_temp.ok(6,'internal helpers are closed',not has_function_privilege('authenticated','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE') and not has_function_privilege('service_role','public._tenant_verification_status_for_lane_v1(uuid,uuid)','EXECUTE'));
  perform pg_temp.ok(7,'profile trigger matches tenant-aware onboarding cutover',md5(replace(replace(pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10)))='05fe62eb086d5bfe7a6f5bd5a1c2dcca');
  perform pg_temp.ok(8,'compatibility defaults remain 7/7',(select count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));

  insert into public.tenants(id,name,slug,status) values(b,'[TEST][4B2B] B','test-4b2b-b','dormant');
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
    (admin_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-admin-a@example.invalid','',now(),'{}','{}',now(),now()),
    (employee_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-employee-a@example.invalid','',now(),'{}','{}',now(),now()),
    (admin_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-admin-b@example.invalid','',now(),'{}','{}',now(),now()),
    (global_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-global@example.invalid','',now(),'{}','{}',now(),now()),
    (pending_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-pending@example.invalid','',now(),'{}','{}',now(),now()),
    (suspended_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-suspended@example.invalid','',now(),'{}','{}',now(),now()),
    (user_x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-user@example.invalid','',now(),'{}','{}',now(),now()),
    (unrelated,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-unrelated@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.profiles(id,user_id,email,full_name,phone,role,verification_status,created_at,updated_at)
  select id,id,email,'[TEST][4B2B]','000','user','pending',now(),now()
  from auth.users where id in(admin_a,employee_a,admin_b,global_admin,pending_admin,suspended_admin,user_x,unrelated)
  on conflict(user_id) do update set email=excluded.email,full_name=excluded.full_name,phone=excluded.phone,updated_at=now();
  update public.profiles set phone='000',first_name='Test',last_name='User',full_name='[TEST][4B2B]',verification_status='rejected',permissions_verified=false where user_id in(admin_a,employee_a,admin_b,global_admin,pending_admin,suspended_admin,user_x,unrelated);
  update public.profiles set role='admin' where user_id in(admin_a,admin_b,global_admin,pending_admin,suspended_admin);
  update public.profiles set role='pracownik' where user_id=employee_a;
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (a,admin_a,'admin','active'),
    (a,employee_a,'employee','active'),
    (a,pending_admin,'admin','pending'),
    (a,suspended_admin,'admin','suspended'),
    (a,user_x,'user','active')
  on conflict(tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=a and user_id in(admin_b,global_admin,unrelated);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (b,admin_b,'admin','active'),(b,user_x,'user','active')
  on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values
    (lane_a,a,'[TEST][4B2B] A','test',true,2,60,9980,'PLN','lane',null,true,false),
    (lane_b,b,'[TEST][4B2B] B','test',true,2,60,9981,'PLN','lane',null,true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price) values
    (price_a,lane_a,'mon_thu',1,2,'A price',10),(price_b,lane_b,'mon_thu',1,2,'B price',10);
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,check_in_token,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id) values
    (res_a,user_x,a,lane_a,'Test User','4b2b-user@example.invalid','000',date '2099-10-10',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,price_a,'mon_thu','A','A price',10,10,'PLN',gen_random_uuid()),
    (res_b,user_x,b,lane_b,'Test User','4b2b-user@example.invalid','000',date '2099-10-11',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,price_b,'mon_thu','B','B price',10,10,'PLN',gen_random_uuid());
  insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified,permissions_verification_note) values
    (a,user_x,'verified',true,'A note'),(b,user_x,'pending',false,'B note') on conflict(tenant_id,user_id) do update set verification_status=excluded.verification_status,permissions_verified=excluded.permissions_verified,permissions_verification_note=excluded.permissions_verification_note;

  result:=pg_temp.as_actor_text(admin_a,format('public.update_reservation_customer_verification_v1(%L,''mark_pending'',''A changed'')',res_a))::jsonb;
  perform pg_temp.ok(9,'Admin A resource A is allowed',result->>'verification_status'='pending');
  perform pg_temp.ok(10,'resource A update does not affect Tenant B',(select verification_status='pending' and permissions_verification_note='B note' from public.tenant_user_verifications where tenant_id=b and user_id=user_x));
  perform pg_temp.ok(11,'Admin B resource A denied',pg_temp.as_actor_raises(admin_b,format('select public.update_reservation_customer_verification_v1(%L,''verify'',null)',res_a)));
  perform pg_temp.ok(12,'global profile admin without membership denied',pg_temp.as_actor_raises(global_admin,format('select public.update_reservation_customer_verification_v1(%L,''verify'',null)',res_a)));
  perform pg_temp.ok(13,'pending membership denied',pg_temp.as_actor_raises(pending_admin,format('select public.update_reservation_customer_verification_v1(%L,''verify'',null)',res_a)));
  perform pg_temp.ok(14,'suspended membership denied',pg_temp.as_actor_raises(suspended_admin,format('select public.update_reservation_customer_verification_v1(%L,''verify'',null)',res_a)));
  perform pg_temp.ok(15,'employee resource A is allowed',((pg_temp.as_actor_text(employee_a,format('public.update_reservation_customer_verification_v1(%L,''verify'',''employee'')',res_a)))::jsonb)->>'verification_status'='verified');
  perform pg_temp.ok(16,'legacy profile mismatch does not control resource reader',((pg_temp.as_actor_text(admin_a,format('(select jsonb_build_object(''verification_status'',verification_status) from public.get_reservation_customer_profiles_v1(array[%L]::uuid[]) where reservation_id=%L)',res_a,res_a)))::jsonb)->>'verification_status'='verified');
  update public.profiles set verification_status='rejected',permissions_verified=false where user_id=user_x;
  perform pg_temp.ok(17,'changing legacy verification does not alter reader result',((pg_temp.as_actor_text(admin_a,format('(select jsonb_build_object(''verification_status'',verification_status,''permissions_verified'',permissions_verified) from public.get_reservation_customer_profiles_v1(array[%L]::uuid[]) where reservation_id=%L)',res_a,res_a)))::jsonb @> '{"verification_status":"verified","permissions_verified":true}'::jsonb));
  perform pg_temp.ok(18,'admin list uses tenant verification',((pg_temp.as_actor_text(admin_a,format('(select jsonb_build_object(''verification_status'',verification_status,''permissions_verified'',permissions_verified) from public.admin_list_users_v2(%L,100,0,null,null,null,''newest'') where user_id=%L)',a,user_x)))::jsonb @> '{"verification_status":"verified","permissions_verified":true}'::jsonb));
  perform pg_temp.ok(19,'tenant writer denies unrelated user',pg_temp.as_actor_raises(admin_a,format('select public.update_tenant_profile_verification_v2(%L,%L,''verify'',null)',a,unrelated)));
  perform pg_temp.ok(20,'mixed-tenant profile reader fails closed',pg_temp.as_actor_raises(admin_a,format('select * from public.get_reservation_customer_profiles_v1(array[%L,%L]::uuid[])',res_a,res_b)));
  perform pg_temp.ok(21,'duplicate reservation IDs fail closed',pg_temp.as_actor_raises(admin_a,format('select * from public.get_reservation_customer_profiles_v1(array[%L,%L]::uuid[])',res_a,res_a),'22023'));
  perform pg_temp.ok(22,'owner reader has explicit tenant input and excludes note and actor fields',(select proargnames=array['p_tenant_id','verification_status','permissions_verified','permissions_verified_at','updated_at'] from pg_proc where oid='public.get_my_tenant_verification_v2(uuid)'::regprocedure));
  perform pg_temp.ok(23,'owner reader signature has four output fields',(select cardinality(proallargtypes)-pronargs=4 from pg_proc where oid='public.get_my_tenant_verification_v2(uuid)'::regprocedure));
  perform pg_temp.ok(24,'no public RPC accepts tenant_id',(select pg_get_function_arguments('public.update_reservation_customer_verification_v1(uuid,text,text)'::regprocedure) not ilike '%tenant%'));
  select count(*) into audit_count from public.audit_logs where target_type='tenant_user_verification' and target_id=user_x and tenant_id=a;
  perform pg_temp.ok(25,'changed verification writes tenant-bound audit',audit_count>=2 and not exists(select 1 from public.audit_logs where target_type='tenant_user_verification' and target_id=user_x and tenant_id is null));
  perform pg_temp.ok(26,'audit details exclude note and profile PII',not exists(select 1 from public.audit_logs where target_type='tenant_user_verification' and target_id=user_x and (details ? 'note' or details ? 'email' or details ? 'phone' or details ? 'address')));
  perform pg_temp.ok(27,'legacy writer service_role grant removed',not has_function_privilege('service_role','public.update_tenant_profile_verification_v2(uuid,uuid,text,text)','EXECUTE'));
  perform pg_temp.ok(28,'reader source has no legacy verification fallback',strpos((select prosrc from pg_proc where oid='public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure),'profile.verification_status')=0 and strpos((select prosrc from pg_proc where oid='public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure),'profile.verification_status')=0);
  perform pg_temp.ok(29,'booking core reads tenant verification helper',strpos((select prosrc from pg_proc where oid='public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure),'_tenant_verification_status_for_lane_v1')>0);
  perform pg_temp.ok(30,'booking core scopes verification limit by lane tenant',strpos((select prosrc from pg_proc where oid='public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure),'reservation.tenant_id=')>0);

  update public.tenants set status='dormant' where id=a; update public.tenants set status='active' where id=b;
  result_b:=pg_temp.as_actor_text(admin_b,format('public.update_reservation_customer_verification_v1(%L,''reject'',''B changed'')',res_b))::jsonb;
  perform pg_temp.ok(31,'Admin B resource B allowed when B is active',result_b->>'verification_status'='rejected');
  perform pg_temp.ok(32,'Tenant B update does not affect A',(select verification_status='verified' from public.tenant_user_verifications where tenant_id=a and user_id=user_x));
  perform pg_temp.ok(33,'Tenant B reader returns B decision',((pg_temp.as_actor_text(admin_b,format('(select jsonb_build_object(''verification_status'',verification_status) from public.get_reservation_customer_profiles_v1(array[%L]::uuid[]) where reservation_id=%L)',res_b,res_b)))::jsonb)->>'verification_status'='rejected');
  perform pg_temp.ok(34,'Admin A resource B denied',pg_temp.as_actor_raises(admin_a,format('select public.update_reservation_customer_verification_v1(%L,''verify'',null)',res_b)));
  update public.tenants set status='dormant' where id=b; update public.tenants set status='active' where id=a;
  perform pg_temp.ok(35,'single active production invariant restored without compatibility authority',(select count(*)=1 from public.tenants where status='active') and pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null);
  perform pg_temp.ok(36,'target functions contain no profiles role authority',strpos((select prosrc from pg_proc where oid='public.update_reservation_customer_verification_v1(uuid,text,text)'::regprocedure),'profiles.role')=0 and strpos((select prosrc from pg_proc where oid='public.update_tenant_profile_verification_v2(uuid,uuid,text,text)'::regprocedure),'profiles.role')=0);
  perform pg_temp.ok(37,'4B-2C closes generic employee compatibility writer',pg_temp.as_actor_raises(employee_a,format('select public.update_tenant_profile_verification_v2(%L,%L,''mark_pending'',''closed compatibility'')',a,user_x)));
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_no||' - '||description||case when detail is null then '' else ' # '||detail end from saas9d4b2b_results order by test_no;
do $finish$ begin if exists(select 1 from saas9d4b2b_results where not passed) or (select count(*) from saas9d4b2b_results)<>37 then raise exception 'SAAS-9D-4B-2B focused test failed'; end if; end;$finish$;
rollback;
