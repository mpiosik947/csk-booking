\set ON_ERROR_STOP on
\pset format unaligned

select '1..36';
begin;

create temporary table saas9d4b2c_results(test_no integer primary key,description text not null,passed boolean not null,detail text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text default null) returns void language sql as $f$
  insert into pg_temp.saas9d4b2c_results values($1,$2,coalesce($3,false),$4);
$f$;
create function pg_temp.as_actor_text(p_user uuid,p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated; execute 'select ('||p_sql||')::text' into v; reset role;
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
  a uuid:='c5c00000-0000-4000-8000-000000000001'; b uuid:='42c00000-0000-4000-8000-000000000001';
  admin_a uuid:='42c00000-0000-4000-8000-000000000010'; employee_a uuid:='42c00000-0000-4000-8000-000000000011';
  admin_b uuid:='42c00000-0000-4000-8000-000000000012'; global_admin uuid:='42c00000-0000-4000-8000-000000000013';
  pending_admin uuid:='42c00000-0000-4000-8000-000000000014'; suspended_admin uuid:='42c00000-0000-4000-8000-000000000015';
  user_x uuid:='42c00000-0000-4000-8000-000000000020'; unrelated uuid:='42c00000-0000-4000-8000-000000000021';
  lane_a uuid:='42c00000-0000-4000-8000-000000000030'; price_a uuid:='42c00000-0000-4000-8000-000000000032';
  res_a uuid:='42c00000-0000-4000-8000-000000000040'; result jsonb; legacy_before jsonb; audit_before bigint;
begin
  perform pg_temp.ok(1,'target signatures exist',pg_catalog.to_regprocedure('public.update_tenant_profile_verification_v2(uuid,uuid,text,text)') is not null and pg_catalog.to_regprocedure('public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)') is not null);
  perform pg_temp.ok(2,'SECURITY DEFINER count is 100 after PRODUCT-10C public landing',(select pg_catalog.count(*)=  100 from pg_catalog.pg_proc procedure_record join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace where namespace_record.nspname='public' and procedure_record.prosecdef));
  perform pg_temp.ok(3,'compatibility defaults remain 7/7',(select pg_catalog.count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));
  perform pg_temp.ok(4,'profile trigger matches tenant-aware onboarding cutover',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))='05fe62eb086d5bfe7a6f5bd5a1c2dcca');
  perform pg_temp.ok(5,'legacy writer ACL is authenticated only',pg_catalog.has_function_privilege('authenticated','public.update_tenant_profile_verification_v2(uuid,uuid,text,text)','EXECUTE') and not pg_catalog.has_function_privilege('public','public.update_tenant_profile_verification_v2(uuid,uuid,text,text)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.update_tenant_profile_verification_v2(uuid,uuid,text,text)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public.update_tenant_profile_verification_v2(uuid,uuid,text,text)','EXECUTE'));
  perform pg_temp.ok(6,'mutation core remains closed',not pg_catalog.has_function_privilege('public','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE') and not pg_catalog.has_function_privilege('authenticated','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE'));
  perform pg_temp.ok(7,'target metadata is preserved',(select procedure_record.prosecdef and pg_catalog.pg_get_userbyid(procedure_record.proowner)='postgres' and procedure_record.proconfig=array['search_path=pg_catalog, public, pg_temp'] from pg_catalog.pg_proc procedure_record where procedure_record.oid='public.update_tenant_profile_verification_v2(uuid,uuid,text,text)'::regprocedure));
  perform pg_temp.ok(8,'mutation core is SECURITY INVOKER',(select not procedure_record.prosecdef from pg_catalog.pg_proc procedure_record where procedure_record.oid='public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)'::regprocedure));
  perform pg_temp.ok(9,'global profile mirror is absent',pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)'::regprocedure),'update public.profiles')=0 and pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)'::regprocedure),'profile_verification_rpc_')=0);
  perform pg_temp.ok(10,'generic writer is admin-only and profile-role free',pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.update_tenant_profile_verification_v2(uuid,uuid,text,text)'::regprocedure),'v_actor_role is distinct from ''admin''')>0 and pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.update_tenant_profile_verification_v2(uuid,uuid,text,text)'::regprocedure),'profiles.role')=0 and pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.update_tenant_profile_verification_v2(uuid,uuid,text,text)'::regprocedure),'''employee''')=0);

  insert into public.tenants(id,name,slug,status) values(b,'[TEST][4B2C] B','test-4b2c-b','dormant');
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
    (admin_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2c-admin-a@example.invalid','',now(),'{}','{}',now(),now()),
    (employee_a,'00000000-0000-0000-8000-000000000000','authenticated','authenticated','4b2c-employee-a@example.invalid','',now(),'{}','{}',now(),now()),
    (admin_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2c-admin-b@example.invalid','',now(),'{}','{}',now(),now()),
    (global_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2c-global@example.invalid','',now(),'{}','{}',now(),now()),
    (pending_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2c-pending@example.invalid','',now(),'{}','{}',now(),now()),
    (suspended_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2c-suspended@example.invalid','',now(),'{}','{}',now(),now()),
    (user_x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2c-user@example.invalid','',now(),'{}','{}',now(),now()),
    (unrelated,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2c-unrelated@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.profiles(id,user_id,email,full_name,phone,role,verification_status,created_at,updated_at)
  select id,id,email,'[TEST][4B2C]','000','user','rejected',now(),now() from auth.users where id in(admin_a,employee_a,admin_b,global_admin,pending_admin,suspended_admin,user_x,unrelated)
  on conflict(user_id) do update set email=excluded.email,full_name=excluded.full_name,phone=excluded.phone,verification_status='rejected',permissions_verified=false,permissions_verification_note='legacy frozen',updated_at=now();
  update public.profiles set role='admin' where user_id in(admin_a,admin_b,global_admin,pending_admin,suspended_admin);
  update public.profiles set role='pracownik' where user_id=employee_a;
  delete from public.tenant_memberships where tenant_id=a and user_id in(admin_b,global_admin,unrelated);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (a,admin_a,'admin','active'),(a,employee_a,'employee','active'),(a,pending_admin,'admin','pending'),(a,suspended_admin,'admin','suspended'),
    (b,admin_b,'admin','active'),(b,user_x,'user','active')
  on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(lane_a,a,'[TEST][4B2C] A','test',true,2,60,9980,'PLN','lane',null,true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price) values(price_a,lane_a,'mon_thu',1,2,'A price',10);
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,check_in_token,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values(res_a,user_x,a,lane_a,'Test User','4b2c-user@example.invalid','000',date '2099-10-10',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,price_a,'mon_thu','A','A price',10,10,'PLN',gen_random_uuid());
  insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified,permissions_verification_note) values
    (a,user_x,'pending',false,'A note'),(b,user_x,'rejected',false,'B note')
  on conflict(tenant_id,user_id) do update set verification_status=excluded.verification_status,permissions_verified=excluded.permissions_verified,permissions_verification_note=excluded.permissions_verification_note;

  select pg_catalog.jsonb_build_object('verification_status',verification_status,'permissions_verified',permissions_verified,'permissions_verification_note',permissions_verification_note,'verified_at',verified_at,'verified_by',verified_by,'unverified_at',unverified_at,'unverified_by',unverified_by) into legacy_before from public.profiles where user_id=user_x;
  select pg_catalog.count(*) into audit_before from public.audit_logs where tenant_id=a and target_type='tenant_user_verification' and target_id=user_x;
  result:=pg_temp.as_actor_text(admin_a,format('public.update_tenant_profile_verification_v2(%L,%L,''verify'',''A verified'')',a,user_x))::jsonb;
  perform pg_temp.ok(11,'Admin A generic writer remains compatible',result @> '{"ok":true,"verification_status":"verified","permissions_verified":true}'::jsonb);
  perform pg_temp.ok(12,'Tenant A row is authoritative',(select verification_status='verified' and permissions_verified and permissions_verification_note='A verified' from public.tenant_user_verifications where tenant_id=a and user_id=user_x));
  perform pg_temp.ok(13,'Tenant B row is independent',(select verification_status='rejected' and not permissions_verified and permissions_verification_note='B note' from public.tenant_user_verifications where tenant_id=b and user_id=user_x));
  perform pg_temp.ok(14,'legacy profile fields remain byte-for-value frozen',(select pg_catalog.jsonb_build_object('verification_status',verification_status,'permissions_verified',permissions_verified,'permissions_verification_note',permissions_verification_note,'verified_at',verified_at,'verified_by',verified_by,'unverified_at',unverified_at,'unverified_by',unverified_by)=legacy_before from public.profiles where user_id=user_x));
  perform pg_temp.ok(15,'Admin Users reader returns tenant decision',((pg_temp.as_actor_text(admin_a,format('(select jsonb_build_object(''verification_status'',verification_status,''permissions_verified'',permissions_verified) from public.admin_list_users_v2(%L,100,0,null,null,null,''newest'') where user_id=%L)',a,user_x)))::jsonb @> '{"verification_status":"verified","permissions_verified":true}'::jsonb));
  update public.profiles set verification_status='pending',permissions_verified=false,permissions_verification_note='conflicting legacy' where user_id=user_x;
  perform pg_temp.ok(16,'conflicting legacy profile cannot change tenant reader',((pg_temp.as_actor_text(admin_a,format('(select jsonb_build_object(''verification_status'',verification_status,''permissions_verified'',permissions_verified) from public.admin_list_users_v2(%L,100,0,null,null,null,''newest'') where user_id=%L)',a,user_x)))::jsonb @> '{"verification_status":"verified","permissions_verified":true}'::jsonb));
  perform pg_temp.ok(17,'reservation profile reader has no legacy fallback',((pg_temp.as_actor_text(admin_a,format('(select jsonb_build_object(''verification_status'',verification_status,''permissions_verified'',permissions_verified) from public.get_reservation_customer_profiles_v1(array[%L]::uuid[]) where reservation_id=%L)',res_a,res_a)))::jsonb @> '{"verification_status":"verified","permissions_verified":true}'::jsonb));
  perform pg_temp.ok(18,'employee generic writer is denied',pg_temp.as_actor_raises(employee_a,format('select public.update_tenant_profile_verification_v2(%L,%L,''mark_pending'',null)',a,user_x)));
  perform pg_temp.ok(19,'global profile admin without membership is denied',pg_temp.as_actor_raises(global_admin,format('select public.update_tenant_profile_verification_v2(%L,%L,''verify'',null)',a,user_x)));
  perform pg_temp.ok(20,'pending membership is denied',pg_temp.as_actor_raises(pending_admin,format('select public.update_tenant_profile_verification_v2(%L,%L,''verify'',null)',a,user_x)));
  perform pg_temp.ok(21,'suspended membership is denied',pg_temp.as_actor_raises(suspended_admin,format('select public.update_tenant_profile_verification_v2(%L,%L,''verify'',null)',a,user_x)));
  perform pg_temp.ok(22,'unrelated global user is denied',pg_temp.as_actor_raises(admin_a,format('select public.update_tenant_profile_verification_v2(%L,%L,''verify'',null)',a,unrelated)));
  perform pg_temp.ok(23,'foreign tenant admin is denied',pg_temp.as_actor_raises(admin_b,format('select public.update_tenant_profile_verification_v2(%L,%L,''verify'',null)',a,user_x)));
  perform pg_temp.ok(24,'resource-bound employee writer still works',((pg_temp.as_actor_text(employee_a,format('public.update_reservation_customer_verification_v1(%L,''mark_pending'',''resource-bound'')',res_a)))::jsonb)->>'verification_status'='pending');
  perform pg_temp.ok(25,'resource writer does not touch Tenant B',(select verification_status='rejected' and permissions_verification_note='B note' from public.tenant_user_verifications where tenant_id=b and user_id=user_x));
  perform pg_temp.ok(26,'resource writer does not touch legacy profile',(select verification_status='pending' and permissions_verification_note='conflicting legacy' from public.profiles where user_id=user_x));
  perform pg_temp.ok(27,'changed mutations write explicit Tenant A audit',(select pg_catalog.count(*)>=audit_before+2 from public.audit_logs where tenant_id=a and target_type='tenant_user_verification' and target_id=user_x) and not exists(select 1 from public.audit_logs where target_type='tenant_user_verification' and target_id=user_x and tenant_id is null));
  perform pg_temp.ok(28,'audit details remain PII free',not exists(select 1 from public.audit_logs where target_type='tenant_user_verification' and target_id=user_x and (details ? 'note' or details ? 'email' or details ? 'phone' or details ? 'address')));
  perform pg_temp.ok(29,'active readers contain no profile verification fallback',pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure),'profile.verification_status')=0 and pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure),'profile.verification_status')=0);
  perform pg_temp.ok(30,'booking gate uses tenant helper',pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure),'_tenant_verification_status_for_lane_v1')>0);
  perform pg_temp.ok(31,'account lifecycle functions remain unchanged',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.export_my_data_v1()'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))='d159b7d0a14f7ffc9d6c3e5088d18dc5' and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))='c44c385685f00f36449c5ae80a9e81ce');
  perform pg_temp.ok(32,'Admin Users reader includes approved PRODUCT-10D staff entitlement gate',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))='aa83a0f9cb00b3b00dc0ff1294b1ffa2');
  perform pg_temp.ok(33,'Check-in reader remains unchanged',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))='3f9ff02e63286a2784891ce4bb75c613');
  perform pg_temp.ok(34,'resource writer includes PRODUCT-10D check-in entitlement gate',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.update_reservation_customer_verification_v1(uuid,text,text)'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))='c2b3e5497b3b1b5d1b39f3498d678dda');
  perform pg_temp.ok(35,'owner reader remains unchanged',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_my_tenant_verification_v2(uuid)'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))='954b1d4d47706d91dca196727d46f6f7');
  perform pg_temp.ok(36,'legacy profile verification columns still exist',(select pg_catalog.count(*)=9 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name in('verification_status','permissions_verified','permissions_verified_at','permissions_verified_by','permissions_verification_note','verified_at','verified_by','unverified_at','unverified_by')));
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_no||' - '||description||case when detail is null then '' else ' # '||detail end from saas9d4b2c_results order by test_no;
do $finish$ begin if exists(select 1 from saas9d4b2c_results where not passed) or (select pg_catalog.count(*) from saas9d4b2c_results)<>36 then raise exception 'SAAS-9D-4B-2C focused test failed'; end if; end;$finish$;
rollback;
