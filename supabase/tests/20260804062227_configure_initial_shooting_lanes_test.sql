-- Test konfiguracji pięciu osi po migracjach 20260724071150,
-- 20260724081359 i 20260804062227. Kończy się ROLLBACK.

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
  values (p_order, p_name, p_passed, p_result);
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
    p_lane_id, p_date, p_time, p_duration, p_shooters,
    pg_catalog.gen_random_uuid(), '[TEST] initial lane configuration'
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
  v_user constant uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  v_result jsonb;
  v_ok boolean;
begin
  perform pg_temp.record_result(1, 'Pięć osi ma właściwe max_shooters',
    (select pg_catalog.count(*) = 5 from public.shooting_lanes
     where (id in (v_lane_50_1, v_lane_50_2) and max_shooters = 5)
        or (id in (v_lane_100, v_trap, v_skeet) and max_shooters = 6)),
    'Oczekiwano max_shooters 5/5/6/6/6.');
  perform pg_temp.record_result(2, 'Obie osie 50 m mają max_shooters=5',
    (select pg_catalog.count(*) = 2 from public.shooting_lanes
     where id in (v_lane_50_1, v_lane_50_2) and max_shooters = 5),
    'Oczekiwano dwóch osi 50 m z limitem 5.');
  perform pg_temp.record_result(3, 'Oś 100 m ma max_shooters=6',
    (select max_shooters = 6 from public.shooting_lanes where id = v_lane_100),
    'Oczekiwano limitu 6.');
  perform pg_temp.record_result(4, 'Trap ma max_shooters=6',
    (select max_shooters = 6 from public.shooting_lanes where id = v_trap),
    'Oczekiwano limitu 6.');
  perform pg_temp.record_result(5, 'Skeet ma max_shooters=6',
    (select max_shooters = 6 from public.shooting_lanes where id = v_skeet),
    'Oczekiwano limitu 6.');
  perform pg_temp.record_result(6, 'Wszystkie sześć osi jest nieaktywnych',
    (select pg_catalog.count(*) = 6 from public.shooting_lanes
     where id in (v_lane_50_1, v_lane_50_2, v_lane_100, v_trap, v_skeet, v_bazant)
       and not is_active),
    'Żadna oś nie może zostać aktywowana.');
  perform pg_temp.record_result(7, 'Kolejność osi jest zgodna',
    (select pg_catalog.count(*) = 6 from public.shooting_lanes
     where (id = v_lane_50_1 and display_order = 10)
        or (id = v_lane_50_2 and display_order = 20)
        or (id = v_lane_100 and display_order = 30)
        or (id = v_trap and display_order = 40)
        or (id = v_skeet and display_order = 50)
        or (id = v_bazant and display_order = 90)),
    'Oczekiwano kolejności 10/20/30/40/50/90.');
  perform pg_temp.record_result(8, 'Pięć osi ma krok 60',
    (select pg_catalog.count(*) = 5 from public.shooting_lanes
     where id in (v_lane_50_1, v_lane_50_2, v_lane_100, v_trap, v_skeet)
       and booking_step_minutes = 60),
    'Oczekiwano kroku 60 minut.');
  perform pg_temp.record_result(9, 'Każda oś ma cztery długości',
    not exists (
      select 1 from (values (v_lane_50_1), (v_lane_50_2), (v_lane_100), (v_trap), (v_skeet)) lane(id)
      where (select pg_catalog.count(*) from public.lane_booking_durations d
             where d.lane_id = lane.id and d.is_active) <> 4),
    'Oczekiwano czterech długości na oś.');
  perform pg_temp.record_result(10, 'Długości to 60,120,180,240',
    not exists (
      select 1 from (values (v_lane_50_1), (v_lane_50_2), (v_lane_100), (v_trap), (v_skeet)) lane(id)
      where (select pg_catalog.array_agg(d.duration_minutes order by d.duration_minutes)
             from public.lane_booking_durations d where d.lane_id = lane.id and d.is_active)
            is distinct from array[60,120,180,240]),
    'Każda oś powinna mieć dokładny zestaw długości.');
  perform pg_temp.record_result(11, 'Istnieje dokładnie 20 długości',
    (select pg_catalog.count(*) = 20 from public.lane_booking_durations
     where lane_id in (v_lane_50_1, v_lane_50_2, v_lane_100, v_trap, v_skeet)),
    'Oczekiwano 5 × 4 rekordy.');
  perform pg_temp.record_result(12, 'Każda oś ma cztery progi mon_thu',
    not exists (
      select 1 from (values (v_lane_50_1), (v_lane_50_2), (v_lane_100), (v_trap), (v_skeet)) lane(id)
      where (select pg_catalog.count(*) from public.lane_pricing_rules r
             where r.lane_id = lane.id and r.day_group = 'mon_thu' and r.is_active) <> 4),
    'Oczekiwano czterech progów mon_thu na oś.');
  perform pg_temp.record_result(13, 'Każda oś ma cztery progi fri_sun',
    not exists (
      select 1 from (values (v_lane_50_1), (v_lane_50_2), (v_lane_100), (v_trap), (v_skeet)) lane(id)
      where (select pg_catalog.count(*) from public.lane_pricing_rules r
             where r.lane_id = lane.id and r.day_group = 'fri_sun' and r.is_active) <> 4),
    'Oczekiwano czterech progów fri_sun na oś.');
  perform pg_temp.record_result(14, 'Istnieje dokładnie 40 reguł cenowych',
    (select pg_catalog.count(*) = 40 from public.lane_pricing_rules
     where lane_id in (v_lane_50_1, v_lane_50_2, v_lane_100, v_trap, v_skeet)),
    'Oczekiwano 5 × 2 × 4 reguły.');
  perform pg_temp.record_result(15, 'Cenniki obu osi 50 m są identyczne',
    not exists (
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_lane_50_1)
      except
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_lane_50_2)
    ) and not exists (
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_lane_50_2)
      except
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_lane_50_1)
    ), 'Obie osie 50 m powinny mieć identyczne reguły.');
  perform pg_temp.record_result(16, 'Ceny osi 50 m są dokładne',
    (select pg_catalog.array_agg(hourly_price order by day_group desc, min_shooters)
     from public.lane_pricing_rules where lane_id = v_lane_50_1)
      = array[50,90,120,150,65,120,160,200]::numeric[],
    'Oczekiwano pełnych taryf 50/90/120/150 i 65/120/160/200.');
  perform pg_temp.record_result(17, 'Ceny osi 100 m są dokładne',
    (select pg_catalog.array_agg(hourly_price order by day_group desc, min_shooters)
     from public.lane_pricing_rules where lane_id = v_lane_100)
      = array[90,160,220,300,120,210,280,380]::numeric[],
    'Oczekiwano pełnych taryf osi 100 m.');
  perform pg_temp.record_result(18, 'Ceny Trap są dokładne',
    (select pg_catalog.array_agg(hourly_price order by day_group desc, min_shooters)
     from public.lane_pricing_rules where lane_id = v_trap)
      = array[80,130,180,220,110,170,230,280]::numeric[],
    'Oczekiwano pełnych taryf Trap.');
  perform pg_temp.record_result(19, 'Cennik Skeet jest identyczny jak Trap',
    not exists (
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_trap)
      except
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_skeet)
    ) and not exists (
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_skeet)
      except
      (select day_group, min_shooters, max_shooters, label, hourly_price, display_order
       from public.lane_pricing_rules where lane_id = v_trap)
    ), 'Trap i Skeet powinny mieć identyczne reguły.');
  perform pg_temp.record_result(20, 'Bażant ma zero długości',
    not exists (select 1 from public.lane_booking_durations where lane_id = v_bazant),
    'Bażant nie może mieć długości.');
  perform pg_temp.record_result(21, 'Bażant ma zero cenników',
    not exists (select 1 from public.lane_pricing_rules where lane_id = v_bazant),
    'Bażant nie może mieć cennika.');
  perform pg_temp.record_result(22, 'Cennik pokrywa 1..max_shooters',
    not exists (
      select 1
      from (values
        (v_lane_50_1,5), (v_lane_50_2,5), (v_lane_100,6), (v_trap,6), (v_skeet,6)
      ) lane(id,max_shooters)
      cross join (values ('mon_thu'::text),('fri_sun'::text)) day_group(name)
      cross join lateral pg_catalog.generate_series(1,lane.max_shooters) shooter(value)
      where not exists (
        select 1 from public.lane_pricing_rules r
        where r.lane_id=lane.id and r.day_group=day_group.name and r.is_active
          and shooter.value between r.min_shooters and r.max_shooters)),
    'Każda liczba strzelców musi mieć regułę.');
  perform pg_temp.record_result(23, 'Pierwszy i ostatni próg są pełne',
    not exists (
      select 1 from (values
        (v_lane_50_1,5), (v_lane_50_2,5), (v_lane_100,6), (v_trap,6), (v_skeet,6)
      ) lane(id,max_shooters)
      cross join (values ('mon_thu'::text),('fri_sun'::text)) day_group(name)
      where (select pg_catalog.min(min_shooters) from public.lane_pricing_rules r
             where r.lane_id=lane.id and r.day_group=day_group.name and r.is_active) <> 1
         or (select pg_catalog.max(max_shooters) from public.lane_pricing_rules r
             where r.lane_id=lane.id and r.day_group=day_group.name and r.is_active) <> lane.max_shooters),
    'Zakres powinien zaczynać się od 1 i kończyć na limicie osi.');
  perform pg_temp.record_result(24, 'Zakresy nie nakładają się',
    not exists (
      select 1 from public.lane_pricing_rules a
      join public.lane_pricing_rules b on b.lane_id=a.lane_id and b.day_group=a.day_group and b.id>a.id
       and int4range(a.min_shooters,a.max_shooters,'[]') && int4range(b.min_shooters,b.max_shooters,'[]')
      where a.lane_id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet)
        and a.is_active and b.is_active),
    'Aktywne progi nie mogą się nakładać.');
  perform pg_temp.record_result(25, 'Etykiety progów są poprawne',
    not exists (
      select 1 from public.lane_pricing_rules r
      where r.lane_id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet)
        and r.label is distinct from case
          when r.min_shooters=1 and r.max_shooters=1 then '1 strzelec'
          when r.min_shooters=2 and r.max_shooters=2 then '2 strzelców'
          when r.min_shooters=3 and r.max_shooters=3 then '3 strzelców'
          when r.min_shooters=3 and r.max_shooters=4 then '3–4 strzelców'
          else 'Pakiet grupowy — najlepsza cena na osobę' end),
    'Etykiety muszą odpowiadać zatwierdzonym progom.');
  perform pg_temp.record_result(26, 'display_order progów jest poprawne',
    not exists (
      select 1 from public.lane_pricing_rules r
      where r.lane_id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet)
        and r.display_order <> case
          when r.min_shooters=1 then 10 when r.min_shooters=2 then 20
          when r.min_shooters=3 then 30 else 40 end),
    'Oczekiwano kolejności 10/20/30/40.');
  perform pg_temp.record_result(27, 'Waluta pięciu osi to PLN',
    (select pg_catalog.count(*)=5 from public.shooting_lanes
     where id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet)
       and currency_code='PLN'), 'Oczekiwano PLN.');
  perform pg_temp.record_result(28, 'Legacy price_per_hour nie zostało zmienione',
    (select pg_catalog.count(*)=6 from public.shooting_lanes where
      (id in (v_lane_50_1,v_lane_50_2) and price_per_hour=60)
      or (id=v_lane_100 and price_per_hour=100)
      or (id in (v_trap,v_skeet,v_bazant) and price_per_hour=80)),
    'Oczekiwano zachowanych wartości legacy 60/100/80.');
  perform pg_temp.record_result(29, 'Preflight odrzuci ponowne zastosowanie',
    exists (select 1 from public.lane_booking_durations
            where lane_id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet,v_bazant))
    and exists (select 1 from public.lane_pricing_rules
                where lane_id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet,v_bazant)),
    'Ponowne zastosowanie musi wykryć istniejącą konfigurację.');
  perform pg_temp.record_result(30, 'Żadna oś nie została aktywowana',
    not exists (select 1 from public.shooting_lanes
                where id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet,v_bazant)
                  and is_active), 'Wszystkie sześć osi musi pozostać nieaktywnych.');
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values (
    v_user, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', '[TEST]-lane-config@example.invalid', '',
    pg_catalog.transaction_timestamp(), '{}'::jsonb,
    '{"first_name":"Test","last_name":"Konfiguracja","phone":"123456789"}'::jsonb,
    pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
  );

  update public.profiles
  set first_name='Test', last_name='Konfiguracja', full_name='[TEST]',
      phone='123456789', verification_status='verified', role='user'
  where user_id=v_user;

  update public.shooting_lanes
  set is_active=true
  where id in (v_lane_50_1,v_lane_50_2,v_lane_100,v_trap,v_skeet);

  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-07-22',time '08:00',60,1);
  perform pg_temp.record_result(31, 'RPC 50 m poniedziałek wybiera 50 PLN',
    v_result->>'code'='created' and v_result->>'pricing_day_group'='mon_thu'
      and (v_result->>'price_per_hour')::numeric=50,
    'Oczekiwano mon_thu i 50 PLN/h.');

  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-07-26',time '08:00',60,1);
  perform pg_temp.record_result(32, 'RPC 50 m piątek wybiera 65 PLN',
    v_result->>'code'='created' and v_result->>'pricing_day_group'='fri_sun'
      and (v_result->>'price_per_hour')::numeric=65,
    'Oczekiwano fri_sun i 65 PLN/h.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_2,date '2030-07-29',time '08:00',60,5);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=150;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_2,date '2030-08-02',time '08:00',60,5);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=200;
  perform pg_temp.record_result(33, 'RPC 50 m obsługuje maksymalnie 5 strzelców', v_ok,
    'Oczekiwano cen 150 i 200 dla pięciu strzelców.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_100,date '2030-08-05',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=90;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_100,date '2030-08-09',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=380;
  perform pg_temp.record_result(34, 'RPC Oś 100 m wybiera ceny minimalną i maksymalną', v_ok,
    'Oczekiwano 90 i 380 PLN/h.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_trap,date '2030-08-12',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=80;
  v_result := pg_temp.call_create_reservation(v_user,v_trap,date '2030-08-16',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=280;
  perform pg_temp.record_result(35, 'RPC Trap wybiera ceny minimalną i maksymalną', v_ok,
    'Oczekiwano 80 i 280 PLN/h.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_skeet,date '2030-08-19',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=80;
  v_result := pg_temp.call_create_reservation(v_user,v_skeet,date '2030-08-23',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='created' and (v_result->>'price_per_hour')::numeric=280;
  perform pg_temp.record_result(36, 'RPC Skeet wybiera ceny minimalną i maksymalną', v_ok,
    'Oczekiwano 80 i 280 PLN/h.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-09-02',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_2,date '2030-09-02',time '08:00',60,6);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_100,date '2030-09-02',time '08:00',60,7);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_trap,date '2030-09-02',time '08:00',60,7);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  v_result := pg_temp.call_create_reservation(v_user,v_skeet,date '2030-09-02',time '08:00',60,7);
  v_ok := v_ok and v_result->>'code'='capacity_exceeded';
  perform pg_temp.record_result(37, 'RPC odrzuca przekroczenie limitu każdej osi', v_ok,
    'Oczekiwano capacity_exceeded dla pięciu osi.');

  v_result := pg_temp.call_create_reservation(v_user,v_bazant,date '2030-09-02',time '08:00',60,1);
  perform pg_temp.record_result(38, 'RPC odrzuca nieaktywnego Bażanta',
    v_result->>'code'='lane_inactive', 'Oczekiwano lane_inactive.');

  v_ok := true;
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-09-09',time '08:00',60,1);
  v_ok := v_ok and v_result->>'code'='created';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-09-16',time '08:00',120,1);
  v_ok := v_ok and v_result->>'code'='created';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-09-23',time '08:00',180,1);
  v_ok := v_ok and v_result->>'code'='created';
  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-09-30',time '08:00',240,1);
  v_ok := v_ok and v_result->>'code'='created';
  perform pg_temp.record_result(39, 'RPC akceptuje długości 60/120/180/240', v_ok,
    'Oczekiwano czterech wyników created.');

  v_result := pg_temp.call_create_reservation(v_user,v_lane_50_1,date '2030-10-07',time '08:00',90,1);
  perform pg_temp.record_result(40, 'RPC odrzuca inną długość',
    v_result->>'code'='invalid_duration', 'Oczekiwano invalid_duration.');
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
    raise exception 'Initial lane configuration tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
