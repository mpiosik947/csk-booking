-- SAAS-9B-2A: additive tenant ownership columns.
-- Runtime authorization and tenant resolution intentionally remain unchanged.

set lock_timeout = '5s';
set statement_timeout = '60s';

do $preflight$
declare
  v_expected record;
  v_actual_fingerprint text;
begin
  if (select pg_catalog.count(*) from public.tenants) <> 1
     or not exists (
       select 1
       from public.tenants
       where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and name = 'CSK'
         and slug = 'csk'
         and status = 'active'
     )
     or (select pg_catalog.count(*) from public.tenants where status = 'active') <> 1 then
    raise exception 'SAAS-9B-2A preflight failed: canonical CSK tenant differs.';
  end if;

  for v_expected in
    select *
    from (values
      ('audit_logs', '0d5b1ae7b9503ac291de4f977020265a'),
      ('email_deliveries', '26b0913dce00552d0c05ccfd5bf130ac'),
      ('event_lanes', 'f7e2e869f29ed34e6a26c540de677807'),
      ('event_registrations', '5028bd59156100c8e39a9401b2c1e3ff'),
      ('events', '24e305a3b402e7f6fd2e227aa6993803'),
      ('lane_blocks', '490b87b62393580c46d9de60d075be90'),
      ('reservations', '4f1e8b3993b600b86eae3d9ba03db880'),
      ('shooting_lanes', '6289fa15df5ba0b1c5a9c8adf84d996e')
    ) as expected(table_name, column_fingerprint)
  loop
    if pg_catalog.to_regclass('public.' || v_expected.table_name) is null then
      raise exception 'SAAS-9B-2A preflight failed: table % is missing.', v_expected.table_name;
    end if;

    if exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = v_expected.table_name
        and column_name = 'tenant_id'
    ) then
      raise exception 'SAAS-9B-2A preflight failed: %.tenant_id already exists.', v_expected.table_name;
    end if;

    select pg_catalog.md5(
      pg_catalog.string_agg(
        pg_catalog.format(
          '%s|%s|%s|%s',
          column_name,
          udt_schema || '.' || udt_name,
          is_nullable,
          coalesce(column_default, '')
        ),
        E'\n' order by ordinal_position
      )
    )
    into v_actual_fingerprint
    from information_schema.columns
    where table_schema = 'public'
      and table_name = v_expected.table_name;

    if v_actual_fingerprint is distinct from v_expected.column_fingerprint then
      raise exception
        'SAAS-9B-2A preflight failed: schema fingerprint for % is %, expected %.',
        v_expected.table_name,
        v_actual_fingerprint,
        v_expected.column_fingerprint;
    end if;
  end loop;
end;
$preflight$;

alter table public.shooting_lanes add column tenant_id uuid;
alter table public.reservations add column tenant_id uuid;
alter table public.lane_blocks add column tenant_id uuid;
alter table public.events add column tenant_id uuid;
alter table public.event_lanes add column tenant_id uuid;
alter table public.event_registrations add column tenant_id uuid;
alter table public.email_deliveries add column tenant_id uuid;
alter table public.audit_logs add column tenant_id uuid;

alter table public.shooting_lanes
  alter column tenant_id set default 'c5c00000-0000-4000-8000-000000000001'::uuid;
alter table public.reservations
  alter column tenant_id set default 'c5c00000-0000-4000-8000-000000000001'::uuid;
alter table public.lane_blocks
  alter column tenant_id set default 'c5c00000-0000-4000-8000-000000000001'::uuid;
alter table public.events
  alter column tenant_id set default 'c5c00000-0000-4000-8000-000000000001'::uuid;
alter table public.event_lanes
  alter column tenant_id set default 'c5c00000-0000-4000-8000-000000000001'::uuid;
alter table public.event_registrations
  alter column tenant_id set default 'c5c00000-0000-4000-8000-000000000001'::uuid;
alter table public.email_deliveries
  alter column tenant_id set default 'c5c00000-0000-4000-8000-000000000001'::uuid;

alter table public.shooting_lanes
  add constraint shooting_lanes_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;
alter table public.reservations
  add constraint reservations_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;
alter table public.lane_blocks
  add constraint lane_blocks_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;
alter table public.events
  add constraint events_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;
alter table public.event_lanes
  add constraint event_lanes_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;
alter table public.event_registrations
  add constraint event_registrations_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;
alter table public.email_deliveries
  add constraint email_deliveries_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;
alter table public.audit_logs
  add constraint audit_logs_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id) not valid;

comment on column public.shooting_lanes.tenant_id is
  'SAAS-9B-2 tenant ownership. Temporary CSK default must be removed before tenant-aware writer cutover and before second-tenant activation.';
comment on column public.reservations.tenant_id is
  'SAAS-9B-2 tenant ownership. Temporary CSK default must be removed before tenant-aware writer cutover and before second-tenant activation.';
comment on column public.lane_blocks.tenant_id is
  'SAAS-9B-2 tenant ownership. Temporary CSK default must be removed before tenant-aware writer cutover and before second-tenant activation.';
comment on column public.events.tenant_id is
  'SAAS-9B-2 tenant ownership. Temporary CSK default must be removed before tenant-aware writer cutover and before second-tenant activation.';
comment on column public.event_lanes.tenant_id is
  'SAAS-9B-2 tenant ownership. Temporary CSK default must be removed before tenant-aware writer cutover and before second-tenant activation.';
comment on column public.event_registrations.tenant_id is
  'SAAS-9B-2 tenant ownership. Temporary CSK default must be removed before tenant-aware writer cutover and before second-tenant activation.';
comment on column public.email_deliveries.tenant_id is
  'SAAS-9B-2 tenant ownership. Temporary CSK default must be removed before tenant-aware writer cutover and before second-tenant activation.';
comment on column public.audit_logs.tenant_id is
  'Nullable tenant attribution for tenant-scoped audit. Global/account/platform audit remains NULL.';

do $postflight$
declare
  v_table text;
begin
  foreach v_table in array array[
    'shooting_lanes',
    'reservations',
    'lane_blocks',
    'events',
    'event_lanes',
    'event_registrations',
    'email_deliveries',
    'audit_logs'
  ] loop
    if not exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = v_table
        and column_name = 'tenant_id'
        and udt_schema = 'pg_catalog'
        and udt_name = 'uuid'
        and is_nullable = 'YES'
    ) then
      raise exception 'SAAS-9B-2A postflight failed: %.tenant_id differs.', v_table;
    end if;
  end loop;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_constraint constraint_record
      join pg_catalog.pg_class relation on relation.oid = constraint_record.conrelid
      join pg_catalog.pg_namespace namespace on namespace.oid = relation.relnamespace
      where namespace.nspname = 'public'
        and relation.relname in (
          'shooting_lanes', 'reservations', 'lane_blocks', 'events',
          'event_lanes', 'event_registrations', 'email_deliveries', 'audit_logs'
        )
        and constraint_record.contype = 'f'
        and constraint_record.conname = relation.relname || '_tenant_id_fkey'
        and not constraint_record.convalidated) <> 8 then
    raise exception 'SAAS-9B-2A postflight failed: tenant FK inventory differs.';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name in (
        'shooting_lanes', 'reservations', 'lane_blocks', 'events',
        'event_lanes', 'event_registrations', 'email_deliveries'
      )
      and column_name = 'tenant_id'
      and column_default is distinct from
        '''c5c00000-0000-4000-8000-000000000001''::uuid'
  ) or exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'audit_logs'
      and column_name = 'tenant_id'
      and column_default is not null
  ) then
    raise exception 'SAAS-9B-2A postflight failed: temporary defaults differ.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;
