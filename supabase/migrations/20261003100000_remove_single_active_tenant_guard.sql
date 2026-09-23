-- SAAS-9H: remove the rollout-only single-active-tenant guard after the full
-- tenant cutover and local two-active-tenant E2E have passed.

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is null then
    raise exception 'SAAS-9H preflight: single-active guard is missing';
  end if;

  if (select pg_catalog.count(*) from public.tenants where status='active') <> 1 then
    raise exception 'SAAS-9H preflight: expected exactly one active production tenant';
  end if;

  if exists(select 1 from public.tenant_memberships m left join public.tenants t on t.id=m.tenant_id where t.id is null) then
    raise exception 'SAAS-9H preflight: orphan tenant membership';
  end if;

  if exists(
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id' and column_default is not null
  ) then
    raise exception 'SAAS-9H preflight: tenant compatibility default remains';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef) <> 74 then
    raise exception 'SAAS-9H preflight: SECURITY DEFINER baseline differs';
  end if;

  if exists(
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and (p.prosrc ilike '%active_single_tenant%' or p.prosrc ilike '%c5c00000-0000-4000-8000-000000000001%')
  ) then
    raise exception 'SAAS-9H preflight: implicit single-tenant authority remains';
  end if;
end;
$preflight$;

drop index public.tenants_single_active_runtime_guard;

do $postflight$
begin
  if pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is not null then
    raise exception 'SAAS-9H postflight: single-active guard still exists';
  end if;

  if (select pg_catalog.count(*) from public.tenants where status='active') <> 1 then
    raise exception 'SAAS-9H postflight: tenant state changed';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef) <> 74 then
    raise exception 'SAAS-9H postflight: SECURITY DEFINER inventory changed';
  end if;
end;
$postflight$;
