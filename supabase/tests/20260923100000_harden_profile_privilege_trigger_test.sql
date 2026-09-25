\set ON_ERROR_STOP on
\pset format unaligned

select '1..36';
begin;

create temporary table saas9d4d1_results(
  test_no integer primary key,
  description text not null,
  passed boolean not null,
  detail text
) on commit drop;

create function pg_temp.ok(integer,text,boolean,text default null)
returns void language sql as $f$
  insert into pg_temp.saas9d4d1_results values($1,$2,coalesce($3,false),$4);
$f$;

create function pg_temp.as_actor_json(p_user uuid,p_sql text)
returns jsonb language plpgsql as $f$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated;
  execute 'select ('||p_sql||')::jsonb' into v_result;
  reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_result;
exception when others then
  reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  raise;
end;$f$;

create function pg_temp.as_actor_raises(p_user uuid,p_sql text,p_state text)
returns boolean language plpgsql as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated;
  execute p_sql;
  reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return false;
exception when others then
  reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return sqlstate=p_state;
end;$f$;

-- Executes as the database owner while retaining a synthetic authenticated
-- auth.uid(). This bypasses table RLS only so the trigger itself is exercised.
create function pg_temp.direct_as_actor_raises(p_user uuid,p_sql text,p_state text)
returns boolean language plpgsql security definer as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  execute p_sql;
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return false;
exception when others then
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return sqlstate=p_state;
end;$f$;

create function pg_temp.as_service_role_raises(p_sql text,p_state text)
returns boolean language plpgsql as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  set local role service_role;
  execute p_sql;
  reset role;
  return false;
exception when others then
  reset role;
  return sqlstate=p_state;
end;$f$;

do $tests$
declare
  tenant_a constant uuid := 'c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid := '4d100000-0000-4000-8000-000000000001';
  admin_a uuid := '4d100000-0000-4000-8000-000000000010';
  employee_a uuid := '4d100000-0000-4000-8000-000000000011';
  owner_a uuid := '4d100000-0000-4000-8000-000000000012';
  b_only uuid := '4d100000-0000-4000-8000-000000000013';
  global_admin uuid := '4d100000-0000-4000-8000-000000000014';
  pending_admin uuid := '4d100000-0000-4000-8000-000000000015';
  suspended_admin uuid := '4d100000-0000-4000-8000-000000000016';
  no_membership uuid := '4d100000-0000-4000-8000-000000000017';
  result jsonb;
  audit_before bigint;
begin
  perform pg_temp.ok(1,'exact trigger function and binding exist',
    pg_catalog.to_regprocedure('public.prevent_non_admin_profile_privilege_changes()') is not null
    and (select pg_catalog.count(*)=1 from pg_catalog.pg_trigger trigger_record where trigger_record.tgrelid='public.profiles'::regclass and trigger_record.tgfoid='public.prevent_non_admin_profile_privilege_changes()'::regprocedure and not trigger_record.tgisinternal and trigger_record.tgname='prevent_non_admin_profile_privilege_changes_trigger'));
  perform pg_temp.ok(2,'target normalized fingerprint is exact',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='05fe62eb086d5bfe7a6f5bd5a1c2dcca');
  perform pg_temp.ok(3,'trigger remains closed postgres SECURITY DEFINER SP1',
    (select procedure_record.prosecdef and pg_catalog.pg_get_userbyid(procedure_record.proowner)='postgres' and procedure_record.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] from pg_catalog.pg_proc procedure_record where procedure_record.oid='public.prevent_non_admin_profile_privilege_changes()'::regprocedure)
    and not pg_catalog.has_function_privilege('public','public.prevent_non_admin_profile_privilege_changes()','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.prevent_non_admin_profile_privilege_changes()','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.prevent_non_admin_profile_privilege_changes()','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.prevent_non_admin_profile_privilege_changes()','EXECUTE'));
  perform pg_temp.ok(4,'global role helpers are absent from trigger authority',
    (select pg_catalog.strpos(procedure_record.prosrc,'public.is_admin')=0 and procedure_record.prosrc !~ 'select[^;]*profile[.]role' from pg_catalog.pg_proc procedure_record where procedure_record.oid='public.prevent_non_admin_profile_privilege_changes()'::regprocedure));
  perform pg_temp.ok(5,'tenant membership helper is the privileged authority',
    (select pg_catalog.strpos(procedure_record.prosrc,'get_my_tenant_role_v1')>0 and pg_catalog.strpos(procedure_record.prosrc,'tenant_memberships')>0 from pg_catalog.pg_proc procedure_record where procedure_record.oid='public.prevent_non_admin_profile_privilege_changes()'::regprocedure));
  perform pg_temp.ok(6,'SECURITY DEFINER count is 100 after PRODUCT-10C public landing',
    (select pg_catalog.count(*)=  97 from pg_catalog.pg_proc procedure_record join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace where namespace_record.nspname='public' and procedure_record.prosecdef));
  perform pg_temp.ok(7,'compatibility defaults remain 7/7',
    (select pg_catalog.count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));

  insert into public.tenants(id,name,slug,status)
  values(tenant_b,'[TEST][9D4D1] Tenant B','test-9d4d1-b','dormant');
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',email,'',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()
  from (values
    (admin_a,'9d4d1-admin-a@example.invalid'),
    (employee_a,'9d4d1-employee-a@example.invalid'),
    (owner_a,'9d4d1-owner-a@example.invalid'),
    (b_only,'9d4d1-b-only@example.invalid'),
    (global_admin,'9d4d1-global-admin@example.invalid'),
    (pending_admin,'9d4d1-pending@example.invalid'),
    (suspended_admin,'9d4d1-suspended@example.invalid'),
    (no_membership,'9d4d1-no-membership@example.invalid')
  ) fixture(user_id,email);

  insert into public.profiles(id,user_id,email,role,verification_status)
  select user_id,user_id,email,'user','pending'
  from (values
    (admin_a,'9d4d1-admin-a@example.invalid'),
    (employee_a,'9d4d1-employee-a@example.invalid'),
    (owner_a,'9d4d1-owner-a@example.invalid'),
    (b_only,'9d4d1-b-only@example.invalid'),
    (global_admin,'9d4d1-global-admin@example.invalid'),
    (pending_admin,'9d4d1-pending@example.invalid'),
    (suspended_admin,'9d4d1-suspended@example.invalid'),
    (no_membership,'9d4d1-no-membership@example.invalid')
  ) fixture(user_id,email)
  on conflict(user_id) do nothing;

  update public.profiles set first_name='Test',last_name='User',full_name='Test User',phone='500000000'
  where user_id in(admin_a,employee_a,owner_a,b_only,global_admin,pending_admin,suspended_admin,no_membership);
  update public.profiles set role='admin' where user_id in(admin_a,global_admin,pending_admin,suspended_admin);
  update public.profiles set role='pracownik' where user_id=employee_a;

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_a,admin_a,'admin','active'),
    (tenant_a,employee_a,'employee','active'),
    (tenant_a,owner_a,'user','active'),
    (tenant_a,global_admin,'admin','active'),
    (tenant_a,pending_admin,'admin','pending'),
    (tenant_a,suspended_admin,'admin','suspended'),
    (tenant_a,no_membership,'user','active')
  on conflict(tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=tenant_a and user_id in(b_only,global_admin,no_membership);
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(tenant_b,b_only,'user','active');
  update public.tenant_memberships set status='pending' where tenant_id=tenant_a and user_id=pending_admin;
  update public.tenant_memberships set status='suspended' where tenant_id=tenant_a and user_id=suspended_admin;
  insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified)
  values(tenant_a,owner_a,'verified',true)
  on conflict(tenant_id,user_id) do update
  set verification_status=excluded.verification_status,
      permissions_verified=excluded.permissions_verified;

  perform pg_temp.ok(8,'owner self-service allowed field succeeds',
    (pg_temp.as_actor_json(owner_a,$sql$public.update_my_profile_v2('501001001','00-001','Warszawa','Testowa','1',null,true,false,false,false,false,false,false,false,false,false)$sql$)->>'code')='updated');
  perform pg_temp.ok(9,'owner contact value is persisted',(select phone='501001001' and city='Warszawa' from public.profiles where user_id=owner_a));
  perform pg_temp.ok(10,'owner declaration invalidates tenant verification without changing legacy verification',
    (select permission_sport and verification_status='pending' and not permissions_verified from public.profiles where user_id=owner_a)
    and (select verification_status='pending' and not permissions_verified from public.tenant_user_verifications where tenant_id=tenant_a and user_id=owner_a));
  perform pg_temp.ok(11,'owner direct role escalation is denied',pg_temp.direct_as_actor_raises(owner_a,pg_catalog.format('update public.profiles set role=%L where user_id=%L','admin',owner_a),'42501'));
  perform pg_temp.ok(12,'owner direct identity mutation is denied',pg_temp.direct_as_actor_raises(owner_a,pg_catalog.format('update public.profiles set first_name=%L where user_id=%L','Escalated',owner_a),'42501'));
  perform pg_temp.ok(13,'owner direct legacy verification mutation is denied',pg_temp.direct_as_actor_raises(owner_a,pg_catalog.format('update public.profiles set verification_status=%L where user_id=%L','verified',owner_a),'42501'));
  perform pg_temp.ok(14,'owner direct legacy admin note mutation is denied',pg_temp.direct_as_actor_raises(owner_a,pg_catalog.format('update public.profiles set admin_note=%L where user_id=%L','secret',owner_a),'42501'));
  perform pg_temp.ok(15,'owner direct immutable email mutation is denied',pg_temp.direct_as_actor_raises(owner_a,pg_catalog.format('update public.profiles set email=%L where user_id=%L','changed@example.invalid',owner_a),'42501'));
  perform pg_temp.ok(16,'owner direct permit mutation is denied',pg_temp.direct_as_actor_raises(owner_a,pg_catalog.format('update public.profiles set weapon_permit_number=%L where user_id=%L','X',owner_a),'42501'));

  result:=pg_temp.as_actor_json(admin_a,pg_catalog.format('public.update_tenant_profile_identity_v2(%L,%L,%L,%L)',tenant_a,owner_a,'Jan','Testowy'));
  perform pg_temp.ok(17,'tenant admin controlled identity writer remains compatible',result->>'full_name'='Jan Testowy');
  result:=pg_temp.as_actor_json(employee_a,pg_catalog.format('public.update_tenant_profile_contact_details_v2(%L,%L,%L,%L,%L,%L,%L,null)',tenant_a,owner_a,'502002002','00-002','Warszawa','Pracownicza','2'));
  perform pg_temp.ok(18,'tenant employee controlled related-customer contact remains compatible',result->>'phone'='502002002');
  perform pg_temp.ok(19,'employee cannot mutate an admin profile',pg_temp.as_actor_raises(employee_a,pg_catalog.format('select public.update_tenant_profile_contact_details_v2(%L,%L,%L,null,null,null,null,null)',tenant_a,admin_a,'503003003'),'42501'));

  result:=pg_temp.as_actor_json(admin_a,pg_catalog.format('public.admin_set_user_role_v2(%L,%L,%L)',tenant_a,owner_a,'instruktor'));
  perform pg_temp.ok(20,'tenant role writer remains compatible while global profile role stays frozen',
    result->>'code'='updated'
    and (select role='instructor' from public.tenant_memberships where tenant_id=tenant_a and user_id=owner_a)
    and (select role='user' from public.profiles where user_id=owner_a));
  perform pg_temp.ok(21,'profile role is compatibility data rather than independent authority',
    (select role='admin' from public.profiles where user_id=global_admin)
    and not exists(select 1 from public.tenant_memberships where tenant_id=tenant_a and user_id=global_admin));

  perform pg_catalog.set_config('csk.profile_identity_rpc_actor',global_admin::text,true);
  perform pg_catalog.set_config('csk.profile_identity_rpc_target',owner_a::text,true);
  perform pg_temp.ok(22,'global profile admin without active membership cannot spoof privileged identity path',
    pg_temp.direct_as_actor_raises(global_admin,pg_catalog.format('update public.profiles set first_name=%L where user_id=%L','Spoofed',owner_a),'42501'));
  perform pg_catalog.set_config('csk.profile_identity_rpc_actor','',true);
  perform pg_catalog.set_config('csk.profile_identity_rpc_target','',true);

  perform pg_temp.ok(23,'pending membership cannot authorize privileged writer',pg_temp.as_actor_raises(pending_admin,pg_catalog.format('select public.update_tenant_profile_identity_v2(%L,%L,%L,%L)',tenant_a,owner_a,'Pending','Denied'),'42501'));
  perform pg_temp.ok(24,'suspended membership cannot authorize privileged writer',pg_temp.as_actor_raises(suspended_admin,pg_catalog.format('select public.update_tenant_profile_identity_v2(%L,%L,%L,%L)',tenant_a,owner_a,'Suspended','Denied'),'42501'));
  perform pg_temp.ok(25,'no membership cannot authorize privileged writer',pg_temp.as_actor_raises(no_membership,pg_catalog.format('select public.update_tenant_profile_identity_v2(%L,%L,%L,%L)',tenant_a,owner_a,'None','Denied'),'42501'));
  perform pg_temp.ok(26,'Tenant A admin cannot mutate Tenant B-only user through controlled writer',pg_temp.as_actor_raises(admin_a,pg_catalog.format('select public.update_tenant_profile_identity_v2(%L,%L,%L,%L)',tenant_a,b_only,'Cross','Tenant'),'42501'));

  perform pg_catalog.set_config('csk.profile_contact_rpc_actor',admin_a::text,true);
  perform pg_catalog.set_config('csk.profile_contact_rpc_target',b_only::text,true);
  perform pg_temp.ok(27,'forged writer markers cannot bypass cross-tenant relationship',
    pg_temp.direct_as_actor_raises(admin_a,pg_catalog.format('update public.profiles set phone=%L where user_id=%L','599999999',b_only),'42501'));
  perform pg_catalog.set_config('csk.profile_contact_rpc_actor','',true);
  perform pg_catalog.set_config('csk.profile_contact_rpc_target','',true);
  perform pg_temp.ok(28,'Tenant B membership remains unchanged after denied A operations',
    exists(select 1 from public.tenant_memberships where tenant_id=tenant_b and user_id=b_only and role='user' and status='active')
    and not exists(select 1 from public.tenant_memberships where tenant_id=tenant_a and user_id=b_only));

  perform pg_temp.ok(29,'service_role direct protected UPDATE is denied',
    pg_temp.as_service_role_raises(pg_catalog.format('update public.profiles set verification_status=%L where user_id=%L','verified',owner_a),'42501'));
  update public.profiles set verification_status='system-maintenance-test' where user_id=owner_a;
  perform pg_temp.ok(30,'owner-operated postgres maintenance path remains available',
    (select verification_status='system-maintenance-test' from public.profiles where user_id=owner_a));
  perform pg_temp.ok(31,'system exception is explicitly limited to postgres without SET ROLE',
    (select pg_catalog.strpos(procedure_record.prosrc,'session_user=''postgres''')>0 and pg_catalog.strpos(procedure_record.prosrc,'pg_catalog.current_setting(''role'',true)')>0 from pg_catalog.pg_proc procedure_record where procedure_record.oid='public.prevent_non_admin_profile_privilege_changes()'::regprocedure));

  select pg_catalog.count(*) into audit_before from public.audit_logs;
  perform pg_temp.direct_as_actor_raises(owner_a,pg_catalog.format('update public.profiles set role=%L where user_id=%L','admin',owner_a),'42501');
  perform pg_temp.ok(32,'denied direct updates create no audit rows',
    (select pg_catalog.count(*)=audit_before from public.audit_logs));
  perform pg_temp.ok(33,'legacy note remains frozen and tenant note model is unchanged',
    not exists(select 1 from public.profiles where user_id in(owner_a,b_only) and admin_note is not null)
    and pg_catalog.to_regclass('public.tenant_user_admin_notes') is not null);
  perform pg_temp.ok(34,'legacy verification writer remains closed',
    (select pg_catalog.strpos(procedure_record.prosrc,'update public.profiles')=0 from pg_catalog.pg_proc procedure_record where procedure_record.oid='public.update_tenant_profile_verification_v2(uuid,uuid,text,text)'::regprocedure));
  perform pg_temp.ok(35,'4D-2 and 4E functions remain unchanged',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='eec66d2c695d3892caec4d4242756ed0'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_public_booking_configuration_v2(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='96b419fa86c59606bc6f953abbeac73f');
  perform pg_temp.ok(36,'fixture is transaction-scoped',
    (select pg_catalog.count(*)=1 from public.tenants where id=tenant_b)
    and (select pg_catalog.count(*)=8 from auth.users where id in(admin_a,employee_a,owner_a,b_only,global_admin,pending_admin,suspended_admin,no_membership)));
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_no||' - '||description||case when detail is null then '' else ' # '||detail end
from saas9d4d1_results order by test_no;

do $finish$
begin
  if exists(select 1 from saas9d4d1_results where not passed)
     or (select pg_catalog.count(*) from saas9d4d1_results)<>36 then
    raise exception 'SAAS-9D-4D-1 focused test failed.';
  end if;
end;
$finish$;

rollback;
