-- PRODUCT-10B: separate public tenant URLs from technical tenant identity.

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenant_public_profiles') is null
     or pg_catalog.to_regprocedure('public.get_public_tenant_directory_v1(text)') is null
     or pg_catalog.to_regprocedure('public.resolve_active_tenant_by_slug_v1(text)') is null then
    raise exception 'PRODUCT-10B preflight failed: public tenant foundation is incomplete.';
  end if;

  if exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'tenant_public_profiles'
         and column_name in ('public_slug', 'hero_image_path', 'description', 'regulations_path')
     )
     or pg_catalog.to_regprocedure('public.get_public_tenant_directory_v2(text)') is not null
     or pg_catalog.to_regprocedure('public.get_public_tenant_landing_v1(text)') is not null
     or pg_catalog.to_regprocedure('public.enforce_public_tenant_slug_namespace()') is not null then
    raise exception 'PRODUCT-10B preflight failed: target objects already exist.';
  end if;

  if (select pg_catalog.count(*) from public.tenants where status = 'active') <> 1
     or not exists (
       select 1 from public.tenants
       where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and slug = 'csk' and status = 'active'
     )
     or (select pg_catalog.count(*) from public.tenant_public_profiles) <> 1
     or not exists (
       select 1 from public.tenant_public_profiles
       where tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and is_public
     ) then
    raise exception 'PRODUCT-10B preflight failed: production tenant baseline differs.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'public' and procedure.prosecdef) <> 75 then
    raise exception 'PRODUCT-10B preflight failed: SECURITY DEFINER baseline differs.';
  end if;
end;
$preflight$;

alter table public.tenant_public_profiles
  add column public_slug text,
  add column hero_image_path text,
  add column description text,
  add column regulations_path text;

update public.tenant_public_profiles
set public_slug = 'csk-krutla',
    description = 'System rezerwacji osi strzeleckich, szkoleń i eventów.',
    regulations_path = '/terms'
where tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid;

alter table public.tenant_public_profiles
  alter column public_slug set not null,
  add constraint tenant_public_profiles_public_slug_key unique (public_slug),
  add constraint tenant_public_profiles_public_slug_check check (
    public_slug = pg_catalog.lower(public_slug)
    and pg_catalog.char_length(public_slug) between 2 and 63
    and public_slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    and public_slug <> all (array[
      'account', 'admin', 'api', 'auth', 'booking', 'check-in', 'dashboard',
      'events', 'forgot-password', 'login', 'my-events', 'my-reservations',
      'privacy', 'register', 'reset-password', 't', 'terms'
    ]::text[])
  ),
  add constraint tenant_public_profiles_hero_image_path_check check (
    hero_image_path is null or (
      hero_image_path = pg_catalog.btrim(hero_image_path)
      and pg_catalog.char_length(hero_image_path) between 2 and 255
      and hero_image_path ~ '^/[A-Za-z0-9][A-Za-z0-9._/-]*$'
      and pg_catalog.strpos(hero_image_path, '..') = 0
      and pg_catalog.strpos(hero_image_path, '//') = 0
    )
  ),
  add constraint tenant_public_profiles_description_check check (
    description is null or (
      description = pg_catalog.btrim(description)
      and pg_catalog.char_length(description) between 1 and 1200
    )
  ),
  add constraint tenant_public_profiles_regulations_path_check check (
    regulations_path is null or (
      regulations_path = pg_catalog.btrim(regulations_path)
      and pg_catalog.char_length(regulations_path) between 2 and 255
      and regulations_path ~ '^/[A-Za-z0-9][A-Za-z0-9._/-]*$'
      and pg_catalog.strpos(regulations_path, '..') = 0
      and pg_catalog.strpos(regulations_path, '//') = 0
    )
  );

comment on column public.tenant_public_profiles.public_slug is
  'Canonical public URL selector only. It is never tenant authorization or resource authority.';
comment on column public.tenant_public_profiles.hero_image_path is
  'Optional same-origin public hero image path.';
comment on column public.tenant_public_profiles.description is
  'Optional public tenant description; never internal notes or profile data.';
comment on column public.tenant_public_profiles.regulations_path is
  'Optional same-origin public regulations path.';

create function public.enforce_public_tenant_slug_namespace()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $function$
begin
  -- Serialize the cross-table namespace check so tenant and public slugs cannot race.
  perform pg_catalog.pg_advisory_xact_lock(722025101);

  if tg_table_name = 'tenant_public_profiles' then
    if exists (select 1 from public.tenants where slug = new.public_slug) then
      raise exception 'public_slug_conflict';
    end if;
  elsif tg_table_name = 'tenants' then
    if exists (
      select 1 from public.tenant_public_profiles profile
      where profile.public_slug = new.slug
    ) then
      raise exception 'tenant_slug_conflict';
    end if;
  else
    raise exception 'unsupported_slug_namespace_target';
  end if;
  return new;
end;
$function$;

alter function public.enforce_public_tenant_slug_namespace() owner to postgres;
revoke all on function public.enforce_public_tenant_slug_namespace()
  from public, anon, authenticated, service_role;

create trigger enforce_tenant_public_profile_slug_namespace
  before insert or update of public_slug on public.tenant_public_profiles
  for each row execute function public.enforce_public_tenant_slug_namespace();

create trigger enforce_tenant_slug_public_namespace
  before insert or update of slug on public.tenants
  for each row execute function public.enforce_public_tenant_slug_namespace();

create function public.get_public_tenant_directory_v2(p_search text default null)
returns table(
  public_slug text,
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
  select profile.public_slug, profile.display_name, profile.city, profile.logo_path
  from public.tenant_public_profiles profile
  join public.tenants tenant on tenant.id = profile.tenant_id
  where profile.is_public
    and tenant.status = 'active'
    and (
      v_search is null
      or pg_catalog.strpos(pg_catalog.lower(profile.display_name), pg_catalog.lower(v_search)) > 0
      or pg_catalog.strpos(pg_catalog.lower(profile.city), pg_catalog.lower(v_search)) > 0
      or pg_catalog.strpos(pg_catalog.lower(profile.public_slug), pg_catalog.lower(v_search)) > 0
      or pg_catalog.strpos(pg_catalog.lower(tenant.slug), pg_catalog.lower(v_search)) > 0
    )
  order by pg_catalog.lower(profile.city), pg_catalog.lower(profile.display_name), profile.public_slug
  limit 50;
end;
$function$;

alter function public.get_public_tenant_directory_v2(text) owner to postgres;
revoke all on function public.get_public_tenant_directory_v2(text)
  from public, anon, authenticated, service_role;
grant execute on function public.get_public_tenant_directory_v2(text)
  to anon, authenticated;

create function public.get_public_tenant_landing_v1(p_slug text)
returns table(
  tenant_slug text,
  public_slug text,
  tenant_name text,
  tenant_city text,
  tenant_logo_path text,
  tenant_hero_image_path text,
  tenant_description text,
  tenant_regulations_path text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
begin
  if p_slug is null
     or p_slug <> pg_catalog.lower(p_slug)
     or pg_catalog.char_length(p_slug) not between 2 and 63
     or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    return;
  end if;

  return query
  select tenant.slug, profile.public_slug, profile.display_name, profile.city,
         profile.logo_path, profile.hero_image_path, profile.description,
         profile.regulations_path
  from public.tenant_public_profiles profile
  join public.tenants tenant on tenant.id = profile.tenant_id
  where profile.is_public
    and tenant.status = 'active'
    and (profile.public_slug = p_slug or tenant.slug = p_slug)
    and not exists (
      select 1
      from public.tenant_public_profiles other_profile
      join public.tenants other_tenant on other_tenant.id = other_profile.tenant_id
      where other_profile.is_public
        and other_tenant.status = 'active'
        and other_profile.tenant_id <> profile.tenant_id
        and (other_profile.public_slug = p_slug or other_tenant.slug = p_slug)
    )
  limit 1;
end;
$function$;

alter function public.get_public_tenant_landing_v1(text) owner to postgres;
revoke all on function public.get_public_tenant_landing_v1(text)
  from public, anon, authenticated, service_role;
grant execute on function public.get_public_tenant_landing_v1(text)
  to anon, authenticated;

do $postflight$
begin
  if not exists (
       select 1 from public.tenant_public_profiles profile
       join public.tenants tenant on tenant.id = profile.tenant_id
       where tenant.id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and tenant.slug = 'csk'
         and profile.public_slug = 'csk-krutla'
         and profile.is_public
     )
     or (select pg_catalog.count(*) from public.get_public_tenant_directory_v2(null)) <> 1
     or not exists (
       select 1 from public.get_public_tenant_landing_v1('csk-krutla')
       where tenant_slug = 'csk' and public_slug = 'csk-krutla'
     )
     or not exists (
       select 1 from public.get_public_tenant_landing_v1('csk')
       where tenant_slug = 'csk' and public_slug = 'csk-krutla'
     ) then
    raise exception 'PRODUCT-10B postflight failed: public slug bootstrap differs.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'public' and procedure.prosecdef) <> 77 then
    raise exception 'PRODUCT-10B postflight failed: SECURITY DEFINER inventory differs.';
  end if;

  if pg_catalog.has_function_privilege('public', 'public.get_public_tenant_directory_v2(text)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('anon', 'public.get_public_tenant_directory_v2(text)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', 'public.get_public_tenant_directory_v2(text)', 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', 'public.get_public_tenant_directory_v2(text)', 'EXECUTE')
     or pg_catalog.has_function_privilege('public', 'public.get_public_tenant_landing_v1(text)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('anon', 'public.get_public_tenant_landing_v1(text)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', 'public.get_public_tenant_landing_v1(text)', 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', 'public.get_public_tenant_landing_v1(text)', 'EXECUTE')
     or pg_catalog.has_function_privilege('public', 'public.enforce_public_tenant_slug_namespace()', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'public.enforce_public_tenant_slug_namespace()', 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', 'public.enforce_public_tenant_slug_namespace()', 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', 'public.enforce_public_tenant_slug_namespace()', 'EXECUTE') then
    raise exception 'PRODUCT-10B postflight failed: function ACL differs.';
  end if;
end;
$postflight$;
