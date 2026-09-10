-- SAAS-9C-2A/2B: tenant-aware direct-table RLS for the booking domain.
-- Legacy SECURITY DEFINER RPCs are intentionally unchanged and remain 9D work.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null then
    raise exception 'SAAS-9C-2 preflight failed: 9C-1 authorization foundation is absent.';
  end if;

  if exists (
    select 1
    from public.profiles profile
    left join public.tenant_memberships membership
      on membership.tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid
     and membership.user_id = profile.user_id
    where membership.user_id is null
       or membership.status <> 'active'
       or membership.role is distinct from public.legacy_profile_role_to_tenant_role_v1(profile.role)
  ) then
    raise exception 'SAAS-9C-2 preflight failed: CSK profile/membership reconciliation differs.';
  end if;

  if pg_catalog.to_regprocedure('public.is_active_public_tenant_v1(uuid)') is not null then
    raise exception 'SAAS-9C-2 preflight failed: public tenant policy helper already exists.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname = 'public' and tablename in ('shooting_lanes','reservations','lane_blocks')) <> 6
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='shooting_lanes' and policyname='Public can view active shooting lanes' and cmd='SELECT' and qual='(is_active = true)')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='shooting_lanes' and policyname='Staff can view all shooting lanes' and cmd='SELECT' and qual='is_admin_or_staff()')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='reservations' and policyname='Users can view own reservations' and cmd='SELECT' and qual='(user_id = auth.uid())')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='reservations' and policyname='Admins and staff can view all reservations' and cmd='SELECT' and qual='is_admin_or_employee()')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='lane_blocks' and policyname='Anyone can view active lane blocks' and cmd='SELECT' and qual='(is_active = true)')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='lane_blocks' and policyname='Admins and staff can view all lane blocks' and cmd='SELECT' and qual='is_admin_or_staff()') then
    raise exception 'SAAS-9C-2 preflight failed: booking policy baseline drifted.';
  end if;
end;
$preflight$;

create temporary table saas9c2_security_snapshot as
select
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|', tablename, policyname, cmd, roles::text, qual, with_check),
      E'\n' order by tablename, policyname
    )
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename not in ('shooting_lanes','reservations','lane_blocks')
  ), '')) as unrelated_policy_fingerprint,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|', n.nspname, p.proname,
        pg_catalog.pg_get_function_identity_arguments(p.oid),
        p.prosecdef::text, pg_catalog.pg_get_userbyid(p.proowner),
        coalesce(p.proconfig::text,''), pg_catalog.pg_get_functiondef(p.oid)),
      E'\n' order by n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid)
    )
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  ), '')) as security_definer_fingerprint,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|', table_name, grantee, privilege_type),
      E'\n' order by table_name, grantee, privilege_type
    )
    from information_schema.role_table_grants
    where table_schema='public'
      and table_name in ('shooting_lanes','reservations','lane_blocks')
  ), '')) as booking_acl_fingerprint;

create function public.is_active_public_tenant_v1(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select p_tenant_id is not null
    and exists (
      select 1
      from public.tenants tenant
      where tenant.id = p_tenant_id
        and tenant.status = 'active'
    )
    and (
      select pg_catalog.count(*) = 1
      from public.tenants active_tenant
      where active_tenant.status = 'active'
    );
$function$;

alter function public.is_active_public_tenant_v1(uuid) owner to postgres;
revoke all on function public.is_active_public_tenant_v1(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.is_active_public_tenant_v1(uuid) to anon, authenticated;

drop policy "Public can view active shooting lanes" on public.shooting_lanes;
drop policy "Staff can view all shooting lanes" on public.shooting_lanes;

create policy "Public can view active tenant shooting lanes"
on public.shooting_lanes
for select
to anon, authenticated
using (
  is_active = true
  and public.is_active_public_tenant_v1(tenant_id)
);

create policy "Tenant staff can view shooting lanes"
on public.shooting_lanes
for select
to authenticated
using (
  public.has_tenant_role_v1(tenant_id, array['admin','employee','instructor']::text[])
);

drop policy "Users can view own reservations" on public.reservations;
drop policy "Admins and staff can view all reservations" on public.reservations;

create policy "Tenant members can view own reservations"
on public.reservations
for select
to authenticated
using (
  user_id = (select auth.uid())
  and public.is_tenant_member_v1(tenant_id)
);

create policy "Tenant admin and employee can view reservations"
on public.reservations
for select
to authenticated
using (
  public.has_tenant_role_v1(tenant_id, array['admin','employee']::text[])
);

drop policy "Anyone can view active lane blocks" on public.lane_blocks;
drop policy "Admins and staff can view all lane blocks" on public.lane_blocks;

create policy "Tenant members can view active lane blocks"
on public.lane_blocks
for select
to authenticated
using (
  is_active = true
  and public.is_tenant_member_v1(tenant_id)
);

create policy "Tenant staff can view lane blocks"
on public.lane_blocks
for select
to authenticated
using (
  public.has_tenant_role_v1(tenant_id, array['admin','employee','instructor']::text[])
);

do $postflight$
declare
  v_snapshot record;
begin
  select * into v_snapshot from saas9c2_security_snapshot;

  if v_snapshot.unrelated_policy_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|', tablename, policyname, cmd, roles::text, qual, with_check),
         E'\n' order by tablename, policyname
       )
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename not in ('shooting_lanes','reservations','lane_blocks')
     ), '')) then
    raise exception 'SAAS-9C-2 postflight failed: unrelated RLS changed.';
  end if;

  if v_snapshot.security_definer_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|', n.nspname, p.proname,
           pg_catalog.pg_get_function_identity_arguments(p.oid),
           p.prosecdef::text, pg_catalog.pg_get_userbyid(p.proowner),
           coalesce(p.proconfig::text,''), pg_catalog.pg_get_functiondef(p.oid)),
         E'\n' order by n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid)
       )
       from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.prosecdef
         and p.proname <> 'is_active_public_tenant_v1'
     ), '')) then
    raise exception 'SAAS-9C-2 postflight failed: existing SECURITY DEFINER changed.';
  end if;

  if v_snapshot.booking_acl_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|', table_name, grantee, privilege_type),
         E'\n' order by table_name, grantee, privilege_type
       )
       from information_schema.role_table_grants
       where table_schema='public'
         and table_name in ('shooting_lanes','reservations','lane_blocks')
     ), '')) then
    raise exception 'SAAS-9C-2 postflight failed: booking table ACL changed.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname='public' and tablename in ('shooting_lanes','reservations','lane_blocks')) <> 6
     or exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public'
         and tablename in ('shooting_lanes','reservations','lane_blocks')
         and (coalesce(qual,'') ~ '\m(is_admin|is_admin_or_employee|is_admin_or_staff)\M'
              or coalesce(with_check,'') ~ '\m(is_admin|is_admin_or_employee|is_admin_or_staff)\M')
     )
     or (select pg_catalog.count(*) from pg_catalog.pg_policies
         where schemaname='public' and tablename in ('shooting_lanes','reservations','lane_blocks')
           and cmd <> 'SELECT') <> 0 then
    raise exception 'SAAS-9C-2 postflight failed: booking policy contract differs.';
  end if;

  if not exists (
       select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='is_active_public_tenant_v1'
         and p.prosecdef and pg_catalog.pg_get_userbyid(p.proowner)='postgres'
         and p.provolatile='s'
         and p.proconfig @> array['search_path=pg_catalog, public, pg_temp']
     )
     or pg_catalog.has_function_privilege('public','public.is_active_public_tenant_v1(uuid)','EXECUTE')
     or not pg_catalog.has_function_privilege('anon','public.is_active_public_tenant_v1(uuid)','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.is_active_public_tenant_v1(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.is_active_public_tenant_v1(uuid)','EXECUTE') then
    raise exception 'SAAS-9C-2 postflight failed: public tenant helper hardening differs.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;
