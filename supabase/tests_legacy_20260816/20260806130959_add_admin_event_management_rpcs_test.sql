\set ON_ERROR_STOP on

-- Test przeznaczony do uruchomienia przez psql. Migracja, funkcje pomocnicze
-- i wszystkie dane [TEST][5D-2] są objęte jedną transakcją z ROLLBACK.
begin;

\ir ../migrations/20260806130959_add_admin_event_management_rpcs.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.call_create(
  p_user_id uuid,
  p_title text,
  p_event_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_lane_ids uuid[]
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_create_event(
    p_title, ' [TEST][5D-2] ', p_event_date, p_start_time, p_end_time,
    ' [TEST][5D-2] ', 10, 10, p_lane_ids
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_update(
  p_user_id uuid,
  p_event_id uuid,
  p_title text,
  p_event_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_lane_ids uuid[]
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_update_event(
    p_event_id, p_title, ' [TEST][5D-2] ', p_event_date,
    p_start_time, p_end_time, ' [TEST][5D-2] ', 10, 10, p_lane_ids
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_active(
  p_user_id uuid,
  p_event_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_set_event_active(p_event_id, p_is_active) into v_result;
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
  v_base_date date := current_date + 5000;
  v_admin_id uuid := pg_catalog.gen_random_uuid();
  v_employee_id uuid := pg_catalog.gen_random_uuid();
  v_instructor_id uuid := pg_catalog.gen_random_uuid();
  v_user_id uuid := pg_catalog.gen_random_uuid();
  v_reservation_user_id uuid := pg_catalog.gen_random_uuid();
  v_lane1 uuid := pg_catalog.gen_random_uuid();
  v_lane2 uuid := pg_catalog.gen_random_uuid();
  v_lane3 uuid := pg_catalog.gen_random_uuid();
  v_lane4 uuid := pg_catalog.gen_random_uuid();
  v_lane5 uuid := pg_catalog.gen_random_uuid();
  v_pricing_rule_id uuid;
  v_result jsonb;
  v_event_id uuid;
  v_event_id2 uuid;
  v_target_event_id uuid;
  v_count bigint;
  v_passed boolean;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d2-admin@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_employee_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d2-employee@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_instructor_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d2-instructor@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_user_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d2-user@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_reservation_user_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d2-reservation@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
        when v_admin_id then 'admin'
        when v_employee_id then 'pracownik'
        when v_instructor_id then 'instruktor'
        else 'user'
      end,
      verification_status = 'zweryfikowany'
  where user_id in (
    v_admin_id, v_employee_id, v_instructor_id,
    v_user_id, v_reservation_user_id
  );

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code
  ) values
    (v_lane1, '[TEST][5D-2][LANE-1]', '[TEST]', '[TEST]', 10, true, 10, 60, 901, 'PLN'),
    (v_lane2, '[TEST][5D-2][LANE-2]', '[TEST]', '[TEST]', 10, true, 10, 60, 902, 'PLN'),
    (v_lane3, '[TEST][5D-2][LANE-3]', '[TEST]', '[TEST]', 10, true, 10, 60, 903, 'PLN'),
    (v_lane4, '[TEST][5D-2][LANE-4]', '[TEST]', '[TEST]', 10, false, 10, 60, 904, 'PLN'),
    (v_lane5, '[TEST][5D-2][LANE-5]', '[TEST]', '[TEST]', 10, true, 10, 60, 905, 'PLN');

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters,
    label, hourly_price, display_order, is_active
  ) values (
    v_lane1, 'mon_thu', 1, 10, '[TEST][5D-2]', 10, 1, true
  ) returning id into v_pricing_rule_id;

  -- 1. Admin może tworzyć.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][ADMIN]', v_base_date,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  insert into test_results values (
    1, 'Admin może tworzyć',
    v_result->>'code' = 'created' and (v_result->>'changed')::boolean,
    'Oczekiwano created dla admina.'
  );
  v_target_event_id := (v_result->>'event_id')::uuid;

  -- 2. Pracownik może tworzyć.
  v_result := pg_temp.call_create(
    v_employee_id, '[TEST][5D-2][EMPLOYEE]', v_base_date + 1,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  v_passed := v_result->>'code' = 'created';
  v_result := pg_temp.call_update(
    v_employee_id, v_target_event_id, '[TEST][5D-2][ADMIN]', v_base_date,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  v_passed := v_passed and v_result->>'code' = 'no_change';
  v_result := pg_temp.call_active(v_employee_id, v_target_event_id, true);
  insert into test_results values (
    2, 'Pracownik może wykonywać wszystkie trzy RPC',
    v_passed and v_result->>'code' = 'no_change',
    'Pracownik powinien mieć funkcjonalny dostęp do create, update i set active.'
  );

  -- 3. Instruktor jest blokowany.
  v_result := pg_temp.call_create(
    v_instructor_id, '[TEST][5D-2][INSTRUCTOR]', v_base_date + 2,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  v_passed := v_result->>'code' = 'not_allowed'
    and not (v_result->>'changed')::boolean;
  v_result := pg_temp.call_update(
    v_instructor_id, v_target_event_id, '[TEST][5D-2][ADMIN]', v_base_date,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  v_passed := v_passed and v_result->>'code' = 'not_allowed';
  v_result := pg_temp.call_active(v_instructor_id, v_target_event_id, false);
  insert into test_results values (
    3, 'Instruktor otrzymuje not_allowed ze wszystkich RPC',
    v_passed and v_result->>'code' = 'not_allowed',
    'Instruktor nie może tworzyć, aktualizować ani zmieniać aktywności eventów.'
  );

  -- 4. User jest blokowany.
  v_result := pg_temp.call_create(
    v_user_id, '[TEST][5D-2][USER]', v_base_date + 2,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  v_passed := v_result->>'code' = 'not_allowed';
  v_result := pg_temp.call_update(
    v_user_id, v_target_event_id, '[TEST][5D-2][ADMIN]', v_base_date,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  v_passed := v_passed and v_result->>'code' = 'not_allowed';
  v_result := pg_temp.call_active(v_user_id, v_target_event_id, false);
  insert into test_results values (
    4, 'User otrzymuje not_allowed ze wszystkich RPC',
    v_passed and v_result->>'code' = 'not_allowed',
    'Zwykły user nie może tworzyć, aktualizować ani zmieniać aktywności eventów.'
  );

  -- 5. Brak JWT jest blokowany.
  perform pg_catalog.set_config('request.jwt.claims', '{}', true);
  select public.admin_create_event(
    '[TEST][5D-2][NO-JWT]', '[TEST]', v_base_date + 2,
    time '10:00', time '11:00', '[TEST]', 0, 1, '{}'::uuid[]
  ) into v_result;
  v_passed := v_result->>'code' = 'not_allowed';
  select public.admin_update_event(
    v_target_event_id, '[TEST][5D-2][ADMIN]', '[TEST]', v_base_date,
    time '10:00', time '11:00', '[TEST]', 0, 1, '{}'::uuid[]
  ) into v_result;
  v_passed := v_passed and v_result->>'code' = 'not_allowed';
  select public.admin_set_event_active(v_target_event_id, false) into v_result;
  insert into test_results values (
    5, 'Brak JWT otrzymuje not_allowed ze wszystkich RPC',
    v_passed and v_result->>'code' = 'not_allowed',
    'Brak auth.uid() musi zostać odrzucony przez create, update i set active.'
  );

  -- 6. anon nie ma EXECUTE.
  select
    not pg_catalog.has_function_privilege(
      'anon',
      'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])',
      'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon',
      'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])',
      'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon', 'public.admin_set_event_active(uuid,boolean)', 'EXECUTE'
    )
  into v_passed;
  insert into test_results values (
    6, 'anon bez EXECUTE', v_passed,
    'anon nie może wykonywać żadnego z trzech RPC.'
  );

  -- 7. Dokładne sygnatury, właściciel i ACL są bezpieczne.
  select
    not exists (
      select 1
      from information_schema.routine_privileges
      where routine_schema = 'public'
        and routine_name in (
          'admin_create_event', 'admin_update_event', 'admin_set_event_active'
        )
        and grantee = 'PUBLIC'
        and privilege_type = 'EXECUTE'
    )
    and (
      select pg_catalog.bool_and(
        procedure_record.prosecdef
        and language_record.lanname = 'plpgsql'
        and owner_record.rolname = 'postgres'
        and procedure_record.proconfig = array['search_path=public, pg_temp']::text[]
        and pg_catalog.has_function_privilege(
          'authenticated', procedure_record.oid, 'EXECUTE'
        )
      )
      from pg_catalog.pg_proc as procedure_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = procedure_record.pronamespace
      join pg_catalog.pg_language as language_record
        on language_record.oid = procedure_record.prolang
      join pg_catalog.pg_roles as owner_record
        on owner_record.oid = procedure_record.proowner
      where namespace_record.nspname = 'public'
        and procedure_record.oid in (
          'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::pg_catalog.regprocedure,
          'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::pg_catalog.regprocedure,
          'public.admin_set_event_active(uuid,boolean)'::pg_catalog.regprocedure
        )
    )
    and (
      select pg_catalog.count(*) = 3
      from pg_catalog.pg_proc as procedure_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = procedure_record.pronamespace
      where namespace_record.nspname = 'public'
        and procedure_record.proname in (
          'admin_create_event', 'admin_update_event', 'admin_set_event_active'
        )
    )
    and (
      select pg_catalog.bool_and(procedure_record.pronargdefaults = expected.default_count)
      from (
        values
          ('admin_create_event'::text, 1),
          ('admin_update_event'::text, 1),
          ('admin_set_event_active'::text, 0)
      ) as expected(function_name, default_count)
      join pg_catalog.pg_proc as procedure_record
        on procedure_record.proname = expected.function_name
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = procedure_record.pronamespace
       and namespace_record.nspname = 'public'
    )
  into v_passed;
  insert into test_results values (
    7, 'Dokładne sygnatury, właściciel i bezpieczne ACL RPC', v_passed,
    'Oczekiwano trzech dokładnych sygnatur, owner postgres i kontrolowanego EXECUTE.'
  );

  -- 8. Event globalny bez event_lanes.
  select id into v_event_id
  from public.events where title = '[TEST][5D-2][ADMIN]';
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id;
  insert into test_results values (
    8, 'Event globalny nie tworzy event_lanes', v_count = 0,
    'Pusta tablica osi oznacza event globalny.'
  );

  -- 9. Jedna oś.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][ONE-LANE]', v_base_date + 3,
    time '10:00', time '11:00', array[v_lane1]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id;
  insert into test_results values (
    9, 'Event jednoosiowy tworzy jedno przypisanie',
    v_result->>'code' = 'created' and v_count = 1,
    'Oczekiwano dokładnie jednego event_lanes.'
  );

  -- 10. Wiele osi.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][MULTI-LANE]', v_base_date + 4,
    time '10:00', time '11:00', array[v_lane2, v_lane1]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id;
  insert into test_results values (
    10, 'Event wieloosiowy tworzy wszystkie przypisania',
    v_result->>'code' = 'created' and v_count = 2,
    'Oczekiwano dwóch przypisań osi.'
  );

  -- 11-17. Walidacja wejścia i godzin.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][DUPLICATE]', v_base_date + 5,
    time '10:00', time '11:00', array[v_lane1, v_lane1]
  );
  v_passed := v_result->>'code' = 'invalid_input';
  select public.admin_create_event(
    '[TEST][5D-2][NAN-PRICE]', '[TEST][5D-2]', v_base_date + 5,
    time '10:00', time '11:00', '[TEST][5D-2]', 'NaN'::numeric, 1,
    '{}'::uuid[]
  ) into v_result;
  insert into test_results values (
    11, 'Duplikat lane_id i niefinitywna cena są odrzucane',
    v_passed and v_result->>'code' = 'invalid_input',
    'Duplikaty osi i numeric NaN muszą zwracać invalid_input.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][NULL-LANE]', v_base_date + 5,
    time '10:00', time '11:00', array[v_lane1, null::uuid]
  );
  insert into test_results values (
    12, 'NULL w lane_ids jest odrzucany', v_result->>'code' = 'invalid_input',
    'NULL w tablicy osi jest niedozwolony.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][MISSING-LANE]', v_base_date + 5,
    time '10:00', time '11:00', array[pg_catalog.gen_random_uuid()]
  );
  insert into test_results values (
    13, 'Nieistniejąca oś jest odrzucana', v_result->>'code' = 'invalid_lane',
    'Oczekiwano invalid_lane.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][INACTIVE-LANE]', v_base_date + 5,
    time '10:00', time '11:00', array[v_lane4]
  );
  insert into test_results values (
    14, 'Nieaktywna oś jest odrzucana', v_result->>'code' = 'inactive_lane',
    'Oczekiwano inactive_lane.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][BAD-TIME]', v_base_date + 5,
    time '12:00', time '12:00', '{}'::uuid[]
  );
  insert into test_results values (
    15, 'end_time <= start_time jest odrzucane',
    v_result->>'code' = 'invalid_time_range',
    'Oczekiwano invalid_time_range.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][LANE-OUTSIDE]', v_base_date + 5,
    time '07:00', time '09:00', array[v_lane1]
  );
  insert into test_results values (
    16, 'Event osiowy poza godzinami jest odrzucany',
    v_result->>'code' = 'outside_booking_hours',
    'Event osiowy musi mieścić się w 08:00-20:00.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][GLOBAL-OUTSIDE]', v_base_date + 5,
    time '07:00', time '21:00', '{}'::uuid[]
  );
  insert into test_results values (
    17, 'Event globalny poza 08:00-20:00 jest dozwolony',
    v_result->>'code' = 'created',
    'Event globalny podlega tylko end_time > start_time.'
  );

  -- Rezerwacje syntetyczne do kontroli konfliktów.
  insert into public.reservations (
    user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes,
    price, reservation_status, payment_status, attendance_status,
    reservation_note, shooters_count, pricing_rule_id,
    pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
    price_per_hour_snapshot, total_price, currency_code, creation_request_id
  ) values
    (
      v_reservation_user_id, v_lane1, '[TEST][5D-2]',
      '[TEST]-5d2-active@example.invalid', '[TEST]',
      v_base_date + 10, time '10:00', time '11:00', 60,
      10, 'confirmed', 'pay_on_site', 'planned', '[TEST][5D-2]',
      1, v_pricing_rule_id, 'mon_thu', '[TEST][5D-2][LANE-1]',
      '[TEST][5D-2]', 10, 10, 'PLN', pg_catalog.gen_random_uuid()
    ),
    (
      v_reservation_user_id, v_lane1, '[TEST][5D-2]',
      '[TEST]-5d2-cancelled@example.invalid', '[TEST]',
      v_base_date + 11, time '10:00', time '11:00', 60,
      10, 'cancelled', 'pay_on_site', 'planned', '[TEST][5D-2]',
      1, v_pricing_rule_id, 'mon_thu', '[TEST][5D-2][LANE-1]',
      '[TEST][5D-2]', 10, 10, 'PLN', pg_catalog.gen_random_uuid()
    );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][RES-CONFLICT]', v_base_date + 10,
    time '10:30', time '11:30', array[v_lane1]
  );
  insert into test_results values (
    18, 'Konflikt z aktywną rezerwacją',
    v_result->>'code' = 'reservation_conflict'
      and v_result->>'conflict_type' = 'reservation'
      and (v_result->>'conflict_lane_id')::uuid = v_lane1
      and not (v_result ?| array[
        'reservation_id', 'customer_name', 'customer_email',
        'customer_phone', 'reservation'
      ]),
    'Konflikt ma wskazać wyłącznie techniczny typ i oczekiwaną oś bez PII.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][CANCELLED-RES]', v_base_date + 11,
    time '10:30', time '11:30', array[v_lane1]
  );
  insert into test_results values (
    19, 'Anulowana rezerwacja nie blokuje', v_result->>'code' = 'created',
    'Nieaktywna rezerwacja nie może blokować eventu.'
  );

  insert into public.lane_blocks (
    lane_id, block_date, start_time, end_time, reason, is_active
  ) values
    (v_lane1, v_base_date + 12, time '10:00', time '11:00', '[TEST][5D-2]', true),
    (v_lane1, v_base_date + 13, time '10:00', time '11:00', '[TEST][5D-2]', false);

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][BLOCK-CONFLICT]', v_base_date + 12,
    time '10:30', time '11:30', array[v_lane1]
  );
  insert into test_results values (
    20, 'Konflikt z aktywną lane_block',
    v_result->>'code' = 'lane_block_conflict'
      and v_result->>'conflict_type' = 'lane_block'
      and (v_result->>'conflict_lane_id')::uuid = v_lane1,
    'Aktywna blokada osi musi blokować event.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][INACTIVE-BLOCK]', v_base_date + 13,
    time '10:30', time '11:30', array[v_lane1]
  );
  insert into test_results values (
    21, 'Nieaktywna lane_block nie blokuje', v_result->>'code' = 'created',
    'Nieaktywna blokada osi nie może powodować konfliktu.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][EVENT-BASE]', v_base_date + 14,
    time '10:00', time '11:00', array[v_lane1]
  );
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][EVENT-CONFLICT]', v_base_date + 14,
    time '10:30', time '11:30', array[v_lane1]
  );
  insert into test_results values (
    22, 'Konflikt z aktywnym eventem',
    v_result->>'code' = 'event_conflict'
      and v_result->>'conflict_type' = 'event'
      and (v_result->>'conflict_lane_id')::uuid = v_lane1,
    'Aktywny event na tej samej osi musi blokować.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][INACTIVE-EVENT-BASE]', v_base_date + 15,
    time '10:00', time '11:00', array[v_lane1]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  perform pg_temp.call_active(v_admin_id, v_event_id, false);
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][INACTIVE-EVENT-OK]', v_base_date + 15,
    time '10:30', time '11:30', array[v_lane1]
  );
  insert into test_results values (
    23, 'Nieaktywny event nie blokuje', v_result->>'code' = 'created',
    'Nieaktywny event nie może powodować konfliktu.'
  );

  perform pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][OTHER-LANE-BASE]', v_base_date + 16,
    time '10:00', time '11:00', array[v_lane1]
  );
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][OTHER-LANE-OK]', v_base_date + 16,
    time '10:30', time '11:30', array[v_lane2]
  );
  insert into test_results values (
    24, 'Brak konfliktu na innej osi', v_result->>'code' = 'created',
    'Różne osie mogą mieć nakładające się godziny.'
  );

  perform pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][TOUCH-BASE]', v_base_date + 17,
    time '10:00', time '11:00', array[v_lane1]
  );
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][TOUCH-OK]', v_base_date + 17,
    time '11:00', time '12:00', array[v_lane1]
  );
  insert into test_results values (
    25, 'Styk godzin jest dozwolony', v_result->>'code' = 'created',
    'Przedziały [start,end) mogą się stykać.'
  );

  perform pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][PARTIAL-BASE]', v_base_date + 18,
    time '10:00', time '12:00', array[v_lane1]
  );
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][PARTIAL-CONFLICT]', v_base_date + 18,
    time '11:00', time '13:00', array[v_lane1]
  );
  insert into test_results values (
    26, 'Częściowe nakładanie jest odrzucane',
    v_result->>'code' = 'event_conflict',
    'Częściowe nakładanie musi być konfliktem.'
  );

  perform pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][CONTAIN-BASE]', v_base_date + 19,
    time '10:00', time '14:00', array[v_lane1]
  );
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][CONTAIN-CONFLICT]', v_base_date + 19,
    time '11:00', time '12:00', array[v_lane1]
  );
  insert into test_results values (
    27, 'Pełne zawarcie jest odrzucane', v_result->>'code' = 'event_conflict',
    'Zawarty przedział musi być konfliktem.'
  );

  -- 28. Globalny -> osiowy.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][GLOBAL-TO-LANE]', v_base_date + 20,
    time '10:00', time '11:00', '{}'::uuid[]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  v_result := pg_temp.call_update(
    v_admin_id, v_event_id, '[TEST][5D-2][GLOBAL-TO-LANE]',
    v_base_date + 20, time '10:00', time '11:00', array[v_lane1]
  );
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id;
  insert into test_results values (
    28, 'Zmiana eventu globalnego na osiowy',
    v_result->>'code' = 'updated' and v_count = 1,
    'Update powinien dodać przypisanie osi.'
  );

  -- 29. Osiowy -> globalny.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][LANE-TO-GLOBAL]', v_base_date + 21,
    time '10:00', time '11:00', array[v_lane1]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  v_result := pg_temp.call_update(
    v_admin_id, v_event_id, '[TEST][5D-2][LANE-TO-GLOBAL]',
    v_base_date + 21, time '10:00', time '11:00', '{}'::uuid[]
  );
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id;
  insert into test_results values (
    29, 'Zmiana eventu osiowego na globalny',
    v_result->>'code' = 'updated' and v_count = 0,
    'Update powinien usunąć przypisania osi; NULL i pusta tablica są równoważne.'
  );

  v_result := pg_temp.call_update(
    v_admin_id, v_event_id, '[TEST][5D-2][LANE-TO-GLOBAL]',
    v_base_date + 21, time '10:00', time '11:00', null
  );
  update test_results
  set passed = passed and v_result->>'code' = 'no_change'
  where test_order = 29;

  -- 30-32. Dodawanie, usuwanie i no_change.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][UPDATE-LANES]', v_base_date + 22,
    time '10:00', time '11:00', array[v_lane1]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  v_result := pg_temp.call_update(
    v_admin_id, v_event_id, '[TEST][5D-2][UPDATE-LANES]',
    v_base_date + 22, time '10:00', time '11:00', array[v_lane1, v_lane2]
  );
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id;
  insert into test_results values (
    30, 'Dodanie drugiej osi', v_result->>'code' = 'updated' and v_count = 2,
    'Update powinien dodać drugą oś.'
  );

  v_result := pg_temp.call_update(
    v_admin_id, v_event_id, '[TEST][5D-2][UPDATE-LANES]',
    v_base_date + 22, time '10:00', time '11:00', array[v_lane2]
  );
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id and lane_id = v_lane2;
  insert into test_results values (
    31, 'Usunięcie jednej osi', v_result->>'code' = 'updated' and v_count = 1,
    'Zachowana oś nie powinna być przepisywana.'
  );

  select public.admin_update_event(
    v_event_id, '[TEST][5D-2][UPDATE-LANES]', null,
    v_base_date + 22, time '10:00', time '11:00', null,
    10, 10, array[v_lane1, v_lane2]
  ) into v_result;
  select public.admin_update_event(
    v_event_id, ' [TEST][5D-2][UPDATE-LANES] ', '   ',
    v_base_date + 22, time '10:00', time '11:00', '',
    10, 10, array[v_lane2, v_lane1]
  ) into v_result;
  insert into test_results values (
    32, 'Znormalizowany i przestawiony update zwraca no_change',
    v_result->>'code' = 'no_change' and not (v_result->>'changed')::boolean,
    'Kolejność osi, trim oraz pusty tekst i NULL nie mogą tworzyć pozornej zmiany.'
  );

  -- 33-35. Konflikt update i brak stanu częściowego.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][UPDATE-TARGET]', v_base_date + 23,
    time '08:00', time '09:00', array[v_lane2]
  );
  v_target_event_id := (v_result->>'event_id')::uuid;
  perform pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][UPDATE-BLOCKER]', v_base_date + 24,
    time '10:00', time '12:00', array[v_lane1]
  );
  v_result := pg_temp.call_update(
    v_admin_id, v_target_event_id, '[TEST][5D-2][UPDATE-CHANGED]',
    v_base_date + 24, time '10:30', time '11:30', array[v_lane1, v_lane2]
  );
  insert into test_results values (
    33, 'Update do konfliktu jest odrzucany', v_result->>'code' = 'event_conflict',
    'Konflikt na nowym zakresie musi zatrzymać update.'
  );

  select (
    event_record.title = '[TEST][5D-2][UPDATE-TARGET]'
    and event_record.event_date = v_base_date + 23
    and event_record.start_time = time '08:00'
    and event_record.end_time = time '09:00'
    and (
      select pg_catalog.count(*) = 1
      from public.event_lanes as event_lane
      where event_lane.event_id = v_target_event_id
        and event_lane.lane_id = v_lane2
    )
  )
  into v_passed
  from public.events as event_record
  where event_record.id = v_target_event_id;
  insert into test_results values (
    34, 'Konflikt update nie pozostawia częściowych zmian', v_passed,
    'Dane eventu i pełny zestaw osi muszą pozostać bez zmian.'
  );

  v_result := pg_temp.call_update(
    v_admin_id, v_target_event_id, '[TEST][5D-2][UPDATE-TARGET]',
    v_base_date + 23, time '08:00', time '09:00', array[v_lane2, v_lane4]
  );
  insert into test_results values (
    35, 'Nowo dodawana nieaktywna oś jest odrzucana',
    v_result->>'code' = 'inactive_lane',
    'Update nie może dodać nieaktywnej osi.'
  );

  -- 36. Istniejąca oś może później zostać zdezaktywowana.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][KEEP-INACTIVE]', v_base_date + 25,
    time '10:00', time '11:00', array[v_lane3]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  update public.shooting_lanes set is_active = false where id = v_lane3;
  v_result := pg_temp.call_update(
    v_admin_id, v_event_id, '[TEST][5D-2][KEEP-INACTIVE-UPDATED]',
    v_base_date + 25, time '10:00', time '11:00', array[v_lane3]
  );
  insert into test_results values (
    36, 'Zachowanie przypisanej nieaktywnej osi jest dozwolone',
    v_result->>'code' = 'updated',
    'Istniejące przypisanie nie jest nowym dodaniem osi.'
  );

  -- 37-40. Dezaktywacja, brak blokowania i reaktywacja.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][ACTIVE-FLOW]', v_base_date + 26,
    time '10:00', time '11:00', array[v_lane2]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  v_result := pg_temp.call_active(v_admin_id, v_event_id, false);
  select pg_catalog.count(*) into v_count
  from public.event_lanes where event_id = v_event_id and lane_id = v_lane2;
  insert into test_results values (
    37, 'Dezaktywacja zachowuje event_lanes',
    v_result->>'code' = 'deactivated' and v_count = 1,
    'Dezaktywacja zmienia wyłącznie is_active.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][AFTER-DEACTIVATE]', v_base_date + 26,
    time '10:30', time '11:30', array[v_lane2]
  );
  v_event_id2 := (v_result->>'event_id')::uuid;
  insert into test_results values (
    38, 'Dezaktywowany event nie blokuje drugiego eventu',
    v_result->>'code' = 'created',
    'Nieaktywny event nie uczestniczy w konflikcie.'
  );

  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][REACTIVATE-OK]', v_base_date + 27,
    time '10:00', time '11:00', array[v_lane5]
  );
  v_target_event_id := (v_result->>'event_id')::uuid;
  perform pg_temp.call_active(v_admin_id, v_target_event_id, false);
  v_result := pg_temp.call_active(v_admin_id, v_target_event_id, true);
  insert into test_results values (
    39, 'Ponowna aktywacja bez konfliktu działa',
    v_result->>'code' = 'activated' and (v_result->>'changed')::boolean,
    'Brak konfliktu pozwala reaktywować event.'
  );

  v_result := pg_temp.call_active(v_admin_id, v_event_id, true);
  insert into test_results values (
    40, 'Ponowna aktywacja z konfliktem jest odrzucana',
    v_result->>'code' = 'event_conflict',
    'Drugi aktywny event na osi musi zablokować reaktywację.'
  );

  -- 41. Aktywacja na osi zdezaktywowanej później.
  update public.shooting_lanes set is_active = true where id = v_lane4;
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][REACTIVATE-INACTIVE-LANE]', v_base_date + 28,
    time '10:00', time '11:00', array[v_lane4]
  );
  v_event_id := (v_result->>'event_id')::uuid;
  perform pg_temp.call_active(v_admin_id, v_event_id, false);
  update public.shooting_lanes set is_active = false where id = v_lane4;
  v_result := pg_temp.call_active(v_admin_id, v_event_id, true);
  insert into test_results values (
    41, 'Aktywacja na nieaktywnej osi jest odrzucana',
    v_result->>'code' = 'inactive_lane',
    'Reaktywacja wymaga aktywności wszystkich osi.'
  );

  v_result := pg_temp.call_active(v_admin_id, v_target_event_id, true);
  v_passed := v_result->>'code' = 'no_change'
    and not (v_result->>'changed')::boolean;
  v_result := pg_temp.call_active(v_admin_id, pg_catalog.gen_random_uuid(), true);
  insert into test_results values (
    42, 'Set active zwraca no_change i event_not_found',
    v_passed and v_result->>'code' = 'event_not_found',
    'Idempotentna zmiana nie zapisuje, a brak eventu ma kontrolowany kod.'
  );

  -- 43. Konflikt na jednej osi wycofuje cały create.
  perform pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][ATOMIC-CREATE-BLOCKER]', v_base_date + 30,
    time '10:00', time '12:00', array[v_lane1]
  );
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][ATOMIC-CREATE]', v_base_date + 30,
    time '10:30', time '11:30', array[v_lane1, v_lane2]
  );
  select pg_catalog.count(*) into v_count
  from public.events where title = '[TEST][5D-2][ATOMIC-CREATE]';
  insert into test_results values (
    43, 'Konflikt jednej osi wycofuje cały create',
    v_result->>'code' = 'event_conflict' and v_count = 0,
    'Nie może pozostać event ani częściowe event_lanes.'
  );

  -- 44. Konflikt na jednej osi wycofuje cały update.
  v_result := pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][ATOMIC-UPDATE-TARGET]', v_base_date + 31,
    time '08:00', time '09:00', array[v_lane2]
  );
  v_target_event_id := (v_result->>'event_id')::uuid;
  perform pg_temp.call_create(
    v_admin_id, '[TEST][5D-2][ATOMIC-UPDATE-BLOCKER]', v_base_date + 32,
    time '10:00', time '12:00', array[v_lane1]
  );
  v_result := pg_temp.call_update(
    v_admin_id, v_target_event_id, '[TEST][5D-2][ATOMIC-UPDATE-CHANGED]',
    v_base_date + 32, time '10:30', time '11:30', array[v_lane1, v_lane2]
  );
  select (
    event_record.title = '[TEST][5D-2][ATOMIC-UPDATE-TARGET]'
    and event_record.event_date = v_base_date + 31
    and (
      select pg_catalog.count(*) = 1
      from public.event_lanes as event_lane
      where event_lane.event_id = v_target_event_id
        and event_lane.lane_id = v_lane2
    )
  ) into v_passed
  from public.events as event_record
  where event_record.id = v_target_event_id;
  insert into test_results values (
    44, 'Konflikt jednej osi wycofuje cały update',
    v_result->>'code' = 'event_conflict' and v_passed,
    'Event i zestaw osi muszą pozostać atomowo bez zmian.'
  );

  -- 45. Wszystkie obiekty i dane pozostają w transakcji gotowej do rollbacku.
  insert into test_results values (
    45,
    'Gotowość do końcowego ROLLBACK',
    pg_catalog.to_regprocedure(
      'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ) is not null
    and pg_catalog.to_regprocedure(
      'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ) is not null
    and pg_catalog.to_regprocedure(
      'public.admin_set_event_active(uuid,boolean)'
    ) is not null
    and exists (
      select 1 from public.events where title like '[TEST][5D-2]%'
    ),
    'Migracja i dane syntetyczne są objęte otwartą transakcją.'
  );
end;
$contract_tests$;

select test_order, test_name, passed, result
from test_results
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
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Admin event RPC tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

do $rollback_assertions$
begin
  if not (
    pg_catalog.to_regprocedure(
    'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ) is null
    and pg_catalog.to_regprocedure(
    'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
    ) is null
    and pg_catalog.to_regprocedure(
    'public.admin_set_event_active(uuid,boolean)'
    ) is null
    and not exists (
      select 1 from public.events where title like '[TEST][5D-2]%'
    )
    and not exists (
      select 1 from public.shooting_lanes where name like '[TEST][5D-2]%'
    )
    and not exists (
      select 1 from public.lane_blocks where reason = '[TEST][5D-2]'
    )
    and not exists (
      select 1 from public.reservations where customer_name = '[TEST][5D-2]'
    )
    and not exists (
      select 1 from auth.users where email like '[TEST]-5d2-%@example.invalid'
    )
  ) then
    raise exception 'ROLLBACK nie przywrócił stanu sprzed testu.';
  end if;
end;
$rollback_assertions$;

select true as rollback_confirmed;
