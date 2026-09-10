-- SAAS-9C-1B: tenant membership authorization helper foundation and
-- non-recursive own-membership read. Business-table RLS remains unchanged.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.legacy_profile_role_to_tenant_role_v1(text)') is null
     or pg_catalog.to_regprocedure('public.tenant_role_to_legacy_profile_role_v1(text)') is null
     or pg_catalog.to_regprocedure('public.sync_profile_role_to_csk_membership()') is null
     or pg_catalog.to_regprocedure('public.sync_csk_membership_role_to_profile()') is null then
    raise exception 'SAAS-9C-1B preflight failed: 9C-1A bridge is absent.';
  end if;

  if exists (
    select 1
    from public.profiles profile
    left join public.tenant_memberships membership
      on membership.tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid
     and membership.user_id = profile.user_id
    where membership.user_id is null
       or membership.role is distinct from public.legacy_profile_role_to_tenant_role_v1(profile.role)
  ) then
    raise exception 'SAAS-9C-1B preflight failed: legacy/member role drift exists.';
  end if;

  if pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is not null
     or pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is not null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is not null
     or pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is not null then
    raise exception 'SAAS-9C-1B preflight failed: planned helper already exists.';
  end if;
end;
$preflight$;

create temporary table saas9c1b_security_snapshot as
select
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|', tablename, policyname, cmd, roles::text, qual, with_check),
      E'\n' order by tablename, policyname
    ) from pg_catalog.pg_policies
    where schemaname = 'public' and tablename <> 'tenant_memberships'
  ), '')) as non_membership_policy_fingerprint,
  pg_catalog.md5(pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure)) as get_my_role_fingerprint,
  pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin()'::regprocedure)) as is_admin_fingerprint,
  pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin_or_employee()'::regprocedure)) as is_admin_or_employee_fingerprint,
  pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin_or_staff()'::regprocedure)) as is_admin_or_staff_fingerprint;

create function public.is_tenant_member_v1(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select p_tenant_id is not null
    and auth.uid() is not null
    and exists (
      select 1
      from public.tenant_memberships membership
      join public.tenants tenant on tenant.id = membership.tenant_id
      where membership.tenant_id = p_tenant_id
        and membership.user_id = auth.uid()
        and membership.status = 'active'
        and tenant.status = 'active'
    );
$function$;

alter function public.is_tenant_member_v1(uuid) owner to postgres;
revoke all on function public.is_tenant_member_v1(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.is_tenant_member_v1(uuid) to authenticated;

create function public.has_tenant_role_v1(p_tenant_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select p_tenant_id is not null
    and auth.uid() is not null
    and p_roles is not null
    and pg_catalog.cardinality(p_roles) > 0
    and not exists (
      select 1 from pg_catalog.unnest(p_roles) requested(role)
      where requested.role is null
         or requested.role not in ('admin', 'employee', 'user', 'instructor')
    )
    and exists (
      select 1
      from public.tenant_memberships membership
      join public.tenants tenant on tenant.id = membership.tenant_id
      where membership.tenant_id = p_tenant_id
        and membership.user_id = auth.uid()
        and membership.status = 'active'
        and membership.role = any (p_roles)
        and tenant.status = 'active'
    );
$function$;

alter function public.has_tenant_role_v1(uuid, text[]) owner to postgres;
revoke all on function public.has_tenant_role_v1(uuid, text[])
  from public, anon, authenticated, service_role;
grant execute on function public.has_tenant_role_v1(uuid, text[]) to authenticated;

create function public.get_my_tenant_role_v1(p_tenant_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select membership.role
  from public.tenant_memberships membership
  join public.tenants tenant on tenant.id = membership.tenant_id
  where p_tenant_id is not null
    and auth.uid() is not null
    and membership.tenant_id = p_tenant_id
    and membership.user_id = auth.uid()
    and membership.status = 'active'
    and tenant.status = 'active';
$function$;

alter function public.get_my_tenant_role_v1(uuid) owner to postgres;
revoke all on function public.get_my_tenant_role_v1(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_my_tenant_role_v1(uuid) to authenticated;

create function public.active_single_tenant_id_v1()
returns uuid
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select tenant.id
  from public.tenants tenant
  where tenant.status = 'active'
    and (select pg_catalog.count(*) from public.tenants active_tenant where active_tenant.status = 'active') = 1;
$function$;

alter function public.active_single_tenant_id_v1() owner to postgres;
revoke all on function public.active_single_tenant_id_v1()
  from public, anon, authenticated, service_role;

grant select on table public.tenant_memberships to authenticated;

create policy "Users can view own tenant memberships"
on public.tenant_memberships
for select
to authenticated
using (user_id = (select auth.uid()));

do $postflight$
declare
  v_snapshot record;
begin
  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'tenant_memberships') <> 1
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'tenant_memberships'
         and policyname = 'Users can view own tenant memberships'
         and cmd = 'SELECT'
         and roles = array['authenticated']::name[]
     ) then
    raise exception 'SAAS-9C-1B postflight failed: membership policy differs.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated', 'public.tenant_memberships', 'SELECT')
     or pg_catalog.has_table_privilege('authenticated', 'public.tenant_memberships', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
     or pg_catalog.has_table_privilege('anon', 'public.tenant_memberships', 'SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('service_role', 'public.tenant_memberships', 'SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'SAAS-9C-1B postflight failed: membership ACL differs.';
  end if;

  select * into v_snapshot from saas9c1b_security_snapshot;
  if v_snapshot.non_membership_policy_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|', tablename, policyname, cmd, roles::text, qual, with_check),
         E'\n' order by tablename, policyname
       ) from pg_catalog.pg_policies
       where schemaname = 'public' and tablename <> 'tenant_memberships'
     ), ''))
     or v_snapshot.get_my_role_fingerprint is distinct from pg_catalog.md5(pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure))
     or v_snapshot.is_admin_fingerprint is distinct from pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin()'::regprocedure))
     or v_snapshot.is_admin_or_employee_fingerprint is distinct from pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin_or_employee()'::regprocedure))
     or v_snapshot.is_admin_or_staff_fingerprint is distinct from pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin_or_staff()'::regprocedure)) then
    raise exception 'SAAS-9C-1B postflight failed: legacy authorization or unrelated RLS changed.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;
