\set ON_ERROR_STOP on

-- psql contract test. All migration changes and [TEST][6C-0] fixtures are
-- enclosed in one transaction and removed by the final ROLLBACK.

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::regprocedure
  )) as baseline_v3_definition_md5,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(coalesce(
      function_record.proacl,
      pg_catalog.acldefault('f', function_record.proowner)
    )) as privilege_record
    where function_record.oid =
      'public.get_lane_booking_busy_ranges_v3(uuid,date)'::regprocedure
  ), '')) as baseline_v3_acl_md5,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.resolve_lane_conflict_scope_v1(uuid)'::regprocedure
  )) as baseline_resolver_md5,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure
  )) as baseline_reservation_writer_md5,
  (select pg_catalog.md5(pg_catalog.string_agg(
     pg_catalog.pg_get_functiondef(function_record.oid), E'\n'
     order by function_record.oid::regprocedure::text
   ))
   from pg_catalog.pg_proc as function_record
   join pg_catalog.pg_namespace as namespace_record
     on namespace_record.oid = function_record.pronamespace
   where namespace_record.nspname = 'public'
     and function_record.proname in (
       'lock_lane_conflict_family_v1',
       'lock_lane_conflict_families_v1'
     )) as baseline_family_helpers_md5,
  (select pg_catalog.md5(pg_catalog.string_agg(
     pg_catalog.pg_get_functiondef(function_record.oid), E'\n'
     order by function_record.oid::regprocedure::text
   ))
   from pg_catalog.pg_proc as function_record
   join pg_catalog.pg_namespace as namespace_record
     on namespace_record.oid = function_record.pronamespace
   where namespace_record.nspname = 'public'
     and function_record.proname in (
       'admin_create_lane_block',
       'admin_update_lane_block',
       'admin_set_lane_block_active'
     )) as baseline_lane_block_writers_md5,
  (select pg_catalog.md5(pg_catalog.string_agg(
     pg_catalog.pg_get_functiondef(function_record.oid), E'\n'
     order by function_record.oid::regprocedure::text
   ))
   from pg_catalog.pg_proc as function_record
   join pg_catalog.pg_namespace as namespace_record
     on namespace_record.oid = function_record.pronamespace
   where namespace_record.nspname = 'public'
     and function_record.proname in (
       'admin_create_event_v2',
       'admin_update_event_v2',
       'admin_set_event_active_v2'
     )) as baseline_event_writers_md5,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'::regprocedure
  )) as baseline_config_writer_md5
\gset

begin;

create temporary table test_baseline (
  v3_acl_md5 text not null,
  resolver_md5 text not null,
  reservation_writer_md5 text not null,
  family_helpers_md5 text not null,
  lane_block_writers_md5 text not null,
  event_writers_md5 text not null,
  config_writer_md5 text not null
) on commit drop;

insert into test_baseline values (
  :'baseline_v3_acl_md5',
  :'baseline_resolver_md5',
  :'baseline_reservation_writer_md5',
  :'baseline_family_helpers_md5',
  :'baseline_lane_block_writers_md5',
  :'baseline_event_writers_md5',
  :'baseline_config_writer_md5'
);

\ir ../migrations/20260810123429_harden_lane_booking_busy_ranges_v3.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(
  p_test_order integer,
  p_test_name text,
  p_passed boolean,
  p_result text
)
returns void
language sql
as $function$
  insert into pg_temp.test_results(test_order, test_name, passed, result)
  values (p_test_order, p_test_name, coalesce(p_passed, false), p_result);
$function$;

create function pg_temp.v3_sqlstate(p_lane_id uuid, p_date date)
returns text
language plpgsql
as $function$
begin
  perform pg_catalog.count(*)
  from public.get_lane_booking_busy_ranges_v3(p_lane_id, p_date);
  return null;
exception when others then
  return sqlstate;
end;
$function$;

create function pg_temp.insert_test_reservation(
  p_id uuid,
  p_lane_id uuid,
  p_date date,
  p_start time without time zone,
  p_end time without time zone,
  p_status text
)
returns void
language sql
as $function$
  insert into public.reservations (
    id, user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes, price,
    reservation_status, payment_status, attendance_status, check_in_token,
    reservation_note, shooters_count, pricing_rule_id,
    pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
    price_per_hour_snapshot, total_price, currency_code, creation_request_id
  ) values (
    p_id,
    '6c000000-0000-4000-8000-000000000001',
    p_lane_id,
    '[TEST][6C-0]',
    'test-6c0@example.invalid',
    '000000000',
    p_date,
    p_start,
    p_end,
    (extract(epoch from (p_end - p_start)) / 60)::integer,
    10,
    p_status,
    'pay_on_site',
    'planned',
    pg_catalog.gen_random_uuid(),
    '[TEST][6C-0]',
    1,
    '6c000000-0000-4000-8000-000000000301',
    'mon_thu',
    '[TEST][6C-0]',
    '[TEST][6C-0]',
    10,
    10,
    'PLN',
    pg_catalog.gen_random_uuid()
  );
$function$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '6c000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'test-6c0@example.invalid', '',
  '{}'::jsonb, '{}'::jsonb,
  pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
);

insert into public.profiles (
  user_id, role, first_name, last_name, full_name, email, phone,
  verification_status, permissions_verified
) values (
  '6c000000-0000-4000-8000-000000000001',
  'user', '[TEST]', '6C-0', '[TEST][6C-0]',
  'test-6c0@example.invalid', '000000000', 'verified', true
)
on conflict (user_id) do update set
  role = excluded.role,
  first_name = excluded.first_name,
  last_name = excluded.last_name,
  full_name = excluded.full_name,
  email = excluded.email,
  phone = excluded.phone,
  verification_status = excluded.verification_status,
  permissions_verified = excluded.permissions_verified;

insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values
  ('6c000000-0000-4000-8000-000000000101', '[TEST][6C-0][STANDALONE]', '[TEST]', '[TEST]', 10, true, 10, 60, 9601, 'PLN', 'lane', null, true, false),
  ('6c000000-0000-4000-8000-000000000102', '[TEST][6C-0][PARENT]', '[TEST]', '[TEST]', 10, true, 10, 60, 9602, 'PLN', 'lane', null, true, true),
  ('6c000000-0000-4000-8000-000000000103', '[TEST][6C-0][INACTIVE-PARENT]', '[TEST]', '[TEST]', 10, false, 10, 60, 9603, 'PLN', 'lane', null, true, true),
  ('6c000000-0000-4000-8000-000000000201', '[TEST][6C-0][CHILD-1]', '[TEST]', '[TEST]', 10, true, 1, 60, 9611, 'PLN', 'position', '6c000000-0000-4000-8000-000000000102', false, false),
  ('6c000000-0000-4000-8000-000000000202', '[TEST][6C-0][CHILD-2]', '[TEST]', '[TEST]', 10, true, 1, 60, 9612, 'PLN', 'position', '6c000000-0000-4000-8000-000000000102', false, false),
  ('6c000000-0000-4000-8000-000000000203', '[TEST][6C-0][INACTIVE-CHILD]', '[TEST]', '[TEST]', 10, false, 1, 60, 9613, 'PLN', 'position', '6c000000-0000-4000-8000-000000000102', false, false),
  ('6c000000-0000-4000-8000-000000000204', '[TEST][6C-0][CHILD-INACTIVE-PARENT]', '[TEST]', '[TEST]', 10, true, 1, 60, 9614, 'PLN', 'position', '6c000000-0000-4000-8000-000000000103', false, false);

insert into public.lane_pricing_rules (
  id, lane_id, day_group, min_shooters, max_shooters,
  label, hourly_price, display_order, is_active
) values (
  '6c000000-0000-4000-8000-000000000301',
  '6c000000-0000-4000-8000-000000000101',
  'mon_thu', 1, 10, '[TEST][6C-0]', 10, 1, true
);

do $fixtures$
declare
  v_base_date date := current_date + 6100;
begin
  perform pg_temp.insert_test_reservation(
    '6c000000-0000-4000-8000-000000000401',
    '6c000000-0000-4000-8000-000000000101',
    v_base_date + 1, time '09:00', time '10:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6c000000-0000-4000-8000-000000000402',
    '6c000000-0000-4000-8000-000000000101',
    v_base_date + 1, time '10:00', time '11:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6c000000-0000-4000-8000-000000000403',
    '6c000000-0000-4000-8000-000000000101',
    v_base_date + 1, time '12:00', time '13:00', 'cancelled'
  );
  perform pg_temp.insert_test_reservation(
    '6c000000-0000-4000-8000-000000000404',
    '6c000000-0000-4000-8000-000000000201',
    v_base_date + 5, time '10:00', time '12:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6c000000-0000-4000-8000-000000000405',
    '6c000000-0000-4000-8000-000000000201',
    v_base_date + 6, time '10:00', time '12:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6c000000-0000-4000-8000-000000000406',
    '6c000000-0000-4000-8000-000000000202',
    v_base_date + 7, time '10:00', time '12:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6c000000-0000-4000-8000-000000000407',
    '6c000000-0000-4000-8000-000000000203',
    v_base_date + 8, time '10:00', time '12:00', 'confirmed'
  );

  insert into public.lane_blocks (
    lane_id, block_date, start_time, end_time, reason, is_active
  ) values
    ('6c000000-0000-4000-8000-000000000101', v_base_date + 2, time '11:00', time '12:00', '[TEST][6C-0][BLOCK]', true),
    ('6c000000-0000-4000-8000-000000000101', v_base_date + 2, time '13:00', time '14:00', '[TEST][6C-0][INACTIVE-BLOCK]', false),
    ('6c000000-0000-4000-8000-000000000102', v_base_date + 6, time '11:00', time '13:00', '[TEST][6C-0][PARENT-BLOCK]', true),
    ('6c000000-0000-4000-8000-000000000103', v_base_date + 8, time '09:00', time '10:00', '[TEST][6C-0][INACTIVE-PARENT-BLOCK]', true);

  insert into public.events (
    id, title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values
    ('6c000000-0000-4000-8000-000000000501', '[TEST][6C-0][EVENT]', v_base_date + 3, time '14:00', time '15:00', 0, 5, true),
    ('6c000000-0000-4000-8000-000000000502', '[TEST][6C-0][GLOBAL]', v_base_date + 3, time '15:00', time '16:00', 0, 5, true),
    ('6c000000-0000-4000-8000-000000000503', '[TEST][6C-0][INACTIVE]', v_base_date + 3, time '16:00', time '17:00', 0, 5, false),
    ('6c000000-0000-4000-8000-000000000504', '[TEST][6C-0][MULTI-LANE]', v_base_date + 5, time '13:00', time '14:00', 0, 5, true);

  insert into public.event_lanes(event_id, lane_id) values
    ('6c000000-0000-4000-8000-000000000501', '6c000000-0000-4000-8000-000000000101'),
    ('6c000000-0000-4000-8000-000000000503', '6c000000-0000-4000-8000-000000000101'),
    ('6c000000-0000-4000-8000-000000000504', '6c000000-0000-4000-8000-000000000102'),
    ('6c000000-0000-4000-8000-000000000504', '6c000000-0000-4000-8000-000000000201');
end;
$fixtures$;

alter table public.shooting_lanes
  disable trigger validate_shooting_lane_hierarchy_trigger;
alter table public.shooting_lanes
  drop constraint shooting_lanes_resource_parent_check;

insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values (
  '6c000000-0000-4000-8000-000000000205',
  '[TEST][6C-0][MALFORMED]', '[TEST]', '[TEST]', 10, true,
  1, 60, 9615, 'PLN', 'position', null, false, false
);

do $contract_tests$
declare
  v_base_date date := current_date + 6100;
  v_v3 regprocedure :=
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::regprocedure;
  v_scope uuid[];
begin
  perform pg_temp.record_result(1, 'A. Active standalone zero busy',
    (select pg_catalog.count(*) = 0
     from public.get_lane_booking_busy_ranges_v3(
       '6c000000-0000-4000-8000-000000000101', v_base_date
     )),
    'Poprawny aktywny standalone bez commitments zwraca pusty sukces.');

  perform pg_temp.record_result(2, 'B. Standalone reservation ranges',
    (select pg_catalog.count(*) = 2
       and pg_catalog.min(start_time) = time '09:00'
       and pg_catalog.max(end_time) = time '11:00'
       and pg_catalog.bool_and(busy_type = 'reservation')
     from public.get_lane_booking_busy_ranges_v3(
       '6c000000-0000-4000-8000-000000000101', v_base_date + 1
     )),
    'Dwa touching reservation ranges pozostają raw i cancelled jest pominięty.');

  perform pg_temp.record_result(3, 'C. Standalone block ranges',
    (select pg_catalog.count(*) = 1
       and pg_catalog.min(start_time) = time '11:00'
       and pg_catalog.max(end_time) = time '12:00'
       and pg_catalog.bool_and(busy_type = 'lane_block')
     from public.get_lane_booking_busy_ranges_v3(
       '6c000000-0000-4000-8000-000000000101', v_base_date + 2
     )),
    'Tylko aktywny lane block jest zwracany.');

  perform pg_temp.record_result(4, 'D. Standalone event ranges',
    (select pg_catalog.count(*) = 1
       and pg_catalog.min(start_time) = time '14:00'
       and pg_catalog.max(end_time) = time '15:00'
       and pg_catalog.bool_and(busy_type = 'event')
     from public.get_lane_booking_busy_ranges_v3(
       '6c000000-0000-4000-8000-000000000101', v_base_date + 3
     )),
    'Global i inactive event są pominięte.');

  perform pg_temp.record_result(5, 'E. Active parent zero busy',
    (select pg_catalog.count(*) = 0
     from public.get_lane_booking_busy_ranges_v3(
       '6c000000-0000-4000-8000-000000000102', v_base_date + 4
     )),
    'Poprawny aktywny parent bez commitments zwraca pusty sukces.');

  select pg_catalog.array_agg(conflict_lane_id order by conflict_lane_id)
  into v_scope
  from public.resolve_lane_conflict_scope_v1(
    '6c000000-0000-4000-8000-000000000102'
  );
  perform pg_temp.record_result(6, 'F. Active parent family scope',
    v_scope = array[
      '6c000000-0000-4000-8000-000000000102'::uuid,
      '6c000000-0000-4000-8000-000000000201'::uuid,
      '6c000000-0000-4000-8000-000000000202'::uuid,
      '6c000000-0000-4000-8000-000000000203'::uuid
    ]
    and (select pg_catalog.count(*) = 2
         from public.get_lane_booking_busy_ranges_v3(
           '6c000000-0000-4000-8000-000000000102', v_base_date + 5
         )),
    'Parent obejmuje siebie i direct children; multi-lane event jest deduplikowany.');

  perform pg_temp.record_result(7, 'G. Active child zero busy',
    (select pg_catalog.count(*) = 0
     from public.get_lane_booking_busy_ranges_v3(
       '6c000000-0000-4000-8000-000000000201', v_base_date + 4
     )),
    'Poprawny aktywny child bez commitments zwraca pusty sukces.');

  select pg_catalog.array_agg(conflict_lane_id order by conflict_lane_id)
  into v_scope
  from public.resolve_lane_conflict_scope_v1(
    '6c000000-0000-4000-8000-000000000201'
  );
  perform pg_temp.record_result(8, 'H. Active child parent plus requested scope',
    v_scope = array[
      '6c000000-0000-4000-8000-000000000102'::uuid,
      '6c000000-0000-4000-8000-000000000201'::uuid
    ]
    and (select pg_catalog.count(*) = 2
         from public.get_lane_booking_busy_ranges_v3(
           '6c000000-0000-4000-8000-000000000201', v_base_date + 6
         )),
    'Child obejmuje requested child i parent; overlapping sources pozostają raw.');

  perform pg_temp.record_result(9, 'I. Child scope excludes sibling',
    (select pg_catalog.count(*) = 0
     from public.get_lane_booking_busy_ranges_v3(
       '6c000000-0000-4000-8000-000000000201', v_base_date + 7
     )),
    'Commitment siblinga nie jest zwracany dla requested child.');

  perform pg_temp.record_result(10, 'J. Inactive requested parent fails closed',
    pg_temp.v3_sqlstate(
      '6c000000-0000-4000-8000-000000000103', v_base_date + 8
    ) = '55000',
    'Inactive parent zwraca 55000 także przy istniejącym blocku.');

  perform pg_temp.record_result(11, 'K. Inactive requested child fails closed',
    pg_temp.v3_sqlstate(
      '6c000000-0000-4000-8000-000000000203', v_base_date
    ) = '55000'
    and pg_temp.v3_sqlstate(
      '6c000000-0000-4000-8000-000000000203', v_base_date + 8
    ) = '55000',
    'Inactive child zwraca 55000 przy empty i non-empty busy sources.');

  perform pg_temp.record_result(12, 'L. Active child inactive parent fails closed',
    pg_temp.v3_sqlstate(
      '6c000000-0000-4000-8000-000000000204', v_base_date
    ) = '55000',
    'Active child z inactive parentem zwraca 55000.');

  perform pg_temp.record_result(13, 'M. Missing requested resource fails closed',
    pg_temp.v3_sqlstate(
      '6c000000-0000-4000-8000-000000000999', v_base_date
    ) = 'P0002',
    'Brak requested resource zachowuje resolver SQLSTATE P0002.');

  perform pg_temp.record_result(14, 'N. Malformed hierarchy fails closed',
    pg_temp.v3_sqlstate(
      '6c000000-0000-4000-8000-000000000205', v_base_date
    ) = '55000',
    'Malformed position bez parenta zwraca 55000.');

  perform pg_temp.record_result(15, 'O. V3 signature unchanged',
    (select pg_catalog.count(*) = 1
     from pg_catalog.pg_proc as function_record
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = function_record.pronamespace
     where namespace_record.nspname = 'public'
       and function_record.proname = 'get_lane_booking_busy_ranges_v3')
    and pg_catalog.pg_get_function_identity_arguments(v_v3)
      = 'p_lane_id uuid, p_reservation_date date'
    and pg_catalog.pg_get_function_result(v_v3)
      = 'TABLE(start_time time without time zone, end_time time without time zone, busy_type text)',
    'Sygnatura i RETURNS TABLE są identyczne.');

  perform pg_temp.record_result(16, 'P. V3 owner unchanged',
    (select pg_catalog.pg_get_userbyid(proowner) = 'postgres'
     from pg_catalog.pg_proc where oid = v_v3),
    'Owner pozostaje postgres.');

  perform pg_temp.record_result(17, 'Q. V3 SECURITY DEFINER unchanged',
    (select prosecdef from pg_catalog.pg_proc where oid = v_v3),
    'SECURITY DEFINER pozostaje true.');

  perform pg_temp.record_result(18, 'R. V3 volatility unchanged',
    (select provolatile = 's' from pg_catalog.pg_proc where oid = v_v3),
    'V3 pozostaje STABLE.');

  perform pg_temp.record_result(19, 'S. V3 search_path unchanged',
    (select proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
     from pg_catalog.pg_proc where oid = v_v3),
    'search_path pozostaje pg_catalog, public, pg_temp.');

  perform pg_temp.record_result(20, 'T. V3 ACL unchanged',
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       privilege_record.grantee::text || ':' || privilege_record.privilege_type,
       ',' order by privilege_record.grantee, privilege_record.privilege_type
     ), ''))
     from pg_catalog.pg_proc as function_record
     cross join lateral pg_catalog.aclexplode(coalesce(
       function_record.proacl,
       pg_catalog.acldefault('f', function_record.proowner)
     )) as privilege_record
     where function_record.oid = v_v3)
       = (select v3_acl_md5 from test_baseline),
    'Model EXECUTE pozostaje identyczny.');

  perform pg_temp.record_result(21, 'U. Resolver unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      'public.resolve_lane_conflict_scope_v1(uuid)'::regprocedure
    )) = (select resolver_md5 from test_baseline),
    'Resolver pozostaje source of truth bez zmian.');

  perform pg_temp.record_result(22, 'V. create_reservation_v2 unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure
    )) = (select reservation_writer_md5 from test_baseline),
    'Writer rezerwacji pozostaje identyczny.');

  perform pg_temp.record_result(23, 'W. Family helpers unchanged',
    (select pg_catalog.md5(pg_catalog.string_agg(
       pg_catalog.pg_get_functiondef(function_record.oid), E'\n'
       order by function_record.oid::regprocedure::text
     ))
     from pg_catalog.pg_proc as function_record
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = function_record.pronamespace
     where namespace_record.nspname = 'public'
       and function_record.proname in (
         'lock_lane_conflict_family_v1',
         'lock_lane_conflict_families_v1'
       )) = (select family_helpers_md5 from test_baseline),
    'Single i multi-family lock helpers pozostają identyczne.');

  perform pg_temp.record_result(24, 'X. Lane-block RPC unchanged',
    (select pg_catalog.md5(pg_catalog.string_agg(
       pg_catalog.pg_get_functiondef(function_record.oid), E'\n'
       order by function_record.oid::regprocedure::text
     ))
     from pg_catalog.pg_proc as function_record
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = function_record.pronamespace
     where namespace_record.nspname = 'public'
       and function_record.proname in (
         'admin_create_lane_block',
         'admin_update_lane_block',
         'admin_set_lane_block_active'
       )) = (select lane_block_writers_md5 from test_baseline),
    'Trzy lane-block RPC pozostają identyczne.');

  perform pg_temp.record_result(25, 'Y. Event V2 RPC unchanged',
    (select pg_catalog.md5(pg_catalog.string_agg(
       pg_catalog.pg_get_functiondef(function_record.oid), E'\n'
       order by function_record.oid::regprocedure::text
     ))
     from pg_catalog.pg_proc as function_record
     join pg_catalog.pg_namespace as namespace_record
       on namespace_record.oid = function_record.pronamespace
     where namespace_record.nspname = 'public'
       and function_record.proname in (
         'admin_create_event_v2',
         'admin_update_event_v2',
         'admin_set_event_active_v2'
       )) = (select event_writers_md5 from test_baseline),
    'Trzy Event V2 RPC pozostają identyczne.');

  perform pg_temp.record_result(26, 'Z. Config RPC unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'::regprocedure
    )) = (select config_writer_md5 from test_baseline),
    'Atomic config writer pozostaje identyczny.');
end;
$contract_tests$;

select test_order, test_name, passed, result
from test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  if (select pg_catalog.count(*) from test_results) <> 26 then
    raise exception 'Availability V3 hardening test expected exactly 26 controls.';
  end if;

  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  ) into v_failures
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Availability V3 hardening tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::regprocedure
  )) = :'baseline_v3_definition_md5' as rollback_v3_restored,
  not exists (
    select 1 from public.shooting_lanes
    where name like '[TEST][6C-0]%'
  ) as rollback_lanes_removed,
  not exists (
    select 1 from public.reservations
    where reservation_note = '[TEST][6C-0]'
  ) as rollback_reservations_removed,
  not exists (
    select 1 from auth.users
    where id = '6c000000-0000-4000-8000-000000000001'
  ) as rollback_auth_user_removed,
  not exists (
    select 1 from public.profiles
    where user_id = '6c000000-0000-4000-8000-000000000001'
  ) as rollback_profile_removed
\gset

\if :rollback_v3_restored
\else
  \echo 'Availability V3 hardening rollback failed: V3 definition differs.'
  \quit 1
\endif
\if :rollback_lanes_removed
\else
  \echo 'Availability V3 hardening rollback failed: lanes remain.'
  \quit 1
\endif
\if :rollback_reservations_removed
\else
  \echo 'Availability V3 hardening rollback failed: reservations remain.'
  \quit 1
\endif
\if :rollback_auth_user_removed
\else
  \echo 'Availability V3 hardening rollback failed: auth user remains.'
  \quit 1
\endif
\if :rollback_profile_removed
\else
  \echo 'Availability V3 hardening rollback failed: profile remains.'
  \quit 1
\endif

select
  27 as test_order,
  'ROLLBACK przywrócił baseline' as test_name,
  true as passed,
  'V3 i wszystkie fixture wróciły do stanu sprzed testu.' as result;
