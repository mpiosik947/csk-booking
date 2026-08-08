\set ON_ERROR_STOP on

-- Run only with psql. The migration and all synthetic [TEST][5E-2B-2]
-- fixtures are enclosed in one transaction and removed by the final ROLLBACK.
begin;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure
  )) as baseline_old_function_md5,
  pg_catalog.md5(coalesce(
    (
      select pg_catalog.string_agg(
        privilege_record.grantee::text || ':' || privilege_record.privilege_type,
        ',' order by privilege_record.grantee, privilege_record.privilege_type
      )
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )
      ) as privilege_record
      where function_record.oid =
        'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure
    ),
    ''
  )) as baseline_old_acl_md5,
  pg_catalog.md5(coalesce(
    (
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
        coalesce(
          class_record.relacl,
          pg_catalog.acldefault('r', class_record.relowner)
        )
      ) as privilege_record
      where namespace_record.nspname = 'public'
        and class_record.relname = any(array[
          'reservations','lane_blocks','events','event_lanes','shooting_lanes'
        ]::text[])
    ),
    ''
  )) as baseline_table_acl_md5
\gset

create temporary table csk_5e2b2_baseline (
  old_function_md5 text not null,
  old_acl_md5 text not null,
  table_acl_md5 text not null
) on commit drop;

insert into pg_temp.csk_5e2b2_baseline values (
  :'baseline_old_function_md5', :'baseline_old_acl_md5', :'baseline_table_acl_md5'
);

do $clean_preflight$
begin
  if pg_catalog.to_regprocedure(
       'public.get_lane_booking_busy_ranges_v2(uuid,date)'
     ) is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'get_lane_booking_busy_ranges_v2'
     )
     or exists (
       select 1 from public.events
       where title like '[TEST][5E-2B-2]%'
     )
     or exists (
       select 1 from public.shooting_lanes
       where name like '[TEST][5E-2B-2]%'
     )
     or exists (
       select 1 from public.lane_blocks
       where reason like '[TEST][5E-2B-2]%'
     )
     or exists (
       select 1 from public.reservations
       where reservation_note = '[TEST][5E-2B-2]'
     )
     or exists (
       select 1 from auth.users
       where email = 'test-5e2b2@example.invalid'
     ) then
    raise exception 'Unexpected prior v2 object or [TEST][5E-2B-2] fixture.';
  end if;
end;
$clean_preflight$;

\ir ../migrations/20260808124203_add_lane_booking_busy_ranges_v2.sql

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
  insert into pg_temp.test_results (test_order, test_name, passed, result)
  values (p_test_order, p_test_name, coalesce(p_passed, false), p_result);
$function$;

create function pg_temp.call_create_reservation(
  p_user_id uuid,
  p_lane_id uuid,
  p_test_date date,
  p_start_time time without time zone
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select public.create_reservation(
    p_lane_id,
    p_test_date,
    p_start_time,
    60,
    1,
    pg_catalog.gen_random_uuid(),
    '[TEST][5E-2B-2]'
  )
  into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $contract_tests$
declare
  v_old_function_oid oid :=
    'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure;
  v_new_function_oid oid :=
    'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure;
  v_base_date date := current_date + 5000;
  v_user_id uuid := pg_catalog.gen_random_uuid();
  v_lane_id uuid := pg_catalog.gen_random_uuid();
  v_active_reservation_id uuid;
  v_cancelled_reservation_id uuid;
  v_completed_reservation_id uuid;
  v_no_show_reservation_id uuid;
  v_active_event_id uuid := pg_catalog.gen_random_uuid();
  v_inactive_event_id uuid := pg_catalog.gen_random_uuid();
  v_global_event_id uuid := pg_catalog.gen_random_uuid();
  v_result jsonb;
  v_definition text;
  v_count bigint;
begin
  perform pg_temp.record_result(
    1,
    'Legacy RPC has one exact signature',
    (
      select pg_catalog.count(*) = 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = 'get_lane_booking_busy_ranges'
        and function_record.proargtypes = '2950 1082'::pg_catalog.oidvector
    ) and (
      select pg_catalog.count(*) = 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = 'get_lane_booking_busy_ranges'
    ),
    'Expected exactly the legacy uuid,date function.'
  );

  perform pg_temp.record_result(
    2,
    'Legacy RPC keeps two output columns',
    (
      select function_record.proallargtypes = array[
          'pg_catalog.uuid'::pg_catalog.regtype,
          'pg_catalog.date'::pg_catalog.regtype,
          'time without time zone'::pg_catalog.regtype,
          'time without time zone'::pg_catalog.regtype
        ]::oid[]
        and function_record.proargmodes = array['i','i','t','t']::"char"[]
        and function_record.proargnames = array[
          'p_lane_id','p_reservation_date','start_time','end_time'
        ]::text[]
      from pg_catalog.pg_proc as function_record
      where function_record.oid = v_old_function_oid
    ),
    'Legacy output must remain TABLE(start_time,end_time).'
  );

  perform pg_temp.record_result(
    3,
    'Legacy RPC definition is unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(v_old_function_oid)) =
      (select old_function_md5 from pg_temp.csk_5e2b2_baseline),
    'Legacy pg_get_functiondef hash must be unchanged.'
  );

  perform pg_temp.record_result(
    4,
    'Legacy RPC ACL is unchanged',
    pg_catalog.md5(coalesce(
      (
        select pg_catalog.string_agg(
          privilege_record.grantee::text || ':' || privilege_record.privilege_type,
          ',' order by privilege_record.grantee, privilege_record.privilege_type
        )
        from pg_catalog.pg_proc as function_record
        cross join lateral pg_catalog.aclexplode(
          coalesce(
            function_record.proacl,
            pg_catalog.acldefault('f', function_record.proowner)
          )
        ) as privilege_record
        where function_record.oid = v_old_function_oid
      ),
      ''
    )) = (select old_acl_md5 from pg_temp.csk_5e2b2_baseline),
    'Legacy function ACL hash must be unchanged.'
  );

  perform pg_temp.record_result(
    5,
    'V2 has one exact signature',
    (
      select pg_catalog.count(*) = 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = 'get_lane_booking_busy_ranges_v2'
        and function_record.proargtypes = '2950 1082'::pg_catalog.oidvector
    ) and (
      select pg_catalog.count(*) = 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = 'get_lane_booking_busy_ranges_v2'
    ),
    'Expected exactly public.get_lane_booking_busy_ranges_v2(uuid,date).'
  );

  perform pg_temp.record_result(
    6,
    'V2 has three ordered output columns',
    (
      select function_record.proallargtypes = array[
          'pg_catalog.uuid'::pg_catalog.regtype,
          'pg_catalog.date'::pg_catalog.regtype,
          'time without time zone'::pg_catalog.regtype,
          'time without time zone'::pg_catalog.regtype,
          'pg_catalog.text'::pg_catalog.regtype
        ]::oid[]
        and function_record.proargmodes = array['i','i','t','t','t']::"char"[]
        and function_record.proargnames = array[
          'p_lane_id','p_reservation_date','start_time','end_time','busy_type'
        ]::text[]
      from pg_catalog.pg_proc as function_record
      where function_record.oid = v_new_function_oid
    ),
    'Expected TABLE(start_time,end_time,busy_type).'
  );

  perform pg_temp.record_result(
    7,
    'V2 security properties are exact',
    (
      select language_record.lanname = 'sql'
        and function_record.provolatile = 's'
        and function_record.prosecdef
        and pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
        and function_record.proconfig = array[
          'search_path=pg_catalog, public, pg_temp'
        ]::text[]
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_language as language_record
        on language_record.oid = function_record.prolang
      where function_record.oid = v_new_function_oid
    ),
    'Expected SQL STABLE SECURITY DEFINER owned by postgres.'
  );

  perform pg_temp.record_result(
    8,
    'Authenticated and service_role have EXECUTE',
    pg_catalog.has_function_privilege(
      'authenticated', v_new_function_oid, 'EXECUTE'
    ) and pg_catalog.has_function_privilege(
      'service_role', v_new_function_oid, 'EXECUTE'
    ),
    'Both trusted caller roles require EXECUTE.'
  );

  perform pg_temp.record_result(
    9,
    'anon and PUBLIC have no EXECUTE',
    not pg_catalog.has_function_privilege(
      'anon', v_new_function_oid, 'EXECUTE'
    ) and not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )
      ) as privilege_record
      where function_record.oid = v_new_function_oid
        and privilege_record.grantee = 0
        and privilege_record.privilege_type = 'EXECUTE'
    ),
    'anon and PUBLIC must not execute v2.'
  );

  select pg_catalog.lower(pg_catalog.pg_get_functiondef(v_new_function_oid))
  into v_definition;

  perform pg_temp.record_result(
    10,
    'V2 definition uses exact safe sources and types',
    v_definition ~ 'from[[:space:]]+public[.]reservations'
      and v_definition ~ 'from[[:space:]]+public[.]lane_blocks'
      and v_definition ~ 'from[[:space:]]+public[.]event_lanes'
      and v_definition ~ 'join[[:space:]]+public[.]events'
      and v_definition ~ '''reservation''::text'
      and v_definition ~ '''lane_block''::text'
      and v_definition ~ '''event''::text'
      and v_definition !~ 'customer_|participant|email|phone|full_name|reason',
    'Expected only technical range sources and three safe busy types.'
  );

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values (
    v_user_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'test-5e2b2@example.invalid',
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
      last_name = '5E-2B-2',
      full_name = '[TEST][5E-2B-2]',
      email = 'test-5e2b2@example.invalid',
      phone = '000000000',
      verification_status = 'verified'
  where user_id = v_user_id;

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code
  ) values (
    v_lane_id,
    '[TEST][5E-2B-2][LANE]',
    '[TEST]',
    '[TEST]',
    10,
    true,
    5,
    60,
    995,
    'PLN'
  );

  insert into public.lane_booking_durations (
    lane_id, duration_minutes, display_order, is_active
  ) values
    (v_lane_id, 60, 1, true),
    (v_lane_id, 120, 2, true),
    (v_lane_id, 180, 3, true),
    (v_lane_id, 240, 4, true);

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters, label,
    hourly_price, display_order, is_active
  ) values
    (v_lane_id, 'mon_thu', 1, 5, '[TEST][5E-2B-2]', 10, 1, true),
    (v_lane_id, 'fri_sun', 1, 5, '[TEST][5E-2B-2]', 10, 1, true);

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_id, v_base_date, time '09:00'
  );
  v_active_reservation_id := (v_result->>'reservation_id')::uuid;

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_id, v_base_date + 1, time '08:00'
  );
  v_cancelled_reservation_id := (v_result->>'reservation_id')::uuid;
  update public.reservations
  set reservation_status = 'cancelled'
  where id = v_cancelled_reservation_id;

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_id, v_base_date + 1, time '09:00'
  );
  v_completed_reservation_id := (v_result->>'reservation_id')::uuid;
  update public.reservations
  set reservation_status = 'completed'
  where id = v_completed_reservation_id;

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_id, v_base_date + 1, time '10:00'
  );
  v_no_show_reservation_id := (v_result->>'reservation_id')::uuid;
  update public.reservations
  set reservation_status = 'no_show'
  where id = v_no_show_reservation_id;

  insert into public.lane_blocks (
    lane_id, block_date, start_time, end_time, reason, is_active
  ) values
    (
      v_lane_id, v_base_date, time '10:00', time '11:00',
      '[TEST][5E-2B-2][ACTIVE-BLOCK]', true
    ),
    (
      v_lane_id, v_base_date, time '14:00', time '15:00',
      '[TEST][5E-2B-2][INACTIVE-BLOCK]', false
    );

  insert into public.events (
    id, title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values
    (
      v_active_event_id,
      '[TEST][5E-2B-2][ACTIVE-EVENT]',
      v_base_date,
      time '11:00',
      time '14:00',
      0,
      5,
      true
    ),
    (
      v_inactive_event_id,
      '[TEST][5E-2B-2][INACTIVE-EVENT]',
      v_base_date,
      time '15:00',
      time '16:00',
      0,
      5,
      false
    ),
    (
      v_global_event_id,
      '[TEST][5E-2B-2][GLOBAL-EVENT]',
      v_base_date,
      time '16:00',
      time '17:00',
      0,
      5,
      true
    );

  insert into public.event_lanes (event_id, lane_id) values
    (v_active_event_id, v_lane_id),
    (v_inactive_event_id, v_lane_id);

  perform pg_temp.record_result(
    11,
    'Active reservation has reservation type',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
      where start_time = time '09:00'
        and end_time = time '10:00'
        and busy_type = 'reservation'
    ),
    'Expected the active reservation range.'
  );

  perform pg_temp.record_result(
    12,
    'Active lane block has lane_block type',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
      where start_time = time '10:00'
        and end_time = time '11:00'
        and busy_type = 'lane_block'
    ),
    'Expected the active lane-block range.'
  );

  perform pg_temp.record_result(
    13,
    'Active lane event has event type',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
      where start_time = time '11:00'
        and end_time = time '14:00'
        and busy_type = 'event'
    ),
    'Expected the assigned active event range.'
  );

  perform pg_temp.record_result(
    14,
    'Inactive lane block is absent',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
      where start_time = time '14:00'
        and end_time = time '15:00'
        and busy_type = 'lane_block'
    ),
    'Inactive block must not be returned.'
  );

  perform pg_temp.record_result(
    15,
    'Inactive lane event is absent',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
      where start_time = time '15:00'
        and end_time = time '16:00'
        and busy_type = 'event'
    ),
    'Inactive event must not be returned.'
  );

  perform pg_temp.record_result(
    16,
    'Global event is absent',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
      where start_time = time '16:00'
        and end_time = time '17:00'
        and busy_type = 'event'
    ),
    'Event without event_lanes must not be returned.'
  );

  perform pg_temp.record_result(
    17,
    'Cancelled reservation is absent',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date + 1)
      where start_time = time '08:00'
        and busy_type = 'reservation'
    ),
    'Cancelled reservation must not be returned.'
  );

  perform pg_temp.record_result(
    18,
    'Completed reservation is absent',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date + 1)
      where start_time = time '09:00'
        and busy_type = 'reservation'
    ),
    'Completed reservation must not be returned.'
  );

  perform pg_temp.record_result(
    19,
    'No-show reservation is absent',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date + 1)
      where start_time = time '10:00'
        and busy_type = 'reservation'
    ),
    'No-show reservation must not be returned.'
  );

  perform pg_temp.record_result(
    20,
    'Touching boundaries remain separate raw ranges',
    (
      select pg_catalog.count(*) = 3
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
      where (start_time, end_time, busy_type) in (
        (time '09:00', time '10:00', 'reservation'),
        (time '10:00', time '11:00', 'lane_block'),
        (time '11:00', time '14:00', 'event')
      )
    ),
    'Expected three [start,end) ranges touching only at boundaries.'
  );

  select pg_catalog.count(*)
  into v_count
  from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date);

  perform pg_temp.record_result(
    21,
    'All simultaneous raw sources are returned',
    v_count = 3,
    'Expected exactly reservation, lane_block and event rows.'
  );

  perform pg_temp.record_result(
    22,
    'Result has no additional columns',
    (
      select pg_catalog.array_agg(distinct key order by key) =
        array['busy_type','end_time','start_time']::text[]
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date) as busy
      cross join lateral pg_catalog.jsonb_object_keys(
        pg_catalog.to_jsonb(busy)
      ) as key
    ),
    'Only start_time, end_time and busy_type may be returned.'
  );

  perform pg_temp.record_result(
    23,
    'V2 has stable technical ordering',
    v_definition ~ 'order[[:space:]]+by[[:space:]]+busy_range[.]start_time'
      and v_definition ~ 'busy_range[.]end_time'
      and v_definition ~ 'busy_range[.]busy_type',
    'Expected ORDER BY start_time, end_time, busy_type.'
  );

  perform pg_temp.record_result(
    24,
    'Source table ACL is unchanged',
    pg_catalog.md5(coalesce(
      (
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
          coalesce(
            class_record.relacl,
            pg_catalog.acldefault('r', class_record.relowner)
          )
        ) as privilege_record
        where namespace_record.nspname = 'public'
          and class_record.relname = any(array[
            'reservations','lane_blocks','events','event_lanes','shooting_lanes'
          ]::text[])
      ),
      ''
    )) = (select table_acl_md5 from pg_temp.csk_5e2b2_baseline),
    'Migration must not grant SELECT or alter source table ACL.'
  );

  perform pg_temp.record_result(
    25,
    'No additional old or v2 overloads exist',
    (
      select pg_catalog.count(*) = 2
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = any(array[
          'get_lane_booking_busy_ranges',
          'get_lane_booking_busy_ranges_v2'
        ]::text[])
    ),
    'Expected one old function and one v2 function.'
  );

  update public.shooting_lanes
  set is_active = false
  where id = v_lane_id;

  perform pg_temp.record_result(
    26,
    'Inactive lane returns no availability',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges_v2(v_lane_id, v_base_date)
    ),
    'Inactive shooting lane must suppress every source.'
  );

  update public.shooting_lanes
  set is_active = true
  where id = v_lane_id;

  perform pg_temp.record_result(
    27,
    'Synthetic fixtures are scoped to one marker',
    (select pg_catalog.count(*) = 1 from public.shooting_lanes
      where name like '[TEST][5E-2B-2]%')
    and (select pg_catalog.count(*) = 3 from public.events
      where title like '[TEST][5E-2B-2]%')
    and (select pg_catalog.count(*) = 2 from public.lane_blocks
      where reason like '[TEST][5E-2B-2]%')
    and (select pg_catalog.count(*) = 4 from public.reservations
      where reservation_note = '[TEST][5E-2B-2]'),
    'Expected only the controlled v2 fixture set.'
  );
end;
$contract_tests$;

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
    raise exception '5E-2B-2 busy-range v2 tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure
  )) = :'baseline_old_function_md5' as rollback_old_function_restored,
  pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v2(uuid,date)'
  ) is null as rollback_v2_removed,
  not exists (
    select 1 from public.events
    where title like '[TEST][5E-2B-2]%'
  )
  and not exists (
    select 1 from public.shooting_lanes
    where name like '[TEST][5E-2B-2]%'
  )
  and not exists (
    select 1 from public.lane_blocks
    where reason like '[TEST][5E-2B-2]%'
  )
  and not exists (
    select 1 from public.reservations
    where reservation_note = '[TEST][5E-2B-2]'
  ) as rollback_business_data_removed,
  not exists (
    select 1 from auth.users
    where email = 'test-5e2b2@example.invalid'
  ) as rollback_auth_data_removed
\gset

select *
from (
  values
    (
      28,
      'ROLLBACK restored the legacy RPC',
      :'rollback_old_function_restored'::boolean,
      'Legacy function definition must retain its baseline hash.'
    ),
    (
      29,
      'ROLLBACK removed v2 and business fixtures',
      :'rollback_v2_removed'::boolean
        and :'rollback_business_data_removed'::boolean,
      'V2 and all marked business fixtures must be absent.'
    ),
    (
      30,
      'ROLLBACK removed the synthetic auth user',
      :'rollback_auth_data_removed'::boolean,
      'The example.invalid test user must be absent.'
    )
) as rollback_results(test_order, test_name, passed, result)
order by test_order;

select 1 / (
  :'rollback_old_function_restored'::boolean
  and :'rollback_v2_removed'::boolean
  and :'rollback_business_data_removed'::boolean
  and :'rollback_auth_data_removed'::boolean
)::integer as rollback_assertion;

select true as rollback_confirmed;
