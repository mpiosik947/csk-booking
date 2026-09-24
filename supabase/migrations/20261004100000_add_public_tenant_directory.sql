-- PRODUCT-10A: PII-free public directory for published, active tenants.

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenants') is null
     or pg_catalog.to_regprocedure('public.set_updated_at()') is null
     or pg_catalog.to_regprocedure('public.is_active_public_tenant_v1(uuid)') is null then
    raise exception 'PRODUCT-10A preflight failed: tenant foundation is incomplete.';
  end if;

  if pg_catalog.to_regclass('public.tenant_public_profiles') is not null
     or pg_catalog.to_regprocedure('public.get_public_tenant_directory_v1(text)') is not null then
    raise exception 'PRODUCT-10A preflight failed: directory objects already exist.';
  end if;

  if (select pg_catalog.count(*) from public.tenants where status = 'active') <> 1
     or not exists (
       select 1 from public.tenants
       where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and slug = 'csk' and status = 'active'
     ) then
    raise exception 'PRODUCT-10A preflight failed: production tenant baseline differs.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'public' and procedure.prosecdef) <> 74 then
    raise exception 'PRODUCT-10A preflight failed: SECURITY DEFINER baseline differs.';
  end if;
end;
$preflight$;

create table public.tenant_public_profiles (
  tenant_id uuid not null,
  display_name text not null,
  city text not null,
  logo_path text,
  is_public boolean default false not null,
  created_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  updated_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  constraint tenant_public_profiles_pkey primary key (tenant_id),
  constraint tenant_public_profiles_tenant_id_fkey foreign key (tenant_id)
    references public.tenants(id) on delete cascade,
  constraint tenant_public_profiles_display_name_check check (
    display_name = pg_catalog.btrim(display_name)
    and pg_catalog.char_length(display_name) between 1 and 120
  ),
  constraint tenant_public_profiles_city_check check (
    city = pg_catalog.btrim(city)
    and pg_catalog.char_length(city) between 1 and 120
  ),
  constraint tenant_public_profiles_logo_path_check check (
    logo_path is null or (
      logo_path = pg_catalog.btrim(logo_path)
      and pg_catalog.char_length(logo_path) between 2 and 255
      and logo_path ~ '^/[A-Za-z0-9][A-Za-z0-9._/-]*$'
      and pg_catalog.strpos(logo_path, '..') = 0
      and pg_catalog.strpos(logo_path, '//') = 0
    )
  )
);

alter table public.tenant_public_profiles owner to postgres;
alter table public.tenant_public_profiles enable row level security;

comment on table public.tenant_public_profiles is
  'PRODUCT-10A public directory metadata. Publication is independent from tenant lifecycle status.';
comment on column public.tenant_public_profiles.logo_path is
  'Optional same-origin static asset path. Remote URLs and traversal segments are rejected.';

create index tenant_public_profiles_public_city_name_idx
  on public.tenant_public_profiles (
    is_public,
    pg_catalog.lower(city),
    pg_catalog.lower(display_name),
    tenant_id
  );

create trigger set_tenant_public_profiles_updated_at
  before update on public.tenant_public_profiles
  for each row execute function public.set_updated_at();

revoke all privileges on table public.tenant_public_profiles
  from public, anon, authenticated, service_role;

create function public.get_public_tenant_directory_v1(p_search text default null)
returns table(
  tenant_slug text,
  tenant_name text,
  tenant_city text,
  tenant_logo_path text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_search text := nullif(pg_catalog.btrim(p_search), '');
begin
  if v_search is not null and pg_catalog.char_length(v_search) > 80 then
    return;
  end if;

  return query
  select tenant.slug, profile.display_name, profile.city, profile.logo_path
  from public.tenant_public_profiles profile
  join public.tenants tenant on tenant.id = profile.tenant_id
  where profile.is_public
    and tenant.status = 'active'
    and (
      v_search is null
      or pg_catalog.strpos(pg_catalog.lower(profile.display_name), pg_catalog.lower(v_search)) > 0
      or pg_catalog.strpos(pg_catalog.lower(profile.city), pg_catalog.lower(v_search)) > 0
      or pg_catalog.strpos(pg_catalog.lower(tenant.slug), pg_catalog.lower(v_search)) > 0
    )
  order by
    pg_catalog.lower(profile.city),
    pg_catalog.lower(profile.display_name),
    tenant.slug
  limit 50;
end;
$function$;

alter function public.get_public_tenant_directory_v1(text) owner to postgres;
revoke all on function public.get_public_tenant_directory_v1(text)
  from public, anon, authenticated, service_role;
grant execute on function public.get_public_tenant_directory_v1(text)
  to anon, authenticated;

comment on function public.get_public_tenant_directory_v1(text) is
  'Returns at most 50 active and explicitly published tenants using a four-field PII-free DTO.';

insert into public.tenant_public_profiles (
  tenant_id,
  display_name,
  city,
  logo_path,
  is_public
)
values (
  'c5c00000-0000-4000-8000-000000000001'::uuid,
  'CSK — Centrum Szkolenia Krutla',
  'Wolsztyn',
  '/login-brand.png',
  true
);

do $postflight$
begin
  if not exists (
       select 1
       from pg_catalog.pg_class relation
       join pg_catalog.pg_roles owner_role on owner_role.oid = relation.relowner
       where relation.oid = 'public.tenant_public_profiles'::pg_catalog.regclass
         and relation.relrowsecurity
         and owner_role.rolname = 'postgres'
     )
     or exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'tenant_public_profiles'
     ) then
    raise exception 'PRODUCT-10A postflight failed: directory table boundary differs.';
  end if;

  if pg_catalog.has_table_privilege('anon','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('authenticated','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('service_role','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'PRODUCT-10A postflight failed: direct directory table ACL exists.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_proc procedure
       join pg_catalog.pg_roles owner_role on owner_role.oid = procedure.proowner
       where procedure.oid = 'public.get_public_tenant_directory_v1(text)'::pg_catalog.regprocedure
         and procedure.prosecdef
         and procedure.provolatile = 's'
         and owner_role.rolname = 'postgres'
         and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
     )
     or pg_catalog.has_function_privilege('public','public.get_public_tenant_directory_v1(text)','EXECUTE')
     or not pg_catalog.has_function_privilege('anon','public.get_public_tenant_directory_v1(text)','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_tenant_directory_v1(text)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_tenant_directory_v1(text)','EXECUTE') then
    raise exception 'PRODUCT-10A postflight failed: directory RPC metadata or ACL differs.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'public' and procedure.prosecdef) <> 75
     or (select pg_catalog.count(*) from public.tenant_public_profiles) <> 1
     or (select pg_catalog.count(*) from public.get_public_tenant_directory_v1(null)) <> 1
     or not exists (
       select 1 from public.get_public_tenant_directory_v1('wolsztyn')
       where tenant_slug = 'csk'
         and tenant_name = 'CSK — Centrum Szkolenia Krutla'
         and tenant_city = 'Wolsztyn'
         and tenant_logo_path = '/login-brand.png'
     ) then
    raise exception 'PRODUCT-10A postflight failed: directory data or inventory differs.';
  end if;
end;
$postflight$;
