\set ON_ERROR_STOP on

-- Run with psql against the linked project. The migration and every
-- [TEST][6B-1A] fixture are enclosed in one transaction and rolled back.
begin;

create temporary table booking_configuration_baseline as
select
  (select pg_catalog.md5(pg_catalog.string_agg(
     object_type || '|' || table_name || '|' || object_name || '|' || definition,
     E'\n' order by object_type, table_name, object_name
   ))
   from (
     select 'column'::text as object_type, table_record.relname as table_name,
            attribute_record.attname as object_name,
            pg_catalog.format_type(attribute_record.atttypid, attribute_record.atttypmod)
              || '|' || attribute_record.attnotnull::text || '|'
              || coalesce(pg_catalog.pg_get_expr(default_record.adbin, default_record.adrelid), '<null>')
              as definition
     from pg_catalog.pg_class as table_record
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = table_record.relnamespace
     join pg_catalog.pg_attribute as attribute_record
       on attribute_record.attrelid = table_record.oid
     left join pg_catalog.pg_attrdef as default_record
       on default_record.adrelid = attribute_record.attrelid
      and default_record.adnum = attribute_record.attnum
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'shooting_lanes', 'lane_booking_rules',
         'lane_booking_durations', 'lane_pricing_rules'
       )
       and attribute_record.attnum > 0
       and not attribute_record.attisdropped
     union all
     select 'constraint', table_record.relname, constraint_record.conname,
            pg_catalog.pg_get_constraintdef(constraint_record.oid, true)
     from pg_catalog.pg_constraint as constraint_record
     join pg_catalog.pg_class as table_record
       on table_record.oid = constraint_record.conrelid
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = table_record.relnamespace
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'shooting_lanes', 'lane_booking_rules',
         'lane_booking_durations', 'lane_pricing_rules'
       )
     union all
     select 'index', table_record.relname,
            index_record.indexrelid::pg_catalog.regclass::text,
            pg_catalog.pg_get_indexdef(index_record.indexrelid)
     from pg_catalog.pg_index as index_record
     join pg_catalog.pg_class as table_record
       on table_record.oid = index_record.indrelid
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = table_record.relnamespace
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'shooting_lanes', 'lane_booking_rules',
         'lane_booking_durations', 'lane_pricing_rules'
       )
     union all
     select 'trigger', table_record.relname, trigger_record.tgname,
            pg_catalog.pg_get_triggerdef(trigger_record.oid, true)
     from pg_catalog.pg_trigger as trigger_record
     join pg_catalog.pg_class as table_record
       on table_record.oid = trigger_record.tgrelid
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = table_record.relnamespace
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'shooting_lanes', 'lane_booking_rules',
         'lane_booking_durations', 'lane_pricing_rules'
       )
       and not trigger_record.tgisinternal
     union all
     select 'policy', policy_record.tablename, policy_record.policyname,
            policy_record.permissive || '|' || policy_record.cmd || '|'
              || policy_record.roles::text || '|'
              || coalesce(policy_record.qual, '<null>') || '|'
              || coalesce(policy_record.with_check, '<null>')
     from pg_catalog.pg_policies as policy_record
     where policy_record.schemaname = 'public'
       and policy_record.tablename in (
         'shooting_lanes', 'lane_booking_rules',
         'lane_booking_durations', 'lane_pricing_rules'
       )
   ) as schema_object) as source_schema_hash,
  (select pg_catalog.md5(pg_catalog.string_agg(
     table_record.relname || '|' || coalesce(grantee_role.rolname, 'PUBLIC')
       || '|' || acl.privilege_type || '|' || acl.is_grantable::text,
     E'\n' order by table_record.relname,
       coalesce(grantee_role.rolname, 'PUBLIC'), acl.privilege_type
   ))
   from pg_catalog.pg_class as table_record
   join pg_catalog.pg_namespace as namespace_record
     on namespace_record.oid = table_record.relnamespace
   cross join lateral pg_catalog.aclexplode(
     coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
   ) as acl
   left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
   where namespace_record.nspname = 'public'
     and table_record.relname in (
       'shooting_lanes', 'lane_booking_rules',
       'lane_booking_durations', 'lane_pricing_rules'
     )) as source_acl_hash,
  pg_catalog.md5(
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id
     ), '')) from public.shooting_lanes as row_record)
    || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.lane_id
     ), '')) from public.lane_booking_rules as row_record)
    || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id
     ), '')) from public.lane_booking_durations as row_record)
    || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id
     ), '')) from public.lane_pricing_rules as row_record)
  ) as source_data_hash;

select * from pg_temp.booking_configuration_baseline \gset baseline_

\ir ../migrations/20260808220801_add_public_booking_configuration_v1.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(
  p_order integer,
  p_name text,
  p_passed boolean,
  p_result text
)
returns void
language sql
as $function$
  insert into pg_temp.test_results values (p_order, p_name, p_passed, p_result);
$function$;

create function pg_temp.add_valid_offer(
  p_lane_id uuid,
  p_max_people integer
)
returns void
language plpgsql
as $function$
begin
  insert into public.lane_booking_rules (
    lane_id, online_bookable, max_people_online
  ) values (p_lane_id, true, p_max_people);

  insert into public.lane_booking_durations (
    lane_id, duration_minutes, display_order, is_active
  ) values
    (p_lane_id, 120, 20, true),
    (p_lane_id, 60, 10, true);

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters,
    label, hourly_price, display_order, is_active
  ) values
    (p_lane_id, 'mon_thu', 1, p_max_people, '[TEST] mon-thu', 100, 10, true),
    (p_lane_id, 'fri_sun', 1, p_max_people, '[TEST] fri-sun', 120, 10, true);
end;
$function$;

create function pg_temp.add_lane(
  p_id uuid,
  p_name text,
  p_active boolean,
  p_display_order integer,
  p_parent_id uuid,
  p_kind text,
  p_whole boolean,
  p_positions boolean,
  p_max_shooters integer default 4
)
returns void
language plpgsql
as $function$
begin
  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values (
    p_id, p_name, '[TEST]', '[TEST][6B-1A]', 0, p_active,
    p_max_shooters, 60, p_display_order, 'PLN',
    p_kind, p_parent_id, p_whole, p_positions
  );
end;
$function$;

do $current_production$
declare
  v_count integer;
begin
  select pg_catalog.count(*) into v_count
  from public.get_public_booking_configuration_v1();

  perform pg_temp.record_result(
    1, 'A. Aktualne top-level whole-only',
    v_count = 5
      and not exists (
        select 1 from public.get_public_booking_configuration_v1()
        where resource_kind <> 'lane' or parent_lane_id is not null
          or not effective_online_bookable or not whole_lane_bookable
          or positions_bookable
      ),
    'Aktualna produkcja powinna zwracać dokładnie pięć publicznych osi whole-only.'
  );
end;
$current_production$;

do $fixtures$
begin
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000001', '[TEST][6B-1A] inactive', false, 1001, null, 'lane', true, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000001', 2);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000002', '[TEST][6B-1A] offline', true, 1002, null, 'lane', true, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000002', 2);
  update public.lane_booking_rules set online_bookable = false
  where lane_id = '6b100000-0000-4000-8000-000000000002';

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000003', '[TEST][6B-1A] whole', true, 1010, null, 'lane', true, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000003', 2);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000004', '[TEST][6B-1A] positions parent', true, 1020, null, 'lane', false, true);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000005', '[TEST][6B-1A] child valid', true, 1, '6b100000-0000-4000-8000-000000000004', 'position', false, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000005', 1);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000006', '[TEST][6B-1A] both parent', true, 1030, null, 'lane', true, true);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000006', 3);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000007', '[TEST][6B-1A] both child', true, 1, '6b100000-0000-4000-8000-000000000006', 'position', false, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000007', 1);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000008', '[TEST][6B-1A] inactive child', false, 2, '6b100000-0000-4000-8000-000000000004', 'position', false, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000008', 1);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000009', '[TEST][6B-1A] inactive parent', false, 1040, null, 'lane', false, true);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000010', '[TEST][6B-1A] inactive-parent child', true, 1, '6b100000-0000-4000-8000-000000000009', 'position', false, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000010', 1);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000011', '[TEST][6B-1A] offline child', true, 3, '6b100000-0000-4000-8000-000000000004', 'position', false, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000011', 1);
  update public.lane_booking_rules set online_bookable = false
  where lane_id = '6b100000-0000-4000-8000-000000000011';

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000012', '[TEST][6B-1A] no duration', true, 1050, null, 'lane', true, false);
  insert into public.lane_booking_rules values ('6b100000-0000-4000-8000-000000000012', true, 2, default, default);
  insert into public.lane_pricing_rules (lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values
    ('6b100000-0000-4000-8000-000000000012','mon_thu',1,2,'[TEST]',100,1,true),
    ('6b100000-0000-4000-8000-000000000012','fri_sun',1,2,'[TEST]',100,1,true);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000013', '[TEST][6B-1A] no mon', true, 1051, null, 'lane', true, false);
  insert into public.lane_booking_rules values ('6b100000-0000-4000-8000-000000000013', true, 2, default, default);
  insert into public.lane_booking_durations (lane_id,duration_minutes,display_order,is_active) values ('6b100000-0000-4000-8000-000000000013',60,1,true);
  insert into public.lane_pricing_rules (lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values ('6b100000-0000-4000-8000-000000000013','fri_sun',1,2,'[TEST]',100,1,true);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000014', '[TEST][6B-1A] no fri', true, 1052, null, 'lane', true, false);
  insert into public.lane_booking_rules values ('6b100000-0000-4000-8000-000000000014', true, 2, default, default);
  insert into public.lane_booking_durations (lane_id,duration_minutes,display_order,is_active) values ('6b100000-0000-4000-8000-000000000014',60,1,true);
  insert into public.lane_pricing_rules (lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values ('6b100000-0000-4000-8000-000000000014','mon_thu',1,2,'[TEST]',100,1,true);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000015', '[TEST][6B-1A] gap', true, 1053, null, 'lane', true, false, 3);
  insert into public.lane_booking_rules values ('6b100000-0000-4000-8000-000000000015', true, 3, default, default);
  insert into public.lane_booking_durations (lane_id,duration_minutes,display_order,is_active) values ('6b100000-0000-4000-8000-000000000015',60,1,true);
  insert into public.lane_pricing_rules (lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values
    ('6b100000-0000-4000-8000-000000000015','mon_thu',1,1,'[TEST]',100,1,true),
    ('6b100000-0000-4000-8000-000000000015','mon_thu',3,3,'[TEST]',100,2,true),
    ('6b100000-0000-4000-8000-000000000015','fri_sun',1,3,'[TEST]',100,1,true);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000016', '[TEST][6B-1A] overlap', true, 1054, null, 'lane', true, false, 3);
  insert into public.lane_booking_rules values ('6b100000-0000-4000-8000-000000000016', true, 3, default, default);
  insert into public.lane_booking_durations (lane_id,duration_minutes,display_order,is_active) values ('6b100000-0000-4000-8000-000000000016',60,1,true);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000017', '[TEST][6B-1A] beyond max', true, 1055, null, 'lane', true, false, 4);
  insert into public.lane_booking_rules values ('6b100000-0000-4000-8000-000000000017', true, 2, default, default);
  insert into public.lane_booking_durations (lane_id,duration_minutes,display_order,is_active) values ('6b100000-0000-4000-8000-000000000017',60,1,true);
  insert into public.lane_pricing_rules (lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values
    ('6b100000-0000-4000-8000-000000000017','mon_thu',1,3,'[TEST]',100,1,true),
    ('6b100000-0000-4000-8000-000000000017','fri_sun',1,3,'[TEST]',100,1,true);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000018', '[TEST][6B-1A] thresholds', true, 1060, null, 'lane', true, false, 4);
  insert into public.lane_booking_rules values ('6b100000-0000-4000-8000-000000000018', true, 4, default, default);
  insert into public.lane_booking_durations (lane_id,duration_minutes,display_order,is_active) values
    ('6b100000-0000-4000-8000-000000000018',120,2,true),
    ('6b100000-0000-4000-8000-000000000018',60,1,true);
  insert into public.lane_pricing_rules (lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values
    ('6b100000-0000-4000-8000-000000000018','mon_thu',1,2,'[TEST] M1',100,2,true),
    ('6b100000-0000-4000-8000-000000000018','mon_thu',3,4,'[TEST] M2',80,1,true),
    ('6b100000-0000-4000-8000-000000000018','fri_sun',1,2,'[TEST] F1',120,2,true),
    ('6b100000-0000-4000-8000-000000000018','fri_sun',3,4,'[TEST] F2',100,1,true);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000019', '[TEST][6B-1A] missing-rule parent', true, 1070, null, 'lane', true, true);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000020', '[TEST][6B-1A] missing-rule child', true, 1, '6b100000-0000-4000-8000-000000000019', 'position', false, false);
  perform pg_temp.add_valid_offer('6b100000-0000-4000-8000-000000000020', 1);

  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000021', '[TEST][6B-1A] coverage A', true, 1081, null, 'lane', true, false, 6);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000022', '[TEST][6B-1A] coverage B', true, 1082, null, 'lane', true, false, 6);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000023', '[TEST][6B-1A] coverage C', true, 1083, null, 'lane', true, false, 6);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000024', '[TEST][6B-1A] coverage D', true, 1084, null, 'lane', true, false, 6);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000025', '[TEST][6B-1A] coverage E', true, 1085, null, 'lane', true, false, 6);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000026', '[TEST][6B-1A] coverage F', true, 1086, null, 'lane', true, false, 6);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000027', '[TEST][6B-1A] coverage G', true, 1087, null, 'lane', true, false, 7);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000028', '[TEST][6B-1A] coverage H mon', true, 1088, null, 'lane', true, false, 6);
  perform pg_temp.add_lane('6b100000-0000-4000-8000-000000000029', '[TEST][6B-1A] coverage H fri', true, 1089, null, 'lane', true, false, 6);

  insert into public.lane_booking_rules (lane_id, online_bookable, max_people_online)
  select configured_lane.lane_id, true, 6
  from pg_catalog.unnest(array[
    '6b100000-0000-4000-8000-000000000021'::uuid,
    '6b100000-0000-4000-8000-000000000022'::uuid,
    '6b100000-0000-4000-8000-000000000023'::uuid,
    '6b100000-0000-4000-8000-000000000024'::uuid,
    '6b100000-0000-4000-8000-000000000025'::uuid,
    '6b100000-0000-4000-8000-000000000026'::uuid,
    '6b100000-0000-4000-8000-000000000027'::uuid,
    '6b100000-0000-4000-8000-000000000028'::uuid,
    '6b100000-0000-4000-8000-000000000029'::uuid
  ]) as configured_lane(lane_id);

  insert into public.lane_booking_durations (
    lane_id, duration_minutes, display_order, is_active
  )
  select configured_lane.lane_id, 60, 1, true
  from pg_catalog.unnest(array[
    '6b100000-0000-4000-8000-000000000021'::uuid,
    '6b100000-0000-4000-8000-000000000022'::uuid,
    '6b100000-0000-4000-8000-000000000023'::uuid,
    '6b100000-0000-4000-8000-000000000024'::uuid,
    '6b100000-0000-4000-8000-000000000025'::uuid,
    '6b100000-0000-4000-8000-000000000026'::uuid,
    '6b100000-0000-4000-8000-000000000027'::uuid,
    '6b100000-0000-4000-8000-000000000028'::uuid,
    '6b100000-0000-4000-8000-000000000029'::uuid
  ]) as configured_lane(lane_id);

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters,
    label, hourly_price, display_order, is_active
  ) values
    ('6b100000-0000-4000-8000-000000000021','mon_thu',1,6,'[TEST] A',100,1,true),
    ('6b100000-0000-4000-8000-000000000021','fri_sun',1,6,'[TEST] A',120,1,true),
    ('6b100000-0000-4000-8000-000000000022','mon_thu',1,2,'[TEST] B1',100,1,true),
    ('6b100000-0000-4000-8000-000000000022','mon_thu',3,4,'[TEST] B2',90,2,true),
    ('6b100000-0000-4000-8000-000000000022','mon_thu',5,6,'[TEST] B3',80,3,true),
    ('6b100000-0000-4000-8000-000000000022','fri_sun',1,2,'[TEST] B1',120,1,true),
    ('6b100000-0000-4000-8000-000000000022','fri_sun',3,4,'[TEST] B2',110,2,true),
    ('6b100000-0000-4000-8000-000000000022','fri_sun',5,6,'[TEST] B3',100,3,true),
    ('6b100000-0000-4000-8000-000000000023','mon_thu',1,2,'[TEST] C1',100,1,true),
    ('6b100000-0000-4000-8000-000000000023','mon_thu',4,6,'[TEST] C2',90,2,true),
    ('6b100000-0000-4000-8000-000000000023','fri_sun',1,6,'[TEST] C',120,1,true),
    ('6b100000-0000-4000-8000-000000000025','mon_thu',2,6,'[TEST] E',100,1,true),
    ('6b100000-0000-4000-8000-000000000025','fri_sun',2,6,'[TEST] E',120,1,true),
    ('6b100000-0000-4000-8000-000000000026','mon_thu',1,5,'[TEST] F',100,1,true),
    ('6b100000-0000-4000-8000-000000000026','fri_sun',1,5,'[TEST] F',120,1,true),
    ('6b100000-0000-4000-8000-000000000027','mon_thu',1,7,'[TEST] G',100,1,true),
    ('6b100000-0000-4000-8000-000000000027','fri_sun',1,7,'[TEST] G',120,1,true),
    ('6b100000-0000-4000-8000-000000000028','mon_thu',1,6,'[TEST] H mon',100,1,true),
    ('6b100000-0000-4000-8000-000000000028','fri_sun',1,2,'[TEST] H fri 1',120,1,true),
    ('6b100000-0000-4000-8000-000000000028','fri_sun',4,6,'[TEST] H fri 2',110,2,true),
    ('6b100000-0000-4000-8000-000000000029','mon_thu',1,2,'[TEST] H mon 1',100,1,true),
    ('6b100000-0000-4000-8000-000000000029','mon_thu',4,6,'[TEST] H mon 2',90,2,true),
    ('6b100000-0000-4000-8000-000000000029','fri_sun',1,6,'[TEST] H fri',120,1,true);
end;
$fixtures$;

-- The production exclusion constraint normally makes overlap impossible. It is
-- removed only inside this rollback transaction to prove the RPC also fails closed
-- against malformed legacy/drifted data, then restored before schema assertions.
alter table public.lane_pricing_rules
  drop constraint lane_pricing_rules_active_ranges_excl;

insert into public.lane_pricing_rules (
  lane_id, day_group, min_shooters, max_shooters,
  label, hourly_price, display_order, is_active
) values
  ('6b100000-0000-4000-8000-000000000016','mon_thu',1,2,'[TEST] overlap 1',100,1,true),
  ('6b100000-0000-4000-8000-000000000016','mon_thu',2,3,'[TEST] overlap 2',90,2,true),
  ('6b100000-0000-4000-8000-000000000016','fri_sun',1,3,'[TEST]',100,1,true),
  ('6b100000-0000-4000-8000-000000000024','mon_thu',1,3,'[TEST] D1',100,1,true),
  ('6b100000-0000-4000-8000-000000000024','mon_thu',3,6,'[TEST] D2',90,2,true),
  ('6b100000-0000-4000-8000-000000000024','fri_sun',1,3,'[TEST] D1',120,1,true),
  ('6b100000-0000-4000-8000-000000000024','fri_sun',3,6,'[TEST] D2',110,2,true);

do $overlap_test$
begin
  perform pg_temp.record_result(
    15, 'O. Overlap pricing jest fail-closed',
    not exists (
      select 1 from public.get_public_booking_configuration_v1()
      where lane_id = '6b100000-0000-4000-8000-000000000016'
    ),
    'Zasób z overlapem nie może być publicznie rezerwowalny.'
  );
  perform pg_temp.record_result(
    35, 'Coverage D. 1-3 i 3-6 jest odrzucone',
    not exists (
      select 1 from public.get_public_booking_configuration_v1()
      where lane_id = '6b100000-0000-4000-8000-000000000024'
    ),
    'Styk współdzielący wartość 3 jest overlapem, a nie ciągłością.'
  );
end;
$overlap_test$;

delete from public.lane_pricing_rules
where lane_id in (
  '6b100000-0000-4000-8000-000000000016',
  '6b100000-0000-4000-8000-000000000024'
);
delete from public.lane_booking_durations
where lane_id in (
  '6b100000-0000-4000-8000-000000000016',
  '6b100000-0000-4000-8000-000000000024'
);
delete from public.lane_booking_rules
where lane_id in (
  '6b100000-0000-4000-8000-000000000016',
  '6b100000-0000-4000-8000-000000000024'
);
delete from public.shooting_lanes
where id in (
  '6b100000-0000-4000-8000-000000000016',
  '6b100000-0000-4000-8000-000000000024'
);

alter table public.lane_pricing_rules
  add constraint lane_pricing_rules_active_ranges_excl
  exclude using gist (
    lane_id with =,
    day_group with =,
    int4range(min_shooters, max_shooters, '[]') with &&
  ) where (is_active);

set local role anon;
select pg_catalog.count(*) > 0 as rpc_accessible \gset anon_
from public.get_public_booking_configuration_v1();
reset role;

set local role authenticated;
select pg_catalog.count(*) > 0 as rpc_accessible \gset authenticated_
from public.get_public_booking_configuration_v1();
reset role;

set local role service_role;
select pg_catalog.count(*) > 0 as rpc_accessible \gset service_role_
from public.get_public_booking_configuration_v1();
reset role;

do $tests$
declare
  v_function oid := 'public.get_public_booking_configuration_v1()'::pg_catalog.regprocedure;
  v_schema_hash text;
  v_acl_hash text;
begin
  perform pg_temp.record_result(2, 'B. Inactive lane jest ukryta', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000001'), 'Inactive lane nie może być widoczna.');
  perform pg_temp.record_result(3, 'C. Offline lane jest ukryta', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000002'), 'Offline booking rule wyłącza zasób.');
  perform pg_temp.record_result(4, 'D. Whole-only parent', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000003' and effective_online_bookable and whole_lane_bookable and not positions_bookable and max_people_online=2 and durations_minutes=array[60,120]), 'Whole-only ma pełną samodzielną ofertę.');
  perform pg_temp.record_result(5, 'E. Positions-only parent i valid child', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000004' and not effective_online_bookable and not whole_lane_bookable and positions_bookable) and exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000005' and effective_online_bookable), 'Parent grupuje co najmniej jedno poprawne dziecko.');
  perform pg_temp.record_result(6, 'F. Oba tryby parenta', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000006' and effective_online_bookable and whole_lane_bookable and positions_bookable), 'Both mode wymaga poprawnej oferty whole i dziecka.');
  perform pg_temp.record_result(7, 'G. Valid child', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000005' and resource_kind='position' and not whole_lane_bookable and not positions_bookable and max_people_online=1), 'Poprawna position jest rezerwowalna samodzielnie.');
  perform pg_temp.record_result(8, 'H. Inactive child', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000008'), 'Nieaktywne dziecko jest ukryte.');
  perform pg_temp.record_result(9, 'I. Inactive parent', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id in ('6b100000-0000-4000-8000-000000000009','6b100000-0000-4000-8000-000000000010')), 'Nieaktywny parent wyłącza siebie i child.');
  perform pg_temp.record_result(10, 'J. Offline child', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000011'), 'Offline child jest ukryte.');
  perform pg_temp.record_result(11, 'K. Brak durations', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000012'), 'Brak aktywnej duration jest fail-closed.');
  perform pg_temp.record_result(12, 'L. Brak mon_thu', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000013'), 'Brak mon_thu jest fail-closed.');
  perform pg_temp.record_result(13, 'M. Brak fri_sun', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000014'), 'Brak fri_sun jest fail-closed.');
  perform pg_temp.record_result(14, 'N. Gap pricing', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000015'), 'Luka w 1..max_people_online jest fail-closed.');
  perform pg_temp.record_result(16, 'P. Pricing ponad max_people_online', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000017'), 'Zakres ponad publiczny limit jest fail-closed.');
  perform pg_temp.record_result(17, 'Q. Coverage wielu progów', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000018' and effective_online_bookable and max_people_online=4 and pg_catalog.jsonb_array_length(pricing)=4 and durations_minutes=array[60,120]), 'Dokładne pokrycie wieloma progami jest akceptowane.');
  perform pg_temp.record_result(18, 'R. display_name child', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000005' and display_name='[TEST][6B-1A] positions parent — [TEST][6B-1A] child valid'), 'display_name child jest generowane z parent i child.');
  perform pg_temp.record_result(19, 'S. Sortowanie parent przed children', (select pg_catalog.array_agg(lane_id order by ordinality) from public.get_public_booking_configuration_v1() with ordinality where lane_id in ('6b100000-0000-4000-8000-000000000004','6b100000-0000-4000-8000-000000000005')) = array['6b100000-0000-4000-8000-000000000004'::uuid,'6b100000-0000-4000-8000-000000000005'::uuid], 'Parent bezpośrednio poprzedza własne children.');
  perform pg_temp.record_result(20, 'T. Group-only parent', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000004' and not effective_online_bookable and max_people_online is null and durations_minutes=array[]::integer[] and pricing='[]'::jsonb), 'Kontener nie ujawnia półskonfigurowanej oferty whole.');
  perform pg_temp.record_result(21, 'U. Dokładny zestaw kolumn RPC', (select procedure_record.proargnames from pg_catalog.pg_proc procedure_record where procedure_record.oid=v_function) = array['lane_id','parent_lane_id','resource_kind','name','display_name','display_order','effective_online_bookable','whole_lane_bookable','positions_bookable','max_people_online','booking_step_minutes','currency_code','durations_minutes','pricing']::text[] and (select procedure_record.proargmodes from pg_catalog.pg_proc procedure_record where procedure_record.oid=v_function) = array['t','t','t','t','t','t','t','t','t','t','t','t','t','t']::"char"[] and (select procedure_record.proallargtypes from pg_catalog.pg_proc procedure_record where procedure_record.oid=v_function) = array['uuid'::pg_catalog.regtype::oid,'uuid'::pg_catalog.regtype::oid,'text'::pg_catalog.regtype::oid,'text'::pg_catalog.regtype::oid,'text'::pg_catalog.regtype::oid,'integer'::pg_catalog.regtype::oid,'boolean'::pg_catalog.regtype::oid,'boolean'::pg_catalog.regtype::oid,'boolean'::pg_catalog.regtype::oid,'integer'::pg_catalog.regtype::oid,'integer'::pg_catalog.regtype::oid,'text'::pg_catalog.regtype::oid,'integer[]'::pg_catalog.regtype::oid,'jsonb'::pg_catalog.regtype::oid]::oid[], 'RETURNS TABLE ma dokładnie 14 uzgodnionych nazw i typów.');
  perform pg_temp.record_result(22, 'V. Dokładny shape pricing JSON', not exists (select 1 from public.get_public_booking_configuration_v1() result cross join lateral pg_catalog.jsonb_array_elements(result.pricing) item where (select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(item) key) <> array['day_group','hourly_price','label','max_shooters','min_shooters']::text[]), 'Każdy element pricing ma dokładnie pięć publicznych kluczy.');
  perform pg_temp.record_result(23, 'W. Brak PII i metadata administracyjnych', not exists (select 1 from public.get_public_booking_configuration_v1() result cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(result)) key where key in ('id','pricing_rule_id','duration_id','max_shooters','is_active','online_bookable','customer_name','customer_email','customer_phone','user_id','created_at','updated_at')) and pg_catalog.strpos((select pricing::text from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000018'), 'lane_id')=0, 'Kontrakt nie ujawnia PII, raw flags ani wewnętrznych ID reguł.');
  perform pg_temp.record_result(24, 'X. anon EXECUTE', :'anon_rpc_accessible'::boolean, 'anon może wykonać publiczny snapshot.');
  perform pg_temp.record_result(25, 'Y. authenticated EXECUTE', :'authenticated_rpc_accessible'::boolean, 'authenticated może wykonać publiczny snapshot.');
  perform pg_temp.record_result(26, 'Z. service_role EXECUTE', :'service_role_rpc_accessible'::boolean, 'service_role zachowuje EXECUTE.');
  perform pg_temp.record_result(27, 'AA. PUBLIC bez EXECUTE', not exists (select 1 from pg_catalog.pg_proc procedure_record cross join lateral pg_catalog.aclexplode(coalesce(procedure_record.proacl,pg_catalog.acldefault('f',procedure_record.proowner))) acl where procedure_record.oid=v_function and acl.grantee=0 and acl.privilege_type='EXECUTE'), 'Pseudo-rola PUBLIC nie ma EXECUTE.');
  perform pg_temp.record_result(28, 'AB. SECURITY DEFINER i właściwości', exists (select 1 from pg_catalog.pg_proc procedure_record join pg_catalog.pg_roles owner_role on owner_role.oid=procedure_record.proowner join pg_catalog.pg_language language_record on language_record.oid=procedure_record.prolang where procedure_record.oid=v_function and procedure_record.prosecdef and procedure_record.provolatile='s' and owner_role.rolname='postgres' and language_record.lanname='sql' and procedure_record.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]), 'SQL STABLE SECURITY DEFINER, postgres, bezpieczny search_path.');

  select pg_catalog.md5(pg_catalog.string_agg(table_record.relname||'|'||coalesce(grantee_role.rolname,'PUBLIC')||'|'||acl.privilege_type||'|'||acl.is_grantable::text,E'\n' order by table_record.relname,coalesce(grantee_role.rolname,'PUBLIC'),acl.privilege_type)) into v_acl_hash from pg_catalog.pg_class table_record join pg_catalog.pg_namespace namespace_record on namespace_record.oid=table_record.relnamespace cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl,pg_catalog.acldefault('r',table_record.relowner))) acl left join pg_catalog.pg_roles grantee_role on grantee_role.oid=acl.grantee where namespace_record.nspname='public' and table_record.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules');
  perform pg_temp.record_result(29, 'AC. Brak nowych table grants', v_acl_hash=(select source_acl_hash from pg_temp.booking_configuration_baseline), 'ACL czterech tabel źródłowych pozostaje identyczne.');

  select pg_catalog.md5(pg_catalog.string_agg(object_type||'|'||table_name||'|'||object_name||'|'||definition,E'\n' order by object_type,table_name,object_name)) into v_schema_hash from (
    select 'column'::text object_type,c.relname table_name,a.attname object_name,pg_catalog.format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull::text||'|'||coalesce(pg_catalog.pg_get_expr(d.adbin,d.adrelid),'<null>') definition from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_attribute a on a.attrelid=c.oid left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and a.attnum>0 and not a.attisdropped
    union all select 'constraint',c.relname,x.conname,pg_catalog.pg_get_constraintdef(x.oid,true) from pg_catalog.pg_constraint x join pg_catalog.pg_class c on c.oid=x.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
    union all select 'index',c.relname,i.indexrelid::pg_catalog.regclass::text,pg_catalog.pg_get_indexdef(i.indexrelid) from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
    union all select 'trigger',c.relname,t.tgname,pg_catalog.pg_get_triggerdef(t.oid,true) from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and not t.tgisinternal
    union all select 'policy',p.tablename,p.policyname,p.permissive||'|'||p.cmd||'|'||p.roles::text||'|'||coalesce(p.qual,'<null>')||'|'||coalesce(p.with_check,'<null>') from pg_catalog.pg_policies p where p.schemaname='public' and p.tablename in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
  ) schema_object;
  perform pg_temp.record_result(30, 'AD. Stare Booking tables i schema bez zmian', v_schema_hash=(select source_schema_hash from pg_temp.booking_configuration_baseline), 'Migracja nie zmienia tabel, constraintów, indeksów, triggerów ani RLS.');
  perform pg_temp.record_result(31, 'AE. Brak własnego booking rule jest fail-closed', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000019' and not effective_online_bookable and not whole_lane_bookable and positions_bookable and max_people_online is null and durations_minutes=array[]::integer[] and pricing='[]'::jsonb) and exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000020' and effective_online_bookable), 'Parent bez własnej reguły jest tylko kontenerem i zwraca jawne false, a nie NULL.');
  perform pg_temp.record_result(32, 'Coverage A. 1-6 jest poprawne', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000021' and effective_online_bookable and max_people_online=6 and pg_catalog.jsonb_array_length(pricing)=2), 'Jeden pełny przedział dla każdej grupy dni jest akceptowany.');
  perform pg_temp.record_result(33, 'Coverage B. 1-2, 3-4, 5-6 jest poprawne', exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000022' and effective_online_bookable and max_people_online=6 and pg_catalog.jsonb_array_length(pricing)=6), 'Trzy dokładnie ciągłe przedziały dla każdej grupy dni są akceptowane.');
  perform pg_temp.record_result(34, 'Coverage C. 1-2, 4-6 ma lukę', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000023'), 'Brak wartości 3 jest odrzucany.');
  perform pg_temp.record_result(36, 'Coverage E. 2-6 nie zaczyna się od 1', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000025'), 'Pierwszy min_shooters musi wynosić 1.');
  perform pg_temp.record_result(37, 'Coverage F. 1-5 nie kończy się na limicie 6', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000026'), 'Ostatni max_shooters musi równać się max_people_online.');
  perform pg_temp.record_result(38, 'Coverage G. 1-7 przekracza limit 6', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id='6b100000-0000-4000-8000-000000000027'), 'Zakres powyżej max_people_online jest odrzucany.');
  perform pg_temp.record_result(39, 'Coverage H. Grupy dni są walidowane osobno', not exists (select 1 from public.get_public_booking_configuration_v1() where lane_id in ('6b100000-0000-4000-8000-000000000028','6b100000-0000-4000-8000-000000000029')), 'Luka tylko w mon_thu albo tylko w fri_sun wyłącza zasób.');
end;
$tests$;

table pg_temp.test_results order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name, ', ' order by test_order
  ) into v_failures
  from pg_temp.test_results
  where not passed;

  if v_failures is not null then
    raise exception 'Public booking configuration tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure('public.get_public_booking_configuration_v1()') is null
  and not exists (
    select 1 from public.shooting_lanes
    where name like '[TEST][6B-1A]%'
  )
  and :'baseline_source_schema_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(object_type||'|'||table_name||'|'||object_name||'|'||definition,E'\n' order by object_type,table_name,object_name)) from (
      select 'column'::text object_type,c.relname table_name,a.attname object_name,pg_catalog.format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull::text||'|'||coalesce(pg_catalog.pg_get_expr(d.adbin,d.adrelid),'<null>') definition from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_attribute a on a.attrelid=c.oid left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and a.attnum>0 and not a.attisdropped
      union all select 'constraint',c.relname,x.conname,pg_catalog.pg_get_constraintdef(x.oid,true) from pg_catalog.pg_constraint x join pg_catalog.pg_class c on c.oid=x.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
      union all select 'index',c.relname,i.indexrelid::pg_catalog.regclass::text,pg_catalog.pg_get_indexdef(i.indexrelid) from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
      union all select 'trigger',c.relname,t.tgname,pg_catalog.pg_get_triggerdef(t.oid,true) from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and not t.tgisinternal
      union all select 'policy',p.tablename,p.policyname,p.permissive||'|'||p.cmd||'|'||p.roles::text||'|'||coalesce(p.qual,'<null>')||'|'||coalesce(p.with_check,'<null>') from pg_catalog.pg_policies p where p.schemaname='public' and p.tablename in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
    ) schema_object
  )
  and :'baseline_source_acl_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(c.relname||'|'||coalesce(r.rolname,'PUBLIC')||'|'||a.privilege_type||'|'||a.is_grantable::text,E'\n' order by c.relname,coalesce(r.rolname,'PUBLIC'),a.privilege_type)) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace cross join lateral pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) a left join pg_catalog.pg_roles r on r.oid=a.grantee where n.nspname='public' and c.relname in ('shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules')
  )
  and :'baseline_source_data_hash' = pg_catalog.md5(
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(r)::text),E'\n' order by r.id),'')) from public.shooting_lanes r)
    || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(r)::text),E'\n' order by r.lane_id),'')) from public.lane_booking_rules r)
    || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(r)::text),E'\n' order by r.id),'')) from public.lane_booking_durations r)
    || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(r)::text),E'\n' order by r.id),'')) from public.lane_pricing_rules r)
  ) as rollback_confirmed;
