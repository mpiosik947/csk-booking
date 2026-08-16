\set ON_ERROR_STOP on

-- Run with psql. The ACL migration and all catalog checks are enclosed in one
-- transaction that always ends with an explicit ROLLBACK.
select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
  ))) as v1_definition,
  (select function_record.proacl::text
   from pg_catalog.pg_proc as function_record
   where function_record.oid = pg_catalog.to_regprocedure(
     'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
   )) as v1_acl,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
  ))) as v2_definition,
  (select function_record.proacl::text
   from pg_catalog.pg_proc as function_record
   where function_record.oid = pg_catalog.to_regprocedure(
     'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
   )) as v2_acl,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'
  ))) as availability_v3_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.get_public_booking_configuration_v1()'
  ))) as public_config_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.lock_lane_conflict_families_v1(uuid[])'
  ))) as family_helper_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
  ))) as config_writer_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
  ))) as lane_block_create_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
  ))) as lane_block_update_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_lane_block_active(uuid,boolean)'
  ))) as lane_block_active_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) as event_create_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) as event_update_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_event_active_v2(uuid,boolean)'
  ))) as event_active_definition,
  (select pg_catalog.count(*) from public.reservations) as reservations_count,
  (select pg_catalog.count(*) from public.shooting_lanes) as shooting_lanes_count,
  (select pg_catalog.count(*) from public.lane_blocks) as lane_blocks_count,
  (select pg_catalog.count(*) from public.events) as events_count,
  (select pg_catalog.count(*) from public.event_lanes) as event_lanes_count,
  (select pg_catalog.count(*) from public.shooting_lanes
   where resource_kind = 'position') as positions_count
\gset baseline_

begin;

\ir ../migrations/20260810093150_revoke_create_reservation_v1_authenticated_execute.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

insert into pg_temp.test_results values
  (1, 'V1 istnieje z dokladna sygnatura',
    pg_catalog.to_regprocedure(
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
    ) is not null
      and (select pg_catalog.count(*)
           from pg_catalog.pg_proc as function_record
           join pg_catalog.pg_namespace as namespace_record
             on namespace_record.oid = function_record.pronamespace
           where namespace_record.nspname = 'public'
             and function_record.proname = 'create_reservation') = 1,
    'V1 istnieje fizycznie bez dodatkowych overloadow.'),
  (2, 'V1 authenticated bez EXECUTE',
    not pg_catalog.has_function_privilege(
      'authenticated',
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    ),
    'authenticated nie moze wykonywac V1.'),
  (3, 'V1 anon ACL zgodne z baseline',
    not pg_catalog.has_function_privilege(
      'anon',
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    ),
    'anon pozostaje bez EXECUTE V1.'),
  (4, 'V1 PUBLIC ACL zgodne z baseline',
    not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(coalesce(
        function_record.proacl,
        pg_catalog.acldefault('f', function_record.proowner)
      )) as function_acl
      where function_record.oid = pg_catalog.to_regprocedure(
        'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
      )
        and function_acl.grantee = 0
        and function_acl.privilege_type = 'EXECUTE'
    ),
    'PUBLIC pozostaje bez EXECUTE V1.'),
  (5, 'V1 service_role ACL zgodne z baseline',
    pg_catalog.has_function_privilege(
      'service_role',
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    ),
    'service_role zachowuje EXECUTE V1.'),
  (6, 'V1 owner zachowuje EXECUTE',
    pg_catalog.has_function_privilege(
      'postgres',
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    ),
    'Owner postgres zachowuje EXECUTE V1.'),
  (7, 'V1 definition unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
    ))) = :'baseline_v1_definition',
    'REVOKE nie zmienia definicji V1.'),
  (8, 'V1 properties unchanged',
    exists (
      select 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_roles as owner_role
        on owner_role.oid = function_record.proowner
      where function_record.oid = pg_catalog.to_regprocedure(
        'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
      )
        and owner_role.rolname = 'postgres'
        and function_record.prosecdef
        and function_record.provolatile = 'v'
        and function_record.proconfig =
          array['search_path=pg_catalog, public, pg_temp']::text[]
    ),
    'Owner, SECURITY DEFINER, volatility i search_path V1 sa bez zmian.'),
  (9, 'V2 istnieje z dokladna sygnatura',
    pg_catalog.to_regprocedure(
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
    ) is not null
      and (select pg_catalog.count(*)
           from pg_catalog.pg_proc as function_record
           join pg_catalog.pg_namespace as namespace_record
             on namespace_record.oid = function_record.pronamespace
           where namespace_record.nspname = 'public'
             and function_record.proname = 'create_reservation_v2') = 1,
    'V2 istnieje bez dodatkowych overloadow.'),
  (10, 'V2 authenticated zachowuje EXECUTE',
    pg_catalog.has_function_privilege(
      'authenticated',
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    ),
    'Publiczny runtime zachowuje dostep do V2.'),
  (11, 'V2 definition unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
    ))) = :'baseline_v2_definition',
    'Migracja nie zmienia definicji V2.'),
  (12, 'V2 properties unchanged',
    exists (
      select 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_roles as owner_role
        on owner_role.oid = function_record.proowner
      where function_record.oid = pg_catalog.to_regprocedure(
        'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
      )
        and owner_role.rolname = 'postgres'
        and function_record.prosecdef
        and function_record.provolatile = 'v'
        and function_record.proconfig =
          array['search_path=pg_catalog, public, pg_temp']::text[]
    ),
    'Owner, SECURITY DEFINER, volatility i search_path V2 sa bez zmian.'),
  (13, 'V2 ACL unchanged',
    (select function_record.proacl::text
     from pg_catalog.pg_proc as function_record
     where function_record.oid = pg_catalog.to_regprocedure(
       'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
     )) = :'baseline_v2_acl',
    'Pelne ACL V2 jest identyczne.'),
  (14, 'Availability V3 unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.get_lane_booking_busy_ranges_v3(uuid,date)'
    ))) = :'baseline_availability_v3_definition',
    'Availability V3 nie zostalo zmienione.'),
  (15, 'Family helper unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.lock_lane_conflict_families_v1(uuid[])'
    ))) = :'baseline_family_helper_definition',
    'Helper blokad rodzin osi jest identyczny.'),
  (16, 'Lane-block RPC unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
    ))) = :'baseline_lane_block_create_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
      ))) = :'baseline_lane_block_update_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_set_lane_block_active(uuid,boolean)'
      ))) = :'baseline_lane_block_active_definition',
    'Trzy lane-block RPC sa identyczne.'),
  (17, 'Event V2 RPC unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ))) = :'baseline_event_create_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
      ))) = :'baseline_event_update_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_set_event_active_v2(uuid,boolean)'
      ))) = :'baseline_event_active_definition',
    'Trzy Event V2 RPC sa identyczne.'),
  (18, 'Configuration RPC unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
    ))) = :'baseline_config_writer_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.get_public_booking_configuration_v1()'
      ))) = :'baseline_public_config_definition',
    'Config writer i publiczny reader sa identyczne.'),
  (19, 'Production data counts unchanged',
    (select pg_catalog.count(*) from public.reservations) =
      :'baseline_reservations_count'::bigint
      and (select pg_catalog.count(*) from public.shooting_lanes) =
        :'baseline_shooting_lanes_count'::bigint
      and (select pg_catalog.count(*) from public.lane_blocks) =
        :'baseline_lane_blocks_count'::bigint
      and (select pg_catalog.count(*) from public.events) =
        :'baseline_events_count'::bigint
      and (select pg_catalog.count(*) from public.event_lanes) =
        :'baseline_event_lanes_count'::bigint,
    'ACL-only migration nie zmienia danych.'),
  (20, 'Current hierarchy remains dormant',
    (select pg_catalog.count(*)
     from public.shooting_lanes
     where resource_kind = 'position') = :'baseline_positions_count'::bigint
      and :'baseline_positions_count'::bigint = 0,
    'Position count pozostaje rowny zero.' );

table pg_temp.test_results order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  )
  into v_failures
  from pg_temp.test_results
  where not passed;

  if v_failures is not null then
    raise exception 'Reservation V1 EXECUTE revoke tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
    'EXECUTE'
  )
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
  ))) = :'baseline_v1_definition'
  and (select function_record.proacl::text
       from pg_catalog.pg_proc as function_record
       where function_record.oid = pg_catalog.to_regprocedure(
         'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
       )) = :'baseline_v1_acl'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
  ))) = :'baseline_v2_definition'
  and (select function_record.proacl::text
       from pg_catalog.pg_proc as function_record
       where function_record.oid = pg_catalog.to_regprocedure(
         'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
       )) = :'baseline_v2_acl'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'
  ))) = :'baseline_availability_v3_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.lock_lane_conflict_families_v1(uuid[])'
  ))) = :'baseline_family_helper_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
  ))) = :'baseline_config_writer_definition'
  and (select pg_catalog.count(*) from public.reservations) =
    :'baseline_reservations_count'::bigint
  and (select pg_catalog.count(*) from public.shooting_lanes) =
    :'baseline_shooting_lanes_count'::bigint
  and (select pg_catalog.count(*) from public.lane_blocks) =
    :'baseline_lane_blocks_count'::bigint
  and (select pg_catalog.count(*) from public.events) =
    :'baseline_events_count'::bigint
  and (select pg_catalog.count(*) from public.event_lanes) =
    :'baseline_event_lanes_count'::bigint
  and (select pg_catalog.count(*) from public.shooting_lanes
       where resource_kind = 'position') = :'baseline_positions_count'::bigint
  as rollback_confirmed;
