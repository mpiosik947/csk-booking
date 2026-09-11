-- SAAS-9C-2D: remaining tenant-aware direct-table RLS and profile privacy.
-- Legacy SECURITY DEFINER business RPCs are intentionally unchanged and remain SAAS-9D work.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is null
     or pg_catalog.to_regprocedure('public.is_active_public_tenant_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.handle_new_user()') is null then
    raise exception 'SAAS-9C-2D preflight failed: authorization or registration foundation is absent.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_class relation
      where relation.oid in (
        'public.audit_logs'::regclass,
        'public.profiles'::regclass,
        'public.lane_booking_rules'::regclass,
        'public.lane_booking_durations'::regclass,
        'public.lane_pricing_rules'::regclass,
        'public.tenants'::regclass,
        'public.tenant_memberships'::regclass,
        'public.email_deliveries'::regclass
      ) and relation.relrowsecurity) <> 8 then
    raise exception 'SAAS-9C-2D preflight failed: required RLS flags differ.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname='public'
        and tablename in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')) <> 10
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='audit_logs'
         and policyname='Admins can view audit logs' and cmd='SELECT'
         and roles=array['authenticated']::name[] and qual='is_admin()'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='profiles'
         and policyname='Users can view own profile' and cmd='SELECT'
         and roles=array['authenticated']::name[] and qual='(user_id = auth.uid())'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='profiles'
         and policyname='Admins can view all profiles' and cmd='SELECT'
         and roles=array['authenticated']::name[] and qual='is_admin()'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='profiles'
         and policyname='Admins can insert profiles' and cmd='INSERT'
         and roles=array['authenticated']::name[] and with_check='is_admin()'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='lane_booking_rules'
         and policyname='Staff can view all lane booking rules' and cmd='SELECT'
         and roles=array['authenticated']::name[] and qual='is_admin_or_staff()'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='lane_booking_durations'
         and policyname='Admins and employees can view all lane durations' and cmd='SELECT'
         and roles=array['authenticated']::name[] and qual='is_admin_or_employee()'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='lane_pricing_rules'
         and policyname='Admins and employees can view all lane pricing rules' and cmd='SELECT'
         and roles=array['authenticated']::name[] and qual='is_admin_or_employee()'
     ) then
    raise exception 'SAAS-9C-2D preflight failed: exact target policy baseline drifted.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname='public' and tablename='tenants') <> 0
     or (select pg_catalog.count(*) from pg_catalog.pg_policies
         where schemaname='public' and tablename='tenant_memberships') <> 1
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='tenant_memberships'
         and policyname='Users can view own tenant memberships' and cmd='SELECT'
         and roles=array['authenticated']::name[]
     )
     or (select pg_catalog.count(*) from pg_catalog.pg_policies
         where schemaname='public' and tablename='email_deliveries') <> 0
     or pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is null then
    raise exception 'SAAS-9C-2D preflight failed: control-plane fail-closed baseline drifted.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated','public.profiles','SELECT')
     or not pg_catalog.has_table_privilege('authenticated','public.profiles','INSERT')
     or pg_catalog.has_table_privilege('authenticated','public.profiles','UPDATE,DELETE,TRUNCATE')
     or pg_catalog.has_table_privilege('anon','public.profiles','SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'SAAS-9C-2D preflight failed: profiles ACL baseline drifted.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_trigger trigger_record
      where not trigger_record.tgisinternal
        and trigger_record.tgrelid='auth.users'::regclass
        and trigger_record.tgfoid='public.handle_new_user()'::regprocedure) > 1 then
    raise exception 'SAAS-9C-2D preflight failed: multiple auth profile triggers exist.';
  end if;

  if exists (
    select 1 from public.profiles profile
    left join public.tenant_memberships membership
      on membership.tenant_id='c5c00000-0000-4000-8000-000000000001'::uuid
     and membership.user_id=profile.user_id
    where membership.user_id is null
       or membership.status<>'active'
       or membership.role is distinct from public.legacy_profile_role_to_tenant_role_v1(profile.role)
  ) then
    raise exception 'SAAS-9C-2D preflight failed: profile/membership bridge is not reconciled.';
  end if;
end;
$preflight$;

create temporary table saas9c2d_security_snapshot as
select
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),
      E'\n' order by tablename,policyname
    )
    from pg_catalog.pg_policies
    where schemaname='public'
      and tablename not in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
  ),'')) as unrelated_policy_fingerprint,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      pg_catalog.concat_ws('|',namespace.nspname,procedure.proname,
        pg_catalog.pg_get_function_identity_arguments(procedure.oid),procedure.prosecdef::text,
        pg_catalog.pg_get_userbyid(procedure.proowner),coalesce(procedure.proconfig::text,''),
        pg_catalog.pg_get_functiondef(procedure.oid)),
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
      and table_name in ('audit_logs','lane_booking_rules','lane_booking_durations','lane_pricing_rules','tenants','tenant_memberships','email_deliveries')
  ),'')) as unchanged_acl_fingerprint,
  (select pg_catalog.count(*) from pg_catalog.pg_trigger trigger_record
   where not trigger_record.tgisinternal
     and trigger_record.tgrelid='auth.users'::regclass
     and trigger_record.tgfoid='public.handle_new_user()'::regprocedure) as auth_profile_trigger_count;

drop policy "Admins can view audit logs" on public.audit_logs;

create policy "Tenant admin and employee can view audit logs"
on public.audit_logs
for select
to authenticated
using (
  tenant_id is not null
  and public.has_tenant_role_v1(tenant_id,array['admin','employee']::text[])
);

drop policy "Admins can view all profiles" on public.profiles;
drop policy "Admins can insert profiles" on public.profiles;

create policy "Tenant admins can view related customer profiles"
on public.profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.reservations reservation
    where reservation.user_id=profiles.user_id
      and public.has_tenant_role_v1(reservation.tenant_id,array['admin']::text[])
  )
  or exists (
    select 1
    from public.event_registrations registration
    where registration.user_id=profiles.user_id
      and public.has_tenant_role_v1(registration.tenant_id,array['admin']::text[])
  )
);

revoke insert on table public.profiles from authenticated;

drop policy "Public can view online lane booking rules" on public.lane_booking_rules;
drop policy "Staff can view all lane booking rules" on public.lane_booking_rules;

create policy "Public can view active tenant lane booking rules"
on public.lane_booking_rules
for select
to anon, authenticated
using (
  online_bookable
  and exists (
    select 1
    from public.shooting_lanes lane
    where lane.id=lane_booking_rules.lane_id
      and lane.is_active
      and public.is_active_public_tenant_v1(lane.tenant_id)
      and (
        (lane.resource_kind='lane' and lane.whole_lane_bookable)
        or (
          lane.resource_kind='position'
          and exists (
            select 1
            from public.shooting_lanes parent
            where parent.id=lane.parent_lane_id
              and parent.resource_kind='lane'
              and parent.parent_lane_id is null
              and parent.is_active
              and parent.positions_bookable
          )
        )
      )
  )
);

create policy "Tenant staff can view lane booking rules"
on public.lane_booking_rules
for select
to authenticated
using (
  exists (
    select 1
    from public.shooting_lanes lane
    where lane.id=lane_booking_rules.lane_id
      and public.has_tenant_role_v1(lane.tenant_id,array['admin','employee','instructor']::text[])
  )
);

drop policy "Active lane durations are readable" on public.lane_booking_durations;
drop policy "Admins and employees can view all lane durations" on public.lane_booking_durations;

create policy "Public can view active tenant lane durations"
on public.lane_booking_durations
for select
to anon, authenticated
using (
  is_active
  and exists (
    select 1
    from public.shooting_lanes lane
    where lane.id=lane_booking_durations.lane_id
      and lane.is_active
      and public.is_active_public_tenant_v1(lane.tenant_id)
  )
);

create policy "Tenant admin and employee can view lane durations"
on public.lane_booking_durations
for select
to authenticated
using (
  exists (
    select 1
    from public.shooting_lanes lane
    where lane.id=lane_booking_durations.lane_id
      and public.has_tenant_role_v1(lane.tenant_id,array['admin','employee']::text[])
  )
);

drop policy "Active lane pricing rules are readable" on public.lane_pricing_rules;
drop policy "Admins and employees can view all lane pricing rules" on public.lane_pricing_rules;

create policy "Public can view active tenant lane pricing rules"
on public.lane_pricing_rules
for select
to anon, authenticated
using (
  is_active
  and exists (
    select 1
    from public.shooting_lanes lane
    where lane.id=lane_pricing_rules.lane_id
      and lane.is_active
      and public.is_active_public_tenant_v1(lane.tenant_id)
  )
);

create policy "Tenant admin and employee can view lane pricing rules"
on public.lane_pricing_rules
for select
to authenticated
using (
  exists (
    select 1
    from public.shooting_lanes lane
    where lane.id=lane_pricing_rules.lane_id
      and public.has_tenant_role_v1(lane.tenant_id,array['admin','employee']::text[])
  )
);

do $postflight$
declare
  v_snapshot record;
begin
  select * into v_snapshot from saas9c2d_security_snapshot;

  if v_snapshot.unrelated_policy_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),
         E'\n' order by tablename,policyname
       )
       from pg_catalog.pg_policies
       where schemaname='public'
         and tablename not in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
     ),'')) then
    raise exception 'SAAS-9C-2D postflight failed: unrelated RLS changed.';
  end if;

  if v_snapshot.security_definer_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|',namespace.nspname,procedure.proname,
           pg_catalog.pg_get_function_identity_arguments(procedure.oid),procedure.prosecdef::text,
           pg_catalog.pg_get_userbyid(procedure.proowner),coalesce(procedure.proconfig::text,''),
           pg_catalog.pg_get_functiondef(procedure.oid)),
         E'\n' order by namespace.nspname,procedure.proname,
           pg_catalog.pg_get_function_identity_arguments(procedure.oid)
       )
       from pg_catalog.pg_proc procedure
       join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
       where namespace.nspname='public' and procedure.prosecdef
     ),'')) then
    raise exception 'SAAS-9C-2D postflight failed: SECURITY DEFINER inventory changed.';
  end if;

  if v_snapshot.unchanged_acl_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         pg_catalog.concat_ws('|',table_name,grantee,privilege_type),
         E'\n' order by table_name,grantee,privilege_type
       )
       from information_schema.role_table_grants
       where table_schema='public'
         and table_name in ('audit_logs','lane_booking_rules','lane_booking_durations','lane_pricing_rules','tenants','tenant_memberships','email_deliveries')
     ),'')) then
    raise exception 'SAAS-9C-2D postflight failed: unrelated target ACL changed.';
  end if;

  if v_snapshot.auth_profile_trigger_count is distinct from (
       select pg_catalog.count(*) from pg_catalog.pg_trigger trigger_record
       where not trigger_record.tgisinternal
         and trigger_record.tgrelid='auth.users'::regclass
         and trigger_record.tgfoid='public.handle_new_user()'::regprocedure
     ) then
    raise exception 'SAAS-9C-2D postflight failed: auth profile trigger changed.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname='public'
        and tablename in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')) <> 9
     or exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public'
         and tablename in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
         and (coalesce(qual,'') ~ '\m(is_admin|is_employee|is_admin_or_employee|is_admin_or_staff|get_my_role)\M'
              or coalesce(with_check,'') ~ '\m(is_admin|is_employee|is_admin_or_employee|is_admin_or_staff|get_my_role)\M')
     )
     or exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public'
         and tablename in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
         and cmd<>'SELECT'
     ) then
    raise exception 'SAAS-9C-2D postflight failed: target policy isolation differs.';
  end if;

  if pg_catalog.has_table_privilege('authenticated','public.profiles','INSERT,UPDATE,DELETE,TRUNCATE')
     or not pg_catalog.has_table_privilege('authenticated','public.profiles','SELECT') then
    raise exception 'SAAS-9C-2D postflight failed: profiles ACL hardening differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies where schemaname='public' and tablename='tenants')<>0
     or (select pg_catalog.count(*) from pg_catalog.pg_policies where schemaname='public' and tablename='tenant_memberships')<>1
     or (select pg_catalog.count(*) from pg_catalog.pg_policies where schemaname='public' and tablename='email_deliveries')<>0
     or pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is null then
    raise exception 'SAAS-9C-2D postflight failed: fail-closed control-plane contract changed.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;
