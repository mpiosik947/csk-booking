\set ON_ERROR_STOP on

-- Run with psql. The ACL migration and all catalog checks are enclosed in one
-- transaction that always ends with an explicit ROLLBACK.
select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) as v1_create_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) as v1_update_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_event_active(uuid,boolean)'
  ))) as v1_active_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) as v2_create_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) as v2_update_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_event_active_v2(uuid,boolean)'
  ))) as v2_active_definition,
  (select function_record.proacl::text from pg_catalog.pg_proc as function_record
   where function_record.oid = pg_catalog.to_regprocedure(
     'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
   )) as v2_create_acl,
  (select function_record.proacl::text from pg_catalog.pg_proc as function_record
   where function_record.oid = pg_catalog.to_regprocedure(
     'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
   )) as v2_update_acl,
  (select function_record.proacl::text from pg_catalog.pg_proc as function_record
   where function_record.oid = pg_catalog.to_regprocedure(
     'public.admin_set_event_active_v2(uuid,boolean)'
   )) as v2_active_acl,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.lock_lane_conflict_families_v1(uuid[])'
  ))) as helper_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
  ))) as reservation_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
  ))) as block_create_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
  ))) as block_update_definition,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_lane_block_active(uuid,boolean)'
  ))) as block_active_definition,
  (select pg_catalog.count(*) from public.events) as events_count,
  (select pg_catalog.count(*) from public.event_lanes) as event_lanes_count,
  (select pg_catalog.count(*) from public.reservations) as reservations_count,
  (select pg_catalog.count(*) from public.lane_blocks) as lane_blocks_count,
  (select pg_catalog.count(*) from public.shooting_lanes
   where resource_kind = 'position') as positions_count
\gset baseline_

begin;

\ir ../migrations/20260809193000_revoke_event_v1_authenticated_execute.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

insert into pg_temp.test_results values
  (1, 'authenticated bez EXECUTE create V1',
    not pg_catalog.has_function_privilege('authenticated',
      'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE'),
    'V1 create nie jest dostępne dla authenticated.'),
  (2, 'authenticated bez EXECUTE update V1',
    not pg_catalog.has_function_privilege('authenticated',
      'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE'),
    'V1 update nie jest dostępne dla authenticated.'),
  (3, 'authenticated bez EXECUTE set-active V1',
    not pg_catalog.has_function_privilege('authenticated',
      'public.admin_set_event_active(uuid,boolean)', 'EXECUTE'),
    'V1 set-active nie jest dostępne dla authenticated.'),
  (4, 'authenticated zachowuje EXECUTE create V2',
    pg_catalog.has_function_privilege('authenticated',
      'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE'),
    'V2 create pozostaje dostępne.'),
  (5, 'authenticated zachowuje EXECUTE update V2',
    pg_catalog.has_function_privilege('authenticated',
      'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE'),
    'V2 update pozostaje dostępne.'),
  (6, 'authenticated zachowuje EXECUTE set-active V2',
    pg_catalog.has_function_privilege('authenticated',
      'public.admin_set_event_active_v2(uuid,boolean)', 'EXECUTE'),
    'V2 set-active pozostaje dostępne.'),
  (7, 'Funkcje V1 nadal istnieją bez dodatkowych overloadów',
    pg_catalog.to_regprocedure(
      'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ) is not null
      and pg_catalog.to_regprocedure(
        'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
      ) is not null
      and pg_catalog.to_regprocedure('public.admin_set_event_active(uuid,boolean)') is not null
      and (select pg_catalog.count(*) from pg_catalog.pg_proc as function_record
           join pg_catalog.pg_namespace as namespace_record
             on namespace_record.oid = function_record.pronamespace
           where namespace_record.nspname = 'public'
             and function_record.proname in (
               'admin_create_event', 'admin_update_event', 'admin_set_event_active'
             )) = 3,
    'Każda właściwa sygnatura V1 istnieje dokładnie raz.'),
  (8, 'Definicje V1 są identyczne',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ))) = :'baseline_v1_create_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
      ))) = :'baseline_v1_update_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_set_event_active(uuid,boolean)'
      ))) = :'baseline_v1_active_definition',
    'REVOKE nie zmienia kodu V1.'),
  (9, 'Definicje V2 są identyczne',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ))) = :'baseline_v2_create_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
      ))) = :'baseline_v2_update_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_set_event_active_v2(uuid,boolean)'
      ))) = :'baseline_v2_active_definition',
    'Migracja nie zmienia kodu V2.'),
  (10, 'Owner V1 i V2 pozostaje postgres',
    not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      join pg_catalog.pg_roles as owner_role
        on owner_role.oid = function_record.proowner
      where namespace_record.nspname = 'public'
        and function_record.proname in (
          'admin_create_event', 'admin_update_event', 'admin_set_event_active',
          'admin_create_event_v2', 'admin_update_event_v2', 'admin_set_event_active_v2'
        )
        and owner_role.rolname is distinct from 'postgres'
    ),
    'Właściciele sześciu RPC są niezmienieni.'),
  (11, 'Tryb bezpieczeństwa V1 i V2 jest niezmieniony',
    not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname in (
          'admin_create_event', 'admin_update_event', 'admin_set_event_active',
          'admin_create_event_v2', 'admin_update_event_v2', 'admin_set_event_active_v2'
        )
        and (
          not function_record.prosecdef
          or function_record.provolatile <> 'v'
          or (
            function_record.proname in (
              'admin_create_event', 'admin_update_event', 'admin_set_event_active'
            )
            and function_record.proconfig is distinct from
              array['search_path=public, pg_temp']::text[]
          )
          or (
            function_record.proname in (
              'admin_create_event_v2', 'admin_update_event_v2', 'admin_set_event_active_v2'
            )
            and function_record.proconfig is distinct from
              array['search_path=pg_catalog, public, pg_temp']::text[]
          )
        )
    ),
    'SECURITY DEFINER, volatility i dokładny search_path pozostają ustawione.'),
  (12, 'ACL V2 jest identyczne',
    (select function_record.proacl::text from pg_catalog.pg_proc as function_record
     where function_record.oid = pg_catalog.to_regprocedure(
       'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
     )) = :'baseline_v2_create_acl'
      and (select function_record.proacl::text from pg_catalog.pg_proc as function_record
           where function_record.oid = pg_catalog.to_regprocedure(
             'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
           )) = :'baseline_v2_update_acl'
      and (select function_record.proacl::text from pg_catalog.pg_proc as function_record
           where function_record.oid = pg_catalog.to_regprocedure(
             'public.admin_set_event_active_v2(uuid,boolean)'
           )) = :'baseline_v2_active_acl',
    'V2 ACL nie zostało dotknięte.'),
  (13, 'PUBLIC i anon nie uzyskują EXECUTE V1',
    not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(coalesce(
        function_record.proacl,
        pg_catalog.acldefault('f', function_record.proowner)
      )) as function_acl
      where function_record.oid in (
        pg_catalog.to_regprocedure('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
        pg_catalog.to_regprocedure('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
        pg_catalog.to_regprocedure('public.admin_set_event_active(uuid,boolean)')
      )
        and function_acl.privilege_type = 'EXECUTE'
        and (
          function_acl.grantee = 0
          or function_acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon')
        )
    ),
    'PUBLIC i anon pozostają bez EXECUTE.'),
  (14, 'service_role zachowuje EXECUTE V1',
    pg_catalog.has_function_privilege('service_role',
      'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE')
      and pg_catalog.has_function_privilege('service_role',
        'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE')
      and pg_catalog.has_function_privilege('service_role',
        'public.admin_set_event_active(uuid,boolean)', 'EXECUTE'),
    'Migracja nie zmienia service_role.'),
  (15, 'Helper rodzin osi jest identyczny',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.lock_lane_conflict_families_v1(uuid[])'
    ))) = :'baseline_helper_definition',
    'Helper nie został zmieniony.'),
  (16, 'create_reservation_v2 jest identyczne',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
    ))) = :'baseline_reservation_definition',
    'Reservation V2 nie zostało zmienione.'),
  (17, 'Lane-block RPC są identyczne',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
      'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
    ))) = :'baseline_block_create_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
      ))) = :'baseline_block_update_definition'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
        'public.admin_set_lane_block_active(uuid,boolean)'
      ))) = :'baseline_block_active_definition',
    'Writery lane_blocks nie zostały zmienione.'),
  (18, 'Dane produkcyjne są niezmienione',
    (select pg_catalog.count(*) from public.events) = :'baseline_events_count'::bigint
      and (select pg_catalog.count(*) from public.event_lanes) = :'baseline_event_lanes_count'::bigint
      and (select pg_catalog.count(*) from public.reservations) = :'baseline_reservations_count'::bigint
      and (select pg_catalog.count(*) from public.lane_blocks) = :'baseline_lane_blocks_count'::bigint
      and (select pg_catalog.count(*) from public.shooting_lanes
           where resource_kind = 'position') = :'baseline_positions_count'::bigint,
    'Migracja ACL-only nie zmienia danych ani hierarchii.');

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
    raise exception 'Event V1 EXECUTE revoke tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.has_function_privilege('authenticated',
    'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE')
  and pg_catalog.has_function_privilege('authenticated',
    'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', 'EXECUTE')
  and pg_catalog.has_function_privilege('authenticated',
    'public.admin_set_event_active(uuid,boolean)', 'EXECUTE')
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) = :'baseline_v1_create_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) = :'baseline_v1_update_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_event_active(uuid,boolean)'
  ))) = :'baseline_v1_active_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) = :'baseline_v2_create_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  ))) = :'baseline_v2_update_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_event_active_v2(uuid,boolean)'
  ))) = :'baseline_v2_active_definition'
  and (select function_record.proacl::text from pg_catalog.pg_proc as function_record
       where function_record.oid = pg_catalog.to_regprocedure(
         'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
       )) = :'baseline_v2_create_acl'
  and (select function_record.proacl::text from pg_catalog.pg_proc as function_record
       where function_record.oid = pg_catalog.to_regprocedure(
         'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
       )) = :'baseline_v2_update_acl'
  and (select function_record.proacl::text from pg_catalog.pg_proc as function_record
       where function_record.oid = pg_catalog.to_regprocedure(
         'public.admin_set_event_active_v2(uuid,boolean)'
       )) = :'baseline_v2_active_acl'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.lock_lane_conflict_families_v1(uuid[])'
  ))) = :'baseline_helper_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
  ))) = :'baseline_reservation_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
  ))) = :'baseline_block_create_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
  ))) = :'baseline_block_update_definition'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(
    'public.admin_set_lane_block_active(uuid,boolean)'
  ))) = :'baseline_block_active_definition'
  and (select pg_catalog.count(*) from public.events) = :'baseline_events_count'::bigint
  and (select pg_catalog.count(*) from public.event_lanes) = :'baseline_event_lanes_count'::bigint
  and (select pg_catalog.count(*) from public.reservations) = :'baseline_reservations_count'::bigint
  and (select pg_catalog.count(*) from public.lane_blocks) = :'baseline_lane_blocks_count'::bigint
  and (select pg_catalog.count(*) from public.shooting_lanes
       where resource_kind = 'position') = :'baseline_positions_count'::bigint
  as rollback_confirmed;
