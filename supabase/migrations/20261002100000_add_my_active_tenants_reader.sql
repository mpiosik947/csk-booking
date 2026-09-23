-- SAAS-9F: PII-free tenant selector for the global dashboard.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenants') is null
     or pg_catalog.to_regclass('public.tenant_memberships') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null then
    raise exception 'SAAS-9F preflight failed: tenant foundation is absent';
  end if;

  if pg_catalog.to_regprocedure('public.get_my_active_tenants_v1()') is not null then
    raise exception 'SAAS-9F preflight failed: target reader already exists';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>73 then
    raise exception 'SAAS-9F preflight failed: SECURITY DEFINER baseline is not 73';
  end if;

  if (select pg_catalog.count(*) from public.tenants where status='active')<>1 then
    raise exception 'SAAS-9F preflight failed: production active-tenant baseline differs';
  end if;

  if exists (
    select 1 from public.tenant_memberships membership
    left join public.tenants tenant on tenant.id=membership.tenant_id
    left join auth.users account on account.id=membership.user_id
    where tenant.id is null or account.id is null
  ) then
    raise exception 'SAAS-9F preflight failed: orphan tenant membership exists';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id'
      and column_default is not null
  ) then
    raise exception 'SAAS-9F preflight failed: a retired compatibility default reappeared';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.prokind='f'
      and (
        pg_catalog.pg_get_functiondef(procedure.oid) ilike '%active_single_tenant_id_v1%'
        or pg_catalog.pg_get_functiondef(procedure.oid) ilike '%c5c00000-0000-4000-8000-000000000001%'
      )
  ) then
    raise exception 'SAAS-9F preflight failed: retired single-tenant authority reappeared';
  end if;
end
$preflight$;

create function public.get_my_active_tenants_v1()
returns table (
  tenant_id uuid,
  tenant_slug text,
  tenant_name text,
  tenant_role text
)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select
    tenant.id,
    tenant.slug,
    tenant.name,
    membership.role
  from public.tenant_memberships membership
  join public.tenants tenant on tenant.id=membership.tenant_id
  where auth.uid() is not null
    and membership.user_id=auth.uid()
    and membership.status='active'
    and tenant.status='active'
  order by tenant.name,tenant.id;
$function$;

alter function public.get_my_active_tenants_v1() owner to postgres;
revoke all on function public.get_my_active_tenants_v1()
  from public,anon,authenticated,service_role;
grant execute on function public.get_my_active_tenants_v1() to authenticated;

comment on function public.get_my_active_tenants_v1() is
  'PII-free list of the current user active tenant memberships for global navigation. Returned IDs/slugs are selectors, never authorization.';

do $postflight$
declare
  v_function oid:='public.get_my_active_tenants_v1()'::pg_catalog.regprocedure;
begin
  if not exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
    where procedure.oid=v_function
      and procedure.prosecdef
      and procedure.provolatile='s'
      and owner_role.rolname='postgres'
      and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']
  ) then
    raise exception 'SAAS-9F postflight failed: reader metadata differs';
  end if;

  if pg_catalog.has_function_privilege('public',v_function,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_function,'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated',v_function,'EXECUTE')
     or pg_catalog.has_function_privilege('service_role',v_function,'EXECUTE') then
    raise exception 'SAAS-9F postflight failed: reader ACL differs';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>74 then
    raise exception 'SAAS-9F postflight failed: SECURITY DEFINER target is not 74';
  end if;
end
$postflight$;
