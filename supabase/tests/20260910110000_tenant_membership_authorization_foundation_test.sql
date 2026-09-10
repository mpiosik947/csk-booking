\set ON_ERROR_STOP on
\pset format unaligned

select '1..47';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.ok(integer, text, boolean, text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1, $2, coalesce($3, false), $4);
$function$;

create function pg_temp.raises(p_sql text, p_state text)
returns boolean language plpgsql as $function$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlstate = p_state;
end;
$function$;

create function pg_temp.as_authenticated_text(p_user uuid, p_sql text)
returns text language plpgsql as $function$
declare
  v_result text;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user, 'role', 'authenticated')::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub', p_user::text, true);
  execute 'set local role authenticated';
  execute 'select (' || p_sql || ')::text' into v_result;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims', '{}', true);
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
  return v_result;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims', '{}', true);
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
  raise;
end;
$function$;

create function pg_temp.as_role_raises(p_role text, p_user uuid, p_sql text, p_state text)
returns boolean language plpgsql as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user, 'role', p_role)::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true);
  execute pg_catalog.format('set local role %I', p_role);
  execute p_sql;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims', '{}', true);
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
  return false;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims', '{}', true);
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
  return sqlstate = p_state;
end;
$function$;

do $tests$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
  v_admin uuid := pg_catalog.gen_random_uuid();
  v_employee uuid := pg_catalog.gen_random_uuid();
  v_instructor uuid := pg_catalog.gen_random_uuid();
  v_user uuid := pg_catalog.gen_random_uuid();
  v_banned uuid := pg_catalog.gen_random_uuid();
  v_dormant uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');
begin
  perform pg_temp.ok(1, 'canonical membership roles include instructor',
    pg_catalog.pg_get_constraintdef((
      select oid from pg_catalog.pg_constraint
      where conrelid = 'public.tenant_memberships'::regclass
        and conname = 'tenant_memberships_role_check'
    )) like '%admin%employee%user%instructor%',
    'Membership role CHECK does not expose the approved canonical vocabulary.');

  perform pg_temp.ok(2, 'legacy admin maps to canonical admin',
    public.legacy_profile_role_to_tenant_role_v1('admin') = 'admin', 'admin mapping differs.');
  perform pg_temp.ok(3, 'legacy user maps to canonical user',
    public.legacy_profile_role_to_tenant_role_v1('user') = 'user', 'user mapping differs.');
  perform pg_temp.ok(4, 'legacy pracownik maps to canonical employee',
    public.legacy_profile_role_to_tenant_role_v1('pracownik') = 'employee', 'pracownik mapping differs.');
  perform pg_temp.ok(5, 'legacy instruktor maps to canonical instructor',
    public.legacy_profile_role_to_tenant_role_v1('instruktor') = 'instructor', 'instruktor mapping differs.');
  perform pg_temp.ok(6, 'canonical employee maps back to pracownik',
    public.tenant_role_to_legacy_profile_role_v1('employee') = 'pracownik', 'employee reverse mapping differs.');
  perform pg_temp.ok(7, 'canonical instructor maps back to instruktor',
    public.tenant_role_to_legacy_profile_role_v1('instructor') = 'instruktor', 'instructor reverse mapping differs.');
  perform pg_temp.ok(8, 'unknown role has no forward fallback',
    public.legacy_profile_role_to_tenant_role_v1('owner') is null, 'Unknown legacy role was guessed.');
  perform pg_temp.ok(9, 'unknown role has no reverse fallback',
    public.tenant_role_to_legacy_profile_role_v1('owner') is null, 'Unknown membership role was guessed.');

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'saas9c-admin-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_employee, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'saas9c-employee-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_instructor, '00000000-0000-0000-8000-000000000000', 'authenticated', 'authenticated', 'saas9c-instructor-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'saas9c-user-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now());

  insert into public.profiles(user_id,email,role)
  values
    (v_admin,'saas9c-admin-' || v_run || '@example.invalid','user'),
    (v_employee,'saas9c-employee-' || v_run || '@example.invalid','user'),
    (v_instructor,'saas9c-instructor-' || v_run || '@example.invalid','user'),
    (v_user,'saas9c-user-' || v_run || '@example.invalid','user');

  perform pg_temp.ok(10, 'synthetic Auth users have one profile each',
    (select pg_catalog.count(*) = 4 from public.profiles where user_id in (v_admin, v_employee, v_instructor, v_user)),
    'Synthetic fixture does not contain exactly four profiles.');
  perform pg_temp.ok(11, 'new profiles receive active CSK memberships',
    (select pg_catalog.count(*) = 4 from public.tenant_memberships where tenant_id = v_csk and user_id in (v_admin, v_employee, v_instructor, v_user) and role = 'user' and status = 'active'),
    'Profile bridge did not create four active user memberships.');

  update public.profiles set role = 'admin' where user_id = v_admin;
  update public.profiles set role = 'pracownik' where user_id = v_employee;
  update public.profiles set role = 'instruktor' where user_id = v_instructor;

  perform pg_temp.ok(12, 'profile admin synchronizes membership admin',
    exists(select 1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_admin and role='admin'),
    'Forward admin synchronization failed.');
  perform pg_temp.ok(13, 'profile pracownik synchronizes membership employee',
    exists(select 1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_employee and role='employee'),
    'Forward employee synchronization failed.');
  perform pg_temp.ok(14, 'profile instruktor synchronizes membership instructor',
    exists(select 1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_instructor and role='instructor'),
    'Forward instructor synchronization failed.');
  perform pg_temp.ok(15, 'profile user keeps membership user',
    exists(select 1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_user and role='user'),
    'Forward user synchronization failed.');

  update public.tenant_memberships set role = 'employee' where tenant_id=v_csk and user_id=v_user;
  perform pg_temp.ok(16, 'membership employee synchronizes profile pracownik',
    exists(select 1 from public.profiles where user_id=v_user and role='pracownik'),
    'Reverse employee synchronization failed.');
  update public.tenant_memberships set role = 'instructor' where tenant_id=v_csk and user_id=v_user;
  perform pg_temp.ok(17, 'membership instructor synchronizes profile instruktor',
    exists(select 1 from public.profiles where user_id=v_user and role='instruktor'),
    'Reverse instructor synchronization failed.');
  update public.tenant_memberships set role = 'user' where tenant_id=v_csk and user_id=v_user;
  perform pg_temp.ok(18, 'membership user synchronizes profile user',
    exists(select 1 from public.profiles where user_id=v_user and role='user'),
    'Reverse user synchronization failed.');

  update public.tenant_memberships set status='suspended' where tenant_id=v_csk and user_id=v_instructor;
  update public.profiles set role='pracownik' where user_id=v_instructor;
  perform pg_temp.ok(19, 'profile role sync preserves membership lifecycle status',
    exists(select 1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_instructor and role='employee' and status='suspended'),
    'Role bridge overwrote the membership lifecycle status.');

  insert into public.tenants(id,name,slug,status)
  values(v_dormant,'[TEST][SAAS-9C] Dormant','saas9c-' || pg_catalog.left(v_run,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(v_dormant,v_user,'admin','active');
  perform pg_temp.ok(20, 'non-CSK membership does not rewrite legacy global role',
    exists(select 1 from public.profiles where user_id=v_user and role='user'),
    'Bridge leaked a non-CSK membership into profiles.role.');

  perform pg_temp.ok(21, 'unknown legacy role update fails closed',
    pg_temp.raises(pg_catalog.format('update public.profiles set role=%L where user_id=%L','owner',v_user),'23514'),
    'Unknown profile role bypassed the bridge.');
  perform pg_temp.ok(22, 'unknown membership role fails closed',
    pg_temp.raises(pg_catalog.format('update public.tenant_memberships set role=%L where tenant_id=%L and user_id=%L','owner',v_csk,v_user),'23514'),
    'Unknown membership role bypassed its CHECK.');

  perform pg_temp.ok(23, 'active admin is a tenant member',
    pg_temp.as_authenticated_text(v_admin, pg_catalog.format('public.is_tenant_member_v1(%L::uuid)',v_csk))='true',
    'Active membership helper denied admin.');
  perform pg_temp.ok(24, 'active admin has exact tenant admin role',
    pg_temp.as_authenticated_text(v_admin, pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[''admin''])',v_csk))='true',
    'Role helper denied exact admin role.');
  perform pg_temp.ok(25, 'admin does not implicitly have employee role',
    pg_temp.as_authenticated_text(v_admin, pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[''employee''])',v_csk))='false',
    'Role helper expanded admin to an unrequested role.');
  perform pg_temp.ok(26, 'active employee role is returned canonically',
    pg_temp.as_authenticated_text(v_employee, pg_catalog.format('public.get_my_tenant_role_v1(%L::uuid)',v_csk))='employee',
    'Canonical employee role was not returned.');
  perform pg_temp.ok(27, 'suspended membership fails membership helper',
    pg_temp.as_authenticated_text(v_instructor, pg_catalog.format('public.is_tenant_member_v1(%L::uuid)',v_csk))='false',
    'Suspended membership was authorized.');
  perform pg_temp.ok(28, 'unknown requested role array fails closed',
    pg_temp.as_authenticated_text(v_admin, pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[''admin'',''owner''])',v_csk))='false',
    'Unknown requested role was ignored.');
  perform pg_temp.ok(29, 'empty requested role array fails closed',
    pg_temp.as_authenticated_text(v_admin, pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[]::text[])',v_csk))='false',
    'Empty requested roles were authorized.');
  perform pg_temp.ok(30, 'NULL tenant fails closed',
    pg_temp.as_authenticated_text(v_admin, 'public.is_tenant_member_v1(null::uuid)')='false',
    'NULL tenant was authorized.');
  perform pg_temp.ok(31, 'dormant tenant fails closed despite active membership',
    pg_temp.as_authenticated_text(v_user, pg_catalog.format('public.is_tenant_member_v1(%L::uuid)',v_dormant))='false',
    'Dormant tenant membership was authorized.');

  perform pg_temp.ok(32, 'authenticated user sees only own memberships',
    pg_temp.as_authenticated_text(v_user, '(select count(*) from public.tenant_memberships)')='2',
    'Own-membership RLS count differs.');
  perform pg_temp.ok(33, 'another user cannot see foreign memberships',
    pg_temp.as_authenticated_text(v_employee, '(select count(*) from public.tenant_memberships)')='1',
    'Membership RLS exposed another user.');
  perform pg_temp.ok(34, 'authenticated cannot self-assign membership',
    pg_temp.as_role_raises('authenticated',v_user,pg_catalog.format('insert into public.tenant_memberships(tenant_id,user_id,role,status) values(%L,%L,%L,%L)',v_csk,v_user,'admin','active'),'42501'),
    'Direct membership INSERT was allowed.');
  perform pg_temp.ok(35, 'authenticated cannot update membership role',
    pg_temp.as_role_raises('authenticated',v_user,pg_catalog.format('update public.tenant_memberships set role=%L where tenant_id=%L and user_id=%L','admin',v_csk,v_user),'42501'),
    'Direct membership UPDATE was allowed.');
  perform pg_temp.ok(36, 'authenticated cannot delete membership',
    pg_temp.as_role_raises('authenticated',v_user,pg_catalog.format('delete from public.tenant_memberships where tenant_id=%L and user_id=%L',v_csk,v_user),'42501'),
    'Direct membership DELETE was allowed.');
  perform pg_temp.ok(37, 'anon cannot execute tenant helper',
    pg_temp.as_role_raises('anon',v_user,pg_catalog.format('select public.is_tenant_member_v1(%L)',v_csk),'42501'),
    'Anon received tenant-helper EXECUTE.');
  perform pg_temp.ok(38, 'service role cannot execute tenant helper',
    pg_temp.as_role_raises('service_role',v_user,pg_catalog.format('select public.is_tenant_member_v1(%L)',v_csk),'42501'),
    'Service role received tenant-helper EXECUTE.');

  perform pg_temp.ok(39, 'tenant helpers are hardened SECURITY DEFINER functions',
    (select pg_catalog.count(*)=3 and pg_catalog.bool_and(function_record.prosecdef)
       and pg_catalog.bool_and(function_record.proconfig @> array['search_path=pg_catalog, public, pg_temp'])
     from pg_catalog.pg_proc function_record
     join pg_catalog.pg_namespace namespace on namespace.oid=function_record.pronamespace
     where namespace.nspname='public'
       and function_record.proname in ('is_tenant_member_v1','has_tenant_role_v1','get_my_tenant_role_v1')),
    'Tenant helper owner/search-path/security contract differs.');
  perform pg_temp.ok(40, 'mapping and trigger functions have no client EXECUTE',
    not exists(
      select 1
      from pg_catalog.pg_proc function_record
      join pg_catalog.pg_namespace namespace on namespace.oid=function_record.pronamespace
      cross join (values('anon'::name),('authenticated'::name),('service_role'::name)) client(role_name)
      where namespace.nspname='public'
        and function_record.proname in (
          'legacy_profile_role_to_tenant_role_v1','tenant_role_to_legacy_profile_role_v1',
          'sync_profile_role_to_csk_membership','sync_csk_membership_role_to_profile'
        )
        and pg_catalog.has_function_privilege(client.role_name,function_record.oid,'EXECUTE')
    ),
    'Internal bridge function is client executable.');
  perform pg_temp.ok(41, 'membership policy is non-recursive and self-scoped',
    (select pg_catalog.count(*)=1
     from pg_catalog.pg_policies
     where schemaname='public' and tablename='tenant_memberships'
       and cmd='SELECT' and qual like '%user_id%auth.uid%'
       and qual not like '%is_tenant_member_v1%'
       and qual not like '%has_tenant_role_v1%'),
    'Membership policy is missing, broad, or recursive.');
  perform pg_temp.ok(42, 'RLS outside approved booking cutover is unchanged',
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),E'\n' order by tablename,policyname),''))='d3c02109fea9966d27cfaef2e481f738'
     from pg_catalog.pg_policies where schemaname='public' and tablename not in ('tenant_memberships','shooting_lanes','reservations','lane_blocks')),
    'RLS changed outside the approved 9C-2 booking tables.');
  perform pg_temp.ok(43, 'legacy role helpers remain profiles based',
    pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure) like '%public.profiles%'
    and pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure) not like '%tenant_memberships%'
    and pg_catalog.pg_get_functiondef('public.is_admin()'::regprocedure) not like '%tenant_memberships%',
    'Legacy runtime authorization source changed early.');
  perform pg_temp.ok(44, 'only approved booking policies consume tenant helpers',
    not exists(
      select 1 from pg_catalog.pg_policies
      where schemaname='public' and tablename not in ('tenant_memberships','shooting_lanes','reservations','lane_blocks')
        and coalesce(qual,'') || coalesce(with_check,'') ~ '(is_tenant_member_v1|has_tenant_role_v1|get_my_tenant_role_v1|is_active_public_tenant_v1)'
    ),
    'Tenant-aware RLS leaked outside the approved booking tables.');
  perform pg_temp.ok(45, 'active-single-tenant helper returns only CSK',
    public.active_single_tenant_id_v1()=v_csk,
    'Internal single-active bridge did not resolve canonical CSK.');

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, banned_until
  ) values (
    v_banned, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'saas9c-banned-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}',
    pg_catalog.now(), pg_catalog.now(), pg_catalog.now() + interval '1 day'
  );
  perform pg_temp.ok(46, 'banned account cannot receive an active CSK membership',
    pg_temp.raises(
      pg_catalog.format(
        'insert into public.profiles(user_id,email,role) values(%L,%L,%L)',
        v_banned, 'saas9c-banned-' || v_run || '@example.invalid', 'user'
      ),
      '23514'
    )
    and not exists(select 1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_banned),
    'Bridge activated a currently banned Auth account.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)
  || test_order || ' - ' || test_name
  || case when passed then '' else E'\n# ' || result end
from pg_temp.test_results order by test_order;

do $assert$
declare v_failed text;
begin
  if (select pg_catalog.count(*) from pg_temp.test_results) <> 46 then
    raise exception 'SAAS-9C-1 expected exactly 46 transactional checks.';
  end if;
  select pg_catalog.string_agg(test_order || '. ' || test_name || ': ' || result,E'\n' order by test_order)
  into v_failed from pg_temp.test_results where not passed;
  if v_failed is not null then raise exception E'SAAS-9C-1 failures:\n%',v_failed; end if;
end;
$assert$;

rollback;

do $cleanup$
begin
  if exists(select 1 from auth.users where email like 'saas9c-%@example.invalid')
     or exists(select 1 from public.profiles where email like 'saas9c-%@example.invalid')
     or exists(select 1 from public.tenants where name like '[TEST][SAAS-9C]%') then
    raise exception 'SAAS-9C-1 rollback cleanup failed.';
  end if;
end;
$cleanup$;

select 'ok 47 - rollback leaves zero SAAS-9C-1 fixture';
