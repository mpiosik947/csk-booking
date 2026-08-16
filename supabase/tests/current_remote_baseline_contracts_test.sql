\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

-- Current-state contract checks for the consolidated remote baseline.
-- This file is read-only and intentionally does not replay historical migrations.
select '1..14';

select case when not exists (
  select required.name
  from (values
    ('shooting_lanes'),
    ('lane_booking_rules'),
    ('lane_booking_durations'),
    ('lane_pricing_rules'),
    ('lane_booking_family_configuration_versions')
  ) as required(name)
  where pg_catalog.to_regclass('public.' || required.name) is null
) then 'ok 1 - current lane configuration tables exist'
else 'not ok 1 - a current lane configuration table is missing' end;

select case when (
  select pg_catalog.count(*) = 4
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'shooting_lanes'
    and (
      (column_name = 'resource_kind' and is_nullable = 'NO' and data_type = 'text')
      or (column_name = 'parent_lane_id' and data_type = 'uuid')
      or (column_name = 'whole_lane_bookable' and is_nullable = 'NO' and data_type = 'boolean')
      or (column_name = 'positions_bookable' and is_nullable = 'NO' and data_type = 'boolean')
    )
) then 'ok 2 - shooting_lanes has the current hierarchy columns'
else 'not ok 2 - shooting_lanes hierarchy columns differ' end;

select case when not exists (
  select expected.name
  from (values
    ('shooting_lanes_resource_kind_check'),
    ('shooting_lanes_resource_parent_check'),
    ('shooting_lanes_parent_not_self_check'),
    ('shooting_lanes_position_booking_modes_check'),
    ('shooting_lanes_parent_lane_id_fkey')
  ) as expected(name)
  where not exists (
    select 1 from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
      and constraint_record.conname = expected.name
  )
) then 'ok 3 - hierarchy constraints exist'
else 'not ok 3 - a hierarchy constraint is missing' end;

select case when not exists (
  select table_record.relname
  from pg_catalog.pg_class as table_record
  where table_record.oid = any(array[
    'public.shooting_lanes'::pg_catalog.regclass,
    'public.lane_booking_rules'::pg_catalog.regclass,
    'public.lane_booking_durations'::pg_catalog.regclass,
    'public.lane_pricing_rules'::pg_catalog.regclass
  ])
    and not table_record.relrowsecurity
) then 'ok 4 - RLS is enabled on every lane configuration table'
else 'not ok 4 - RLS is disabled on a lane configuration table' end;

select case when not exists (
  select table_name
  from (values
    ('shooting_lanes'),('lane_booking_rules'),
    ('lane_booking_durations'),('lane_pricing_rules')
  ) as configured(table_name)
  where pg_catalog.has_table_privilege(
    'authenticated', 'public.' || configured.table_name, 'INSERT,UPDATE,DELETE'
  )
) then 'ok 5 - authenticated has no direct lane configuration writes'
else 'not ok 5 - authenticated has a direct lane configuration write' end;

select case when not exists (
  select table_name
  from (values
    ('shooting_lanes'),('lane_booking_rules'),
    ('lane_booking_durations'),('lane_pricing_rules')
  ) as configured(table_name)
  where pg_catalog.has_table_privilege(
    'anon', 'public.' || configured.table_name, 'INSERT,UPDATE,DELETE'
  )
) then 'ok 6 - anon has no direct lane configuration writes'
else 'not ok 6 - anon has a direct lane configuration write' end;

select case when pg_catalog.to_regprocedure(
  'public.admin_get_lane_booking_configuration_v2()'
) is not null
and pg_catalog.has_function_privilege(
  'authenticated','public.admin_get_lane_booking_configuration_v2()','EXECUTE'
)
and not pg_catalog.has_function_privilege(
  'anon','public.admin_get_lane_booking_configuration_v2()','EXECUTE'
)
then 'ok 7 - current admin configuration reader contract exists'
else 'not ok 7 - admin configuration reader contract differs' end;

select case when pg_catalog.to_regprocedure(
  'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'
) is not null
and pg_catalog.has_function_privilege(
  'authenticated',
  'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)',
  'EXECUTE'
)
and not pg_catalog.has_function_privilege(
  'anon',
  'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)',
  'EXECUTE'
)
then 'ok 8 - current family writer V2 contract exists'
else 'not ok 8 - family writer V2 contract differs' end;

select case when pg_catalog.to_regprocedure(
  'public.get_public_booking_configuration_v1()'
) is not null
and pg_catalog.has_function_privilege(
  'anon','public.get_public_booking_configuration_v1()','EXECUTE'
)
then 'ok 9 - public booking configuration reader exists'
else 'not ok 9 - public booking configuration reader differs' end;

select case when pg_catalog.to_regprocedure(
  'public.get_lane_booking_busy_ranges_v3(uuid,date)'
) is not null
and pg_catalog.has_function_privilege(
  'authenticated','public.get_lane_booking_busy_ranges_v3(uuid,date)','EXECUTE'
)
and not pg_catalog.has_function_privilege(
  'anon','public.get_lane_booking_busy_ranges_v3(uuid,date)','EXECUTE'
)
then 'ok 10 - Availability V3 contract exists'
else 'not ok 10 - Availability V3 contract differs' end;

select case when pg_catalog.to_regprocedure(
  'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
) is not null
and pg_catalog.has_function_privilege(
  'authenticated',
  'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)',
  'EXECUTE'
)
and not pg_catalog.has_function_privilege(
  'anon',
  'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)',
  'EXECUTE'
)
then 'ok 11 - Reservation V2 contract exists'
else 'not ok 11 - Reservation V2 contract differs' end;

select case when (
  select pg_catalog.count(*) = 3
  from pg_catalog.pg_proc as procedure
  join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'public'
    and procedure.proname in (
      'admin_create_lane_block','admin_update_lane_block','admin_set_lane_block_active'
    )
    and procedure.prosecdef
) then 'ok 12 - all three current lane-block writers exist'
else 'not ok 12 - lane-block writer contract differs' end;

select case when (
  select pg_catalog.count(*) = 3
  from pg_catalog.pg_proc as procedure
  join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'public'
    and procedure.proname in (
      'admin_create_event_v2','admin_update_event_v2','admin_set_event_active_v2'
    )
    and procedure.prosecdef
) then 'ok 13 - all three current Event V2 writers exist'
else 'not ok 13 - Event V2 writer contract differs' end;

select case when not exists (
  select 1
  from public.shooting_lanes as lane
  left join public.shooting_lanes as parent on parent.id = lane.parent_lane_id
  where (lane.resource_kind = 'lane' and lane.parent_lane_id is not null)
     or (lane.resource_kind = 'position' and (
       lane.parent_lane_id is null
       or parent.id is null
       or parent.resource_kind is distinct from 'lane'
       or parent.parent_lane_id is not null
     ))
) then 'ok 14 - current hierarchy contains no orphan or nested position'
else 'not ok 14 - current hierarchy is invalid' end;
