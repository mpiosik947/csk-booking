begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
);

create function pg_temp.record_result(
  p_order integer,
  p_name text,
  p_passed boolean,
  p_result text
)
returns void
language sql
as $function$
  insert into test_results(test_order, test_name, passed, result)
  values (p_order, p_name, p_passed, p_result);
$function$;

create function pg_temp.call_create_reservation(
  p_user_id uuid,
  p_lane_id uuid,
  p_date date,
  p_time time without time zone,
  p_duration integer,
  p_shooters integer,
  p_request_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );

  return public.create_reservation(
    p_lane_id,
    p_date,
    p_time,
    p_duration,
    p_shooters,
    p_request_id,
    p_note
  );
end;
$function$;

do $tests$
declare
  v_lane_1 uuid := pg_catalog.gen_random_uuid();
  v_lane_2 uuid := pg_catalog.gen_random_uuid();
  v_lane_inactive uuid := pg_catalog.gen_random_uuid();
  v_rule_1 uuid;
  v_rule_1_weekend uuid;
  v_rule_2 uuid;
  v_user_1 uuid := pg_catalog.gen_random_uuid();
  v_user_2 uuid := pg_catalog.gen_random_uuid();
  v_user_3 uuid := pg_catalog.gen_random_uuid();
  v_admin uuid := pg_catalog.gen_random_uuid();
  v_missing_profile uuid := pg_catalog.gen_random_uuid();
  v_request_1 uuid := pg_catalog.gen_random_uuid();
  v_request_2 uuid := pg_catalog.gen_random_uuid();
  v_request_3 uuid := pg_catalog.gen_random_uuid();
  v_date date := date '2030-07-22';
  v_result jsonb;
  v_monday_result jsonb;
  v_thursday_result jsonb;
  v_friday_result jsonb;
  v_saturday_result jsonb;
  v_sunday_result jsonb;
  v_friday_request_id uuid := pg_catalog.gen_random_uuid();
  v_created_id uuid;
  v_second_id uuid;
  v_direct_blocked boolean;
  v_busy_reservation_visible boolean;
  v_busy_block_visible boolean;
  v_count integer;
  v_audit_count integer;
begin
  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code
  )
  values
    (v_lane_1, '[TEST] RPC oś 1', '[TEST]', '[TEST]', 0, true, 5, 30, 1, 'PLN'),
    (v_lane_2, '[TEST] RPC oś 2', '[TEST]', '[TEST]', 0, true, 5, 60, 2, 'PLN'),
    (v_lane_inactive, '[TEST] RPC nieaktywna', '[TEST]', '[TEST]', 0, false, 2, 60, 3, 'PLN');

  insert into public.lane_booking_durations (
    lane_id, duration_minutes, display_order
  )
  values
    (v_lane_1, 60, 1),
    (v_lane_1, 120, 2),
    (v_lane_2, 60, 1),
    (v_lane_2, 120, 2),
    (v_lane_inactive, 60, 1);

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters, label, hourly_price, display_order
  )
  values
    (v_lane_1, 'mon_thu', 1, 4, '[TEST] 1-4', 100, 1)
    returning id into v_rule_1;

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters, label, hourly_price, display_order
  )
  values
    (v_lane_1, 'fri_sun', 1, 4, '[TEST] weekend 1-4', 130, 1)
    returning id into v_rule_1_weekend;

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters, label, hourly_price, display_order
  )
  values
    (v_lane_2, 'mon_thu', 1, 5, '[TEST] druga oś', 80, 1)
    returning id into v_rule_2;

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters, label, hourly_price, display_order
  )
  values
    (v_lane_inactive, 'mon_thu', 1, 2, '[TEST] nieaktywna', 50, 1);

  insert into public.lane_blocks (
    lane_id, block_date, start_time, end_time, reason, is_active
  )
  values (v_lane_1, v_date, time '14:00', time '15:00', '[TEST]', true);

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  )
  values
    (v_user_1, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-rpc-1@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb,
     '{"first_name":"Test","last_name":"Pierwszy","phone":"111"}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_user_2, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-rpc-2@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb,
     '{"first_name":"Test","last_name":"Drugi","phone":"222"}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_user_3, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-rpc-3@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb,
     '{"first_name":"Test","last_name":"Trzeci","phone":"333"}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_admin, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-rpc-admin@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb,
     '{"first_name":"Test","last_name":"Admin","phone":"444"}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp());

  update public.profiles
  set first_name = 'Test',
      last_name = case user_id
        when v_user_1 then 'Pierwszy'
        when v_user_2 then 'Drugi'
        when v_user_3 then 'Trzeci'
        else 'Admin'
      end,
      full_name = '[TEST]',
      phone = '123456789',
      verification_status = 'verified',
      role = case when user_id = v_admin then 'admin' else 'user' end
  where user_id in (v_user_1, v_user_2, v_user_3, v_admin);

  perform pg_catalog.set_config('request.jwt.claims', '{}', true);
  v_result := public.create_reservation(
    v_lane_1, v_date, time '08:00', 60, 1,
    pg_catalog.gen_random_uuid(), null
  );
  perform pg_temp.record_result(
    1, 'Brak sesji', v_result->>'code' = 'unauthorized',
    'Oczekiwano unauthorized.'
  );

  v_result := pg_temp.call_create_reservation(
    v_missing_profile, v_lane_1, v_date, time '08:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    2, 'Brak profilu', v_result->>'code' = 'profile_not_found',
    'Oczekiwano profile_not_found.'
  );

  v_result := pg_temp.call_create_reservation(
    v_admin, v_lane_1, v_date, time '08:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    3, 'Rola inna niż user', v_result->>'code' = 'not_allowed',
    'Oczekiwano not_allowed.'
  );

  update public.profiles
  set verification_status = 'rejected'
  where user_id = v_user_3;
  v_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, v_date, time '08:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    4, 'Profil rejected', v_result->>'code' = 'profile_rejected',
    'Oczekiwano profile_rejected.'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text,
    true
  );
  update public.profiles
  set verification_status = 'verified', phone = null
  where user_id = v_user_3;
  v_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, v_date, time '08:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    5, 'Niekompletny profil', v_result->>'code' = 'profile_incomplete',
    'Oczekiwano profile_incomplete.'
  );
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text,
    true
  );
  update public.profiles set phone = '333' where user_id = v_user_3;

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_inactive, v_date, time '08:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    6, 'Nieaktywna oś', v_result->>'code' = 'lane_inactive',
    'Oczekiwano lane_inactive.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '08:00', 60, 0,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    7, 'Nieprawidłowa liczba strzelców',
    v_result->>'code' = 'invalid_shooters_count',
    'Oczekiwano invalid_shooters_count.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '08:00', 60, 6,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    8, 'Przekroczona pojemność',
    v_result->>'code' = 'capacity_exceeded',
    'Oczekiwano capacity_exceeded.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '08:00', 90, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    9, 'Niedozwolona długość', v_result->>'code' = 'invalid_duration',
    'Oczekiwano invalid_duration.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '08:00', 60, 5,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    10, 'Brak reguły cenowej',
    v_result->>'code' = 'pricing_not_configured',
    'Oczekiwano pricing_not_configured.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '07:30', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    11, 'Godzina poza zakresem',
    v_result->>'code' = 'outside_booking_hours',
    'Oczekiwano outside_booking_hours.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '08:15', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    12, 'Zły booking step', v_result->>'code' = 'invalid_start_time',
    'Oczekiwano invalid_start_time.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, current_date - 1, time '08:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    13, 'Termin w przeszłości',
    v_result->>'code' = 'reservation_already_started',
    'Oczekiwano reservation_already_started.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '14:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    14, 'Aktywna blokada osi', v_result->>'code' = 'lane_blocked',
    'Oczekiwano lane_blocked.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '10:00', 120, 2,
    v_request_1, '  test   note  '
  );
  v_created_id := (v_result->>'reservation_id')::uuid;
  perform pg_temp.record_result(
    15, 'Poprawne utworzenie',
    v_result->>'code' = 'created' and (v_result->>'changed')::boolean,
    'Oczekiwano created i changed=true.'
  );

  select pg_catalog.count(*)
  into v_count
  from public.reservations
  where id = v_created_id
    and lane_name_snapshot = '[TEST] RPC oś 1'
    and pricing_label_snapshot = '[TEST] 1-4'
    and pricing_day_group_snapshot = 'mon_thu'
    and pricing_rule_id = v_rule_1
    and shooters_count = 2
    and duration_minutes = 120;
  perform pg_temp.record_result(
    16, 'Poprawne snapshoty', v_count = 1,
    'Snapshoty powinny pochodzić z konfiguracji DB.'
  );

  perform pg_temp.record_result(
    17, 'Cena obliczona przez bazę',
    (v_result->>'total_price')::numeric = 200.00
    and v_result->>'pricing_day_group' = 'mon_thu'
    and (v_result->>'price_per_hour')::numeric = 100.00,
    'Oczekiwano 100/h i 200 łącznie.'
  );

  select pg_catalog.count(*) into v_count
  from public.reservations
  where id = v_created_id and price = total_price and total_price = 200.00;
  perform pg_temp.record_result(
    18, 'Legacy price równe total_price', v_count = 1,
    'Oczekiwano price=total_price.'
  );

  select pg_catalog.count(*) into v_count
  from public.reservations
  where id = v_created_id
    and reservation_status = 'confirmed'
    and payment_status = 'pay_on_site'
    and attendance_status = 'planned';
  perform pg_temp.record_result(
    19, 'Statusy ustalone przez DB', v_count = 1,
    'Oczekiwano confirmed/pay_on_site/planned.'
  );

  select pg_catalog.count(*) into v_count
  from public.reservations
  where id = v_created_id and check_in_token is not null;
  perform pg_temp.record_result(
    20, 'Token check-in pochodzi z defaultu', v_count = 1,
    'Oczekiwano niepustego check_in_token.'
  );

  select pg_catalog.count(*) into v_audit_count
  from public.audit_logs
  where target_id = v_created_id
    and action = 'reservation_created';
  perform pg_temp.record_result(
    21, 'Audit utworzony dokładnie raz', v_audit_count = 1,
    'Oczekiwano jednego reservation_created.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '10:00', 120, 2,
    v_request_1, 'test note'
  );
  perform pg_temp.record_result(
    22, 'Identyczny retry',
    v_result->>'code' = 'already_created'
    and not (v_result->>'changed')::boolean
    and v_result->>'pricing_day_group' = 'mon_thu'
    and (v_result->>'reservation_id')::uuid = v_created_id,
    'Oczekiwano already_created tego samego rekordu.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_1, v_lane_1, v_date, time '10:00', 60, 2,
    v_request_1, 'test note'
  );
  perform pg_temp.record_result(
    23, 'Retry z innymi parametrami',
    v_result->>'code' = 'idempotency_conflict',
    'Oczekiwano idempotency_conflict.'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text,
    true
  );
  update public.profiles
  set verification_status = 'pending'
  where user_id = v_user_2;
  v_result := pg_temp.call_create_reservation(
    v_user_2, v_lane_1, v_date, time '12:00', 60, 1,
    v_request_2
  );
  v_second_id := (v_result->>'reservation_id')::uuid;
  v_result := pg_temp.call_create_reservation(
    v_user_2, v_lane_2, v_date, time '16:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    24, 'Limit nieweryfikowanego profilu',
    v_result->>'code' = 'verification_limit_reached',
    'Oczekiwano verification_limit_reached.'
  );

  update public.reservations
  set reservation_status = 'cancelled'
  where id = v_second_id;
  v_result := pg_temp.call_create_reservation(
    v_user_2, v_lane_2, v_date, time '16:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    25, 'Anulowana rezerwacja nie blokuje limitu',
    v_result->>'code' = 'created',
    'Oczekiwano created po anulowaniu poprzedniej.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, v_date, time '11:00', 60, 1,
    v_request_3
  );
  perform pg_temp.record_result(
    26, 'Nakładający termin',
    v_result->>'code' = 'slot_unavailable',
    'Oczekiwano slot_unavailable.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, v_date, time '12:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    27, 'Stykający termin przechodzi', v_result->>'code' = 'created',
    'Przedziały półotwarte mogą stykać się o 12:00.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_2, v_date, time '10:00', 60, 1,
    pg_catalog.gen_random_uuid()
  );
  perform pg_temp.record_result(
    28, 'Ta sama pora na innej osi przechodzi',
    v_result->>'code' = 'created',
    'Oczekiwano created na drugiej osi.'
  );

  v_direct_blocked := false;
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_user_1, 'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  begin
    insert into public.reservations (
      user_id, lane_id, customer_name, customer_email, customer_phone,
      reservation_date, start_time, end_time, duration_minutes, price,
      reservation_status, payment_status, check_in_token, shooters_count,
      pricing_rule_id, pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
      price_per_hour_snapshot, total_price, currency_code, creation_request_id
    )
    values (
      v_user_1, v_lane_2, '[TEST]', '[TEST]@example.invalid', '[TEST]',
      v_date, time '18:00', time '19:00', 60, 80,
      'confirmed', 'pay_on_site', pg_catalog.gen_random_uuid(), 1,
      v_rule_2, 'mon_thu', '[TEST]', '[TEST]', 80, 80, 'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when insufficient_privilege then
      v_direct_blocked := true;
  end;
  execute 'reset role';
  perform pg_temp.record_result(
    29, 'Direct INSERT usera zabroniony', v_direct_blocked,
    'Oczekiwano braku INSERT dla authenticated.'
  );

  v_direct_blocked := false;
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_admin, 'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  begin
    insert into public.reservations (
      user_id, lane_id, customer_name, customer_email, customer_phone,
      reservation_date, start_time, end_time, duration_minutes, price,
      reservation_status, payment_status, check_in_token, shooters_count,
      pricing_rule_id, pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
      price_per_hour_snapshot, total_price, currency_code, creation_request_id
    )
    values (
      v_admin, v_lane_2, '[TEST]', '[TEST]@example.invalid', '[TEST]',
      v_date, time '18:00', time '19:00', 60, 80,
      'confirmed', 'pay_on_site', pg_catalog.gen_random_uuid(), 1,
      v_rule_2, 'mon_thu', '[TEST]', '[TEST]', 80, 80, 'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when insufficient_privilege then
      v_direct_blocked := true;
  end;
  execute 'reset role';
  perform pg_temp.record_result(
    30, 'Direct INSERT admina zabroniony', v_direct_blocked,
    'Personel również nie powinien mieć bezpośredniego INSERT.'
  );

  perform pg_temp.record_result(
    31, 'authenticated ma EXECUTE na RPC',
    pg_catalog.has_function_privilege(
      'authenticated',
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    ),
    'Oczekiwano EXECUTE dla authenticated.'
  );

  perform pg_temp.record_result(
    32, 'anon i PUBLIC nie mają EXECUTE',
    not pg_catalog.has_function_privilege(
      'anon',
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'public',
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)',
      'EXECUTE'
    ),
    'Oczekiwano braku EXECUTE dla anon i PUBLIC.'
  );

  perform pg_temp.record_result(
    33, 'Stary trigger weryfikacji usunięty',
    not exists (
      select 1
      from pg_catalog.pg_trigger
      where tgrelid = 'public.reservations'::pg_catalog.regclass
        and tgname = 'prevent_unverified_reservation_trigger'
        and not tgisinternal
    ),
    'Nie może pozostać konkurencyjny trigger.'
  );

  select pg_catalog.count(*) into v_count
  from pg_catalog.pg_trigger
  where not tgisinternal
    and tgname in (
      'lock_lane_blocks_configuration',
      'lock_lane_booking_durations_configuration',
      'lock_lane_pricing_rules_configuration'
    );
  perform pg_temp.record_result(
    34, 'Trzy triggery konfiguracji istnieją', v_count = 3,
    'Oczekiwano triggerów na blokadach, długościach i cenach.'
  );

  select pg_catalog.count(*) into v_count
  from public.audit_logs
  where target_id = v_created_id
    and action = 'reservation_created';
  perform pg_temp.record_result(
    35, 'Retry nie tworzy drugiego auditu', v_count = 1,
    'Oczekiwano nadal jednego auditu.'
  );

  select pg_catalog.count(*) into v_count
  from public.audit_logs
  where target_id = v_created_id
    and (
      details::text ilike '%@example.invalid%'
      or details ? 'email'
      or details ? 'phone'
      or details ? 'customer_name'
    );
  perform pg_temp.record_result(
    36, 'Audit nie zawiera PII', v_count = 0,
    'Details powinno zawierać tylko dane techniczne.'
  );

  v_direct_blocked := false;
  begin
    insert into public.lane_blocks (
      lane_id, block_date, start_time, end_time, reason, is_active
    )
    values (
      v_lane_1, v_date, time '10:30', time '11:30', '[TEST] conflict', true
    );
  exception
    when exclusion_violation then
      v_direct_blocked := true;
  end;
  perform pg_temp.record_result(
    37, 'Lane block nie może przykryć aktywnej rezerwacji',
    v_direct_blocked,
    'Oczekiwano kontrolowanego 23P01.'
  );

  perform pg_temp.record_result(
    38, 'Brak polityk INSERT reservations',
    not exists (
      select 1
      from pg_catalog.pg_policy
      where polrelid = 'public.reservations'::pg_catalog.regclass
        and polcmd = 'a'
    ),
    'Nie może pozostać polityka INSERT.'
  );

  perform pg_temp.record_result(
    39, 'authenticated i anon bez tabelowego INSERT',
    not pg_catalog.has_table_privilege(
      'authenticated', 'public.reservations', 'INSERT'
    )
    and not pg_catalog.has_table_privilege(
      'anon', 'public.reservations', 'INSERT'
    ),
    'Oczekiwano REVOKE INSERT.'
  );

  select pg_catalog.count(*) into v_count
  from public.reservations
  where user_id = v_user_1 and creation_request_id = v_request_1;
  perform pg_temp.record_result(
    40, 'Idempotencja pozostawia jeden rekord', v_count = 1,
    'Oczekiwano dokładnie jednego rekordu request_id.'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_user_2, 'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select
    pg_catalog.bool_or(
      busy.start_time = time '10:00'
      and busy.end_time = time '12:00'
    ),
    pg_catalog.bool_or(
      busy.start_time = time '14:00'
      and busy.end_time = time '15:00'
    )
  into v_busy_reservation_visible, v_busy_block_visible
  from public.get_lane_booking_busy_ranges(v_lane_1, v_date) as busy;
  execute 'reset role';

  perform pg_temp.record_result(
    41, 'Podgląd pokazuje cudzą rezerwację i blokadę',
    coalesce(v_busy_reservation_visible, false)
      and coalesce(v_busy_block_visible, false),
    'Oczekiwano obu zajętych przedziałów bez odczytu rekordu klienta.'
  );

  perform pg_temp.record_result(
    42, 'ACL podglądu tylko dla authenticated',
    pg_catalog.has_function_privilege(
      'authenticated',
      'public.get_lane_booking_busy_ranges(uuid,date)',
      'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon',
      'public.get_lane_booking_busy_ranges(uuid,date)',
      'EXECUTE'
    )
    and not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )
      ) as privilege_record
      where function_record.oid =
        'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure
        and privilege_record.grantee = 0
        and privilege_record.privilege_type = 'EXECUTE'
    ),
    'authenticated powinien mieć EXECUTE, a anon i PUBLIC nie.'
  );

  perform pg_temp.record_result(
    43, 'Podgląd dostępności nie odwołuje się do PII',
    pg_catalog.lower(
      pg_catalog.pg_get_functiondef(
        'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure
      )
    ) !~ 'customer_|email|phone|full_name',
    'Funkcja powinna zwracać wyłącznie przedziały czasu.'
  );

  v_monday_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, date '2030-07-29', time '08:00', 60, 2,
    pg_catalog.gen_random_uuid()
  );
  v_thursday_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, date '2030-07-25', time '08:00', 60, 2,
    pg_catalog.gen_random_uuid()
  );
  v_friday_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, date '2030-07-26', time '08:00', 60, 2,
    v_friday_request_id
  );
  v_saturday_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, date '2030-07-27', time '08:00', 60, 2,
    pg_catalog.gen_random_uuid()
  );
  v_sunday_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, date '2030-07-28', time '08:00', 60, 2,
    pg_catalog.gen_random_uuid()
  );

  perform pg_temp.record_result(
    44, 'Poniedziałek wybiera mon_thu',
    v_monday_result->>'code' = 'created'
      and v_monday_result->>'pricing_day_group' = 'mon_thu',
    'Stała data 2030-07-29 powinna użyć mon_thu.'
  );
  perform pg_temp.record_result(
    45, 'Czwartek wybiera mon_thu',
    v_thursday_result->>'code' = 'created'
      and v_thursday_result->>'pricing_day_group' = 'mon_thu',
    'Stała data 2030-07-25 powinna użyć mon_thu.'
  );
  perform pg_temp.record_result(
    46, 'Piątek wybiera fri_sun',
    v_friday_result->>'code' = 'created'
      and v_friday_result->>'pricing_day_group' = 'fri_sun',
    'Stała data 2030-07-26 powinna użyć fri_sun.'
  );
  perform pg_temp.record_result(
    47, 'Sobota wybiera fri_sun',
    v_saturday_result->>'code' = 'created'
      and v_saturday_result->>'pricing_day_group' = 'fri_sun',
    'Stała data 2030-07-27 powinna użyć fri_sun.'
  );
  perform pg_temp.record_result(
    48, 'Niedziela wybiera fri_sun',
    v_sunday_result->>'code' = 'created'
      and v_sunday_result->>'pricing_day_group' = 'fri_sun',
    'Stała data 2030-07-28 powinna użyć fri_sun.'
  );
  perform pg_temp.record_result(
    49, 'Cena zależy od grupy dnia',
    (v_monday_result->>'price_per_hour')::numeric = 100
      and (v_friday_result->>'price_per_hour')::numeric = 130
      and (v_monday_result->>'total_price')::numeric
          <> (v_friday_result->>'total_price')::numeric,
    'Ten sam wariant powinien kosztować 100 w mon_thu i 130 w fri_sun.'
  );
  perform pg_temp.record_result(
    50, 'Snapshot zapisuje grupę dnia',
    exists (
      select 1
      from public.reservations
      where id = (v_friday_result->>'reservation_id')::uuid
        and pricing_rule_id = v_rule_1_weekend
        and pricing_day_group_snapshot = 'fri_sun'
        and price_per_hour_snapshot = 130
    ),
    'Rezerwacja piątkowa powinna zachować snapshot fri_sun.'
  );

  update public.lane_pricing_rules
  set hourly_price = 140
  where id = v_rule_1_weekend;
  v_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, date '2030-07-26', time '08:00', 60, 2,
    v_friday_request_id
  );
  perform pg_temp.record_result(
    51, 'Idempotentny retry zwraca zapisany snapshot',
    v_result->>'code' = 'already_created'
      and v_result->>'pricing_day_group' = 'fri_sun'
      and (v_result->>'price_per_hour')::numeric = 130,
    'Retry nie może przeliczać istniejącej rezerwacji po zmianie cennika.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_3, v_lane_1, date '2030-07-25', time '08:00', 60, 2,
    v_friday_request_id
  );
  perform pg_temp.record_result(
    52, 'Ta sama próba z inną datą jest konfliktem',
    v_result->>'code' = 'idempotency_conflict',
    'Zmiana piątku na czwartek przy tym samym request ID ma być odrzucona.'
  );
  perform pg_temp.record_result(
    53, 'Granica czwartek-piątek zmienia taryfę',
    v_thursday_result->>'pricing_day_group' = 'mon_thu'
      and v_friday_result->>'pricing_day_group' = 'fri_sun'
      and (v_thursday_result->>'price_per_hour')::numeric = 100
      and (v_friday_result->>'price_per_hour')::numeric = 130,
    'Daty 2030-07-25 i 2030-07-26 muszą użyć różnych taryf.'
  );
end;
$tests$;

select test_order, test_name, passed, result
from test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', '
    order by test_order
  )
  into v_failures
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Atomic reservation tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
