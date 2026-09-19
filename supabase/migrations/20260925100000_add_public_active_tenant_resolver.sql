-- SAAS-9E-A: additive, PII-free active-tenant slug resolution only.
-- No existing caller, policy, compatibility bridge, writer or route is changed.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenants') is null
     or pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null
     or pg_catalog.to_regprocedure('public.resolve_active_tenant_by_slug_v1(text)') is not null then
    raise exception 'SAAS-9E-A preflight failed: tenant/function inventory differs.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef) <> 69
     or (select pg_catalog.count(*) from information_schema.columns
       where table_schema='public' and column_name='tenant_id'
         and table_name in ('shooting_lanes','reservations','lane_blocks','events',
                            'event_lanes','event_registrations','email_deliveries')
         and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid') <> 7 then
    raise exception 'SAAS-9E-A preflight failed: definer/default baseline differs.';
  end if;
  if not exists(select 1 from pg_catalog.pg_class c
      join pg_catalog.pg_roles r on r.oid=c.relowner
      where c.oid='public.tenants'::pg_catalog.regclass
        and c.relrowsecurity and r.rolname='postgres')
     or exists(select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='tenants')
     or pg_catalog.has_table_privilege('anon','public.tenants','SELECT')
     or pg_catalog.has_table_privilege('authenticated','public.tenants','SELECT')
     or pg_catalog.has_table_privilege('service_role','public.tenants','SELECT') then
    raise exception 'SAAS-9E-A preflight failed: tenants table boundary differs.';
  end if;
  if (select pg_catalog.count(*) from public.tenants where status='active') <> 1
     or not exists(select 1 from public.tenants where
       id='c5c00000-0000-4000-8000-000000000001'::uuid
       and name='CSK' and slug='csk' and status='active')
     or not exists(select 1 from pg_catalog.pg_indexes
       where schemaname='public' and indexname='tenants_single_active_runtime_guard') then
    raise exception 'SAAS-9E-A preflight failed: active-CSK/second-tenant guard differs.';
  end if;
end;
$preflight$;

create function public.resolve_active_tenant_by_slug_v1(p_slug text)
returns table(tenant_id uuid, tenant_slug text, tenant_name text, tenant_status text)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select tenant.id, tenant.slug, tenant.name, tenant.status
  from public.tenants tenant
  where p_slug is not null
    and pg_catalog.char_length(p_slug) between 2 and 63
    and p_slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    and tenant.slug = p_slug
    and tenant.status = 'active';
$function$;

alter function public.resolve_active_tenant_by_slug_v1(text) owner to postgres;
revoke all on function public.resolve_active_tenant_by_slug_v1(text)
  from public, anon, authenticated, service_role;
grant execute on function public.resolve_active_tenant_by_slug_v1(text)
  to anon, authenticated;

do $postflight$
begin
  if not exists(select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.resolve_active_tenant_by_slug_v1(text)'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='s' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     or pg_catalog.has_function_privilege('public',
       'public.resolve_active_tenant_by_slug_v1(text)','EXECUTE')
     or not pg_catalog.has_function_privilege('anon',
       'public.resolve_active_tenant_by_slug_v1(text)','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated',
       'public.resolve_active_tenant_by_slug_v1(text)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role',
       'public.resolve_active_tenant_by_slug_v1(text)','EXECUTE')
     or (select pg_catalog.count(*) from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.prosecdef) <> 70
     or pg_catalog.has_table_privilege('anon','public.tenants','SELECT')
     or pg_catalog.has_table_privilege('authenticated','public.tenants','SELECT')
     or pg_catalog.has_table_privilege('service_role','public.tenants','SELECT') then
    raise exception 'SAAS-9E-A postflight failed: resolver or table ACL differs.';
  end if;
  if (select pg_catalog.count(*) from public.resolve_active_tenant_by_slug_v1('csk')) <> 1
     or (select tenant_id from public.resolve_active_tenant_by_slug_v1('csk'))
        <> 'c5c00000-0000-4000-8000-000000000001'::uuid
     or exists(select 1 from public.resolve_active_tenant_by_slug_v1('CSK'))
     or exists(select 1 from public.resolve_active_tenant_by_slug_v1('unknown')) then
    raise exception 'SAAS-9E-A postflight failed: active-slug resolution differs.';
  end if;
end;
$postflight$;
