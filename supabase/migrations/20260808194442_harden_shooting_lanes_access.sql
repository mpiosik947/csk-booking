do $preflight$
declare
  v_table_oid oid;
  v_staff_oid oid;
  v_employee_oid oid;
  v_staff_definition text;
  v_employee_definition text;
  v_expected_full_acl constant text[] := array[
    'DELETE', 'INSERT', 'MAINTAIN', 'REFERENCES',
    'SELECT', 'TRIGGER', 'TRUNCATE', 'UPDATE'
  ];
begin
  v_table_oid := pg_catalog.to_regclass('public.shooting_lanes');
  v_staff_oid := pg_catalog.to_regprocedure('public.is_admin_or_staff()');
  v_employee_oid := pg_catalog.to_regprocedure('public.is_admin_or_employee()');

  if v_table_oid is null then
    raise exception 'Preflight failed: public.shooting_lanes does not exist.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class as table_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = table_record.relnamespace
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = table_record.relowner
    where table_record.oid = v_table_oid
      and namespace_record.nspname = 'public'
      and table_record.relkind = 'r'
      and owner_role.rolname = 'postgres'
      and table_record.relrowsecurity
      and not table_record.relforcerowsecurity
  ) then
    raise exception 'Preflight failed: unexpected owner or RLS flags on public.shooting_lanes.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'shooting_lanes') <> 2
     or not exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'shooting_lanes'
         and policyname = 'Admins and staff can manage shooting lanes'
         and permissive = 'PERMISSIVE'
         and roles = array['authenticated']::name[]
         and cmd = 'ALL'
         and qual = 'is_admin_or_staff()'
         and with_check = 'is_admin_or_staff()'
     )
     or not exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'shooting_lanes'
         and policyname = 'Public can view active shooting lanes'
         and permissive = 'PERMISSIVE'
         and roles = array['public']::name[]
         and cmd = 'SELECT'
         and qual = '(is_active = true)'
         and with_check is null
     ) then
    raise exception 'Preflight failed: unexpected public.shooting_lanes policies.';
  end if;

  if v_staff_oid is null
     or (select pg_catalog.count(*)
         from pg_catalog.pg_proc as procedure_record
         join pg_catalog.pg_namespace as namespace_record
           on namespace_record.oid = procedure_record.pronamespace
         where namespace_record.nspname = 'public'
           and procedure_record.proname = 'is_admin_or_staff') <> 1
     or v_employee_oid is null
     or (select pg_catalog.count(*)
         from pg_catalog.pg_proc as procedure_record
         join pg_catalog.pg_namespace as namespace_record
           on namespace_record.oid = procedure_record.pronamespace
         where namespace_record.nspname = 'public'
           and procedure_record.proname = 'is_admin_or_employee') <> 1 then
    raise exception 'Preflight failed: unexpected role helper signatures or overloads.';
  end if;

  select pg_catalog.lower(pg_catalog.pg_get_functiondef(v_staff_oid)),
         pg_catalog.lower(pg_catalog.pg_get_functiondef(v_employee_oid))
  into v_staff_definition, v_employee_definition;

  if not exists (
       select 1
       from pg_catalog.pg_proc as procedure_record
       join pg_catalog.pg_language as language_record
         on language_record.oid = procedure_record.prolang
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = procedure_record.proowner
       where procedure_record.oid = v_staff_oid
         and language_record.lanname = 'sql'
         and owner_role.rolname = 'postgres'
         and procedure_record.prosecdef
         and procedure_record.provolatile = 's'
         and procedure_record.proconfig = array['search_path=public']
     )
     or v_staff_definition !~ 'from[[:space:]]+public[.]profiles'
     or v_staff_definition !~ 'user_id[[:space:]]*=[[:space:]]*auth[.]uid[(][)]'
     or v_staff_definition !~ '''admin''[^;]+''pracownik''[^;]+''instruktor'''
     or v_staff_definition ~ '''user'''
     or not exists (
       select 1
       from pg_catalog.pg_proc as procedure_record
       join pg_catalog.pg_language as language_record
         on language_record.oid = procedure_record.prolang
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = procedure_record.proowner
       where procedure_record.oid = v_employee_oid
         and language_record.lanname = 'sql'
         and owner_role.rolname = 'postgres'
         and procedure_record.prosecdef
         and procedure_record.provolatile = 's'
         and procedure_record.proconfig = array['search_path=public']
     )
     or v_employee_definition !~ 'from[[:space:]]+public[.]profiles'
     or v_employee_definition !~ 'user_id[[:space:]]*=[[:space:]]*auth[.]uid[(][)]'
     or v_employee_definition !~ 'lower[(]btrim[(]role::text[)][)][[:space:]]+in[[:space:]]*[(]''admin'',[[:space:]]*''pracownik''[)]'
     or v_employee_definition ~ '''instruktor'''
     or v_employee_definition ~ '''user''' then
    raise exception 'Preflight failed: unexpected role helper definition.';
  end if;

  if exists (
       select 1
       from pg_catalog.pg_class as table_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           table_record.relacl,
           pg_catalog.acldefault('r', table_record.relowner)
         )
       ) as acl
       where table_record.oid = v_table_oid
         and acl.grantee = 0
     ) then
    raise exception 'Preflight failed: PUBLIC unexpectedly has shooting_lanes privileges.';
  end if;

  if (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = v_table_oid
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon'))
       is distinct from v_expected_full_acl
     or (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = v_table_oid
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'authenticated'))
       is distinct from v_expected_full_acl
     or (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = v_table_oid
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'service_role'))
       is distinct from v_expected_full_acl
     or (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = v_table_oid
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'postgres'))
       is distinct from v_expected_full_acl then
    raise exception 'Preflight failed: unexpected public.shooting_lanes ACL.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_class as table_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
    ) as acl
    left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
    where table_record.oid = v_table_oid
      and acl.grantee <> 0
      and grantee_role.rolname not in ('postgres', 'anon', 'authenticated', 'service_role')
  ) then
    raise exception 'Preflight failed: unexpected public.shooting_lanes ACL grantee.';
  end if;
end;
$preflight$;

revoke all privileges on table public.shooting_lanes from public;
revoke all privileges on table public.shooting_lanes from anon;
revoke all privileges on table public.shooting_lanes from authenticated;

grant select on table public.shooting_lanes to anon;
grant select on table public.shooting_lanes to authenticated;

drop policy "Admins and staff can manage shooting lanes"
on public.shooting_lanes;

create policy "Staff can view all shooting lanes"
on public.shooting_lanes
for select
to authenticated
using (public.is_admin_or_staff());

do $postflight$
declare
  v_table_oid oid := pg_catalog.to_regclass('public.shooting_lanes');
  v_expected_full_acl constant text[] := array[
    'DELETE', 'INSERT', 'MAINTAIN', 'REFERENCES',
    'SELECT', 'TRIGGER', 'TRUNCATE', 'UPDATE'
  ];
begin
  if v_table_oid is null
     or (select pg_catalog.count(*) from pg_catalog.pg_policies
         where schemaname = 'public' and tablename = 'shooting_lanes') <> 2
     or (select pg_catalog.count(*) from pg_catalog.pg_policies
         where schemaname = 'public'
           and tablename = 'shooting_lanes'
           and cmd = 'SELECT') <> 2
     or exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'shooting_lanes'
         and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')
     )
     or not exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'shooting_lanes'
         and policyname = 'Public can view active shooting lanes'
         and permissive = 'PERMISSIVE'
         and roles = array['public']::name[]
         and cmd = 'SELECT'
         and qual = '(is_active = true)'
         and with_check is null
     )
     or not exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'shooting_lanes'
         and policyname = 'Staff can view all shooting lanes'
         and permissive = 'PERMISSIVE'
         and roles = array['authenticated']::name[]
         and cmd = 'SELECT'
         and qual = 'is_admin_or_staff()'
         and with_check is null
     ) then
    raise exception 'Postflight failed: unexpected public.shooting_lanes policies.';
  end if;

  if exists (
       select 1
       from pg_catalog.pg_class as table_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
       ) as acl
       where table_record.oid = v_table_oid
         and acl.grantee = 0
     )
     or (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = v_table_oid
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon'))
       is distinct from array['SELECT']::text[]
     or (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = v_table_oid
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'authenticated'))
       is distinct from array['SELECT']::text[]
     or (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = v_table_oid
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'service_role'))
       is distinct from v_expected_full_acl then
    raise exception 'Postflight failed: unexpected public.shooting_lanes ACL.';
  end if;
end;
$postflight$;
