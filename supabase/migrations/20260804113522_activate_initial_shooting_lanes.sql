-- Aktywuje pięć skonfigurowanych osi po pełnej kontroli stanu produkcyjnego.
-- Bażant pozostaje nieaktywny i bez konfiguracji rezerwacyjnej.

do $activate_initial_shooting_lanes$
declare
  v_lane_50_1 constant uuid := '8e49e6dd-8ec5-4f21-b63d-f59180cb9f77';
  v_lane_50_2 constant uuid := '4e93b955-da4f-438e-ac9b-9b197e220c49';
  v_lane_100 constant uuid := '254ca7f6-ce80-4267-8966-4558cc8f8fd2';
  v_trap constant uuid := '063cca57-4db6-4b05-b4d2-46ff1f5696f9';
  v_skeet constant uuid := 'df4efac0-0203-4d23-84ac-3861a68e4e40';
  v_bazant constant uuid := '56ece689-5fde-4733-95d3-2c7aa1396c6c';
  v_updated_count integer;
  v_axes_before jsonb;
  v_durations_before jsonb;
  v_prices_before jsonb;
  v_axes_after jsonb;
  v_durations_after jsonb;
  v_prices_after jsonb;
begin
  if pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.lane_booking_durations') is null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is null then
    raise exception 'Brakuje wymaganych tabel konfiguracji osi.';
  end if;

  if (select pg_catalog.count(*) from public.reservations) <> 0 then
    raise exception 'Aktywacja wymaga pustej tabeli public.reservations.';
  end if;

  if (
    select pg_catalog.count(*)
    from public.shooting_lanes as lane
    where lane.id in (
      v_lane_50_1, v_lane_50_2, v_lane_100,
      v_trap, v_skeet, v_bazant
    )
  ) <> 6 then
    raise exception 'Nie znaleziono dokładnie sześciu oczekiwanych osi.';
  end if;

  if exists (
    select 1
    from (
      values
        (v_lane_50_1, 'Oś 50 m — stanowisko 1'),
        (v_lane_50_2, 'Oś 50 m — stanowisko 2'),
        (v_lane_100, 'Oś 100 m'),
        (v_trap, 'Trap'),
        (v_skeet, 'Skeet'),
        (v_bazant, 'Bażant')
    ) as expected(id, name)
    left join public.shooting_lanes as lane on lane.id = expected.id
    where lane.id is null
       or lane.name is distinct from expected.name
  ) then
    raise exception 'UUID i nazwy osi nie są zgodne z zatwierdzonym manifestem.';
  end if;

  if exists (
    select 1
    from public.shooting_lanes as lane
    where lane.id in (
      v_lane_50_1, v_lane_50_2, v_lane_100,
      v_trap, v_skeet, v_bazant
    )
      and lane.is_active
  ) then
    raise exception 'Wszystkie sześć osi musi być nieaktywnych przed aktywacją.';
  end if;

  if (select pg_catalog.count(*) from public.lane_booking_durations) <> 20 then
    raise exception 'Oczekiwano dokładnie 20 długości rezerwacji.';
  end if;

  if (select pg_catalog.count(*) from public.lane_pricing_rules) <> 40 then
    raise exception 'Oczekiwano dokładnie 40 reguł cenowych.';
  end if;

  if (
    select pg_catalog.count(*)
    from (
      values (v_lane_50_1), (v_lane_50_2), (v_lane_100), (v_trap), (v_skeet)
    ) as expected(id)
    where (select pg_catalog.count(*) from public.lane_booking_durations as duration where duration.lane_id = expected.id) = 4
      and (select pg_catalog.count(*) from public.lane_pricing_rules as rule where rule.lane_id = expected.id) = 8
  ) <> 5 then
    raise exception 'Dokładnie pięć osi musi mieć pełną konfigurację.';
  end if;

  if exists (
    select 1 from public.lane_booking_durations where lane_id = v_bazant
  ) or exists (
    select 1 from public.lane_pricing_rules where lane_id = v_bazant
  ) then
    raise exception 'Bażant nie może mieć długości ani reguł cenowych.';
  end if;

  if exists (
    select 1
    from (
      values
        (v_lane_50_1, 5, 10),
        (v_lane_50_2, 5, 20),
        (v_lane_100, 6, 30),
        (v_trap, 6, 40),
        (v_skeet, 6, 50)
    ) as expected(id, max_shooters, display_order)
    left join public.shooting_lanes as lane on lane.id = expected.id
    where lane.id is null
       or lane.max_shooters is distinct from expected.max_shooters
       or lane.booking_step_minutes is distinct from 60
       or lane.currency_code::text is distinct from 'PLN'
       or lane.display_order is distinct from expected.display_order
  ) then
    raise exception 'Parametry pięciu osi różnią się od zatwierdzonej konfiguracji.';
  end if;

  if not exists (
    select 1
    from public.shooting_lanes
    where id = v_bazant
      and display_order = 90
  ) then
    raise exception 'Bażant musi mieć display_order=90.';
  end if;

  if exists (
    select 1
    from (
      values (v_lane_50_1), (v_lane_50_2), (v_lane_100), (v_trap), (v_skeet)
    ) as expected(id)
    where coalesce((
      select pg_catalog.array_agg(duration.duration_minutes order by duration.duration_minutes)
      from public.lane_booking_durations as duration
      where duration.lane_id = expected.id
        and duration.is_active
    ), array[]::integer[]) <> array[60, 120, 180, 240]
  ) then
    raise exception 'Długości osi nie są zgodne z zestawem 60/120/180/240.';
  end if;

  if exists (
    select 1
    from (
      values (v_lane_50_1), (v_lane_50_2), (v_lane_100), (v_trap), (v_skeet)
    ) as expected(id)
    cross join (values ('mon_thu'), ('fri_sun')) as day_group(value)
    where (
      select pg_catalog.count(*)
      from public.lane_pricing_rules as rule
      where rule.lane_id = expected.id
        and rule.day_group = day_group.value
        and rule.is_active
    ) <> 4
  ) then
    raise exception 'Każda oś musi mieć po cztery aktywne reguły w obu taryfach.';
  end if;

  if exists (
    select 1
    from public.lane_pricing_rules as left_rule
    join public.lane_pricing_rules as right_rule
      on right_rule.lane_id = left_rule.lane_id
     and right_rule.day_group = left_rule.day_group
     and right_rule.id > left_rule.id
     and right_rule.is_active
     and left_rule.is_active
     and pg_catalog.int4range(right_rule.min_shooters, right_rule.max_shooters, '[]')
         && pg_catalog.int4range(left_rule.min_shooters, left_rule.max_shooters, '[]')
  ) then
    raise exception 'Aktywne progi cenowe nakładają się.';
  end if;

  if exists (
    select 1
    from (
      values
        (v_lane_50_1, 5), (v_lane_50_2, 5), (v_lane_100, 6),
        (v_trap, 6), (v_skeet, 6)
    ) as expected(id, max_shooters)
    cross join (values ('mon_thu'), ('fri_sun')) as day_group(value)
    cross join lateral pg_catalog.generate_series(1, expected.max_shooters) as shooter(value)
    where (
      select pg_catalog.count(*)
      from public.lane_pricing_rules as rule
      where rule.lane_id = expected.id
        and rule.day_group = day_group.value
        and rule.is_active
        and shooter.value between rule.min_shooters and rule.max_shooters
    ) <> 1
  ) then
    raise exception 'Cennik zawiera lukę albo wielokrotne dopasowanie.';
  end if;

  if exists (
    select 1
    from public.lane_booking_durations as duration
    left join public.shooting_lanes as lane on lane.id = duration.lane_id
    where lane.id is null
  ) or exists (
    select 1
    from public.lane_pricing_rules as rule
    left join public.shooting_lanes as lane on lane.id = rule.lane_id
    where lane.id is null
  ) then
    raise exception 'Konfiguracja zawiera osierocone rekordy.';
  end if;

  select pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'id', lane.id,
      'name', lane.name,
      'max_shooters', lane.max_shooters,
      'booking_step_minutes', lane.booking_step_minutes,
      'display_order', lane.display_order,
      'currency_code', lane.currency_code,
      'price_per_hour', lane.price_per_hour,
      'created_at', lane.created_at
    ) order by lane.id
  )
  into v_axes_before
  from public.shooting_lanes as lane
  where lane.id in (
    v_lane_50_1, v_lane_50_2, v_lane_100,
    v_trap, v_skeet, v_bazant
  );

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration) order by duration.id)
  into v_durations_before
  from public.lane_booking_durations as duration;

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule) order by rule.id)
  into v_prices_before
  from public.lane_pricing_rules as rule;

  update public.shooting_lanes
  set is_active = true
  where id in (v_lane_50_1, v_lane_50_2, v_lane_100, v_trap, v_skeet)
    and is_active = false;

  get diagnostics v_updated_count = row_count;

  if v_updated_count <> 5 then
    raise exception 'Aktywacja zmieniła % rekordów zamiast dokładnie 5.', v_updated_count;
  end if;

  if (select pg_catalog.count(*) from public.shooting_lanes where is_active) <> 5
     or exists (
       select 1
       from public.shooting_lanes
       where is_active
         and id not in (v_lane_50_1, v_lane_50_2, v_lane_100, v_trap, v_skeet)
     ) then
    raise exception 'Po aktywacji aktywne muszą być wyłącznie zatwierdzone osie.';
  end if;

  if not exists (
    select 1 from public.shooting_lanes where id = v_bazant and is_active = false
  ) then
    raise exception 'Bażant musi pozostać nieaktywny.';
  end if;

  if (select pg_catalog.count(*) from public.lane_booking_durations) <> 20
     or (select pg_catalog.count(*) from public.lane_pricing_rules) <> 40
     or (select pg_catalog.count(*) from public.reservations) <> 0 then
    raise exception 'Aktywacja zmieniła liczby konfiguracji albo rezerwacji.';
  end if;

  if exists (select 1 from public.lane_booking_durations where lane_id = v_bazant)
     or exists (select 1 from public.lane_pricing_rules where lane_id = v_bazant) then
    raise exception 'Bażant otrzymał niedozwoloną konfigurację.';
  end if;

  select pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'id', lane.id,
      'name', lane.name,
      'max_shooters', lane.max_shooters,
      'booking_step_minutes', lane.booking_step_minutes,
      'display_order', lane.display_order,
      'currency_code', lane.currency_code,
      'price_per_hour', lane.price_per_hour,
      'created_at', lane.created_at
    ) order by lane.id
  )
  into v_axes_after
  from public.shooting_lanes as lane
  where lane.id in (
    v_lane_50_1, v_lane_50_2, v_lane_100,
    v_trap, v_skeet, v_bazant
  );

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration) order by duration.id)
  into v_durations_after
  from public.lane_booking_durations as duration;

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule) order by rule.id)
  into v_prices_after
  from public.lane_pricing_rules as rule;

  if v_axes_after is distinct from v_axes_before
     or v_durations_after is distinct from v_durations_before
     or v_prices_after is distinct from v_prices_before then
    raise exception 'Aktywacja zmieniła parametry osi, długości albo cennik.';
  end if;
end;
$activate_initial_shooting_lanes$;
