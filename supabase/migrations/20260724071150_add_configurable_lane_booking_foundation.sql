do $preflight$
declare
  v_count bigint;
begin
  if pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.lane_blocks') is null
     or pg_catalog.to_regclass('auth.users') is null then
    raise exception 'Brak wymaganych tabel bazowych dla modelu rezerwacji.'
      using errcode = '42P01';
  end if;

  if pg_catalog.to_regprocedure('public.is_admin_or_employee()') is null then
    raise exception 'Brak wymaganego helpera public.is_admin_or_employee().'
      using errcode = '42883';
  end if;

  select pg_catalog.count(*)
  into v_count
  from public.reservations;

  if v_count <> 0 then
    raise exception
      'Migracja wymaga pustej tabeli public.reservations; znaleziono % rekordów.',
      v_count
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.reservations
    where user_id is null
       or lane_id is null
       or check_in_token is null
  ) then
    raise exception
      'public.reservations zawiera NULL w user_id, lane_id lub check_in_token.'
      using errcode = '23502';
  end if;

  if pg_catalog.to_regclass('public.lane_booking_durations') is not null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is not null then
    raise exception
      'Docelowe tabele konfiguracji osi już istnieją; wymagany jest osobny audyt ich struktury.'
      using errcode = '42P07';
  end if;

  if pg_catalog.to_regprocedure(
       'public.set_booking_configuration_updated_at()'
     ) is not null then
    raise exception
      'Funkcja public.set_booking_configuration_updated_at() już istnieje.'
      using errcode = '42723';
  end if;

  if pg_catalog.to_regnamespace('extensions') is null then
    raise exception 'Brak schematu extensions wymaganego dla btree_gist.'
      using errcode = '3F000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_available_extensions
    where name = 'btree_gist'
  ) then
    raise exception 'Rozszerzenie btree_gist nie jest dostępne.'
      using errcode = '0A000';
  end if;

  if exists (
    select 1
    from public.lane_blocks as lane_block
    where lane_block.lane_id is null
       or lane_block.start_time is null
       or lane_block.end_time is null
       or lane_block.end_time <= lane_block.start_time
       or not exists (
         select 1
         from public.shooting_lanes as lane
         where lane.id = lane_block.lane_id
       )
  ) then
    raise exception
      'lane_blocks zawiera NULL, nieprawidłowy przedział czasu lub osieroconą oś.'
      using errcode = '23514';
  end if;
end;
$preflight$;

create extension if not exists btree_gist with schema extensions;

create function public.set_booking_configuration_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $function$
begin
  new.updated_at := pg_catalog.transaction_timestamp();
  return new;
end;
$function$;

comment on function public.set_booking_configuration_updated_at() is
  'Ustawia updated_at dla konfiguracji osi przed każdą aktualizacją.';

revoke all on function public.set_booking_configuration_updated_at()
from public;
revoke all on function public.set_booking_configuration_updated_at()
from anon;
revoke all on function public.set_booking_configuration_updated_at()
from authenticated;

alter table public.shooting_lanes
  add column max_shooters integer not null default 1,
  add column booking_step_minutes integer not null default 60,
  add column display_order integer not null default 0,
  add column currency_code char(3) not null default 'PLN',
  add column updated_at timestamptz not null
    default pg_catalog.transaction_timestamp(),
  add constraint shooting_lanes_max_shooters_check
    check (max_shooters >= 1),
  add constraint shooting_lanes_booking_step_minutes_check
    check (
      booking_step_minutes > 0
      and booking_step_minutes <= 1440
    ),
  add constraint shooting_lanes_display_order_check
    check (display_order >= 0),
  add constraint shooting_lanes_currency_code_check
    check (currency_code::text ~ '^[A-Z]{3}$');

update public.shooting_lanes
set is_active = false,
    max_shooters = 1,
    booking_step_minutes = 60,
    display_order = 0,
    currency_code = 'PLN',
    updated_at = pg_catalog.transaction_timestamp();

comment on column public.shooting_lanes.price_per_hour is
  'LEGACY: stara stawka godzinowa. Po przełączeniu formularza i raportów źródłem cen będą lane_pricing_rules oraz snapshoty reservations.';
comment on column public.shooting_lanes.max_shooters is
  'Maksymalna liczba strzelców dopuszczona dla rezerwacji osi.';
comment on column public.shooting_lanes.booking_step_minutes is
  'Krok minutowy dostępnych godzin rozpoczęcia rezerwacji.';
comment on column public.shooting_lanes.display_order is
  'Kolejność wyświetlania osi w interfejsie.';
comment on column public.shooting_lanes.currency_code is
  'Trzyliterowy kod waluty ISO używany przez cennik osi.';

create trigger set_shooting_lanes_updated_at
before update on public.shooting_lanes
for each row
execute function public.set_booking_configuration_updated_at();

create table public.lane_booking_durations (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  lane_id uuid not null,
  duration_minutes integer not null,
  display_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null
    default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null
    default pg_catalog.transaction_timestamp(),
  constraint lane_booking_durations_lane_id_fkey
    foreign key (lane_id)
    references public.shooting_lanes (id)
    on delete restrict,
  constraint lane_booking_durations_duration_check
    check (
      duration_minutes > 0
      and duration_minutes <= 1440
    ),
  constraint lane_booking_durations_display_order_check
    check (display_order >= 0),
  constraint lane_booking_durations_lane_duration_key
    unique (lane_id, duration_minutes)
);

comment on table public.lane_booking_durations is
  'Konfigurowalne długości rezerwacji dostępne dla poszczególnych osi.';

create index lane_booking_durations_active_order_idx
on public.lane_booking_durations (
  lane_id,
  display_order,
  duration_minutes
)
where is_active;

create trigger set_lane_booking_durations_updated_at
before update on public.lane_booking_durations
for each row
execute function public.set_booking_configuration_updated_at();

create table public.lane_pricing_rules (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  lane_id uuid not null,
  min_shooters integer not null,
  max_shooters integer not null,
  label text not null,
  hourly_price numeric(12,2) not null,
  display_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null
    default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null
    default pg_catalog.transaction_timestamp(),
  constraint lane_pricing_rules_lane_id_fkey
    foreign key (lane_id)
    references public.shooting_lanes (id)
    on delete restrict,
  constraint lane_pricing_rules_min_shooters_check
    check (min_shooters >= 1),
  constraint lane_pricing_rules_shooters_range_check
    check (max_shooters >= min_shooters),
  constraint lane_pricing_rules_label_check
    check (pg_catalog.btrim(label) <> ''),
  constraint lane_pricing_rules_hourly_price_check
    check (hourly_price >= 0),
  constraint lane_pricing_rules_display_order_check
    check (display_order >= 0),
  constraint lane_pricing_rules_active_ranges_excl
    exclude using gist (
      lane_id with =,
      int4range(min_shooters, max_shooters, '[]') with &&
    )
    where (is_active)
);

comment on table public.lane_pricing_rules is
  'Aktywne i historyczne progi cenowe osi zależne od liczby strzelców.';
comment on column public.lane_pricing_rules.label is
  'Snapshot tej etykiety jest zapisywany w reservations przy tworzeniu rezerwacji.';

create index lane_pricing_rules_lane_id_idx
on public.lane_pricing_rules (lane_id);

create index lane_pricing_rules_active_order_idx
on public.lane_pricing_rules (
  lane_id,
  display_order,
  min_shooters,
  max_shooters
)
where is_active;

create trigger set_lane_pricing_rules_updated_at
before update on public.lane_pricing_rules
for each row
execute function public.set_booking_configuration_updated_at();

alter table public.lane_booking_durations enable row level security;
alter table public.lane_pricing_rules enable row level security;

revoke all on table public.lane_booking_durations from public;
revoke all on table public.lane_booking_durations from anon;
revoke all on table public.lane_booking_durations from authenticated;

revoke all on table public.lane_pricing_rules from public;
revoke all on table public.lane_pricing_rules from anon;
revoke all on table public.lane_pricing_rules from authenticated;

grant select on table public.lane_booking_durations to anon;
grant select, insert, update, delete
on table public.lane_booking_durations
to authenticated;

grant select on table public.lane_pricing_rules to anon;
grant select, insert, update, delete
on table public.lane_pricing_rules
to authenticated;

create policy "Active lane durations are readable"
on public.lane_booking_durations
for select
to anon, authenticated
using (
  is_active
  and exists (
    select 1
    from public.shooting_lanes as lane
    where lane.id = lane_booking_durations.lane_id
      and lane.is_active
  )
);

create policy "Admins and employees manage lane durations"
on public.lane_booking_durations
for all
to authenticated
using (public.is_admin_or_employee())
with check (public.is_admin_or_employee());

create policy "Active lane pricing rules are readable"
on public.lane_pricing_rules
for select
to anon, authenticated
using (
  is_active
  and exists (
    select 1
    from public.shooting_lanes as lane
    where lane.id = lane_pricing_rules.lane_id
      and lane.is_active
  )
);

create policy "Admins and employees manage lane pricing rules"
on public.lane_pricing_rules
for all
to authenticated
using (public.is_admin_or_employee())
with check (public.is_admin_or_employee());

do $replace_lane_foreign_keys$
declare
  v_constraint_name name;
  v_constraint_count integer;
begin
  select
    pg_catalog.count(*),
    pg_catalog.min(constraint_record.conname)
  into
    v_constraint_count,
    v_constraint_name
  from pg_catalog.pg_constraint as constraint_record
  join pg_catalog.pg_attribute as attribute_record
    on attribute_record.attrelid = constraint_record.conrelid
   and attribute_record.attname = 'lane_id'
  where constraint_record.contype = 'f'
    and constraint_record.conrelid =
          'public.reservations'::pg_catalog.regclass
    and constraint_record.confrelid =
          'public.shooting_lanes'::pg_catalog.regclass
    and constraint_record.conkey =
          array[attribute_record.attnum]::smallint[];

  if v_constraint_count <> 1 then
    raise exception
      'Oczekiwano jednego FK reservations.lane_id -> shooting_lanes.id; znaleziono %.',
      v_constraint_count;
  end if;

  execute pg_catalog.format(
    'alter table public.reservations drop constraint %I',
    v_constraint_name
  );

  select
    pg_catalog.count(*),
    pg_catalog.min(constraint_record.conname)
  into
    v_constraint_count,
    v_constraint_name
  from pg_catalog.pg_constraint as constraint_record
  join pg_catalog.pg_attribute as attribute_record
    on attribute_record.attrelid = constraint_record.conrelid
   and attribute_record.attname = 'lane_id'
  where constraint_record.contype = 'f'
    and constraint_record.conrelid =
          'public.lane_blocks'::pg_catalog.regclass
    and constraint_record.confrelid =
          'public.shooting_lanes'::pg_catalog.regclass
    and constraint_record.conkey =
          array[attribute_record.attnum]::smallint[];

  if v_constraint_count <> 1 then
    raise exception
      'Oczekiwano jednego FK lane_blocks.lane_id -> shooting_lanes.id; znaleziono %.',
      v_constraint_count;
  end if;

  execute pg_catalog.format(
    'alter table public.lane_blocks drop constraint %I',
    v_constraint_name
  );
end;
$replace_lane_foreign_keys$;

alter table public.lane_blocks
  alter column lane_id set not null,
  add constraint lane_blocks_lane_id_fkey
    foreign key (lane_id)
    references public.shooting_lanes (id)
    on delete restrict,
  add constraint lane_blocks_time_range_check
    check (end_time > start_time);

create index lane_blocks_active_schedule_idx
on public.lane_blocks (
  lane_id,
  block_date,
  is_active,
  start_time,
  end_time
);

do $verify_reservation_user_fk$
declare
  v_count integer;
begin
  select pg_catalog.count(*)
  into v_count
  from pg_catalog.pg_constraint as constraint_record
  join pg_catalog.pg_attribute as attribute_record
    on attribute_record.attrelid = constraint_record.conrelid
   and attribute_record.attname = 'user_id'
  where constraint_record.contype = 'f'
    and constraint_record.conrelid =
          'public.reservations'::pg_catalog.regclass
    and constraint_record.conkey =
          array[attribute_record.attnum]::smallint[];

  if v_count <> 0 then
    raise exception
      'reservations.user_id posiada już % FK; wymagany jest osobny audyt.',
      v_count;
  end if;
end;
$verify_reservation_user_fk$;

alter table public.reservations
  add column shooters_count integer not null,
  add column pricing_rule_id uuid not null,
  add column lane_name_snapshot text not null,
  add column pricing_label_snapshot text not null,
  add column price_per_hour_snapshot numeric(12,2) not null,
  add column total_price numeric(12,2) not null,
  add column currency_code char(3) not null,
  add column creation_request_id uuid not null,
  add column booking_period tsrange
    generated always as (
      pg_catalog.tsrange(
        reservation_date + start_time,
        reservation_date + end_time,
        '[)'
      )
    ) stored,
  alter column user_id set not null,
  alter column lane_id set not null,
  alter column check_in_token set not null,
  add constraint reservations_lane_id_fkey
    foreign key (lane_id)
    references public.shooting_lanes (id)
    on delete restrict,
  add constraint reservations_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,
  add constraint reservations_pricing_rule_id_fkey
    foreign key (pricing_rule_id)
    references public.lane_pricing_rules (id)
    on delete restrict,
  add constraint reservations_shooters_count_check
    check (shooters_count >= 1),
  add constraint reservations_duration_minutes_check
    check (
      duration_minutes > 0
      and duration_minutes <= 1440
    ),
  add constraint reservations_time_range_check
    check (end_time > start_time),
  add constraint reservations_lane_name_snapshot_check
    check (pg_catalog.btrim(lane_name_snapshot) <> ''),
  add constraint reservations_pricing_label_snapshot_check
    check (pg_catalog.btrim(pricing_label_snapshot) <> ''),
  add constraint reservations_price_per_hour_snapshot_check
    check (price_per_hour_snapshot >= 0),
  add constraint reservations_total_price_check
    check (total_price >= 0),
  add constraint reservations_legacy_price_matches_total_check
    check (price = total_price),
  add constraint reservations_currency_code_check
    check (currency_code::text ~ '^[A-Z]{3}$'),
  add constraint reservations_user_creation_request_key
    unique (user_id, creation_request_id),
  add constraint reservations_reservation_status_check
    check (
      reservation_status = pg_catalog.lower(
        pg_catalog.btrim(reservation_status)
      )
      and reservation_status in (
        'confirmed',
        'completed',
        'no_show',
        'cancelled',
        'canceled',
        'cancelled_by_admin',
        'cancelled_by_user'
      )
    ),
  add constraint reservations_payment_status_check
    check (
      payment_status = pg_catalog.lower(
        pg_catalog.btrim(payment_status)
      )
      and payment_status in (
        'pay_on_site',
        'paid',
        'paid_on_site',
        'unpaid',
        'free',
        'voucher'
      )
    ),
  add constraint reservations_attendance_status_check
    check (
      attendance_status is null
      or (
        attendance_status = pg_catalog.lower(
          pg_catalog.btrim(attendance_status)
        )
        and attendance_status in (
          'planned',
          'present',
          'completed',
          'no_show'
        )
      )
    ),
  add constraint reservations_no_overlapping_active_booking
    exclude using gist (
      lane_id with =,
      booking_period with &&
    )
    where (
      pg_catalog.lower(
        pg_catalog.btrim(reservation_status)
      ) not in (
        'completed',
        'no_show',
        'cancelled',
        'canceled',
        'cancelled_by_admin',
        'cancelled_by_user'
      )
    );

comment on column public.reservations.price is
  'LEGACY alias total_price. Nowe RPC zapisuje price i total_price identycznie; kolumna zostanie usunięta po migracji wszystkich odczytów.';
comment on column public.reservations.shooters_count is
  'Liczba strzelców zadeklarowana przy utworzeniu rezerwacji.';
comment on column public.reservations.pricing_rule_id is
  'Reguła cenowa użyta do wyliczenia snapshotów rezerwacji.';
comment on column public.reservations.lane_name_snapshot is
  'Historyczna nazwa osi z chwili utworzenia rezerwacji.';
comment on column public.reservations.pricing_label_snapshot is
  'Historyczna etykieta progu cenowego.';
comment on column public.reservations.price_per_hour_snapshot is
  'Historyczna stawka godzinowa użyta do wyliczenia ceny.';
comment on column public.reservations.total_price is
  'Końcowa cena rezerwacji obliczona przez bazę.';
comment on column public.reservations.creation_request_id is
  'Identyfikator idempotencji pojedynczego żądania utworzenia rezerwacji.';
comment on column public.reservations.booking_period is
  'Półotwarty przedział [start,end) używany do ochrony przed kolizjami.';

-- Celowo nie seedujemy długości ani cen i nie aktywujemy osi.
-- Kompletność zakresów 1..max_shooters oraz zgodność max_shooters reguły
-- z pojemnością osi zostaną wymuszone przez przyszłe administracyjne RPC.
-- Polityka "Users can insert own reservations" pozostaje tymczasowo
-- bez zmian do czasu wdrożenia RPC tworzącego rezerwację i nowego frontendu.
