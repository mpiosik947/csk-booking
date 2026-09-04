-- CLEAN-004: application roles must preserve reservation history and use controlled lifecycle RPCs.

do $preflight$
declare
  v_table_oid oid := pg_catalog.to_regclass('public.reservations');
begin
  if v_table_oid is null then
    raise exception 'CLEAN-004 preflight failed: public.reservations does not exist.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_roles as owner_role on owner_role.oid = relation.relowner
    where relation.oid = v_table_oid
      and relation.relkind in ('r', 'p')
      and relation.relrowsecurity
      and owner_role.rolname = 'postgres'
  ) then
    raise exception 'CLEAN-004 preflight failed: table owner or RLS state is unexpected.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'reservations'
  ) <> 3 or not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and policyname = 'Admins can delete reservations'
      and cmd = 'DELETE'
      and roles = array['authenticated']::name[]
      and qual = 'is_admin()'
      and with_check is null
  ) or not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and policyname = 'Admins and staff can view all reservations'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and qual = 'is_admin_or_employee()'
      and with_check is null
  ) or not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and policyname = 'Users can view own reservations'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and qual = '(user_id = auth.uid())'
      and with_check is null
  ) then
    raise exception 'CLEAN-004 preflight failed: reservation policy inventory is unexpected.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated', v_table_oid, 'SELECT')
     or not pg_catalog.has_table_privilege('authenticated', v_table_oid, 'DELETE')
     or pg_catalog.has_table_privilege('authenticated', v_table_oid, 'INSERT')
     or pg_catalog.has_table_privilege('authenticated', v_table_oid, 'UPDATE')
     or pg_catalog.has_table_privilege('authenticated', v_table_oid, 'TRUNCATE')
     or pg_catalog.has_table_privilege('authenticated', v_table_oid, 'REFERENCES')
     or pg_catalog.has_table_privilege('authenticated', v_table_oid, 'TRIGGER')
     or pg_catalog.has_table_privilege('authenticated', v_table_oid, 'MAINTAIN') then
    raise exception 'CLEAN-004 preflight failed: authenticated table ACL is unexpected.';
  end if;

  if pg_catalog.has_table_privilege(
    'anon', v_table_oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
  ) or exists (
    select 1
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
    ) as acl
    where relation.oid = v_table_oid
      and acl.grantee = 0
  ) then
    raise exception 'CLEAN-004 preflight failed: anon or PUBLIC has unexpected table ACL.';
  end if;

  if not pg_catalog.has_table_privilege('service_role', v_table_oid, 'SELECT')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'INSERT')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'UPDATE')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'DELETE')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'TRUNCATE')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'REFERENCES')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'TRIGGER')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'MAINTAIN') then
    raise exception 'CLEAN-004 preflight failed: service_role table ACL is unexpected.';
  end if;

  if pg_catalog.to_regprocedure('public.cancel_reservation(uuid)') is null
     or pg_catalog.to_regprocedure('public.anonymize_my_account_v1()') is null then
    raise exception 'CLEAN-004 preflight failed: required controlled lifecycle RPC is absent.';
  end if;
end;
$preflight$;

drop policy "Admins can delete reservations" on public.reservations;
revoke delete on table public.reservations from authenticated;

do $postflight$
declare
  v_table_oid oid := 'public.reservations'::regclass;
begin
  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
  ) <> 2 or exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) or not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and policyname = 'Admins and staff can view all reservations'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and qual = 'is_admin_or_employee()'
      and with_check is null
  ) or not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and policyname = 'Users can view own reservations'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and qual = '(user_id = auth.uid())'
      and with_check is null
  ) then
    raise exception 'CLEAN-004 postflight failed: reservation policies are unexpected.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated', v_table_oid, 'SELECT')
     or pg_catalog.has_table_privilege(
       'authenticated', v_table_oid,
       'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
     ) then
    raise exception 'CLEAN-004 postflight failed: authenticated table ACL is not SELECT-only.';
  end if;

  if pg_catalog.has_table_privilege(
    'anon', v_table_oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
  ) or exists (
    select 1
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
    ) as acl
    where relation.oid = v_table_oid
      and acl.grantee = 0
  ) then
    raise exception 'CLEAN-004 postflight failed: anon or PUBLIC has unexpected table ACL.';
  end if;

  if not pg_catalog.has_table_privilege('service_role', v_table_oid, 'SELECT')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'INSERT')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'UPDATE')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'DELETE')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'TRUNCATE')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'REFERENCES')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'TRIGGER')
     or not pg_catalog.has_table_privilege('service_role', v_table_oid, 'MAINTAIN') then
    raise exception 'CLEAN-004 postflight failed: service_role table ACL changed.';
  end if;
end;
$postflight$;
