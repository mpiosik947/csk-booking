-- Test przeznaczony wyłącznie dla lokalnej bazy odtwarzającej pełny schemat.
-- Wymaga wcześniejszego zastosowania migracji
-- 20260724071150_add_configurable_lane_booking_foundation.sql.
-- Całość działa w transakcji zakończonej ROLLBACK.

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

do $catalog_tests$
declare
  v_passed boolean;
begin
  select
    pg_catalog.to_regclass('public.lane_booking_durations') is not null
    and pg_catalog.to_regclass('public.lane_pricing_rules') is not null
  into v_passed;

  insert into test_results
  values (
    1,
    'Nowe tabele istnieją',
    v_passed,
    'Oczekiwano lane_booking_durations i lane_pricing_rules.'
  );

  select not exists (
    select 1
    from public.shooting_lanes
    where is_active
  )
  into v_passed;

  insert into test_results
  values (
    2,
    'Wszystkie osie są nieaktywne',
    v_passed,
    'Migracja nie może automatycznie aktywować osi.'
  );

  select exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.lane_pricing_rules'::pg_catalog.regclass
      and conname = 'lane_pricing_rules_active_ranges_excl'
      and contype = 'x'
  )
  into v_passed;

  insert into test_results
  values (
    3,
    'Exclusion constraint cennika istnieje',
    v_passed,
    'Aktywne zakresy liczby strzelców nie mogą się nakładać.'
  );

  select exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.reservations'::pg_catalog.regclass
      and conname = 'reservations_no_overlapping_active_booking'
      and contype = 'x'
  )
  into v_passed;

  insert into test_results
  values (
    4,
    'Exclusion constraint rezerwacji istnieje',
    v_passed,
    'Aktywne rezerwacje tej samej osi nie mogą się nakładać.'
  );

  select
    pg_catalog.has_table_privilege(
      'anon',
      'public.lane_booking_durations',
      'SELECT'
    )
    and not pg_catalog.has_table_privilege(
      'anon',
      'public.lane_booking_durations',
      'INSERT'
    )
    and pg_catalog.has_table_privilege(
      'anon',
      'public.lane_pricing_rules',
      'SELECT'
    )
    and not pg_catalog.has_table_privilege(
      'anon',
      'public.lane_pricing_rules',
      'UPDATE'
    )
  into v_passed;

  insert into test_results
  values (
    5,
    'ACL anon jest tylko do odczytu',
    v_passed,
    'anon ma SELECT i nie ma praw zapisu konfiguracji.'
  );

  select
    pg_catalog.has_table_privilege(
      'authenticated',
      'public.lane_booking_durations',
      'SELECT,INSERT,UPDATE,DELETE'
    )
    and pg_catalog.has_table_privilege(
      'authenticated',
      'public.lane_pricing_rules',
      'SELECT,INSERT,UPDATE,DELETE'
    )
  into v_passed;

  insert into test_results
  values (
    6,
    'ACL authenticated podlega RLS',
    v_passed,
    'authenticated ma granty, a zapis ograniczają polityki RLS.'
  );

  select
    (
      select pg_catalog.count(*)
      from pg_catalog.pg_policies
      where schemaname = 'public'
        and tablename = 'lane_booking_durations'
    ) = 2
    and (
      select pg_catalog.count(*)
      from pg_catalog.pg_policies
      where schemaname = 'public'
        and tablename = 'lane_pricing_rules'
    ) = 2
  into v_passed;

  insert into test_results
  values (
    7,
    'Polityki RLS nowych tabel istnieją',
    v_passed,
    'Każda tabela powinna mieć politykę odczytu i zarządzania.'
  );

  select exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and policyname = 'Users can insert own reservations'
  )
  into v_passed;

  insert into test_results
  values (
    8,
    'Legacy INSERT policy pozostaje',
    v_passed,
    'Polityka zostanie usunięta dopiero po przełączeniu frontendu na RPC.'
  );
end;
$catalog_tests$;

do $constraint_tests$
declare
  v_lane_id uuid := pg_catalog.gen_random_uuid();
  v_second_lane_id uuid := pg_catalog.gen_random_uuid();
  v_rule_id uuid;
  v_second_rule_id uuid;
  v_other_lane_rule_id uuid;
  v_user_id uuid := pg_catalog.gen_random_uuid();
  v_second_user_id uuid := pg_catalog.gen_random_uuid();
  v_admin_user_id uuid := pg_catalog.gen_random_uuid();
  v_employee_user_id uuid := pg_catalog.gen_random_uuid();
  v_instructor_user_id uuid := pg_catalog.gen_random_uuid();
  v_reservation_id uuid;
  v_creation_request_id uuid := pg_catalog.gen_random_uuid();
  v_rejected boolean;
  v_duration_rejected boolean;
  v_pricing_rejected boolean;
  v_visible_count integer;
begin
  insert into public.shooting_lanes (
    id,
    name,
    type,
    description,
    price_per_hour,
    is_active,
    max_shooters,
    booking_step_minutes,
    display_order,
    currency_code
  )
  values
    (
      v_lane_id,
      '[TEST] Oś 1',
      '[TEST]',
      '[TEST]',
      0,
      false,
      5,
      60,
      1,
      'PLN'
    ),
    (
      v_second_lane_id,
      '[TEST] Oś 2',
      '[TEST]',
      '[TEST]',
      0,
      false,
      5,
      60,
      2,
      'PLN'
    );

  insert into public.lane_booking_durations (
    lane_id,
    duration_minutes,
    display_order
  )
  values (v_lane_id, 60, 1);

  v_rejected := false;
  begin
    insert into public.lane_booking_durations (
      lane_id,
      duration_minutes
    )
    values (v_lane_id, 60);
  exception
    when unique_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    9,
    'Duplikat długości osi jest odrzucony',
    v_rejected,
    'Oczekiwano UNIQUE(lane_id,duration_minutes).'
  );

  v_rejected := false;
  begin
    insert into public.lane_booking_durations (
      lane_id,
      duration_minutes
    )
    values (v_lane_id, 0);
  exception
    when check_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    10,
    'Niedodatnia długość jest odrzucona',
    v_rejected,
    'Oczekiwano CHECK duration_minutes > 0.'
  );

  v_rejected := false;
  begin
    insert into public.lane_pricing_rules (
      lane_id,
      min_shooters,
      max_shooters,
      label,
      hourly_price
    )
    values (v_lane_id, 0, 1, '[TEST]', 10);
  exception
    when check_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    11,
    'min_shooters poniżej 1 jest odrzucone',
    v_rejected,
    'Oczekiwano CHECK min_shooters >= 1.'
  );

  v_rejected := false;
  begin
    insert into public.lane_pricing_rules (
      lane_id,
      min_shooters,
      max_shooters,
      label,
      hourly_price
    )
    values (v_lane_id, 3, 2, '[TEST]', 10);
  exception
    when check_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    12,
    'Odwrócony zakres cennika jest odrzucony',
    v_rejected,
    'Oczekiwano max_shooters >= min_shooters.'
  );

  insert into public.lane_pricing_rules (
    lane_id,
    min_shooters,
    max_shooters,
    label,
    hourly_price,
    display_order
  )
  values (v_lane_id, 1, 2, '[TEST] 1-2', 50, 1)
  returning id into v_rule_id;

  v_rejected := false;
  begin
    insert into public.lane_pricing_rules (
      lane_id,
      min_shooters,
      max_shooters,
      label,
      hourly_price
    )
    values (v_lane_id, 2, 3, '[TEST] overlap', 70);
  exception
    when exclusion_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    13,
    'Nakładający zakres cennika jest odrzucony',
    v_rejected,
    'Aktywne zakresy 1-2 i 2-3 nakładają się.'
  );

  insert into public.lane_pricing_rules (
    lane_id,
    min_shooters,
    max_shooters,
    label,
    hourly_price,
    display_order
  )
  values (v_lane_id, 3, 5, '[TEST] 3-5', 100, 2)
  returning id into v_second_rule_id;

  insert into public.lane_pricing_rules (
    lane_id,
    min_shooters,
    max_shooters,
    label,
    hourly_price,
    display_order
  )
  values (v_second_lane_id, 1, 5, '[TEST] druga oś', 50, 1)
  returning id into v_other_lane_rule_id;

  insert into test_results
  values (
    14,
    'Sąsiedni zakres cennika jest dozwolony',
    v_second_rule_id is not null,
    'Zakresy 1-2 i 3-5 nie nakładają się.'
  );

  insert into public.lane_pricing_rules (
    lane_id,
    min_shooters,
    max_shooters,
    label,
    hourly_price,
    is_active
  )
  values (v_lane_id, 1, 5, '[TEST] historyczny', 1, false);

  insert into test_results
  values (
    15,
    'Nieaktywna historyczna reguła może się nakładać',
    true,
    'Exclusion constraint obejmuje tylko is_active=true.'
  );

  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  values
    (
      v_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated',
      'authenticated',
      '[TEST]-foundation-1@example.invalid',
      '',
      pg_catalog.transaction_timestamp(),
      '{}'::jsonb,
      '{}'::jsonb,
      pg_catalog.transaction_timestamp(),
      pg_catalog.transaction_timestamp()
    ),
    (
      v_second_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated',
      'authenticated',
      '[TEST]-foundation-2@example.invalid',
      '',
      pg_catalog.transaction_timestamp(),
      '{}'::jsonb,
      '{}'::jsonb,
      pg_catalog.transaction_timestamp(),
      pg_catalog.transaction_timestamp()
    ),
    (
      v_admin_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated',
      'authenticated',
      '[TEST]-foundation-admin@example.invalid',
      '',
      pg_catalog.transaction_timestamp(),
      '{}'::jsonb,
      '{}'::jsonb,
      pg_catalog.transaction_timestamp(),
      pg_catalog.transaction_timestamp()
    ),
    (
      v_employee_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated',
      'authenticated',
      '[TEST]-foundation-employee@example.invalid',
      '',
      pg_catalog.transaction_timestamp(),
      '{}'::jsonb,
      '{}'::jsonb,
      pg_catalog.transaction_timestamp(),
      pg_catalog.transaction_timestamp()
    ),
    (
      v_instructor_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated',
      'authenticated',
      '[TEST]-foundation-instructor@example.invalid',
      '',
      pg_catalog.transaction_timestamp(),
      '{}'::jsonb,
      '{}'::jsonb,
      pg_catalog.transaction_timestamp(),
      pg_catalog.transaction_timestamp()
    );

  update public.profiles
  set
    role = case user_id
      when v_admin_user_id then 'admin'
      when v_employee_user_id then 'pracownik'
      when v_instructor_user_id then 'instruktor'
      else role
    end,
    verification_status = 'verified'
  where user_id in (
    v_user_id,
    v_second_user_id,
    v_admin_user_id,
    v_employee_user_id,
    v_instructor_user_id
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 30,
      time '10:00',
      time '11:00',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      0,
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      50,
      50,
      'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when check_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    16,
    'shooters_count poniżej 1 jest odrzucone',
    v_rejected,
    'Oczekiwano CHECK shooters_count >= 1.'
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 30,
      time '10:00',
      time '10:00',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      1,
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      50,
      50,
      'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when check_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    17,
    'Nieprawidłowy przedział czasu jest odrzucony',
    v_rejected,
    'Oczekiwano end_time > start_time.'
  );

  insert into public.reservations (
    id,
    user_id,
    lane_id,
    customer_name,
    customer_email,
    customer_phone,
    reservation_date,
    start_time,
    end_time,
    duration_minutes,
    price,
    reservation_status,
    payment_status,
    check_in_token,
    shooters_count,
    pricing_rule_id,
    lane_name_snapshot,
    pricing_label_snapshot,
    price_per_hour_snapshot,
    total_price,
    currency_code,
    creation_request_id
  )
  values (
    pg_catalog.gen_random_uuid(),
    v_user_id,
    v_lane_id,
    '[TEST]',
    '[TEST]@example.invalid',
    '[TEST]',
    current_date + 30,
    time '10:00',
    time '11:00',
    60,
    50,
    'confirmed',
    'pay_on_site',
    pg_catalog.gen_random_uuid(),
    1,
    v_rule_id,
    '[TEST] Oś 1',
    '[TEST] 1-2',
    50,
    50,
    'PLN',
    v_creation_request_id
  )
  returning id into v_reservation_id;

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_second_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 30,
      time '10:30',
      time '11:30',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      1,
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      50,
      50,
      'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when exclusion_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    18,
    'Nakładająca aktywna rezerwacja jest odrzucona',
    v_rejected,
    'Oczekiwano exclusion_violation na tej samej osi.'
  );

  insert into public.reservations (
    id,
    user_id,
    lane_id,
    customer_name,
    customer_email,
    customer_phone,
    reservation_date,
    start_time,
    end_time,
    duration_minutes,
    price,
    reservation_status,
    payment_status,
    check_in_token,
    shooters_count,
    pricing_rule_id,
    lane_name_snapshot,
    pricing_label_snapshot,
    price_per_hour_snapshot,
    total_price,
    currency_code,
    creation_request_id
  )
  values (
    pg_catalog.gen_random_uuid(),
    v_second_user_id,
    v_lane_id,
    '[TEST]',
    '[TEST]@example.invalid',
    '[TEST]',
    current_date + 30,
    time '11:00',
    time '12:00',
    60,
    50,
    'confirmed',
    'pay_on_site',
    pg_catalog.gen_random_uuid(),
    1,
    v_rule_id,
    '[TEST] Oś 1',
    '[TEST] 1-2',
    50,
    50,
    'PLN',
    pg_catalog.gen_random_uuid()
  );

  insert into test_results
  values (
    19,
    'Stykające się przedziały są dozwolone',
    true,
    'Półotwarte przedziały [) nie nakładają się.'
  );

  insert into public.reservations (
    id,
    user_id,
    lane_id,
    customer_name,
    customer_email,
    customer_phone,
    reservation_date,
    start_time,
    end_time,
    duration_minutes,
    price,
    reservation_status,
    payment_status,
    check_in_token,
    shooters_count,
    pricing_rule_id,
    lane_name_snapshot,
    pricing_label_snapshot,
    price_per_hour_snapshot,
    total_price,
    currency_code,
    creation_request_id
  )
  values (
    pg_catalog.gen_random_uuid(),
    v_second_user_id,
    v_second_lane_id,
    '[TEST]',
    '[TEST]@example.invalid',
    '[TEST]',
    current_date + 30,
    time '10:00',
    time '11:00',
    60,
    50,
    'confirmed',
    'pay_on_site',
    pg_catalog.gen_random_uuid(),
    1,
    v_other_lane_rule_id,
    '[TEST] Oś 2',
    '[TEST] 1-2',
    50,
    50,
    'PLN',
    pg_catalog.gen_random_uuid()
  );

  insert into test_results
  values (
    20,
    'Ten sam przedział na innej osi jest dozwolony',
    true,
    'Exclusion constraint rozdziela lane_id.'
  );

  update public.reservations
  set reservation_status = 'cancelled'
  where id = v_reservation_id;

  insert into public.reservations (
    id,
    user_id,
    lane_id,
    customer_name,
    customer_email,
    customer_phone,
    reservation_date,
    start_time,
    end_time,
    duration_minutes,
    price,
    reservation_status,
    payment_status,
    check_in_token,
    shooters_count,
    pricing_rule_id,
    lane_name_snapshot,
    pricing_label_snapshot,
    price_per_hour_snapshot,
    total_price,
    currency_code,
    creation_request_id
  )
  values (
    pg_catalog.gen_random_uuid(),
    v_user_id,
    v_lane_id,
    '[TEST]',
    '[TEST]@example.invalid',
    '[TEST]',
    current_date + 30,
    time '10:00',
    time '11:00',
    60,
    50,
    'confirmed',
    'pay_on_site',
    pg_catalog.gen_random_uuid(),
    1,
    v_rule_id,
    '[TEST] Oś 1',
    '[TEST] 1-2',
    50,
    50,
    'PLN',
    pg_catalog.gen_random_uuid()
  );

  insert into test_results
  values (
    21,
    'Anulowana rezerwacja zwalnia termin',
    true,
    'Status cancelled nie uczestniczy w exclusion constraint.'
  );

  v_rejected := false;
  begin
    delete from public.lane_pricing_rules
    where id = v_rule_id;
  exception
    when foreign_key_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    22,
    'Używana reguła cenowa jest chroniona',
    v_rejected,
    'Oczekiwano ON DELETE RESTRICT.'
  );

  v_rejected := false;
  begin
    delete from public.shooting_lanes
    where id = v_lane_id;
  exception
    when foreign_key_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    23,
    'Używana oś jest chroniona',
    v_rejected,
    'Oczekiwano ON DELETE RESTRICT.'
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      pg_catalog.gen_random_uuid(),
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 40,
      time '10:00',
      time '11:00',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      1,
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      50,
      50,
      'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when foreign_key_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    24,
    'user_id musi wskazywać auth.users',
    v_rejected,
    'Oczekiwano FK reservations_user_id_fkey.'
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 50,
      time '10:00',
      time '11:00',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      50,
      50,
      'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when not_null_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    25,
    'shooters_count jest wymagane',
    v_rejected,
    'Oczekiwano NOT NULL dla shooters_count.'
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 51,
      time '10:00',
      time '11:00',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      1,
      v_rule_id,
      '[TEST] 1-2',
      50,
      50,
      'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when not_null_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    26,
    'Snapshot nazwy osi jest wymagany',
    v_rejected,
    'Oczekiwano NOT NULL dla lane_name_snapshot.'
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 52,
      time '10:00',
      time '11:00',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      1,
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      50,
      50,
      'PLN'
    );
  exception
    when not_null_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    27,
    'creation_request_id jest wymagane',
    v_rejected,
    'Oczekiwano NOT NULL dla creation_request_id.'
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 53,
      time '10:00',
      time '11:00',
      60,
      -1,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      1,
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      -1,
      -1,
      'PLN',
      pg_catalog.gen_random_uuid()
    );
  exception
    when check_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    28,
    'Ujemne ceny są odrzucone',
    v_rejected,
    'Oczekiwano CHECK dla snapshotu stawki i total_price.'
  );

  v_rejected := false;
  begin
    insert into public.reservations (
      id,
      user_id,
      lane_id,
      customer_name,
      customer_email,
      customer_phone,
      reservation_date,
      start_time,
      end_time,
      duration_minutes,
      price,
      reservation_status,
      payment_status,
      check_in_token,
      shooters_count,
      pricing_rule_id,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      pg_catalog.gen_random_uuid(),
      v_user_id,
      v_lane_id,
      '[TEST]',
      '[TEST]@example.invalid',
      '[TEST]',
      current_date + 54,
      time '10:00',
      time '11:00',
      60,
      50,
      'confirmed',
      'pay_on_site',
      pg_catalog.gen_random_uuid(),
      1,
      v_rule_id,
      '[TEST] Oś 1',
      '[TEST] 1-2',
      50,
      50,
      'PLN',
      v_creation_request_id
    );
  exception
    when unique_violation then
      v_rejected := true;
  end;

  insert into test_results
  values (
    29,
    'Duplikat user_id i creation_request_id jest odrzucony',
    v_rejected,
    'Oczekiwano UNIQUE(user_id,creation_request_id).'
  );

  update public.shooting_lanes
  set is_active = true
  where id in (v_lane_id, v_second_lane_id);

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select
    (
      select pg_catalog.count(*)
      from public.lane_booking_durations
      where lane_id = v_lane_id
        and is_active
    )
    + (
      select pg_catalog.count(*)
      from public.lane_pricing_rules
      where lane_id = v_lane_id
        and is_active
    )
  into v_visible_count
  ;
  execute 'reset role';

  insert into test_results
  values (
    30,
    'User czyta aktywną konfigurację aktywnej osi',
    v_visible_count = 3,
    'Oczekiwano długości oraz dwóch aktywnych progów cenowych.'
  );

  v_duration_rejected := false;
  v_pricing_rejected := false;
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  begin
    insert into public.lane_booking_durations (
      lane_id,
      duration_minutes
    )
    values (v_lane_id, 120);
  exception
    when insufficient_privilege then
      v_duration_rejected := true;
  end;
  begin
    insert into public.lane_pricing_rules (
      lane_id,
      min_shooters,
      max_shooters,
      label,
      hourly_price,
      is_active
    )
    values (
      v_second_lane_id,
      6,
      6,
      '[TEST] user forbidden',
      1,
      false
    );
  exception
    when insufficient_privilege then
      v_pricing_rejected := true;
  end;
  execute 'reset role';

  insert into test_results
  values (
    31,
    'User nie zarządza konfiguracją',
    v_duration_rejected and v_pricing_rejected,
    'Oczekiwano blokady RLS w obu tabelach.'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_admin_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  insert into public.lane_booking_durations (
    lane_id,
    duration_minutes,
    display_order
  )
  values (v_lane_id, 120, 2);
  execute 'reset role';

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_employee_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  insert into public.lane_pricing_rules (
    lane_id,
    min_shooters,
    max_shooters,
    label,
    hourly_price,
    display_order,
    is_active
  )
  values (
    v_second_lane_id,
    6,
    6,
    '[TEST] employee policy',
    1,
    3,
    false
  );
  execute 'reset role';

  insert into test_results
  values (
    32,
    'Admin i pracownik zarządzają konfiguracją',
    (
      select pg_catalog.count(*)
      from public.lane_booking_durations
      where lane_id = v_lane_id
        and duration_minutes = 120
    ) = 1
    and (
      select pg_catalog.count(*)
      from public.lane_pricing_rules
      where lane_id = v_second_lane_id
        and label = '[TEST] employee policy'
    ) = 1,
    'Admin i pracownik powinni przejść polityki obu tabel.'
  );

  v_duration_rejected := false;
  v_pricing_rejected := false;
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_instructor_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  begin
    insert into public.lane_booking_durations (
      lane_id,
      duration_minutes
    )
    values (v_lane_id, 240);
  exception
    when insufficient_privilege then
      v_duration_rejected := true;
  end;
  begin
    insert into public.lane_pricing_rules (
      lane_id,
      min_shooters,
      max_shooters,
      label,
      hourly_price,
      is_active
    )
    values (
      v_second_lane_id,
      7,
      7,
      '[TEST] instructor forbidden',
      1,
      false
    );
  exception
    when insufficient_privilege then
      v_pricing_rejected := true;
  end;
  execute 'reset role';

  insert into test_results
  values (
    33,
    'Instruktor nie zarządza konfiguracją',
    v_duration_rejected and v_pricing_rejected,
    'Oczekiwano blokady RLS w obu tabelach.'
  );
end;
$constraint_tests$;

select
  test_order,
  test_name,
  passed,
  result
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
    raise exception 'Foundation tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
