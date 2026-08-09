\set ON_ERROR_STOP on

-- Run only with psql against the linked project. The migration, synthetic
-- [TEST][6B-2B] fixtures and malformed-hierarchy checks are enclosed in this
-- transaction and are removed by the final ROLLBACK.
begin;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
  )) as baseline_v2_definition_md5,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid =
      'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
  ), '')) as baseline_v2_acl_md5,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      class_record.relname || ':' || privilege_record.grantee::text || ':' ||
        privilege_record.privilege_type,
      ',' order by class_record.relname, privilege_record.grantee,
        privilege_record.privilege_type
    )
    from pg_catalog.pg_class as class_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = class_record.relnamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(class_record.relacl, pg_catalog.acldefault('r', class_record.relowner))
    ) as privilege_record
    where namespace_record.nspname = 'public'
      and class_record.relname = any(array[
        'shooting_lanes','reservations','lane_blocks','events','event_lanes'
      ]::text[])
  ), '')) as baseline_source_acl_md5
\gset

create temporary table csk_6b2b_test_baseline (
  v2_definition_md5 text not null,
  v2_acl_md5 text not null,
  source_acl_md5 text not null
) on commit drop;

insert into pg_temp.csk_6b2b_test_baseline values (
  :'baseline_v2_definition_md5',
  :'baseline_v2_acl_md5',
  :'baseline_source_acl_md5'
);

do $clean_preflight$
begin
  if pg_catalog.to_regprocedure(
       'public.resolve_lane_conflict_scope_v1(uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       'public.get_lane_booking_busy_ranges_v3(uuid,date)'
     ) is not null
     or exists (
       select 1 from public.shooting_lanes
       where name like '[TEST][6B-2B]%'
     )
     or exists (
       select 1 from public.events
       where title like '[TEST][6B-2B]%'
     )
     or exists (
       select 1 from public.lane_blocks
       where reason like '[TEST][6B-2B]%'
     )
     or exists (
       select 1 from public.reservations
       where reservation_note = '[TEST][6B-2B]'
     )
     or exists (
       select 1 from auth.users
       where email = 'test-6b2b@example.invalid'
     ) then
    raise exception 'Unexpected prior 6B-2B objects or fixture.';
  end if;
end;
$clean_preflight$;

\ir ../migrations/20260809000216_add_lane_booking_busy_ranges_v3.sql

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
    '6b2b0000-0000-4000-8000-000000000001',
    p_lane_id,
    '[TEST][6B-2B]',
    'test-6b2b@example.invalid',
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
    '[TEST][6B-2B]',
    1,
    '6b2b0000-0000-4000-8000-000000000301',
    'mon_thu',
    '[TEST][6B-2B]',
    '[TEST][6B-2B]',
    10,
    10,
    'PLN',
    pg_catalog.gen_random_uuid()
  );
$function$;

create function pg_temp.resolver_sqlstate(p_lane_id uuid)
returns text
language plpgsql
as $function$
begin
  perform 1
  from public.resolve_lane_conflict_scope_v1(p_lane_id);
  return null;
exception when others then
  return sqlstate;
end;
$function$;

create function pg_temp.v3_date_sqlstate(p_lane_id uuid, p_date date)
returns text
language plpgsql
as $function$
begin
  perform 1
  from public.get_lane_booking_busy_ranges_v3(p_lane_id, p_date);
  return null;
exception when others then
  return sqlstate;
end;
$function$;

create function pg_temp.authenticated_v3_count(p_lane_id uuid, p_date date)
returns bigint
language plpgsql
as $function$
declare
  v_count bigint;
begin
  execute 'set local role authenticated';
  select pg_catalog.count(*)
  into v_count
  from public.get_lane_booking_busy_ranges_v3(p_lane_id, p_date);
  execute 'reset role';
  return v_count;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.authenticated_resolver_blocked(p_lane_id uuid)
returns boolean
language plpgsql
as $function$
declare
  v_blocked boolean := false;
begin
  execute 'set local role authenticated';
  begin
    perform 1 from public.resolve_lane_conflict_scope_v1(p_lane_id);
  exception when insufficient_privilege then
    v_blocked := true;
  end;
  execute 'reset role';
  return v_blocked;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

do $fixtures$
declare
  v_base_date date := current_date + 6000;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values (
    '6b2b0000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'test-6b2b@example.invalid',
    '',
    pg_catalog.transaction_timestamp(),
    '{}'::jsonb,
    '{}'::jsonb,
    pg_catalog.transaction_timestamp(),
    pg_catalog.transaction_timestamp()
  );

  update public.profiles
  set role = 'user',
      first_name = '[TEST]',
      last_name = '6B-2B',
      full_name = '[TEST][6B-2B]',
      email = 'test-6b2b@example.invalid',
      phone = '000000000',
      verification_status = 'verified'
  where user_id = '6b2b0000-0000-4000-8000-000000000001';

  if not found then
    raise exception 'Synthetic profile was not created.';
  end if;

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values
    ('6b2b0000-0000-4000-8000-000000000101', '[TEST][6B-2B][STANDALONE]', '[TEST]', '[TEST]', 10, true, 10, 60, 9801, 'PLN', 'lane', null, true, false),
    ('6b2b0000-0000-4000-8000-000000000102', '[TEST][6B-2B][PARENT]', '[TEST]', '[TEST]', 10, true, 10, 60, 9802, 'PLN', 'lane', null, true, true),
    ('6b2b0000-0000-4000-8000-000000000103', '[TEST][6B-2B][PARENT-INACTIVE]', '[TEST]', '[TEST]', 10, false, 10, 60, 9803, 'PLN', 'lane', null, true, true),
    ('6b2b0000-0000-4000-8000-000000000201', '[TEST][6B-2B][CHILD-1]', '[TEST]', '[TEST]', 10, true, 1, 60, 9811, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000102', false, false),
    ('6b2b0000-0000-4000-8000-000000000202', '[TEST][6B-2B][CHILD-2]', '[TEST]', '[TEST]', 10, true, 1, 60, 9812, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000102', false, false),
    ('6b2b0000-0000-4000-8000-000000000203', '[TEST][6B-2B][CHILD-INACTIVE]', '[TEST]', '[TEST]', 10, false, 1, 60, 9813, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000102', false, false),
    ('6b2b0000-0000-4000-8000-000000000204', '[TEST][6B-2B][CHILD-INACTIVE-PARENT]', '[TEST]', '[TEST]', 10, true, 1, 60, 9814, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000103', false, false);

  insert into public.lane_pricing_rules (
    id, lane_id, day_group, min_shooters, max_shooters,
    label, hourly_price, display_order, is_active
  ) values (
    '6b2b0000-0000-4000-8000-000000000301',
    '6b2b0000-0000-4000-8000-000000000101',
    'mon_thu', 1, 10, '[TEST][6B-2B]', 10, 1, true
  );

  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000401',
    '6b2b0000-0000-4000-8000-000000000101',
    v_base_date, time '09:00', time '10:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000402',
    '6b2b0000-0000-4000-8000-000000000102',
    v_base_date + 1, time '10:00', time '12:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000403',
    '6b2b0000-0000-4000-8000-000000000201',
    v_base_date + 2, time '10:00', time '12:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000404',
    '6b2b0000-0000-4000-8000-000000000203',
    v_base_date + 3, time '10:00', time '12:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000405',
    '6b2b0000-0000-4000-8000-000000000201',
    v_base_date + 4, time '08:00', time '09:00', 'cancelled'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000406',
    '6b2b0000-0000-4000-8000-000000000201',
    v_base_date + 4, time '09:00', time '10:00', 'completed'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000407',
    '6b2b0000-0000-4000-8000-000000000201',
    v_base_date + 4, time '10:00', time '11:00', 'no_show'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000408',
    '6b2b0000-0000-4000-8000-000000000102',
    v_base_date + 5, time '10:00', time '12:00', 'confirmed'
  );
  perform pg_temp.insert_test_reservation(
    '6b2b0000-0000-4000-8000-000000000409',
    '6b2b0000-0000-4000-8000-000000000101',
    v_base_date + 12, time '09:00', time '10:00', 'confirmed'
  );

  insert into public.lane_blocks (
    lane_id, block_date, start_time, end_time, reason, is_active
  ) values
    ('6b2b0000-0000-4000-8000-000000000102', v_base_date + 6, time '10:00', time '12:00', '[TEST][6B-2B][PARENT-BLOCK]', true),
    ('6b2b0000-0000-4000-8000-000000000201', v_base_date + 7, time '10:00', time '12:00', '[TEST][6B-2B][CHILD-BLOCK]', true),
    ('6b2b0000-0000-4000-8000-000000000202', v_base_date + 5, time '09:00', time '11:00', '[TEST][6B-2B][MULTI-SOURCE]', true),
    ('6b2b0000-0000-4000-8000-000000000101', v_base_date + 12, time '10:00', time '11:00', '[TEST][6B-2B][TOUCHING]', true);

  insert into public.events (
    id, title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values
    ('6b2b0000-0000-4000-8000-000000000501', '[TEST][6B-2B][PARENT-EVENT]', v_base_date + 8, time '10:00', time '12:00', 0, 5, true),
    ('6b2b0000-0000-4000-8000-000000000502', '[TEST][6B-2B][CHILD-EVENT]', v_base_date + 9, time '10:00', time '12:00', 0, 5, true),
    ('6b2b0000-0000-4000-8000-000000000503', '[TEST][6B-2B][GLOBAL-EVENT]', v_base_date + 10, time '10:00', time '12:00', 0, 5, true),
    ('6b2b0000-0000-4000-8000-000000000504', '[TEST][6B-2B][MULTI-LANE-EVENT]', v_base_date + 11, time '10:00', time '12:00', 0, 5, true),
    ('6b2b0000-0000-4000-8000-000000000505', '[TEST][6B-2B][OVERLAP-EVENT]', v_base_date + 5, time '11:00', time '13:00', 0, 5, true);

  insert into public.event_lanes(event_id, lane_id) values
    ('6b2b0000-0000-4000-8000-000000000501', '6b2b0000-0000-4000-8000-000000000102'),
    ('6b2b0000-0000-4000-8000-000000000502', '6b2b0000-0000-4000-8000-000000000201'),
    ('6b2b0000-0000-4000-8000-000000000504', '6b2b0000-0000-4000-8000-000000000102'),
    ('6b2b0000-0000-4000-8000-000000000504', '6b2b0000-0000-4000-8000-000000000201'),
    ('6b2b0000-0000-4000-8000-000000000505', '6b2b0000-0000-4000-8000-000000000201');
end;
$fixtures$;

do $contract_tests$
declare
  v_base_date date := current_date + 6000;
  v_v2 oid := 'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure;
  v_v3 oid := 'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure;
  v_resolver oid := 'public.resolve_lane_conflict_scope_v1(uuid)'::pg_catalog.regprocedure;
  v_v3_definition text := pg_catalog.lower(pg_catalog.pg_get_functiondef(v_v3));
  v_resolver_definition text := pg_catalog.lower(pg_catalog.pg_get_functiondef(v_resolver));
begin
  perform pg_temp.record_result(1, 'A. Standalone lane v2 equals v3',
    not exists (
      (select * from public.get_lane_booking_busy_ranges_v2('6b2b0000-0000-4000-8000-000000000101', v_base_date)
       except all
       select * from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000101', v_base_date))
      union all
      (select * from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000101', v_base_date)
       except all
       select * from public.get_lane_booking_busy_ranges_v2('6b2b0000-0000-4000-8000-000000000101', v_base_date))
    ), 'Posortowane multizbiory v2 i v3 musza byc identyczne.');

  perform pg_temp.record_result(2, 'B. Parent reservation blocks child',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000201', v_base_date + 1)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='reservation'),
    'Child musi widziec rezerwacje parenta.');

  perform pg_temp.record_result(3, 'C. Child reservation blocks parent',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 2)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='reservation'),
    'Parent musi widziec rezerwacje childa.');

  perform pg_temp.record_result(4, 'D. Child reservation does not block sibling',
    not exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000202', v_base_date + 2)
      where busy_type='reservation'), 'Child scope nie moze obejmowac siblinga.');

  perform pg_temp.record_result(5, 'E. Parent lane block blocks child',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000201', v_base_date + 6)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='lane_block'),
    'Child musi widziec blokade parenta.');

  perform pg_temp.record_result(6, 'F. Child lane block blocks parent',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 7)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='lane_block'),
    'Parent musi widziec blokade childa.');

  perform pg_temp.record_result(7, 'G. Child lane block does not block sibling',
    not exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000202', v_base_date + 7)
      where busy_type='lane_block'), 'Sibling nie nalezy do child scope.');

  perform pg_temp.record_result(8, 'H. Parent event blocks child',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000201', v_base_date + 8)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='event'),
    'Child musi widziec event parenta.');

  perform pg_temp.record_result(9, 'I. Child event blocks parent',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 9)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='event'),
    'Parent musi widziec event childa.');

  perform pg_temp.record_result(10, 'J. Child event does not block sibling',
    not exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000202', v_base_date + 9)
      where busy_type='event'), 'Sibling nie nalezy do child scope.');

  perform pg_temp.record_result(11, 'K. Global event is ignored',
    not exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 10)
      where busy_type='event'), 'Event bez event_lanes nie blokuje availability.');

  perform pg_temp.record_result(12, 'L. Inactive requested parent fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000103')='55000',
    'Inactive requested parent musi zwrocic kontrolowany blad.');

  perform pg_temp.record_result(13, 'M. Inactive requested child fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000203')='55000',
    'Inactive requested child musi zwrocic kontrolowany blad.');

  perform pg_temp.record_result(14, 'N. Child of inactive parent fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000204')='55000',
    'Inactive parent musi wylaczyc requested child.');

  perform pg_temp.record_result(15, 'O. Inactive child commitment blocks parent',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 3)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='reservation'),
    'Parent scope musi zawierac takze inactive direct children.');

  perform pg_temp.record_result(16, 'P. Cancelled reservation is ignored',
    not exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 4)
      where start_time=time '08:00' and busy_type='reservation'), 'Cancelled nie blokuje.');

  perform pg_temp.record_result(17, 'Q. Completed reservation is ignored',
    not exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 4)
      where start_time=time '09:00' and busy_type='reservation'), 'Completed nie blokuje.');

  perform pg_temp.record_result(18, 'R. No-show reservation is ignored',
    not exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 4)
      where start_time=time '10:00' and busy_type='reservation'), 'No_show nie blokuje.');

  perform pg_temp.record_result(19, 'S. Touching boundaries remain separate',
    (select pg_catalog.count(*)=2 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000101', v_base_date + 12)
      where (start_time,end_time,busy_type) in (
        (time '09:00',time '10:00','reservation'),
        (time '10:00',time '11:00','lane_block')
      )), 'Zakresy [start,end) stykajace sie o 10:00 pozostaja osobne.');

  perform pg_temp.record_result(20, 'T. Overlap returns every raw range',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 5)
      where start_time=time '10:00' and end_time=time '12:00' and busy_type='reservation')
    and exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 5)
      where start_time=time '11:00' and end_time=time '13:00' and busy_type='event'),
    'Nachodzace reservation i event musza pozostac surowymi zakresami.');

  perform pg_temp.record_result(21, 'U. Multi-source ranges are not merged',
    (select pg_catalog.count(*)=3 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 5)),
    'Oczekiwano reservation, lane_block i event jako trzech wierszy.');

  perform pg_temp.record_result(22, 'V. Lane-block busy type is retained',
    exists (select 1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 5)
      where start_time=time '09:00' and end_time=time '11:00' and busy_type='lane_block'),
    'Blokada zachowuje osobny busy_type.');

  perform pg_temp.record_result(23, 'W. Multi-lane event is returned once',
    (select pg_catalog.count(*)=1 from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 11)
      where busy_type='event'), 'EXISTS nie moze zwielokrotnic eventu parent+child.');

  perform pg_temp.record_result(24, 'AA. Missing resource fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000009999')='P0002',
    'Nieistniejacy resource musi zwrocic P0002.');

  perform pg_temp.record_result(25, 'AB. Exact v3 return columns',
    pg_catalog.pg_get_function_result(v_v3)=
      'TABLE(start_time time without time zone, end_time time without time zone, busy_type text)'
    and (select pg_catalog.array_agg(distinct key order by key)=array['busy_type','end_time','start_time']::text[]
      from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 5) as row_record
      cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(row_record)) as key),
    'Publiczny shape ma dokladnie trzy techniczne kolumny.');

  perform pg_temp.record_result(26, 'AC. No PII or internal IDs',
    v_v3_definition !~ 'customer_|email|phone|full_name|reservation_id|event_id[[:space:]]+uuid|source_lane|parent_id'
    and not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v3('6b2b0000-0000-4000-8000-000000000102', v_base_date + 5) as row_record
      cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(row_record)) as key
      where key not in ('start_time','end_time','busy_type')
    ), 'Definicja i wynik nie ujawniaja PII ani identyfikatorow zrodel.');

  perform pg_temp.record_result(27, 'AD. V3 ACL is minimal',
    pg_catalog.has_function_privilege('authenticated',v_v3,'EXECUTE')
    and pg_catalog.has_function_privilege('service_role',v_v3,'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',v_v3,'EXECUTE')
    and not exists (select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
      where p.oid=v_v3 and a.grantee=0 and a.privilege_type='EXECUTE'),
    'V3: authenticated/service_role tak; anon/PUBLIC nie.');

  perform pg_temp.record_result(28, 'AE. Resolver has no client EXECUTE',
    not pg_catalog.has_function_privilege('authenticated',v_resolver,'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role',v_resolver,'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',v_resolver,'EXECUTE')
    and pg_temp.authenticated_resolver_blocked('6b2b0000-0000-4000-8000-000000000101'),
    'Resolver jest prywatny dla RPC/writerow SECURITY DEFINER.');

  perform pg_temp.record_result(29, 'AF. Security modes and nested invocation',
    (select not p.prosecdef from pg_catalog.pg_proc p where p.oid=v_resolver)
    and (select p.prosecdef from pg_catalog.pg_proc p where p.oid=v_v3)
    and pg_temp.authenticated_v3_count('6b2b0000-0000-4000-8000-000000000101',v_base_date)=1,
    'SECURITY DEFINER v3 wywoluje prywatny SECURITY INVOKER resolver.');

  perform pg_temp.record_result(30, 'AG. Owner search_path and volatility',
    (select pg_catalog.bool_and(pg_catalog.pg_get_userbyid(p.proowner)='postgres'
      and p.provolatile='s'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     from pg_catalog.pg_proc p where p.oid in (v_resolver,v_v3)),
    'Obie funkcje sa STABLE, owner postgres i maja bezpieczny search_path.');

  perform pg_temp.record_result(31, 'AH. V2 remains byte-for-byte unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(v_v2))=(
      select baseline.v2_definition_md5
      from pg_temp.csk_6b2b_test_baseline as baseline
    )
    and pg_catalog.md5(coalesce((select pg_catalog.string_agg(a.grantee::text||':'||a.privilege_type,',' order by a.grantee,a.privilege_type)
      from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
      where p.oid=v_v2),''))=(
        select baseline.v2_acl_md5
        from pg_temp.csk_6b2b_test_baseline as baseline
      ),
    'Migracja nie moze zmienic definicji ani ACL v2.');

  perform pg_temp.record_result(32, 'AI. NULL lane identifier fails closed',
    pg_temp.resolver_sqlstate(null)='22023', 'NULL lane_id musi zwrocic 22023.');

  perform pg_temp.record_result(33, 'AM. NULL reservation date fails closed',
    pg_temp.v3_date_sqlstate('6b2b0000-0000-4000-8000-000000000101',null)='22023',
    'NULL date musi zwrocic 22023.');

  perform pg_temp.record_result(34, 'Resolver returns exact parent and child scope',
    (select pg_catalog.array_agg(conflict_lane_id order by conflict_lane_id)=array[
      '6b2b0000-0000-4000-8000-000000000102'::uuid,
      '6b2b0000-0000-4000-8000-000000000201'::uuid,
      '6b2b0000-0000-4000-8000-000000000202'::uuid,
      '6b2b0000-0000-4000-8000-000000000203'::uuid]
     from public.resolve_lane_conflict_scope_v1('6b2b0000-0000-4000-8000-000000000102'))
    and (select pg_catalog.array_agg(conflict_lane_id order by conflict_lane_id)=array[
      '6b2b0000-0000-4000-8000-000000000102'::uuid,
      '6b2b0000-0000-4000-8000-000000000201'::uuid]
     from public.resolve_lane_conflict_scope_v1('6b2b0000-0000-4000-8000-000000000201')),
    'Parent zawiera direct children, child tylko siebie i parenta.');
end;
$contract_tests$;

-- Constraints and trigger are relaxed only inside this transaction to create
-- impossible production states and verify independent fail-closed behavior.
alter table public.shooting_lanes
  disable trigger validate_shooting_lane_hierarchy_trigger;
alter table public.shooting_lanes
  drop constraint shooting_lanes_resource_kind_check;
alter table public.shooting_lanes
  drop constraint shooting_lanes_resource_parent_check;
alter table public.shooting_lanes
  drop constraint shooting_lanes_parent_not_self_check;

insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values
  ('6b2b0000-0000-4000-8000-000000000601', '[TEST][6B-2B][MISSING-PARENT]', '[TEST]', '[TEST]', 0, true, 1, 60, 9901, 'PLN', 'position', null, false, false),
  ('6b2b0000-0000-4000-8000-000000000602', '[TEST][6B-2B][POSITION-PARENT]', '[TEST]', '[TEST]', 0, true, 1, 60, 9902, 'PLN', 'position', null, false, false),
  ('6b2b0000-0000-4000-8000-000000000603', '[TEST][6B-2B][POSITION-CHILD]', '[TEST]', '[TEST]', 0, true, 1, 60, 9903, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000602', false, false),
  ('6b2b0000-0000-4000-8000-000000000604', '[TEST][6B-2B][DEPTH-ROOT]', '[TEST]', '[TEST]', 0, true, 1, 60, 9904, 'PLN', 'lane', null, false, true),
  ('6b2b0000-0000-4000-8000-000000000605', '[TEST][6B-2B][DEPTH-MID]', '[TEST]', '[TEST]', 0, true, 1, 60, 9905, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000604', false, false),
  ('6b2b0000-0000-4000-8000-000000000606', '[TEST][6B-2B][DEPTH-DEEP]', '[TEST]', '[TEST]', 0, true, 1, 60, 9906, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000605', false, false),
  ('6b2b0000-0000-4000-8000-000000000607', '[TEST][6B-2B][UNKNOWN-KIND]', '[TEST]', '[TEST]', 0, true, 1, 60, 9907, 'PLN', 'unknown', null, false, false),
  ('6b2b0000-0000-4000-8000-000000000608', '[TEST][6B-2B][LANE-WITH-PARENT]', '[TEST]', '[TEST]', 0, true, 1, 60, 9908, 'PLN', 'lane', '6b2b0000-0000-4000-8000-000000000102', false, false),
  ('6b2b0000-0000-4000-8000-000000000609', '[TEST][6B-2B][SELF-PARENT]', '[TEST]', '[TEST]', 0, true, 1, 60, 9909, 'PLN', 'position', '6b2b0000-0000-4000-8000-000000000609', false, false);

do $malformed_tests$
begin
  perform pg_temp.record_result(35, 'X. Position without parent fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000601')='55000',
    'Malformed position bez parenta musi zostac odrzucone.');
  perform pg_temp.record_result(36, 'Y. Position parent type fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000603')='55000',
    'Parent bedacy position musi zostac odrzucony.');
  perform pg_temp.record_result(37, 'Z. Depth greater than one fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000604')='55000',
    'Root z grandchild musi zostac odrzucony.');
  perform pg_temp.record_result(38, 'AJ. Unknown resource kind fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000607')='55000',
    'Nieznany resource_kind musi zostac odrzucony.');
  perform pg_temp.record_result(39, 'AK. Lane with parent fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000608')='55000',
    'Lane z parent_lane_id musi zostac odrzucone.');
  perform pg_temp.record_result(40, 'AL. Self-parent fails closed',
    pg_temp.resolver_sqlstate('6b2b0000-0000-4000-8000-000000000609')='55000',
    'Self-parent musi zostac odrzucony.');
end;
$malformed_tests$;

select test_order, test_name, passed, result
from pg_temp.test_results
order by test_order;

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
  where passed is false;

  if v_failures is not null then
    raise exception '6B-2B availability v3 tests failed: %', v_failures;
  end if;

  if (select pg_catalog.count(*) from pg_temp.test_results) <> 40 then
    raise exception 'Expected exactly 40 availability v3 tests.';
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure(
    'public.resolve_lane_conflict_scope_v1(uuid)'
  ) is null as rollback_resolver_removed,
  pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'
  ) is null as rollback_v3_removed,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
  )) = :'baseline_v2_definition_md5' as rollback_v2_definition_restored,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid =
      'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
  ), '')) = :'baseline_v2_acl_md5' as rollback_v2_acl_restored,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      class_record.relname || ':' || privilege_record.grantee::text || ':' ||
        privilege_record.privilege_type,
      ',' order by class_record.relname, privilege_record.grantee,
        privilege_record.privilege_type
    )
    from pg_catalog.pg_class as class_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = class_record.relnamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(class_record.relacl, pg_catalog.acldefault('r', class_record.relowner))
    ) as privilege_record
    where namespace_record.nspname = 'public'
      and class_record.relname = any(array[
        'shooting_lanes','reservations','lane_blocks','events','event_lanes'
      ]::text[])
  ), '')) = :'baseline_source_acl_md5' as rollback_source_acl_restored,
  not exists (select 1 from public.shooting_lanes where name like '[TEST][6B-2B]%')
    and not exists (select 1 from public.events where title like '[TEST][6B-2B]%')
    and not exists (select 1 from public.lane_blocks where reason like '[TEST][6B-2B]%')
    and not exists (select 1 from public.reservations where reservation_note='[TEST][6B-2B]')
    and not exists (select 1 from auth.users where email='test-6b2b@example.invalid')
    as rollback_fixtures_removed,
  exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid='public.shooting_lanes'::pg_catalog.regclass
      and conname='shooting_lanes_resource_kind_check'
  )
    and exists (
      select 1
      from pg_catalog.pg_constraint
      where conrelid='public.shooting_lanes'::pg_catalog.regclass
        and conname='shooting_lanes_resource_parent_check'
    )
    and exists (
      select 1
      from pg_catalog.pg_constraint
      where conrelid='public.shooting_lanes'::pg_catalog.regclass
        and conname='shooting_lanes_parent_not_self_check'
    )
    and exists (
      select 1
      from pg_catalog.pg_trigger
      where tgrelid='public.shooting_lanes'::pg_catalog.regclass
        and tgname='validate_shooting_lane_hierarchy_trigger'
        and tgenabled <> 'D'
    ) as rollback_hierarchy_protection_restored
\gset

select
  :'rollback_resolver_removed'::boolean
  and :'rollback_v3_removed'::boolean
  and :'rollback_v2_definition_restored'::boolean
  and :'rollback_v2_acl_restored'::boolean
  and :'rollback_source_acl_restored'::boolean
  and :'rollback_fixtures_removed'::boolean
  and :'rollback_hierarchy_protection_restored'::boolean
  as rollback_confirmed;

select 1 / (
  :'rollback_resolver_removed'::boolean
  and :'rollback_v3_removed'::boolean
  and :'rollback_v2_definition_restored'::boolean
  and :'rollback_v2_acl_restored'::boolean
  and :'rollback_source_acl_restored'::boolean
  and :'rollback_fixtures_removed'::boolean
  and :'rollback_hierarchy_protection_restored'::boolean
)::integer as rollback_assertion;
