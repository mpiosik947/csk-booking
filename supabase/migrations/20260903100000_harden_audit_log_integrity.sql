-- SEC-007: audit records are append-only from the application perspective.
-- Trusted SECURITY DEFINER functions owned by postgres remain responsible for
-- creating audit entries; client roles retain no direct mutation privileges.

do $preflight$
declare
  v_table_oid oid := pg_catalog.to_regclass('public.audit_logs');
begin
  if v_table_oid is null then
    raise exception 'SEC-007 preflight failed: public.audit_logs does not exist.';
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
    raise exception 'SEC-007 preflight failed: audit_logs owner or RLS state is unexpected.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'audit_logs'
      and policy.policyname = 'Admins can insert audit logs'
      and policy.cmd = 'INSERT'
      and policy.roles = array['authenticated']::name[]
      and policy.qual is null
      and policy.with_check = 'is_admin_or_staff()'
  ) then
    raise exception 'SEC-007 preflight failed: expected audit INSERT policy is absent or changed.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'audit_logs'
      and policy.policyname = 'Admins can view audit logs'
      and policy.cmd = 'SELECT'
      and policy.roles = array['authenticated']::name[]
      and policy.qual = 'is_admin()'
      and policy.with_check is null
  ) then
    raise exception 'SEC-007 preflight failed: expected audit SELECT policy is absent or changed.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'audit_logs'
  ) <> 2 then
    raise exception 'SEC-007 preflight failed: unexpected audit_logs policy inventory.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated', v_table_oid, 'INSERT')
     or not pg_catalog.has_table_privilege('authenticated', v_table_oid, 'SELECT') then
    raise exception 'SEC-007 preflight failed: authenticated audit_logs ACL is unexpected.';
  end if;

  if pg_catalog.has_table_privilege(
    'authenticated', v_table_oid,
    'UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
  ) then
    raise exception 'SEC-007 preflight failed: authenticated already has unexpected audit mutation privileges.';
  end if;

  if pg_catalog.has_table_privilege(
    'anon', v_table_oid,
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
  ) or exists (
    select 1
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation.relacl,pg_catalog.acldefault('r',relation.relowner))
    ) as acl
    where relation.oid=v_table_oid
      and acl.grantee=0
  ) then
    raise exception 'SEC-007 preflight failed: anon or PUBLIC has unexpected audit_logs privileges.';
  end if;
end;
$preflight$;

drop policy "Admins can insert audit logs" on public.audit_logs;

revoke all privileges on table public.audit_logs from public, anon, authenticated;
grant select on table public.audit_logs to authenticated;

do $postflight$
begin
  if exists (
    select 1
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation.relacl,pg_catalog.acldefault('r',relation.relowner))
    ) as acl
    where relation.oid='public.audit_logs'::regclass
      and acl.grantee=0
  ) or pg_catalog.has_table_privilege(
    'anon', 'public.audit_logs',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
  ) then
    raise exception 'SEC-007 postflight failed: PUBLIC or anon audit_logs privileges remain.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated', 'public.audit_logs', 'SELECT')
     or pg_catalog.has_table_privilege(
       'authenticated', 'public.audit_logs',
       'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
     ) then
    raise exception 'SEC-007 postflight failed: authenticated ACL is not SELECT-only.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'audit_logs'
      and policy.cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'SEC-007 postflight failed: a client mutation policy remains.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'audit_logs'
      and policy.policyname = 'Admins can view audit logs'
      and policy.cmd = 'SELECT'
      and policy.roles = array['authenticated']::name[]
      and policy.qual = 'is_admin()'
      and policy.with_check is null
  ) <> 1 then
    raise exception 'SEC-007 postflight failed: admin SELECT policy changed.';
  end if;
end;
$postflight$;
