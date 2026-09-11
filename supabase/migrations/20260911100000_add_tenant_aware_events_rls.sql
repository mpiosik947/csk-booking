-- SAAS-9C-2C: tenant-aware direct-table RLS for Events.
-- Legacy SECURITY DEFINER event RPCs are intentionally unchanged and remain SAAS-9D work.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is null
     or pg_catalog.to_regprocedure('public.is_active_public_tenant_v1(uuid)') is null then
    raise exception 'SAAS-9C-2C preflight failed: tenant authorization foundation is absent.';
  end if;

  if (select pg_catalog.count(*) from public.tenants where status = 'active') <> 1
     or not exists (
       select 1 from public.tenants
       where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and slug = 'csk' and status = 'active'
     )
     or pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is null then
    raise exception 'SAAS-9C-2C preflight failed: single-active-CSK guard differs.';
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
    raise exception 'SAAS-9C-2C preflight failed: CSK profile/membership reconciliation differs.';
  end if;

  if exists (select 1 from public.events where tenant_id is null)
     or exists (select 1 from public.event_lanes where tenant_id is null)
     or exists (select 1 from public.event_registrations where tenant_id is null)
     or exists (
       select 1 from public.event_lanes relation
       join public.events event_record on event_record.id = relation.event_id
       join public.shooting_lanes lane on lane.id = relation.lane_id
       where relation.tenant_id is distinct from event_record.tenant_id
          or relation.tenant_id is distinct from lane.tenant_id
     )
     or exists (
       select 1 from public.event_registrations registration
       join public.events event_record on event_record.id = registration.event_id
       where registration.tenant_id is distinct from event_record.tenant_id
     ) then
    raise exception 'SAAS-9C-2C preflight failed: Events tenant ownership integrity differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_constraint
      where conrelid in ('public.event_lanes'::regclass,'public.event_registrations'::regclass)
        and conname in ('event_lanes_event_id_fkey','event_lanes_lane_id_fkey','event_registrations_event_id_fkey')
        and contype = 'f' and convalidated) <> 3 then
    raise exception 'SAAS-9C-2C preflight failed: validated composite tenant constraints are absent.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_class relation
      where relation.oid in ('public.events'::regclass,'public.event_lanes'::regclass,'public.event_registrations'::regclass)
        and relation.relrowsecurity) <> 3 then
    raise exception 'SAAS-9C-2C preflight failed: target RLS flags differ.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname = 'public' and tablename in ('events','event_lanes','event_registrations')) <> 6
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='events' and policyname='Public can view active events' and cmd='SELECT' and roles=array['anon']::name[] and qual='(is_active = true)')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='events' and policyname='Users can view active events' and cmd='SELECT' and roles=array['authenticated']::name[] and qual='(is_active = true)')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='events' and policyname='Admins and staff can view all events' and cmd='SELECT' and roles=array['authenticated']::name[] and qual='is_admin_or_staff()')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='event_lanes' and policyname='Admins and staff can view event lanes' and cmd='SELECT' and roles=array['authenticated']::name[] and qual='is_admin_or_staff()')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='event_registrations' and policyname='Users can view own event registrations' and cmd='SELECT' and roles=array['authenticated']::name[] and qual='(user_id = auth.uid())')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='event_registrations' and policyname='Admins and staff can view all event registrations' and cmd='SELECT' and roles=array['authenticated']::name[] and qual='is_admin_or_staff()') then
    raise exception 'SAAS-9C-2C preflight failed: exact six-policy Events baseline drifted.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_policies
    where schemaname='public'
      and tablename in ('events','event_lanes','event_registrations')
      and cmd <> 'SELECT'
  ) then
    raise exception 'SAAS-9C-2C preflight failed: unexpected target mutation policy exists.';
  end if;
end;
$preflight$;

create temporary table saas9c2c_security_snapshot as
select
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),
      E'\n' order by tablename,policyname
    )
    from pg_catalog.pg_policies
    where schemaname='public'
      and tablename not in ('events','event_lanes','event_registrations')
  ),'')) as unrelated_policy_fingerprint,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|',namespace.nspname,procedure.proname,
        pg_catalog.pg_get_function_identity_arguments(procedure.oid),
        procedure.prosecdef::text,pg_catalog.pg_get_userbyid(procedure.proowner),
        coalesce(procedure.proconfig::text,''),pg_catalog.pg_get_functiondef(procedure.oid)),
      E'\n' order by namespace.nspname,procedure.proname,
        pg_catalog.pg_get_function_identity_arguments(procedure.oid)
    )
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public' and procedure.prosecdef
  ),'')) as security_definer_fingerprint,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|',table_name,grantee,privilege_type),
      E'\n' order by table_name,grantee,privilege_type
    )
    from information_schema.role_table_grants
    where table_schema='public'
      and table_name in ('events','event_lanes','event_registrations')
  ),'')) as target_acl_fingerprint;

drop policy "Public can view active events" on public.events;
drop policy "Users can view active events" on public.events;
drop policy "Admins and staff can view all events" on public.events;

create policy "Public can view active tenant events"
on public.events
for select
to anon
using (
  is_active = true
  and public.is_active_public_tenant_v1(tenant_id)
);

create policy "Authenticated users can view active tenant events"
on public.events
for select
to authenticated
using (
  is_active = true
  and public.is_active_public_tenant_v1(tenant_id)
);

create policy "Tenant staff can view events"
on public.events
for select
to authenticated
using (
  public.has_tenant_role_v1(tenant_id,array['admin','employee','instructor']::text[])
);

drop policy "Admins and staff can view event lanes" on public.event_lanes;

create policy "Tenant staff can view event lanes"
on public.event_lanes
for select
to authenticated
using (
  public.has_tenant_role_v1(tenant_id,array['admin','employee','instructor']::text[])
);

drop policy "Users can view own event registrations" on public.event_registrations;
drop policy "Admins and staff can view all event registrations" on public.event_registrations;

create policy "Users can view own event registrations"
on public.event_registrations
for select
to authenticated
using (
  user_id = (select auth.uid())
);

create policy "Tenant staff can view event registrations"
on public.event_registrations
for select
to authenticated
using (
  public.has_tenant_role_v1(tenant_id,array['admin','employee','instructor']::text[])
);

do $postflight$
declare
  v_snapshot record;
begin
  select * into v_snapshot from saas9c2c_security_snapshot;

  if v_snapshot.unrelated_policy_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),
         E'\n' order by tablename,policyname
       )
       from pg_catalog.pg_policies
       where schemaname='public'
         and tablename not in ('events','event_lanes','event_registrations')
     ),'')) then
    raise exception 'SAAS-9C-2C postflight failed: unrelated RLS changed.';
  end if;

  if v_snapshot.security_definer_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|',namespace.nspname,procedure.proname,
           pg_catalog.pg_get_function_identity_arguments(procedure.oid),
           procedure.prosecdef::text,pg_catalog.pg_get_userbyid(procedure.proowner),
           coalesce(procedure.proconfig::text,''),pg_catalog.pg_get_functiondef(procedure.oid)),
         E'\n' order by namespace.nspname,procedure.proname,
           pg_catalog.pg_get_function_identity_arguments(procedure.oid)
       )
       from pg_catalog.pg_proc procedure
       join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
       where namespace.nspname='public' and procedure.prosecdef
     ),'')) then
    raise exception 'SAAS-9C-2C postflight failed: SECURITY DEFINER inventory changed.';
  end if;

  if v_snapshot.target_acl_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|',table_name,grantee,privilege_type),
         E'\n' order by table_name,grantee,privilege_type
       )
       from information_schema.role_table_grants
       where table_schema='public'
         and table_name in ('events','event_lanes','event_registrations')
     ),'')) then
    raise exception 'SAAS-9C-2C postflight failed: target table ACL changed.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname='public' and tablename in ('events','event_lanes','event_registrations')) <> 6
     or (select pg_catalog.count(*) from pg_catalog.pg_policies
         where schemaname='public' and tablename in ('events','event_lanes','event_registrations') and cmd='SELECT') <> 6
     or exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public'
         and tablename in ('events','event_lanes','event_registrations')
         and (coalesce(qual,'') ~ '\m(is_admin|is_admin_or_employee|is_admin_or_staff)\M'
              or coalesce(with_check,'') ~ '\m(is_admin|is_admin_or_employee|is_admin_or_staff)\M')
     ) then
    raise exception 'SAAS-9C-2C postflight failed: target policy contract differs.';
  end if;

  if not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='events' and policyname='Public can view active tenant events' and roles=array['anon']::name[] and qual like '%is_active = true%is_active_public_tenant_v1(tenant_id)%')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='events' and policyname='Authenticated users can view active tenant events' and roles=array['authenticated']::name[] and qual like '%is_active = true%is_active_public_tenant_v1(tenant_id)%')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='events' and policyname='Tenant staff can view events' and roles=array['authenticated']::name[] and qual like 'has_tenant_role_v1(tenant_id, ARRAY[%admin%employee%instructor%')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='event_lanes' and policyname='Tenant staff can view event lanes' and roles=array['authenticated']::name[] and qual like 'has_tenant_role_v1(tenant_id, ARRAY[%admin%employee%instructor%')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='event_registrations' and policyname='Users can view own event registrations' and roles=array['authenticated']::name[] and qual like '%user_id%auth.uid()%')
     or not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='event_registrations' and policyname='Tenant staff can view event registrations' and roles=array['authenticated']::name[] and qual like 'has_tenant_role_v1(tenant_id, ARRAY[%admin%employee%instructor%') then
    raise exception 'SAAS-9C-2C postflight failed: exact tenant-aware policy definitions differ.';
  end if;

  if pg_catalog.has_table_privilege('anon','public.event_lanes','SELECT')
     or pg_catalog.has_table_privilege('anon','public.event_registrations','SELECT')
     or pg_catalog.has_table_privilege('authenticated','public.events','INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('authenticated','public.event_lanes','INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('authenticated','public.event_registrations','INSERT,UPDATE,DELETE') then
    raise exception 'SAAS-9C-2C postflight failed: direct table privilege boundary differs.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;
