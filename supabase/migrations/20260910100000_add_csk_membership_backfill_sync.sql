-- SAAS-9C-1A: activate CSK memberships while legacy profiles.role remains
-- authoritative for the deployed application. No business-table RLS changes.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
begin
  if (select pg_catalog.count(*) from public.tenants) <> 1
     or (select pg_catalog.count(*) from public.tenants where status = 'active') <> 1
     or not exists (
       select 1 from public.tenants
       where id = v_csk and name = 'CSK' and slug = 'csk' and status = 'active'
     ) then
    raise exception 'SAAS-9C-1A preflight failed: canonical CSK tenant differs.';
  end if;

  if exists (
    select 1 from public.profiles profile
    left join auth.users auth_user on auth_user.id = profile.user_id
    where auth_user.id is null
  ) or exists (
    select 1 from auth.users auth_user
    left join public.profiles profile on profile.user_id = auth_user.id
    where profile.user_id is null
  ) then
    raise exception 'SAAS-9C-1A preflight failed: Auth/profile coverage is not one-to-one.';
  end if;

  if exists (
    select 1
    from auth.users auth_user
    join public.profiles profile on profile.user_id = auth_user.id
    where auth_user.deleted_at is not null
       or auth_user.banned_until > pg_catalog.statement_timestamp()
  ) then
    raise exception 'SAAS-9C-1A preflight failed: deleted or currently banned profile account cannot be activated.';
  end if;

  if exists (
    select 1 from public.profiles
    where role is null
       or role is distinct from pg_catalog.lower(pg_catalog.btrim(role))
       or role not in ('admin', 'user', 'pracownik', 'instruktor')
  ) then
    raise exception 'SAAS-9C-1A preflight failed: unknown or non-normalized legacy role.';
  end if;

  if exists (select 1 from public.tenant_memberships) then
    raise exception 'SAAS-9C-1A preflight failed: pre-existing membership requires manual review.';
  end if;

  if pg_catalog.to_regprocedure('public.legacy_profile_role_to_tenant_role_v1(text)') is not null
     or pg_catalog.to_regprocedure('public.tenant_role_to_legacy_profile_role_v1(text)') is not null
     or pg_catalog.to_regprocedure('public.sync_profile_role_to_csk_membership()') is not null
     or pg_catalog.to_regprocedure('public.sync_csk_membership_role_to_profile()') is not null then
    raise exception 'SAAS-9C-1A preflight failed: planned role bridge already exists.';
  end if;
end;
$preflight$;

alter table public.tenant_memberships
  drop constraint tenant_memberships_role_check;

alter table public.tenant_memberships
  add constraint tenant_memberships_role_check check (
    role = any (array['admin', 'employee', 'user', 'instructor']::text[])
  );

create function public.legacy_profile_role_to_tenant_role_v1(p_role text)
returns text
language sql
immutable
strict
security invoker
set search_path = pg_catalog
as $function$
  select case pg_catalog.lower(pg_catalog.btrim(p_role))
    when 'admin' then 'admin'
    when 'user' then 'user'
    when 'pracownik' then 'employee'
    when 'instruktor' then 'instructor'
    else null
  end;
$function$;

alter function public.legacy_profile_role_to_tenant_role_v1(text) owner to postgres;
revoke all on function public.legacy_profile_role_to_tenant_role_v1(text)
  from public, anon, authenticated, service_role;

create function public.tenant_role_to_legacy_profile_role_v1(p_role text)
returns text
language sql
immutable
strict
security invoker
set search_path = pg_catalog
as $function$
  select case pg_catalog.lower(pg_catalog.btrim(p_role))
    when 'admin' then 'admin'
    when 'user' then 'user'
    when 'employee' then 'pracownik'
    when 'instructor' then 'instruktor'
    else null
  end;
$function$;

alter function public.tenant_role_to_legacy_profile_role_v1(text) owner to postgres;
revoke all on function public.tenant_role_to_legacy_profile_role_v1(text)
  from public, anon, authenticated, service_role;

insert into public.tenant_memberships (tenant_id, user_id, role, status)
select
  'c5c00000-0000-4000-8000-000000000001'::uuid,
  profile.user_id,
  public.legacy_profile_role_to_tenant_role_v1(profile.role),
  'active'
from public.profiles profile;

create function public.sync_profile_role_to_csk_membership()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
  v_membership_role text;
begin
  if not exists (
    select 1 from auth.users auth_user
    where auth_user.id = new.user_id
      and auth_user.deleted_at is null
      and (auth_user.banned_until is null or auth_user.banned_until <= pg_catalog.statement_timestamp())
  ) then
    raise exception using errcode = '23514', message = 'csk_membership_account_not_eligible';
  end if;

  v_membership_role := public.legacy_profile_role_to_tenant_role_v1(new.role);
  if v_membership_role is null then
    raise exception using errcode = '23514', message = 'unsupported_legacy_profile_role';
  end if;

  update public.tenant_memberships membership
  set role = v_membership_role
  where membership.tenant_id = v_csk
    and membership.user_id = new.user_id
    and membership.role is distinct from v_membership_role;

  if not exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = v_csk and membership.user_id = new.user_id
  ) then
    insert into public.tenant_memberships (tenant_id, user_id, role, status)
    values (v_csk, new.user_id, v_membership_role, 'active');
  end if;

  if not exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = v_csk
      and membership.user_id = new.user_id
      and membership.role = v_membership_role
  ) then
    raise exception 'SAAS-9C-1A profile-to-membership reconciliation failed.';
  end if;

  return new;
end;
$function$;

alter function public.sync_profile_role_to_csk_membership() owner to postgres;
revoke all on function public.sync_profile_role_to_csk_membership()
  from public, anon, authenticated, service_role;

create trigger sync_profile_role_to_csk_membership
after insert or update of role on public.profiles
for each row execute function public.sync_profile_role_to_csk_membership();

create function public.sync_csk_membership_role_to_profile()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
  v_legacy_role text;
begin
  if new.tenant_id <> v_csk then
    return new;
  end if;

  v_legacy_role := public.tenant_role_to_legacy_profile_role_v1(new.role);
  if v_legacy_role is null then
    raise exception using errcode = '23514', message = 'unsupported_csk_membership_role';
  end if;

  if auth.uid() is not null then
    perform pg_catalog.set_config('csk.profile_role_rpc_actor', auth.uid()::text, true);
    perform pg_catalog.set_config('csk.profile_role_rpc_target', new.user_id::text, true);
  end if;

  update public.profiles profile
  set role = v_legacy_role
  where profile.user_id = new.user_id
    and profile.role is distinct from v_legacy_role;

  if auth.uid() is not null then
    perform pg_catalog.set_config('csk.profile_role_rpc_actor', '', true);
    perform pg_catalog.set_config('csk.profile_role_rpc_target', '', true);
  end if;

  if not exists (
    select 1 from public.profiles profile
    where profile.user_id = new.user_id and profile.role = v_legacy_role
  ) then
    raise exception 'SAAS-9C-1A membership-to-profile reconciliation failed.';
  end if;

  return new;
end;
$function$;

alter function public.sync_csk_membership_role_to_profile() owner to postgres;
revoke all on function public.sync_csk_membership_role_to_profile()
  from public, anon, authenticated, service_role;

create trigger sync_csk_membership_role_to_profile
after insert or update of role on public.tenant_memberships
for each row execute function public.sync_csk_membership_role_to_profile();

do $postflight$
declare
  v_expected_count bigint;
begin
  select pg_catalog.count(*) into v_expected_count from public.profiles;

  if (select pg_catalog.count(*) from public.tenant_memberships) <> v_expected_count
     or (select pg_catalog.count(*) from public.tenant_memberships where tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid and status = 'active') <> v_expected_count
     or exists (
       select 1
       from public.profiles profile
       left join public.tenant_memberships membership
         on membership.tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid
        and membership.user_id = profile.user_id
       where membership.user_id is null
          or membership.role is distinct from public.legacy_profile_role_to_tenant_role_v1(profile.role)
          or membership.status <> 'active'
     ) then
    raise exception 'SAAS-9C-1A postflight failed: membership backfill differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_trigger
      where not tgisinternal
        and tgname in ('sync_profile_role_to_csk_membership', 'sync_csk_membership_role_to_profile')
        and tgenabled = 'O') <> 2 then
    raise exception 'SAAS-9C-1A postflight failed: sync trigger inventory differs.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;
