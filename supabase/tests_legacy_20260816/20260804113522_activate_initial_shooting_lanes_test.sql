begin;

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
  insert into test_results(test_order, test_name, passed, result)
  values (p_order, p_name, coalesce(p_passed, false), p_result);
$function$;

create function pg_temp.call_create_reservation(
  p_user_id uuid,
  p_lane_id uuid,
  p_date date,
  p_time time without time zone,
  p_duration integer,
  p_shooters integer
)
returns jsonb
language plpgsql
as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );

  return public.create_reservation(
    p_lane_id,
    p_date,
    p_time,
    p_duration,
    p_shooters,
    pg_catalog.gen_random_uuid(),
    '[TEST] initial lane activation'
  );
end;
$function$;

do $tests$
declare
  v_lane_50_1 constant uuid := '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77';
  v_lane_50_2 constant uuid := '4e93b955-da4f-438e-ac9b-9b197e220c49';
  v_lane_100 constant uuid := '254ca7f6-ce80-4267-8966-4558cc8f8fd2';
  v_trap constant uuid := '063cca57-4db6-4b05-b4d2-46ff1f5696f9';
  v_skeet constant uuid := 'df4efac0-0203-4d23-84ac-3861a68e4e40';
  v_bazant constant uuid := '56ece689-5fde-4733-95d3-2c7aa1396c6c';
  v_user constant uuid := 'a3c40000-0000-4000-8000-000000000001';
  v_result jsonb;
  v_ok boolean;
begin
  perform pg_temp.record_result(1, 'Dokładnie pięć osi jest aktywnych',
    (select pg_catalog.count(*) = 5 from public.shooting_lanes where is_active),
    'Oczekiwano dokładnie pięciu aktywnych osi.');

  perform pg_temp.record_result(2, 'Aktywne są wyłącznie zatwierdzone UUID',
    not exists (
      select 1 from public.shooting_lanes
      where is_active
        and id not in (v_lane_50_1, v_lane_50_2, v_lane_100, v_trap, v_skeet)
    ), 'Nie może być aktywna żadna inna oś.');

  perform pg_temp.record_result(3, 'Oś 50 m stanowisko 1 jest aktywna',
    exists(select 1 from public.shooting_lanes where id=v_lane_50_1 and is_active),
    'Oczekiwano aktywnej osi 50 m stanowisko 1.');
  perform pg_temp.record_result(4, 'Oś 50 m stanowisko 2 jest aktywna',
    exists(select 1 from public.shooting_lanes where id=v_lane_50_2 and is_active),
    'Oczekiwano aktywnej osi 50 m stanowisko 2.');
  perform pg_temp.record_result(5, 'Oś 100 m jest aktywna',
    exists(select 1 from public.shooting_lanes where id=v_lane_100 and is_active),
    'Oczekiwano aktywnej osi 100 m.');
  perform pg_temp.record_result(6, 'Trap jest aktywny',
    exists(select 1 from public.shooting_lanes where id=v_trap and is_active),
    'Oczekiwano aktywnego Trap.');
  perform pg_temp.record_result(7, 'Skeet jest aktywny',
    exists(select 1 from public.shooting_lanes where id=v_skeet and is_active),
    'Oczekiwano aktywnego Skeet.');
  perform pg_temp.record_result(8, 'Bażant pozostaje nieaktywny',
    exists(select 1 from public.shooting_lanes where id=v_bazant and not is_active),
    'Bażant musi pozostać nieaktywny.');

  perform pg_temp.record_result(9, 'Długości nadal liczą 20 rekordów',
    (select pg_catalog.count(*)=20 from public.lane_booking_durations),
    'Oczekiwano 20 długości.');
  perform pg_temp.record_result(10, 'Cennik nadal liczy 40 rekordów',
    (select pg_catalog.count(*)=40 from public.lane_pricing_rules),
    'Oczekiwano 40 reguł.');
  perform pg_temp.record_result(11, 'Bażant nadal ma zero długości',
    not exists(select 1 from public.lane_booking_durations where lane_id=v_bazant),
    'Bażant nie może mieć długości.');
  perform pg_temp.record_result(12, 'Bażant nadal ma zero cenników',
    not exists(select 1 from public.lane_pricing_rules where lane_id=v_bazant),
    'Bażant nie może mieć reguł cenowych.');

  perform pg_temp.record_result(13, 'max_shooters pozostał zgodny',
    (select pg_catalog.count(*)=5 from public.shooting_lanes where
      (id in (v_lane_50_1,v_lane_50_2) and max_shooters=5)
      or (id in (v_lane_100,v_trap,v_skeet) and max_shooters=6)),
    'Oczekiwano limitów 5/5/6/6/6.');
  perform pg_temp.record_result(14, 'booking_step_minutes pozostał zgodny',
    (select pg_catalog.count(*)=5 from public.shooting_lanes
     where id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet)
       and booking_step_minutes=60), 'Oczekiwano kroku 60.');
  perform pg_temp.record_result(15, 'display_order pozostał zgodny',
    (select pg_catalog.count(*)=6 from public.shooting_lanes where
      (id=v_lane_50_1 and display_order=10)
      or (id=v_lane_50_2 and display_order=20)
      or (id=v_lane_100 and display_order=30)
      or (id=v_trap and display_order=40)
      or (id=v_skeet and display_order=50)
      or (id=v_bazant and display_order=90)), 'Oczekiwano 10/20/30/40/50/90.');
  perform pg_temp.record_result(16, 'currency_code pozostał PLN',
    (select pg_catalog.count(*)=5 from public.shooting_lanes
     where id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet)
       and currency_code='PLN'), 'Oczekiwano PLN.');
  perform pg_temp.record_result(17, 'Legacy price_per_hour pozostał bez zmian',
    (select pg_catalog.count(*)=6 from public.shooting_lanes where
      (id in (v_lane_50_1,v_lane_50_2) and price_per_hour=60)
      or (id=v_lane_100 and price_per_hour=100)
      or (id in (v_trap,v_skeet,v_bazant) and price_per_hour=80)),
    'Oczekiwano zachowanych wartości legacy.');

  perform pg_temp.record_result(18, 'Ceny mon_thu pozostały bez zmian',
    (select pg_catalog.count(*)=5 from (
      select lane_id, pg_catalog.array_agg(hourly_price order by display_order) prices
      from public.lane_pricing_rules where day_group='mon_thu' group by lane_id
    ) price where
      (lane_id in (v_lane_50_1,v_lane_50_2) and prices=array[50,90,120,150]::numeric[])
      or (lane_id=v_lane_100 and prices=array[90,160,220,300]::numeric[])
      or (lane_id in (v_trap,v_skeet) and prices=array[80,130,180,220]::numeric[])),
    'Oczekiwano zatwierdzonych cen mon_thu.');
  perform pg_temp.record_result(19, 'Ceny fri_sun pozostały bez zmian',
    (select pg_catalog.count(*)=5 from (
      select lane_id, pg_catalog.array_agg(hourly_price order by display_order) prices
      from public.lane_pricing_rules where day_group='fri_sun' group by lane_id
    ) price where
      (lane_id in (v_lane_50_1,v_lane_50_2) and prices=array[65,120,160,200]::numeric[])
      or (lane_id=v_lane_100 and prices=array[120,210,280,380]::numeric[])
      or (lane_id in (v_trap,v_skeet) and prices=array[110,170,230,280]::numeric[])),
    'Oczekiwano zatwierdzonych cen fri_sun.');

  perform pg_temp.record_result(20, 'Każda aktywna oś ma cztery długości',
    not exists (
      select 1 from (
        values (v_lane_50_1),(v_lane_50_2),(v_lane_100),(v_trap),(v_skeet)
      ) expected(id)
      where coalesce((select pg_catalog.array_agg(duration_minutes order by duration_minutes)
                      from public.lane_booking_durations where lane_id=expected.id and is_active),
                     array[]::integer[]) <> array[60,120,180,240]
    ), 'Oczekiwano 60/120/180/240 dla każdej osi.');

  begin
    if exists (
      select 1 from public.shooting_lanes
      where id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet,v_bazant)
        and is_active
    ) then
      raise exception 'Wszystkie sześć osi musi być nieaktywnych przed aktywacją.';
    end if;
    v_ok := false;
  exception when others then
    v_ok := true;
  end;
  perform pg_temp.record_result(21, 'Ponowne wykonanie odrzuca preflight', v_ok,
    'Aktywne osie muszą zatrzymać ponowną aktywację.');

  perform pg_temp.record_result(22, 'reservations_count pozostaje 0',
    (select pg_catalog.count(*)=0 from public.reservations),
    'Przed testami RPC nie może być rezerwacji.');

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values (
    v_user, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', '[TEST]-lane-activation@example.invalid', '',
    pg_catalog.transaction_timestamp(), '{}'::jsonb,
    '{"first_name":"Test","last_name":"Aktywacja","phone":"123456789"}'::jsonb,
    pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
  );

  update public.profiles
  set first_name='Test', last_name='Aktywacja', full_name='[TEST]',
      phone='123456789', verification_status='verified', role='user'
  where user_id=v_user;

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-08-04',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and v_result->>'pricing_day_group'='mon_thu' and (v_result->>'price_per_hour')::numeric=50;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_2,date '2031-08-04',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=50;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_100,date '2031-08-04',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=90;
  v_result := pg_temp.call_create_reservation(v_user,v_trap,date '2031-08-04',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=80;
  v_result := pg_temp.call_create_reservation(v_user,v_skeet,date '2031-08-04',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=80;
  perform pg_temp.record_result(23, 'RPC wybiera minimalne ceny mon_thu dla pięciu osi', v_ok,
    'Oczekiwano 50/50/90/80/80.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-08-08',time '08:00',60,5);
  v_ok := v_ok and v_result->>'code'='created' and v_result->>'pricing_day_group'='fri_sun' and (v_result->>'price_per_hour')::numeric=200;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_2,date '2031-08-08',time '08:00',60,5);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=200;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_100,date '2031-08-08',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=380;
  v_result := pg_temp.call_create_reservation(v_user,v_trap,date '2031-08-08',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=280;
  v_result := pg_temp.call_create_reservation(v_user,v_skeet,date '2031-08-08',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=280;
  perform pg_temp.record_result(24, 'RPC wybiera maksymalne ceny fri_sun dla pięciu osi', v_ok,
    'Oczekiwano 200/200/380/280/280.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-08-11',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-08-18',time '08:00',120,1);
  v_ok := v_ok and v_result->>'code'='created';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-08-25',time '08:00',180,1);
  v_ok := v_ok and v_result->>'code'='created';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-09-01',time '08:00',240,1);
  v_ok := v_ok and v_result->>'code'='created';
  perform pg_temp.record_result(25, 'RPC akceptuje 60/120/180/240 minut', v_ok,
    'Oczekiwano czterech wyników created.');

  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-09-08',time '08:00',90,1);
  perform pg_temp.record_result(26, 'RPC odrzuca długość 90 minut',
    v_result->>'code'='invalid_duration', 'Oczekiwano invalid_duration.');

  v_result := pg_temp.call_create_reservation(v_user,v_bazant,date '2031-09-08',time '08:00',60,1);
  perform pg_temp.record_result(27, 'RPC odrzuca nieaktywnego Bażanta',
    v_result->>'code'='lane_inactive', 'Oczekiwano lane_inactive.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2031-09-15',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_2,date '2031-09-15',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_100,date '2031-09-15',time '08:00',60,7);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_trap,date '2031-09-15',time '08:00',60,7);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_skeet,date '2031-09-15',time '08:00',60,7);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  perform pg_temp.record_result(28, 'RPC odrzuca przekroczenie limitu każdej osi', v_ok,
    'Oczekiwano capacity_exceeded dla pięciu osi.');
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
    ', ' order by test_order
  )
  into v_failures
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Initial lane activation tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
