\set ON_ERROR_STOP on
\pset format unaligned

select '1..30';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer, text, boolean, text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1, $2, coalesce($3, false), $4);
$function$;

create function pg_temp.statement_raises(p_sql text, p_state text)
returns boolean language plpgsql as $function$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlstate = p_state;
end;
$function$;

create function pg_temp.role_statement_raises(p_role text, p_sql text, p_state text)
returns boolean language plpgsql as $function$
begin
  execute pg_catalog.format('set local role %I', p_role);
  execute p_sql;
  execute 'reset role';
  return false;
exception when others then
  execute 'reset role';
  return sqlstate = p_state;
end;
$function$;

do $tests$
declare
  v_user uuid := pg_catalog.gen_random_uuid();
  v_second_tenant uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');
begin
  perform pg_temp.record_result(1, 'Tenant tables exist',
    pg_catalog.to_regclass('public.tenants') is not null
    and pg_catalog.to_regclass('public.tenant_memberships') is not null,
    'Both dormant foundation tables must exist.');

  perform pg_temp.record_result(2, 'Tenant tables are postgres-owned with RLS',
    (select pg_catalog.count(*) = 2
     from pg_catalog.pg_class relation
     join pg_catalog.pg_roles owner_role on owner_role.oid = relation.relowner
     where relation.oid in (
       'public.tenants'::pg_catalog.regclass,
       'public.tenant_memberships'::pg_catalog.regclass
     ) and relation.relrowsecurity and owner_role.rolname = 'postgres'),
    'Both objects must be postgres-owned and RLS-enabled.');

  perform pg_temp.record_result(3, 'CSK is the sole bootstrap tenant',
    (select pg_catalog.count(*) = 1 from public.tenants)
    and exists (
      select 1 from public.tenants
      where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
        and name = 'CSK' and slug = 'csk' and status = 'active'
    ),
    'The additive migration must create exactly the canonical CSK tenant.');

  perform pg_temp.record_result(4, 'No existing-user memberships were guessed',
    not exists (select 1 from public.tenant_memberships),
    'SAAS-9B-1 intentionally leaves membership backfill to a later phase.');

  perform pg_temp.record_result(5, 'Tenant lifecycle is minimal and constrained',
    pg_temp.statement_raises(
      'insert into public.tenants(name,slug,status) values (''Invalid'',''invalid-status'',''unknown'')',
      '23514'
    ),
    'Unknown tenant status must fail its CHECK constraint.');

  perform pg_temp.record_result(6, 'Tenant slug rejects uppercase',
    pg_temp.statement_raises(
      'insert into public.tenants(name,slug,status) values (''Invalid'',''Uppercase'',''dormant'')',
      '23514'
    ),
    'Slug must be normalized lowercase.');

  perform pg_temp.record_result(7, 'Tenant slug rejects unsafe format',
    pg_temp.statement_raises(
      'insert into public.tenants(name,slug,status) values (''Invalid'',''bad slug!'',''dormant'')',
      '23514'
    ),
    'Slug permits only lowercase alphanumeric segments separated by hyphens.');

  perform pg_temp.record_result(8, 'Tenant name rejects blank input',
    pg_temp.statement_raises(
      'insert into public.tenants(name,slug,status) values (''   '',''blank-name'',''dormant'')',
      '23514'
    ),
    'Name must be trimmed and non-empty.');

  perform pg_temp.record_result(9, 'Second active tenant insert is technically blocked',
    pg_temp.statement_raises(
      'insert into public.tenants(name,slug,status) values (''Second active'',''second-active'',''active'')',
      '23505'
    ),
    'Partial unique guard must prevent another active runtime tenant.');

  insert into public.tenants(id, name, slug, status)
  values (v_second_tenant, 'Dormant test tenant', 'dormant-' || pg_catalog.left(v_run, 16), 'dormant');

  perform pg_temp.record_result(10, 'Dormant tenant preparation remains possible',
    exists (select 1 from public.tenants where id = v_second_tenant and status = 'dormant'),
    'Foundation may represent a non-running tenant for later controlled work.');

  perform pg_temp.record_result(11, 'Second tenant activation is technically blocked',
    pg_temp.statement_raises(
      pg_catalog.format('update public.tenants set status=''active'' where id=%L::uuid', v_second_tenant),
      '23505'
    ),
    'The guard must apply to UPDATE as well as INSERT.');

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values (
    v_user, '00000000-0000-0000-0000-000000000000', 'authenticated',
    'authenticated', 'saas9b1-' || v_run || '@example.invalid', '',
    pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()
  );

  insert into public.tenant_memberships(tenant_id, user_id, role, status)
  values (v_second_tenant, v_user, 'admin', 'active');
  perform pg_temp.record_result(12, 'Membership accepts tenant-scoped admin role',
    exists (
      select 1 from public.tenant_memberships
      where tenant_id = v_second_tenant and user_id = v_user
        and role = 'admin' and status = 'active'
    ),
    'Future admin authority is represented only inside one tenant membership.');

  perform pg_temp.record_result(13, 'One membership per user and tenant is enforced',
    pg_temp.statement_raises(
      pg_catalog.format(
        'insert into public.tenant_memberships(tenant_id,user_id,role,status) values (%L::uuid,%L::uuid,''user'',''pending'')',
        v_second_tenant, v_user
      ),
      '23505'
    ),
    'Composite primary key prevents duplicate relationships.');

  perform pg_temp.record_result(14, 'Invalid membership role is rejected',
    pg_temp.statement_raises(
      pg_catalog.format(
        'update public.tenant_memberships set role=''owner'' where tenant_id=%L::uuid and user_id=%L::uuid',
        v_second_tenant, v_user
      ),
      '23514'
    ),
    'Only admin, employee and user belong to this foundation.');

  perform pg_temp.record_result(15, 'Invalid membership status is rejected',
    pg_temp.statement_raises(
      pg_catalog.format(
        'update public.tenant_memberships set status=''disabled'' where tenant_id=%L::uuid and user_id=%L::uuid',
        v_second_tenant, v_user
      ),
      '23514'
    ),
    'Only active, pending and suspended are valid membership states.');

  perform pg_temp.record_result(16, 'Membership tenant FK is enforced',
    pg_temp.statement_raises(
      pg_catalog.format(
        'insert into public.tenant_memberships(tenant_id,user_id,role,status) values (%L::uuid,%L::uuid,''user'',''pending'')',
        pg_catalog.gen_random_uuid(), v_user
      ),
      '23503'
    ),
    'A membership cannot reference an unknown tenant.');

  perform pg_temp.record_result(17, 'Membership auth user FK is enforced',
    pg_temp.statement_raises(
      pg_catalog.format(
        'insert into public.tenant_memberships(tenant_id,user_id,role,status) values (%L::uuid,%L::uuid,''user'',''pending'')',
        v_second_tenant, pg_catalog.gen_random_uuid()
      ),
      '23503'
    ),
    'A membership cannot reference an unknown global Auth account.');

  perform pg_temp.record_result(18, 'Membership updated_at trigger works',
    exists (
      select 1
      from pg_catalog.pg_trigger trigger_record
      where trigger_record.tgrelid = 'public.tenant_memberships'::regclass
        and trigger_record.tgname = 'set_tenant_memberships_updated_at'
        and not trigger_record.tgisinternal
        and trigger_record.tgenabled = 'O'
    ),
    'The shared timestamp trigger must be installed and enabled.');

  perform pg_temp.record_result(19, 'Client and service roles have no tenant ACL',
    not exists (
      select 1
      from (values ('anon'::name), ('authenticated'::name), ('service_role'::name)) role_name(role_name)
      cross join (values ('public.tenants'::regclass), ('public.tenant_memberships'::regclass)) object_name(object_name)
      where pg_catalog.has_table_privilege(
        role_name.role_name,
        object_name.object_name,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
      )
    ),
    'Dormant tables are owner/migration managed only.');

  perform pg_temp.record_result(20, 'PUBLIC has no tenant table ACL',
    not exists (
      select 1
      from pg_catalog.pg_class relation
      cross join lateral pg_catalog.aclexplode(
        coalesce(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
      ) acl
      where relation.oid in (
        'public.tenants'::pg_catalog.regclass,
        'public.tenant_memberships'::pg_catalog.regclass
      ) and acl.grantee = 0
    ),
    'No generic PUBLIC privilege may exist.');

  perform pg_temp.record_result(21, 'Dormant tables define no RLS allow policy',
    not exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'public'
        and tablename in ('tenants', 'tenant_memberships')
    ),
    'No role is authorized before the tenant-aware cutover.');

  perform pg_temp.record_result(22, 'Authenticated direct tenant access is ACL-denied',
    pg_temp.role_statement_raises('authenticated', 'select * from public.tenants', '42501')
    and pg_temp.role_statement_raises(
      'authenticated',
      'insert into public.tenants(name,slug,status) values (''Escalation'',''escalation'',''dormant'')',
      '42501'
    ),
    'Ordinary users cannot read or provision tenants.');

  perform pg_temp.record_result(23, 'Authenticated cannot self-assign membership',
    pg_temp.role_statement_raises(
      'authenticated',
      pg_catalog.format(
        'insert into public.tenant_memberships(tenant_id,user_id,role,status) values (''c5c00000-0000-4000-8000-000000000001'',%L::uuid,''admin'',''active'')',
        v_user
      ),
      '42501'
    ),
    'No client path can grant an admin membership.');

  perform pg_temp.record_result(24, 'Anon cannot access tenant foundation',
    pg_temp.role_statement_raises('anon', 'select * from public.tenants', '42501')
    and pg_temp.role_statement_raises('anon', 'select * from public.tenant_memberships', '42501'),
    'Public discovery is intentionally absent in SAAS-9B-1.');

  perform pg_temp.record_result(25, 'Service role has no dormant-table bypass ACL',
    pg_temp.role_statement_raises('service_role', 'select * from public.tenants', '42501')
    and pg_temp.role_statement_raises('service_role', 'select * from public.tenant_memberships', '42501'),
    'No application server contract needs these tables yet.');

  perform pg_temp.record_result(26, 'No tenant management SECURITY DEFINER RPC was added',
    not exists (
      select 1
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'public'
        and procedure.proname like '%tenant%'
        and procedure.prosecdef
    ),
    'Bootstrap and the runtime guard use tables, constraints and migration-time data only.');

  perform pg_temp.record_result(27, 'Legacy profiles.role remains present',
    exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'profiles'
        and column_name = 'role' and is_nullable = 'NO'
    ),
    'Current V1 authorization source must remain unchanged.');

  perform pg_temp.record_result(28, 'Legacy role helpers do not read memberships',
    pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure) like '%public.profiles%'
    and pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure) not like '%tenant_memberships%'
    and pg_catalog.pg_get_functiondef('public.is_admin()'::regprocedure) not like '%tenant_memberships%',
    'Tenant membership role must remain dormant, never a parallel active source.');

  perform pg_temp.record_result(29, 'Existing critical runtime contracts remain present',
    pg_catalog.to_regprocedure('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)') is not null
    and pg_catalog.to_regprocedure('public.get_public_event_list_v2(text,text,integer,integer)') is not null
    and pg_catalog.to_regprocedure('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)') is not null
    and pg_catalog.to_regprocedure('public.get_check_in_reservation_v1(uuid)') is not null,
    'Booking, Events, Reports and Check-in contracts must not be replaced.');

  perform pg_temp.record_result(30, 'Later ownership remains limited to approved SAAS-9B-2 tables',
    (select pg_catalog.count(*) = 8
     from information_schema.columns
     where table_schema = 'public' and column_name = 'tenant_id'
       and table_name in (
         'shooting_lanes', 'reservations', 'lane_blocks', 'events',
         'event_lanes', 'event_registrations', 'email_deliveries', 'audit_logs'
       ))
    and not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and column_name = 'tenant_id'
        and table_name not in (
          'tenant_memberships', 'shooting_lanes', 'reservations', 'lane_blocks',
          'events', 'event_lanes', 'event_registrations', 'email_deliveries',
          'audit_logs'
        )
    ),
    'Tenant ownership must not spread outside the approved SAAS-9B-2 scope.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)
  || test_order::text || ' - ' || test_name
  || case when passed then '' else E'\n# ' || result end
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  ) into v_failures
  from pg_temp.test_results
  where not passed;

  if v_failures is not null then
    raise exception 'SAAS-9B-1 tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
