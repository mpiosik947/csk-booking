-- SAAS-9B-1: additive tenant and membership foundation.
-- Runtime authorization intentionally remains profiles.role based.

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenants') is not null
     or pg_catalog.to_regclass('public.tenant_memberships') is not null then
    raise exception 'SAAS-9B-1 preflight failed: tenant foundation already exists.';
  end if;

  if pg_catalog.to_regclass('auth.users') is null
     or pg_catalog.to_regprocedure('public.set_updated_at()') is null then
    raise exception 'SAAS-9B-1 preflight failed: required auth/update contracts are absent.';
  end if;
end;
$preflight$;

create table public.tenants (
  id uuid default pg_catalog.gen_random_uuid() not null,
  name text not null,
  slug text not null,
  status text default 'dormant' not null,
  created_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  updated_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  constraint tenants_pkey primary key (id),
  constraint tenants_slug_key unique (slug),
  constraint tenants_name_check check (
    name = pg_catalog.btrim(name)
    and pg_catalog.char_length(name) between 1 and 120
  ),
  constraint tenants_slug_check check (
    slug = pg_catalog.lower(slug)
    and pg_catalog.char_length(slug) between 2 and 63
    and slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
  ),
  constraint tenants_status_check check (
    status = any (array['dormant', 'active', 'suspended', 'disabled']::text[])
  )
);

alter table public.tenants owner to postgres;

comment on table public.tenants is
  'Dormant SAAS-9B-1 tenant registry. Application runtime remains single-tenant until a later controlled cutover.';
comment on column public.tenants.status is
  'Lifecycle only. A partial unique index deliberately permits at most one active tenant until the multi-tenant security cutover.';

create unique index tenants_single_active_runtime_guard
  on public.tenants ((true))
  where status = 'active';

create table public.tenant_memberships (
  tenant_id uuid not null,
  user_id uuid not null,
  role text default 'user' not null,
  status text default 'pending' not null,
  created_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  updated_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  constraint tenant_memberships_pkey primary key (tenant_id, user_id),
  constraint tenant_memberships_tenant_id_fkey foreign key (tenant_id)
    references public.tenants(id) on delete cascade,
  constraint tenant_memberships_user_id_fkey foreign key (user_id)
    references auth.users(id) on delete cascade,
  constraint tenant_memberships_role_check check (
    role = any (array['admin', 'employee', 'user']::text[])
  ),
  constraint tenant_memberships_status_check check (
    status = any (array['active', 'pending', 'suspended']::text[])
  )
);

alter table public.tenant_memberships owner to postgres;

comment on table public.tenant_memberships is
  'Dormant future authorization source. SAAS-9B-1 does not read this table from application authorization.';
comment on column public.tenant_memberships.role is
  'Tenant-scoped future role; profiles.role remains the active legacy runtime source until controlled cutover.';

create index tenant_memberships_user_status_tenant_idx
  on public.tenant_memberships (user_id, status, tenant_id);

create index tenant_memberships_tenant_role_status_user_idx
  on public.tenant_memberships (tenant_id, role, status, user_id);

create trigger set_tenants_updated_at
  before update on public.tenants
  for each row execute function public.set_updated_at();

create trigger set_tenant_memberships_updated_at
  before update on public.tenant_memberships
  for each row execute function public.set_updated_at();

alter table public.tenants enable row level security;
alter table public.tenant_memberships enable row level security;

-- No client or server-runtime role needs these dormant objects yet. Keeping no
-- policies and no table ACL is intentionally fail-closed. Future access must be
-- introduced through a separately reviewed tenant-aware contract.
revoke all privileges on table public.tenants
  from public, anon, authenticated, service_role;
revoke all privileges on table public.tenant_memberships
  from public, anon, authenticated, service_role;

insert into public.tenants (id, name, slug, status)
values (
  'c5c00000-0000-4000-8000-000000000001'::uuid,
  'CSK',
  'csk',
  'active'
);

do $postflight$
declare
  v_role name;
begin
  if (select pg_catalog.count(*) from public.tenants) <> 1
     or not exists (
       select 1 from public.tenants
       where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and name = 'CSK' and slug = 'csk' and status = 'active'
     )
     or exists (select 1 from public.tenant_memberships) then
    raise exception 'SAAS-9B-1 postflight failed: bootstrap data differs.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_class as relation
       join pg_catalog.pg_roles as owner_role on owner_role.oid = relation.relowner
       where relation.oid = 'public.tenants'::pg_catalog.regclass
         and relation.relrowsecurity
         and owner_role.rolname = 'postgres'
     )
     or not exists (
       select 1
       from pg_catalog.pg_class as relation
       join pg_catalog.pg_roles as owner_role on owner_role.oid = relation.relowner
       where relation.oid = 'public.tenant_memberships'::pg_catalog.regclass
         and relation.relrowsecurity
         and owner_role.rolname = 'postgres'
     ) then
    raise exception 'SAAS-9B-1 postflight failed: ownership/RLS differs.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename in ('tenants', 'tenant_memberships')
  ) then
    raise exception 'SAAS-9B-1 postflight failed: dormant tables must have no policies.';
  end if;

  foreach v_role in array array['anon'::name, 'authenticated'::name, 'service_role'::name] loop
    if pg_catalog.has_table_privilege(
      v_role,
      'public.tenants',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
    ) or pg_catalog.has_table_privilege(
      v_role,
      'public.tenant_memberships',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
    ) then
      raise exception 'SAAS-9B-1 postflight failed: role % has tenant foundation ACL.', v_role;
    end if;
  end loop;
end;
$postflight$;
