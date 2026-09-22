\set ON_ERROR_STOP on
\pset format unaligned

select '1..24';
begin;
create temporary table onboarding_results(n integer primary key,label text,passed boolean) on commit drop;
create function pg_temp.ok(p_n integer,p_label text,p_passed boolean)
returns void language sql as $$insert into pg_temp.onboarding_results values(p_n,p_label,coalesce(p_passed,false))$$;
create function pg_temp.as_actor(p_actor uuid,p_sql text)
returns jsonb language plpgsql as $$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_actor,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_actor::text,true);
  execute 'set local role authenticated'; execute p_sql into v_result; execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_result;
exception when others then
  execute 'reset role'; perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true); raise;
end $$;
create function pg_temp.as_actor_raises(p_actor uuid,p_sql text)
returns boolean language plpgsql as $$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_actor,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_actor::text,true);
  execute 'set local role authenticated'; execute p_sql; execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return false;
exception when others then
  execute 'reset role'; perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true); return sqlstate in('42501','P0002','22023');
end $$;

do $tests$
declare
  a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  b uuid:=pg_catalog.gen_random_uuid();
  user_x uuid:=pg_catalog.gen_random_uuid();
  pending_user uuid:=pg_catalog.gen_random_uuid();
  admin_a uuid:=pg_catalog.gen_random_uuid();
  target_a uuid:=pg_catalog.gen_random_uuid();
  marker text:='[TEST][9D5A]['||pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','')||']';
  first_result jsonb; second_result jsonb; b_result jsonb; pending_result jsonb; profile_update jsonb; identity_update jsonb;
begin
  perform pg_temp.ok(1,'onboarding exact signature exists',
    pg_catalog.to_regprocedure('public.self_onboard_tenant_v1(text)') is not null);
  perform pg_temp.ok(2,'onboarding is authenticated-only postgres definer with fixed path',
    (select p.prosecdef and p.provolatile='v' and r.rolname='postgres'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.self_onboard_tenant_v1(text)'::regprocedure)
    and not pg_catalog.has_function_privilege('public','public.self_onboard_tenant_v1(text)','execute')
    and not pg_catalog.has_function_privilege('anon','public.self_onboard_tenant_v1(text)','execute')
    and pg_catalog.has_function_privilege('authenticated','public.self_onboard_tenant_v1(text)','execute')
    and not pg_catalog.has_function_privilege('service_role','public.self_onboard_tenant_v1(text)','execute'));
  perform pg_temp.ok(3,'contract has no role or tenant id input',
    pg_catalog.pg_get_function_identity_arguments('public.self_onboard_tenant_v1(text)'::regprocedure)='p_tenant_slug text'
    and (select pg_catalog.strpos(p.prosrc,'active_single_tenant_id_v1')=0
      and pg_catalog.strpos(p.prosrc,'profiles.role')=0 from pg_catalog.pg_proc p
      where p.oid='public.self_onboard_tenant_v1(text)'::regprocedure));
  perform pg_temp.ok(4,'legacy role sync triggers and functions are removed',
    pg_catalog.to_regprocedure('public.sync_profile_role_to_csk_membership()') is null
    and pg_catalog.to_regprocedure('public.sync_csk_membership_role_to_profile()') is null
    and not exists(select 1 from pg_catalog.pg_trigger where not tgisinternal
      and tgname in('sync_profile_role_to_csk_membership','sync_csk_membership_role_to_profile')));
  perform pg_temp.ok(5,'profile guard has no exact-single or role-mirror dependency',
    (select pg_catalog.strpos(p.prosrc,'active_single_tenant_id_v1')=0
      and pg_catalog.strpos(p.prosrc,'profile_role_rpc')=0 from pg_catalog.pg_proc p
      where p.oid='public.prevent_non_admin_profile_privilege_changes()'::regprocedure));

  insert into public.tenants(id,name,slug,status) values(b,marker||' B','onboarding-b','dormant');
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    marker||label||'@example.invalid','',pg_catalog.now(),'{}',
    '{"accepted_terms":true,"accepted_privacy":true,"first_name":"Test","last_name":"User"}',
    pg_catalog.now(),pg_catalog.now()
  from (values(user_x,'user'),(pending_user,'pending'),(admin_a,'admin'),(target_a,'target')) u(id,label);

  perform pg_temp.ok(6,'global account trigger creates profile only',
    exists(select 1 from public.profiles where user_id=user_x and role='user')
    and not exists(select 1 from public.tenant_memberships where user_id=user_x)
    and (select pg_catalog.count(*)=1 from pg_catalog.pg_trigger where not tgisinternal
      and tgrelid='auth.users'::regclass and tgfoid='public.handle_new_user()'::regprocedure));
  perform pg_temp.ok(7,'unauthenticated onboarding is denied',
    pg_temp.as_actor_raises(null,'select public.self_onboard_tenant_v1(''csk'')'));
  perform pg_temp.ok(8,'invalid tenant selector is denied',
    pg_temp.as_actor_raises(user_x,'select public.self_onboard_tenant_v1(''CSK'')'));
  perform pg_temp.ok(9,'inactive tenant is denied',
    pg_temp.as_actor_raises(user_x,'select public.self_onboard_tenant_v1(''onboarding-b'')'));

  first_result:=pg_temp.as_actor(user_x,'select pg_catalog.to_jsonb(r) from public.self_onboard_tenant_v1(''csk'') r');
  perform pg_temp.ok(10,'explicit CSK onboarding creates active user only',
    first_result->>'tenant_id'=a::text and first_result->>'user_id'=user_x::text
    and first_result->>'role'='user' and first_result->>'status'='active'
    and first_result->>'created'='true');
  perform pg_temp.ok(11,'membership persisted with exact user role and active status',
    exists(select 1 from public.tenant_memberships where tenant_id=a and user_id=user_x and role='user' and status='active'));
  perform pg_temp.ok(12,'self onboarding audit is tenant-bound and PII-free',
    (select pg_catalog.count(*)=1 from public.audit_logs where tenant_id=a and actor_user_id=user_x
      and action='tenant_user_role_updated' and target_type='tenant_user_role' and target_id=user_x
      and details=pg_catalog.jsonb_build_object('previous_role',null,'new_role','user','status','active',
        'operation','self_onboarding','source','explicit_tenant_slug')));
  second_result:=pg_temp.as_actor(user_x,'select pg_catalog.to_jsonb(r) from public.self_onboard_tenant_v1(''csk'') r');
  perform pg_temp.ok(13,'repeat onboarding is idempotent',
    second_result->>'created'='false'
    and (select pg_catalog.count(*)=1 from public.tenant_memberships where tenant_id=a and user_id=user_x)
    and (select pg_catalog.count(*)=1 from public.audit_logs where tenant_id=a and actor_user_id=user_x
      and action='tenant_user_role_updated' and details->>'operation'='self_onboarding'));

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,pending_user,'instructor','pending');
  pending_result:=pg_temp.as_actor(pending_user,'select pg_catalog.to_jsonb(r) from public.self_onboard_tenant_v1(''csk'') r');
  perform pg_temp.ok(14,'existing relationship role and status are never promoted or activated',
    pending_result->>'created'='false' and pending_result->>'role'='instructor' and pending_result->>'status'='pending'
    and exists(select 1 from public.tenant_memberships where tenant_id=a and user_id=pending_user and role='instructor' and status='pending'));

  update public.tenants set status='dormant' where id=a;
  update public.tenants set status='active' where id=b;
  b_result:=pg_temp.as_actor(user_x,'select pg_catalog.to_jsonb(r) from public.self_onboard_tenant_v1(''onboarding-b'') r');
  perform pg_temp.ok(15,'same user can explicitly onboard into another active tenant',
    b_result->>'tenant_id'=b::text and b_result->>'role'='user' and b_result->>'status'='active'
    and exists(select 1 from public.tenant_memberships where tenant_id=a and user_id=user_x and role='user')
    and exists(select 1 from public.tenant_memberships where tenant_id=b and user_id=user_x and role='user'));
  perform pg_temp.ok(16,'tenant B onboarding does not change tenant A relationship',
    (select role='user' and status='active' from public.tenant_memberships where tenant_id=a and user_id=user_x));
  update public.tenants set status='dormant' where id=b;
  update public.tenants set status='active' where id=a;

  insert into public.tenant_memberships(tenant_id,user_id,role,status)
    values(a,admin_a,'admin','active'),(a,target_a,'user','active');
  perform pg_temp.as_actor(admin_a,pg_catalog.format(
    'select public.admin_set_user_role_v2(%L::uuid,%L::uuid,''pracownik'')',a,target_a));
  perform pg_temp.ok(17,'staff role management remains tenant authoritative',
    exists(select 1 from public.tenant_memberships where tenant_id=a and user_id=target_a and role='employee' and status='active'));
  perform pg_temp.ok(18,'membership role changes do not mirror into global profiles role',
    exists(select 1 from public.profiles where user_id=target_a and role='user'));
  perform pg_temp.ok(19,'ordinary owner cannot modify frozen global role',
    pg_temp.as_actor_raises(user_x,pg_catalog.format(
      'update public.profiles set role=''admin'' where user_id=%L::uuid',user_x)));

  profile_update:=pg_temp.as_actor(user_x,
    'select public.update_my_profile_v2(''123456789'',null,null,null,null,null,false,false,false,false,false,false,false,false,false,false)');
  perform pg_temp.ok(20,'global owner profile self-service remains operational',
    profile_update->>'ok'='true' and exists(select 1 from public.profiles where user_id=user_x and phone='123456789'));
  identity_update:=pg_temp.as_actor(admin_a,pg_catalog.format(
    'select public.update_tenant_profile_identity_v2(%L::uuid,%L::uuid,''Target'',''Renamed'')',a,target_a));
  perform pg_temp.ok(21,'controlled tenant identity writer passes explicit guard context',
    identity_update->>'full_name'='Target Renamed'
    and exists(select 1 from public.profiles where user_id=target_a and full_name='Target Renamed'));
  perform pg_temp.ok(22,'compatibility defaults remain seven of seven',
    (select pg_catalog.count(*)=7 from information_schema.columns where table_schema='public' and column_name='tenant_id'
      and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));
  perform pg_temp.ok(23,'SECURITY DEFINER target is 95',
    (select pg_catalog.count(*)=95 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef));
  perform pg_temp.ok(24,'only CSK is active after two-tenant test',
    (select pg_catalog.count(*)=1 from public.tenants where status='active')
    and exists(select 1 from public.tenants where id=a and status='active')
    and exists(select 1 from public.tenants where id=b and status='dormant'));
end;
$tests$;

do $assert$
declare failed text;
begin
  select pg_catalog.string_agg(n::text||' '||label,', ' order by n) into failed
  from pg_temp.onboarding_results where not passed;
  if failed is not null then raise exception 'SAAS-9D-5A focused failures: %',failed; end if;
end;
$assert$;

select case when passed then 'ok ' else 'not ok ' end||n||' - '||label
from onboarding_results order by n;
rollback;
