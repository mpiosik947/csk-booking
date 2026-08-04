-- Konfiguracja pięciu osi dla atomowego przepływu rezerwacji.
-- Wszystkie osie pozostają nieaktywne do osobnego etapu uruchomienia.

do $preflight$
declare
  v_mismatch_count integer;
  v_duration_count integer;
  v_pricing_count integer;
  v_reservation_count bigint;
begin
  if pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.lane_booking_durations') is null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is null
     or pg_catalog.to_regclass('public.reservations') is null then
    raise exception 'Brak wymaganych tabel konfiguracji rezerwacji.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'lane_pricing_rules'
      and column_name = 'day_group'
      and is_nullable = 'NO'
  ) then
    raise exception 'Brak wymaganej kolumny lane_pricing_rules.day_group.';
  end if;

  select pg_catalog.count(*)
  into v_mismatch_count
  from (
    values
      ('063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid, 'Trap'::text),
      ('254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid, 'Oś 100 m'::text),
      ('4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid, 'Oś 50 m — stanowisko 2'::text),
      ('56ece689-5fde-4733-95d3-2c7aa1396c6c'::uuid, 'Bażant'::text),
      ('8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid, 'Oś 50 m — stanowisko 1'::text),
      ('df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid, 'Skeet'::text)
  ) as expected(id, name)
  left join public.shooting_lanes as lane on lane.id = expected.id
  where lane.id is null or lane.name is distinct from expected.name;

  if v_mismatch_count <> 0 then
    raise exception 'ID lub nazwa jednej z sześciu osi nie odpowiada zatwierdzonej konfiguracji.';
  end if;

  select pg_catalog.count(*) into v_duration_count
  from public.lane_booking_durations
  where lane_id = any (array[
    '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
    '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
    '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
    '56ece689-5fde-4733-95d3-2c7aa1396c6c'::uuid,
    '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
    'df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid
  ]);

  select pg_catalog.count(*) into v_pricing_count
  from public.lane_pricing_rules
  where lane_id = any (array[
    '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
    '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
    '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
    '56ece689-5fde-4733-95d3-2c7aa1396c6c'::uuid,
    '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
    'df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid
  ]);

  if v_duration_count <> 0 or v_pricing_count <> 0 then
    raise exception 'Konfiguracja osi już istnieje: durations=%, pricing_rules=%.',
      v_duration_count, v_pricing_count;
  end if;

  select pg_catalog.count(*) into v_reservation_count
  from public.reservations;

  if v_reservation_count <> 0 then
    raise exception 'Konfiguracja początkowa wymaga pustej tabeli reservations.';
  end if;
end;
$preflight$;

update public.shooting_lanes
set max_shooters = case id
      when '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid then 5
      when '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid then 5
      else 6
    end,
    booking_step_minutes = 60,
    currency_code = 'PLN',
    display_order = case id
      when '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid then 10
      when '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid then 20
      when '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid then 30
      when '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid then 40
      else 50
    end,
    is_active = false,
    updated_at = pg_catalog.transaction_timestamp()
where id = any (array[
  '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
  '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
  '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
  '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
  'df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid
]);

update public.shooting_lanes
set display_order = 90,
    is_active = false,
    updated_at = pg_catalog.transaction_timestamp()
where id = '56ece689-5fde-4733-95d3-2c7aa1396c6c'::uuid;

insert into public.lane_booking_durations (
  lane_id, duration_minutes, display_order, is_active
)
select lane.id, duration.duration_minutes, duration.display_order, true
from (
  values
    ('8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid),
    ('4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid),
    ('254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid),
    ('063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid),
    ('df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid)
) as lane(id)
cross join (
  values (60, 10), (120, 20), (180, 30), (240, 40)
) as duration(duration_minutes, display_order);

insert into public.lane_pricing_rules (
  lane_id, day_group, min_shooters, max_shooters, label,
  hourly_price, display_order, is_active
)
select
  lane.id, price.day_group, price.min_shooters, price.max_shooters,
  price.label, price.hourly_price, price.display_order, true
from (
  values
    ('8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid),
    ('4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid)
) as lane(id)
cross join (
  values
    ('mon_thu', 1, 1, '1 strzelec', 50.00::numeric, 10),
    ('mon_thu', 2, 2, '2 strzelców', 90.00::numeric, 20),
    ('mon_thu', 3, 3, '3 strzelców', 120.00::numeric, 30),
    ('mon_thu', 4, 5, 'Pakiet grupowy — najlepsza cena na osobę', 150.00::numeric, 40),
    ('fri_sun', 1, 1, '1 strzelec', 65.00::numeric, 10),
    ('fri_sun', 2, 2, '2 strzelców', 120.00::numeric, 20),
    ('fri_sun', 3, 3, '3 strzelców', 160.00::numeric, 30),
    ('fri_sun', 4, 5, 'Pakiet grupowy — najlepsza cena na osobę', 200.00::numeric, 40)
) as price(day_group, min_shooters, max_shooters, label, hourly_price, display_order);

insert into public.lane_pricing_rules (
  lane_id, day_group, min_shooters, max_shooters, label,
  hourly_price, display_order, is_active
)
values
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'mon_thu', 1, 1, '1 strzelec', 90.00, 10, true),
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'mon_thu', 2, 2, '2 strzelców', 160.00, 20, true),
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'mon_thu', 3, 3, '3 strzelców', 220.00, 30, true),
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'mon_thu', 4, 6, 'Pakiet grupowy — najlepsza cena na osobę', 300.00, 40, true),
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'fri_sun', 1, 1, '1 strzelec', 120.00, 10, true),
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'fri_sun', 2, 2, '2 strzelców', 210.00, 20, true),
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'fri_sun', 3, 3, '3 strzelców', 280.00, 30, true),
  ('254ca7f6-ce80-4267-8966-4558cc8f8fd2', 'fri_sun', 4, 6, 'Pakiet grupowy — najlepsza cena na osobę', 380.00, 40, true);

insert into public.lane_pricing_rules (
  lane_id, day_group, min_shooters, max_shooters, label,
  hourly_price, display_order, is_active
)
select
  lane.id, price.day_group, price.min_shooters, price.max_shooters,
  price.label, price.hourly_price, price.display_order, true
from (
  values
    ('063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid),
    ('df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid)
) as lane(id)
cross join (
  values
    ('mon_thu', 1, 1, '1 strzelec', 80.00::numeric, 10),
    ('mon_thu', 2, 2, '2 strzelców', 130.00::numeric, 20),
    ('mon_thu', 3, 4, '3–4 strzelców', 180.00::numeric, 30),
    ('mon_thu', 5, 6, 'Pakiet grupowy — najlepsza cena na osobę', 220.00::numeric, 40),
    ('fri_sun', 1, 1, '1 strzelec', 110.00::numeric, 10),
    ('fri_sun', 2, 2, '2 strzelców', 170.00::numeric, 20),
    ('fri_sun', 3, 4, '3–4 strzelców', 230.00::numeric, 30),
    ('fri_sun', 5, 6, 'Pakiet grupowy — najlepsza cena na osobę', 280.00::numeric, 40)
) as price(day_group, min_shooters, max_shooters, label, hourly_price, display_order);

do $validate$
declare
  v_count integer;
begin
  select pg_catalog.count(*) into v_count
  from public.shooting_lanes
  where id = any (array[
    '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
    '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
    '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
    '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
    'df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid
  ])
    and not is_active
    and booking_step_minutes = 60
    and currency_code = 'PLN'
    and display_order in (10, 20, 30, 40, 50)
    and max_shooters = case
      when id in (
        '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
        '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid
      ) then 5
      else 6
    end;

  if v_count <> 5 then
    raise exception 'Końcowa walidacja parametrów pięciu osi nie powiodła się.';
  end if;

  if not exists (
    select 1 from public.shooting_lanes
    where id = '56ece689-5fde-4733-95d3-2c7aa1396c6c'::uuid
      and name = 'Bażant'
      and not is_active
      and display_order = 90
  ) then
    raise exception 'Końcowa walidacja osi Bażant nie powiodła się.';
  end if;

  select pg_catalog.count(*) into v_count
  from public.lane_booking_durations
  where lane_id = any (array[
    '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
    '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
    '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
    '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
    'df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid
  ])
    and is_active
    and (duration_minutes, display_order) in (
      (60, 10), (120, 20), (180, 30), (240, 40)
    );

  if v_count <> 20 then
    raise exception 'Oczekiwano dokładnie 20 aktywnych długości; znaleziono %.', v_count;
  end if;

  select pg_catalog.count(*) into v_count
  from public.lane_pricing_rules
  where lane_id = any (array[
    '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
    '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
    '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
    '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
    'df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid
  ]) and is_active;

  if v_count <> 40 then
    raise exception 'Oczekiwano dokładnie 40 aktywnych reguł cenowych; znaleziono %.', v_count;
  end if;

  if exists (
    select 1
    from (
      values
        ('8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
         array[50,90,120,150,65,120,160,200]::numeric[]),
        ('4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
         array[50,90,120,150,65,120,160,200]::numeric[]),
        ('254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
         array[90,160,220,300,120,210,280,380]::numeric[]),
        ('063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
         array[80,130,180,220,110,170,230,280]::numeric[]),
        ('df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid,
         array[80,130,180,220,110,170,230,280]::numeric[])
    ) as expected(lane_id, prices)
    where (
      select pg_catalog.array_agg(rule.hourly_price order by rule.day_group desc, rule.min_shooters)
      from public.lane_pricing_rules as rule
      where rule.lane_id = expected.lane_id and rule.is_active
    ) is distinct from expected.prices
  ) then
    raise exception 'Końcowa walidacja dokładnych cen nie powiodła się.';
  end if;

  if exists (
    select 1
    from public.lane_pricing_rules as rule
    where rule.lane_id = any (array[
      '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid,
      '4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid,
      '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid,
      '063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid,
      'df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid
    ])
      and (
        rule.display_order <> case
          when rule.min_shooters = 1 then 10
          when rule.min_shooters = 2 then 20
          when rule.min_shooters = 3 then 30
          else 40
        end
        or rule.label is distinct from case
          when rule.min_shooters = 1 and rule.max_shooters = 1 then '1 strzelec'
          when rule.min_shooters = 2 and rule.max_shooters = 2 then '2 strzelców'
          when rule.min_shooters = 3 and rule.max_shooters = 3 then '3 strzelców'
          when rule.min_shooters = 3 and rule.max_shooters = 4 then '3–4 strzelców'
          else 'Pakiet grupowy — najlepsza cena na osobę'
        end
      )
  ) then
    raise exception 'Końcowa walidacja etykiet lub kolejności progów nie powiodła się.';
  end if;

  if exists (
    select 1
    from (
      values
        ('8e49e6dd-8ec5-4f21-b63d-f59180cb9f77'::uuid, 5),
        ('4e93b955-da4f-438e-ac9b-9b197e220c49'::uuid, 5),
        ('254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid, 6),
        ('063cca57-4db6-4b05-b4d2-46ff1f5696f9'::uuid, 6),
        ('df4efac0-0203-4d23-84ac-3861a68e4e40'::uuid, 6)
    ) as lane(id, max_shooters)
    cross join (values ('mon_thu'::text), ('fri_sun'::text)) as day_group(name)
    cross join lateral pg_catalog.generate_series(1, lane.max_shooters) as shooter(value)
    where (
      select pg_catalog.count(*)
      from public.lane_pricing_rules as rule
      where rule.lane_id = lane.id
        and rule.day_group = day_group.name
        and rule.is_active
        and shooter.value between rule.min_shooters and rule.max_shooters
    ) <> 1
  ) then
    raise exception 'Cennik zawiera lukę albo nakładanie zakresów.';
  end if;

  if exists (
    select 1 from public.lane_booking_durations
    where lane_id = '56ece689-5fde-4733-95d3-2c7aa1396c6c'::uuid
  ) or exists (
    select 1 from public.lane_pricing_rules
    where lane_id = '56ece689-5fde-4733-95d3-2c7aa1396c6c'::uuid
  ) then
    raise exception 'Bażant nie może mieć długości ani cennika.';
  end if;

  if exists (select 1 from public.reservations) then
    raise exception 'Migracja konfiguracji nie może utworzyć rezerwacji.';
  end if;
end;
$validate$;
