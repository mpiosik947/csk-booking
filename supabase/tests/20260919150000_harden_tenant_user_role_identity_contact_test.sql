select '1..48';
begin;

create temporary table test_results(n integer primary key,name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $f$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$f$;
create function pg_temp.set_client(p_uid uuid) returns void language plpgsql as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_uid,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_uid::text,true);
  set local role authenticated;
end;$f$;
create function pg_temp.role_call(p_uid uuid,p_target uuid,p_role text) returns jsonb language plpgsql as $f$
declare r jsonb; begin perform pg_temp.set_client(p_uid); select public.admin_set_user_role_v1(p_target,p_role) into r; reset role; return r;
exception when others then reset role; raise; end;$f$;
create function pg_temp.identity_call(p_uid uuid,p_target uuid,p_first text,p_last text) returns jsonb language plpgsql as $f$
declare r jsonb; begin perform pg_temp.set_client(p_uid); select public.update_profile_identity(p_target,p_first,p_last) into r; reset role; return r;
exception when others then reset role; raise; end;$f$;
create function pg_temp.contact_call(p_uid uuid,p_target uuid,p_phone text) returns jsonb language plpgsql as $f$
declare r jsonb; begin perform pg_temp.set_client(p_uid); select public.update_profile_contact_details(p_target,p_phone,'00-001','Warszawa','Testowa','1',null) into r; reset role; return r;
exception when others then reset role; raise; end;$f$;
create function pg_temp.identity_denied(p_uid uuid,p_target uuid) returns boolean language plpgsql as $f$
begin perform pg_temp.identity_call(p_uid,p_target,'Denied','Target'); return false; exception when insufficient_privilege then return true; end;$f$;
create function pg_temp.contact_denied(p_uid uuid,p_target uuid) returns boolean language plpgsql as $f$
begin perform pg_temp.contact_call(p_uid,p_target,'999'); return false; exception when insufficient_privilege then return true; end;$f$;
create function pg_temp.table_denied(p_role text,p_sql text) returns boolean language plpgsql as $f$
begin execute pg_catalog.format('set local role %I',p_role); execute p_sql; reset role; return false; exception when insufficient_privilege then reset role; return true; end;$f$;

do $tests$
declare
  tenant_a uuid:=public.active_single_tenant_id_v1(); tenant_b uuid:=pg_catalog.gen_random_uuid();
  admin_a uuid:=pg_catalog.gen_random_uuid(); admin_a2 uuid:=pg_catalog.gen_random_uuid(); admin_b uuid:=pg_catalog.gen_random_uuid();
  user_a uuid:=pg_catalog.gen_random_uuid(); user_b uuid:=pg_catalog.gen_random_uuid(); unrelated uuid:=pg_catalog.gen_random_uuid();
  employee_a uuid:=pg_catalog.gen_random_uuid(); instructor_a uuid:=pg_catalog.gen_random_uuid();
  global_admin uuid:=pg_catalog.gen_random_uuid(); pending_admin uuid:=pg_catalog.gen_random_uuid(); suspended_admin uuid:=pg_catalog.gen_random_uuid();
  run_id text:=pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-',''); r jsonb; before_audit bigint; b_profile_role text;
begin
  insert into public.tenants(id,name,slug,status) values(tenant_b,'[TEST][SAAS-9D-4B-1B] B','saas9d4b1b-'||run_id,'dormant');
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select x.id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',x.label||'-'||run_id||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()
  from (values(admin_a,'admin-a'),(admin_a2,'admin-a2'),(admin_b,'admin-b'),(user_a,'user-a'),(user_b,'user-b'),(unrelated,'unrelated'),(employee_a,'employee-a'),(instructor_a,'instructor-a'),(global_admin,'global-admin'),(pending_admin,'pending'),(suspended_admin,'suspended')) x(id,label);
  insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
  select x.id,x.legacy,'[TEST]',x.label,'[TEST][SAAS-9D-4B-1B] '||x.label,x.label||'-'||run_id||'@example.invalid'
  from (values(admin_a,'admin','Admin A'),(admin_a2,'admin','Admin A2'),(admin_b,'admin','Admin B'),(user_a,'user','User A'),(user_b,'user','User B'),(unrelated,'user','Unrelated'),(employee_a,'pracownik','Employee A'),(instructor_a,'instruktor','Instructor A'),(global_admin,'admin','Global Admin'),(pending_admin,'admin','Pending'),(suspended_admin,'admin','Suspended')) x(id,legacy,label)
  where not exists(select 1 from public.profiles profile where profile.user_id=x.id);
  update public.profiles p set role=x.legacy,first_name='[TEST]',last_name=x.label,full_name='[TEST][SAAS-9D-4B-1B] '||x.label,email=x.label||'-'||run_id||'@example.invalid'
  from (values(admin_a,'admin','Admin A'),(admin_a2,'admin','Admin A2'),(admin_b,'admin','Admin B'),(user_a,'user','User A'),(user_b,'user','User B'),(unrelated,'user','Unrelated'),(employee_a,'pracownik','Employee A'),(instructor_a,'instruktor','Instructor A'),(global_admin,'admin','Global Admin'),(pending_admin,'admin','Pending'),(suspended_admin,'admin','Suspended')) x(id,legacy,label)
  where p.user_id=x.id;

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_a,admin_a,'admin','active'),
    (tenant_a,admin_a2,'admin','active'),
    (tenant_a,user_a,'user','active'),
    (tenant_a,employee_a,'employee','active'),
    (tenant_a,instructor_a,'instructor','active'),
    (tenant_a,pending_admin,'admin','pending'),
    (tenant_a,suspended_admin,'admin','suspended')
  on conflict(tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=tenant_a and user_id in(admin_b,user_b,unrelated,global_admin);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_b,admin_b,'admin','active'),(tenant_b,user_b,'user','active')
  on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;

  perform pg_temp.ok(1,'pre-change scope has exact signatures',(select count(*)=5 from pg_proc where oid in('public.admin_set_user_role_v1(uuid,text)'::regprocedure,'public.update_profile_identity(uuid,text,text)'::regprocedure,'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure,'public.set_audit_log_tenant_id()'::regprocedure,'public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure)),'signature drift');
  perform pg_temp.ok(2,'three writers are authenticated-only DEFINER SP1',not exists(select 1 from pg_proc p join pg_roles o on o.oid=p.proowner where p.oid in('public.admin_set_user_role_v1(uuid,text)'::regprocedure,'public.update_profile_identity(uuid,text,text)'::regprocedure,'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure) and not(p.prosecdef and o.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and has_function_privilege('authenticated',p.oid,'EXECUTE') and not has_function_privilege('public',p.oid,'EXECUTE') and not has_function_privilege('anon',p.oid,'EXECUTE') and not has_function_privilege('service_role',p.oid,'EXECUTE'))),'metadata/ACL differs');
  perform pg_temp.ok(3,'audit trigger remains closed INVOKER',exists(select 1 from pg_proc p join pg_roles o on o.oid=p.proowner where p.oid='public.set_audit_log_tenant_id()'::regprocedure and not p.prosecdef and o.rolname='postgres' and p.proconfig=array['search_path=pg_catalog']::text[] and not has_function_privilege('public',p.oid,'EXECUTE') and not has_function_privilege('authenticated',p.oid,'EXECUTE') and not has_function_privilege('service_role',p.oid,'EXECUTE')),'audit metadata differs');
  perform pg_temp.ok(4,'list body matches approved 4B-2B cutover',md5(regexp_replace(pg_get_functiondef('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure),E'\r\n?',E'\n','g'))='bf37ec48de512ea45f5d4592df5f4eac','list drifted');

  r:=pg_temp.role_call(admin_a,user_a,'pracownik');
  perform pg_temp.ok(5,'admin changes same-tenant membership role',r@>'{"ok":true,"changed":true,"code":"updated","role":"pracownik"}'::jsonb and (select role='employee' from public.tenant_memberships where tenant_id=tenant_a and user_id=user_a),'role update failed');
  perform pg_temp.ok(6,'membership role update leaves frozen global profile role unchanged',(select role='user' from public.profiles where user_id=user_a),'global profile role was mirrored');
  r:=pg_temp.role_call(admin_a,user_a,'instruktor');
  perform pg_temp.ok(7,'instructor mapping works',r->>'role'='instruktor' and (select role='instructor' from public.tenant_memberships where tenant_id=tenant_a and user_id=user_a),'instructor map failed');
  r:=pg_temp.role_call(admin_a,user_a,'user');
  perform pg_temp.ok(8,'user mapping works',r->>'role'='user' and (select role='user' from public.tenant_memberships where tenant_id=tenant_a and user_id=user_a),'user map failed');
  r:=pg_temp.role_call(admin_a,user_a,'admin');
  perform pg_temp.ok(9,'admin mapping works',r->>'role'='admin' and (select role='admin' from public.tenant_memberships where tenant_id=tenant_a and user_id=user_a),'admin map failed');
  r:=pg_temp.role_call(admin_a,user_a,'user');
  perform pg_temp.ok(10,'cross-tenant role mutation denied',pg_temp.role_call(admin_a,user_b,'admin')->>'code'='not_allowed' and (select role='user' from public.tenant_memberships where tenant_id=tenant_b and user_id=user_b),'cross-tenant role changed');
  perform pg_temp.ok(11,'unrelated role mutation denied',pg_temp.role_call(admin_a,unrelated,'admin')->>'code'='not_allowed','unrelated role allowed');
  perform pg_temp.ok(12,'global role without membership denied',pg_temp.role_call(global_admin,user_a,'user')->>'code'='not_allowed','global role bypass');
  perform pg_temp.ok(13,'pending membership denied',pg_temp.role_call(pending_admin,user_a,'user')->>'code'='not_allowed','pending allowed');
  perform pg_temp.ok(14,'suspended membership denied',pg_temp.role_call(suspended_admin,user_a,'user')->>'code'='not_allowed','suspended allowed');

  r:=pg_temp.identity_call(admin_a,user_a,'Tenant','Identity');
  perform pg_temp.ok(15,'tenant admin identity update allowed',r->>'first_name'='Tenant' and (select first_name='Tenant' from public.profiles where user_id=user_a),'identity update failed');
  perform pg_temp.ok(16,'identity B-only denied',pg_temp.identity_denied(admin_a,user_b),'B identity allowed');
  perform pg_temp.ok(17,'identity unrelated denied',pg_temp.identity_denied(admin_a,unrelated),'unrelated identity allowed');
  perform pg_temp.ok(18,'identity global-role bypass removed',pg_temp.identity_denied(global_admin,user_a),'global identity bypass');
  perform pg_temp.ok(19,'identity employee denied',pg_temp.identity_denied(employee_a,user_a),'employee identity allowed');
  perform pg_temp.ok(20,'identity instructor denied',pg_temp.identity_denied(instructor_a,user_a),'instructor identity allowed');

  r:=pg_temp.contact_call(admin_a,user_a,'111');
  perform pg_temp.ok(21,'tenant admin contact update allowed',r->>'phone'='111' and (select phone='111' from public.profiles where user_id=user_a),'admin contact failed');
  r:=pg_temp.contact_call(employee_a,user_a,'222');
  perform pg_temp.ok(22,'employee related customer contact allowed',r->>'phone'='222' and (select phone='222' from public.profiles where user_id=user_a),'employee contact failed');
  perform pg_temp.ok(23,'employee self contact denied',pg_temp.contact_denied(employee_a,employee_a),'employee self allowed');
  perform pg_temp.ok(24,'employee admin target denied',pg_temp.contact_denied(employee_a,admin_a),'employee admin target allowed');
  perform pg_temp.ok(25,'employee instructor target denied',pg_temp.contact_denied(employee_a,instructor_a),'employee instructor target allowed');
  perform pg_temp.ok(26,'contact B-only denied',pg_temp.contact_denied(admin_a,user_b),'B contact allowed');
  perform pg_temp.ok(27,'contact unrelated denied',pg_temp.contact_denied(admin_a,unrelated),'unrelated contact allowed');
  perform pg_temp.ok(28,'contact global-role bypass removed',pg_temp.contact_denied(global_admin,user_a),'global contact bypass');

  select count(*) into before_audit from public.audit_logs where target_id=user_a and action like 'tenant_user_%';
  r:=pg_temp.identity_call(admin_a,user_a,'Tenant','Identity Two');
  r:=pg_temp.contact_call(admin_a,user_a,'333');
  r:=pg_temp.role_call(admin_a,user_a,'pracownik');
  perform pg_temp.ok(29,'changed operations create exactly tenant-bound audits',(select count(*)=before_audit+3 from public.audit_logs where target_id=user_a and action like 'tenant_user_%') and not exists(select 1 from public.audit_logs where target_id=user_a and action like 'tenant_user_%' and tenant_id is distinct from tenant_a),'audit count/tenant differs');
  perform pg_temp.ok(30,'audit payload is PII-free',not exists(select 1 from public.audit_logs where target_id=user_a and action like 'tenant_user_%' and (details::text like '%333%' or details::text like '%Identity Two%' or actor_name not like 'Tenant %' or target_name<>'Tenant user')),'audit PII leaked');
  r:=pg_temp.identity_call(admin_a,user_a,'Tenant','Identity Two');
  r:=pg_temp.contact_call(admin_a,user_a,'333');
  r:=pg_temp.role_call(admin_a,user_a,'pracownik');
  perform pg_temp.ok(31,'no-change is idempotent',(select count(*)=before_audit+3 from public.audit_logs where target_id=user_a and action like 'tenant_user_%'),'no-change audit created');

  update public.tenants set status='dormant' where id=tenant_a;
  update public.tenants set status='active' where id=tenant_b;
  r:=pg_temp.role_call(admin_b,user_b,'admin');
  r:=pg_temp.role_call(admin_b,user_b,'user');
  perform pg_temp.ok(32,'one of multiple active admins may be demoted',r->>'code'='updated','multi-admin demotion denied');
  r:=pg_temp.role_call(admin_b,admin_b,'user');
  perform pg_temp.ok(33,'last active tenant admin protected',r->>'code'='last_admin' and (select count(*)=1 from public.tenant_memberships where tenant_id=tenant_b and status='active' and role='admin'),'last admin lost');
  perform pg_temp.ok(34,'Tenant A admin not counted for Tenant B',(select role='admin' from public.tenant_memberships where tenant_id=tenant_a and user_id=admin_a) and r->>'code'='last_admin','foreign admin counted');
  update public.tenants set status='dormant' where id=tenant_b;
  update public.tenants set status='active' where id=tenant_a;

  update public.tenants set status='dormant' where id=tenant_a;
  update public.tenants set status='active' where id=tenant_b;
  select role into b_profile_role from public.profiles where user_id=user_b;
  r:=pg_temp.role_call(admin_b,user_b,'instruktor');
  perform pg_temp.ok(35,'non-CSK tenant membership role changes',r->>'code'='updated' and (select role='instructor' from public.tenant_memberships where tenant_id=tenant_b and user_id=user_b),'non-CSK role failed');
  perform pg_temp.ok(36,'non-CSK role leaves global profile unchanged',(select role=b_profile_role from public.profiles where user_id=user_b),'global profile changed');
  update public.tenants set status='dormant' where id=tenant_b;
  update public.tenants set status='active' where id=tenant_a;

  perform pg_temp.ok(37,'role function has tenant serialization',(select prosrc like '%pg_advisory_xact_lock%' and prosrc like '%status=''active''%and membership.role=''admin''%' from pg_proc where oid='public.admin_set_user_role_v1(uuid,text)'::regprocedure),'serialization predicate missing');
  perform pg_temp.ok(38,'operational relationship sources are explicit',not exists(select 1 from pg_proc where oid in('public.update_profile_identity(uuid,text,text)'::regprocedure,'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure) and not(prosrc like '%tenant_memberships%' and prosrc like '%reservations%' and prosrc like '%event_registrations%')),'relationship source missing');
  perform pg_temp.ok(39,'global profile role removed from writer authority',not exists(select 1 from pg_proc where oid in('public.admin_set_user_role_v1(uuid,text)'::regprocedure,'public.update_profile_identity(uuid,text,text)'::regprocedure,'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure) and prosrc~'profile[.]role'),'global role authority remains');
  perform pg_temp.ok(40,'audit target allowlist exact',(select prosrc like '%tenant_user_role_updated%' and prosrc like '%tenant_user_identity_updated%' and prosrc like '%tenant_user_contact_updated%' from pg_proc where oid='public.set_audit_log_tenant_id()'::regprocedure),'audit target missing');
  perform pg_temp.ok(41,'account-wide functions frozen',md5(regexp_replace(pg_get_functiondef('public.export_my_data_v1()'::regprocedure),E'\r\n?',E'\n','g'))='d159b7d0a14f7ffc9d6c3e5088d18dc5' and md5(regexp_replace(pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure),E'\r\n?',E'\n','g'))='70b5f590399aa3f3a147935459b7f085','account lifecycle drift');
  perform pg_temp.ok(42,'verification function matches approved 4B-2C closure',md5(regexp_replace(pg_get_functiondef('public.update_profile_verification(uuid,text,text)'::regprocedure),E'\r\n?',E'\n','g'))='022baa5652409d2246cd5e66642e884e','verification drift');
  perform pg_temp.ok(43,'profile privilege trigger matches tenant-aware onboarding cutover',md5(regexp_replace(pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),E'\r\n?',E'\n','g'))='05fe62eb086d5bfe7a6f5bd5a1c2dcca','profile trigger drift');
  perform pg_temp.ok(44,'SECURITY DEFINER count is 95 after Phase 2',(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)=95,'definer count differs');
  perform pg_temp.ok(45,'compatibility defaults remain 7/7',(select count(*) from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')=7,'defaults differ');
  perform pg_temp.ok(46,'direct profile updates remain denied',pg_temp.table_denied('authenticated','update public.profiles set role=''admin'' where false'),'direct update allowed');
  perform pg_temp.ok(47,'list tenant note contract remains active',(select prosrc like '%tenant_user_admin_notes%' and prosrc not like '%profile.admin_note%' from pg_proc where oid='public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure),'note/list regression');
end;$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||n||' - '||name||case when passed then '' else E'\n# '||result end from pg_temp.test_results order by n;
do $assert$ declare failed text; begin
  select string_agg(n||'. '||name||': '||result,E'\n' order by n) into failed from pg_temp.test_results where not passed;
  if (select count(*) from pg_temp.test_results)<>47 then raise exception 'SAAS-9D-4B-1B expected 47 checks'; end if;
  if failed is not null then raise exception E'SAAS-9D-4B-1B failures:\n%',failed; end if;
end;$assert$;
rollback;

select case when not exists(select 1 from public.tenants where slug like 'saas9d4b1b-%')
 and not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9D-4B-1B]%')
 and not exists(select 1 from public.audit_logs where target_name='Tenant user' and action in('tenant_user_role_updated','tenant_user_identity_updated','tenant_user_contact_updated') and target_id in(select user_id from public.profiles where full_name like '[TEST][SAAS-9D-4B-1B]%'))
then 'ok 48 - rollback removed every SAAS-9D-4B-1B fixture' else 'not ok 48 - rollback fixture cleanup failed' end;
