do $preflight$
declare
  v_create_count integer;
  v_lock_count integer;
  v_trigger_count integer;
  v_expected_trigger_count integer;
  v_policy_count integer;
  v_rpc_count integer;
begin
  if pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_lanes') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.lane_blocks') is null
     or pg_catalog.to_regclass('public.lane_booking_durations') is null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is null
     or pg_catalog.to_regclass('public.profiles') is null then
    raise exception 'Brak tabel wymaganych przez ochronę konfliktów osi.'
      using errcode = '42P01';
  end if;

  select pg_catalog.count(*) into v_create_count
  from pg_catalog.pg_proc as procedure_record
  join pg_catalog.pg_namespace as namespace_record
    on namespace_record.oid = procedure_record.pronamespace
  where namespace_record.nspname = 'public'
    and procedure_record.proname = 'create_reservation';

  if v_create_count <> 1
     or pg_catalog.to_regprocedure(
       'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
     ) is null then
    raise exception 'Nieoczekiwane sygnatury public.create_reservation.'
      using errcode = '42883';
  end if;

  select pg_catalog.count(*) into v_lock_count
  from pg_catalog.pg_proc as procedure_record
  join pg_catalog.pg_namespace as namespace_record
    on namespace_record.oid = procedure_record.pronamespace
  where namespace_record.nspname = 'public'
    and procedure_record.proname = 'lock_lane_booking_configuration';

  if v_lock_count <> 1
     or pg_catalog.to_regprocedure(
       'public.lock_lane_booking_configuration()'
     ) is null then
    raise exception 'Nieoczekiwane sygnatury helpera blokad osi.'
      using errcode = '42883';
  end if;

  if pg_catalog.to_regprocedure('public.is_admin_or_employee()') is null then
    raise exception 'Brak helpera public.is_admin_or_employee().'
      using errcode = '42883';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid =
          'public.reservations'::pg_catalog.regclass
      and constraint_record.conname =
          'reservations_no_overlapping_active_booking'
      and constraint_record.contype = 'x'
  ) then
    raise exception 'Brak exclusion constraint aktywnych rezerwacji.'
      using errcode = '42704';
  end if;

  select
    pg_catalog.count(*),
    pg_catalog.count(*) filter (
      where
        (trigger_record.tgname = 'lock_lane_blocks_configuration'
         and trigger_record.tgrelid =
             'public.lane_blocks'::pg_catalog.regclass)
        or
        (trigger_record.tgname = 'lock_lane_booking_durations_configuration'
         and trigger_record.tgrelid =
             'public.lane_booking_durations'::pg_catalog.regclass)
        or
        (trigger_record.tgname = 'lock_lane_pricing_rules_configuration'
         and trigger_record.tgrelid =
             'public.lane_pricing_rules'::pg_catalog.regclass)
    )
  into v_trigger_count, v_expected_trigger_count
  from pg_catalog.pg_trigger as trigger_record
  where trigger_record.tgfoid =
      'public.lock_lane_booking_configuration()'::pg_catalog.regprocedure
    and not trigger_record.tgisinternal;

  if v_trigger_count <> 3 or v_expected_trigger_count <> 3 then
    raise exception 'Nieoczekiwany zestaw triggerów konfiguracji osi.'
      using errcode = '42704';
  end if;

  select pg_catalog.count(*) into v_policy_count
  from pg_catalog.pg_policies as policy_record
  where policy_record.schemaname = 'public'
    and policy_record.tablename = 'lane_blocks';

  if v_policy_count <> 5
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'lane_blocks'
         and policyname = 'Admins and staff can insert lane blocks'
         and cmd = 'INSERT'
         and 'authenticated' = any(roles)
         and pg_catalog.cardinality(roles) = 1
         and with_check ~ 'is_admin_or_staff[(][)]'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'lane_blocks'
         and policyname = 'Admins and staff can update lane blocks'
         and cmd = 'UPDATE'
         and 'authenticated' = any(roles)
         and pg_catalog.cardinality(roles) = 1
         and qual ~ 'is_admin_or_staff[(][)]'
         and with_check ~ 'is_admin_or_staff[(][)]'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'lane_blocks'
         and policyname = 'Admins and staff can delete lane blocks'
         and cmd = 'DELETE'
         and 'authenticated' = any(roles)
         and pg_catalog.cardinality(roles) = 1
         and qual ~ 'is_admin_or_staff[(][)]'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'lane_blocks'
         and policyname = 'Admins and staff can view all lane blocks'
         and cmd = 'SELECT'
         and 'authenticated' = any(roles)
         and pg_catalog.cardinality(roles) = 1
         and qual ~ 'is_admin_or_staff[(][)]'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'lane_blocks'
         and policyname = 'Anyone can view active lane blocks'
         and cmd = 'SELECT'
         and 'authenticated' = any(roles)
         and pg_catalog.cardinality(roles) = 1
         and qual ~ 'is_active[[:space:]]*=[[:space:]]*true'
     ) then
    raise exception 'Nieoczekiwany zestaw polityk public.lane_blocks.'
      using errcode = '42704';
  end if;

  select pg_catalog.count(*) into v_rpc_count
  from pg_catalog.pg_proc as procedure_record
  join pg_catalog.pg_namespace as namespace_record
    on namespace_record.oid = procedure_record.pronamespace
  where namespace_record.nspname = 'public'
    and procedure_record.proname in (
      'admin_create_event',
      'admin_update_event',
      'admin_set_event_active'
    );

  if v_rpc_count <> 3
     or pg_catalog.to_regprocedure(
       'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.admin_set_event_active(uuid,boolean)'
     ) is null then
    raise exception 'Nieoczekiwany zestaw administracyjnych RPC eventów.'
      using errcode = '42883';
  end if;
end;
$preflight$;

create or replace function public.lock_lane_booking_configuration()
returns trigger
language plpgsql
security invoker
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_lane_id uuid;
begin
  for v_lane_id in
    select candidate.lane_id
    from (
      select case when tg_op in ('UPDATE', 'DELETE') then old.lane_id end
        as lane_id
      union
      select case when tg_op in ('INSERT', 'UPDATE') then new.lane_id end
        as lane_id
    ) as candidate
    where candidate.lane_id is not null
    order by candidate.lane_id
  loop
    perform 1
    from public.shooting_lanes as lane
    where lane.id = v_lane_id
    for update;

  end loop;

  if tg_table_schema = 'public'
     and tg_table_name = 'lane_blocks'
     and tg_op in ('INSERT', 'UPDATE')
     and new.is_active then
    if exists (
      select 1
      from public.reservations as reservation
      where reservation.lane_id = new.lane_id
        and reservation.reservation_date = new.block_date
        and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
            not in (
              'completed',
              'no_show',
              'cancelled',
              'canceled',
              'cancelled_by_admin',
              'cancelled_by_user'
            )
        and reservation.start_time < new.end_time
        and reservation.end_time > new.start_time
    ) then
      raise exception 'Aktywna rezerwacja koliduje z blokadą osi.'
        using
          errcode = '23P01',
          constraint = 'lane_blocks_no_active_reservation_overlap';
    end if;
  end if;

  if tg_table_schema = 'public'
     and tg_table_name = 'lane_blocks'
     and tg_op in ('INSERT', 'UPDATE')
     and new.is_active then
    if exists (
      select 1
      from public.event_lanes as event_lane
      join public.events as event_record
        on event_record.id = event_lane.event_id
      where event_lane.lane_id = new.lane_id
        and event_record.is_active is true
        and event_record.event_date = new.block_date
        and event_record.start_time < new.end_time
        and event_record.end_time > new.start_time
    ) then
      raise exception 'Aktywny event koliduje z blokadą osi.'
        using
          errcode = '23P01',
          constraint = 'lane_blocks_no_active_event_overlap';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$function$;

create or replace function public.create_reservation(
  p_lane_id uuid,
  p_reservation_date date,
  p_start_time time without time zone,
  p_duration_minutes integer,
  p_shooters_count integer,
  p_creation_request_id uuid,
  p_reservation_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_lane public.shooting_lanes%rowtype;
  v_profile public.profiles%rowtype;
  v_existing public.reservations%rowtype;
  v_created public.reservations%rowtype;
  v_pricing_rule public.lane_pricing_rules%rowtype;
  v_customer_name text;
  v_customer_email text;
  v_customer_phone text;
  v_role text;
  v_verification_status text;
  v_note text;
  v_end_timestamp timestamp without time zone;
  v_end_time time without time zone;
  v_start_in_warsaw timestamptz;
  v_total_price numeric(12,2);
  v_pricing_count integer;
  v_pricing_day_group text;
  v_constraint_name text;
begin
  if v_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'unauthorized'
    );
  end if;

  if p_creation_request_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_request_id'
    );
  end if;

  if p_lane_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_not_found'
    );
  end if;

  if p_reservation_date is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_date'
    );
  end if;

  v_pricing_day_group := case
    when extract(isodow from p_reservation_date)::integer between 1 and 4
      then 'mon_thu'
    else 'fri_sun'
  end;

  if p_start_time is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_start_time'
    );
  end if;

  if p_duration_minutes is null or p_duration_minutes <= 0 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_duration'
    );
  end if;

  if p_shooters_count is null or p_shooters_count < 1 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_shooters_count'
    );
  end if;

  v_note := nullif(
    pg_catalog.regexp_replace(
      pg_catalog.btrim(coalesce(p_reservation_note, '')),
      '[[:space:]]+',
      ' ',
      'g'
    ),
    ''
  );

  if pg_catalog.length(coalesce(v_note, '')) > 1000 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_request'
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_not_found'
    );
  end if;

  select profile.*
  into v_profile
  from public.profiles as profile
  where profile.user_id = v_user_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'profile_not_found'
    );
  end if;

  select reservation.*
  into v_existing
  from public.reservations as reservation
  where reservation.user_id = v_user_id
    and reservation.creation_request_id = p_creation_request_id
  for update;

  if found then
    if v_existing.lane_id is distinct from p_lane_id
       or v_existing.reservation_date is distinct from p_reservation_date
       or v_existing.start_time is distinct from p_start_time
       or v_existing.duration_minutes is distinct from p_duration_minutes
       or v_existing.shooters_count is distinct from p_shooters_count
       or nullif(
            pg_catalog.regexp_replace(
              pg_catalog.btrim(
                coalesce(v_existing.reservation_note, '')
              ),
              '[[:space:]]+',
              ' ',
              'g'
            ),
            ''
          ) is distinct from v_note then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'idempotency_conflict'
      );
    end if;

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'already_created',
      'reservation_id', v_existing.id,
      'reservation_status', v_existing.reservation_status,
      'lane_name', v_existing.lane_name_snapshot,
      'shooters_count', v_existing.shooters_count,
      'duration_minutes', v_existing.duration_minutes,
      'pricing_day_group', v_existing.pricing_day_group_snapshot,
      'price_per_hour', v_existing.price_per_hour_snapshot,
      'total_price', v_existing.total_price,
      'currency_code', v_existing.currency_code
    );
  end if;

  v_role := pg_catalog.lower(
    pg_catalog.btrim(coalesce(v_profile.role::text, ''))
  );

  if v_role <> 'user' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  v_customer_name := nullif(
    pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(v_profile.first_name), ''),
      nullif(pg_catalog.btrim(v_profile.last_name), '')
    ),
    ''
  );
  v_customer_name := coalesce(
    v_customer_name,
    nullif(pg_catalog.btrim(v_profile.full_name), '')
  );
  v_customer_email := nullif(pg_catalog.btrim(v_profile.email), '');
  v_customer_phone := nullif(pg_catalog.btrim(v_profile.phone), '');

  if v_customer_name is null
     or v_customer_email is null
     or v_customer_phone is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'profile_incomplete'
    );
  end if;

  v_verification_status := pg_catalog.lower(
    pg_catalog.btrim(
      coalesce(v_profile.verification_status::text, 'pending')
    )
  );

  if v_verification_status = 'rejected' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'profile_rejected'
    );
  end if;

  if v_verification_status <> 'verified'
     and exists (
       select 1
       from public.reservations as reservation
       where reservation.user_id = v_user_id
         and pg_catalog.lower(
               pg_catalog.btrim(reservation.reservation_status)
             ) not in (
               'completed',
               'no_show',
               'cancelled',
               'canceled',
               'cancelled_by_admin',
               'cancelled_by_user'
             )
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'verification_limit_reached'
    );
  end if;

  if not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_inactive'
    );
  end if;

  if v_lane.max_shooters < 1
     or v_lane.booking_step_minutes < 1
     or v_lane.booking_step_minutes > 1440
     or pg_catalog.btrim(v_lane.name) = ''
     or v_lane.currency_code::text !~ '^[A-Z]{3}$' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error'
    );
  end if;

  if p_shooters_count > v_lane.max_shooters then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'capacity_exceeded'
    );
  end if;

  v_end_timestamp :=
    p_reservation_date + p_start_time
    + pg_catalog.make_interval(mins => p_duration_minutes);

  if v_end_timestamp::date <> p_reservation_date
     or v_end_timestamp::time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_duration'
    );
  end if;

  v_end_time := v_end_timestamp::time;
  v_start_in_warsaw :=
    (p_reservation_date + p_start_time) at time zone 'Europe/Warsaw';

  if v_start_in_warsaw <= pg_catalog.transaction_timestamp() then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'reservation_already_started'
    );
  end if;

  if (
    extract(hour from p_start_time)::integer * 60
    + extract(minute from p_start_time)::integer
  ) % v_lane.booking_step_minutes <> 0 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_start_time'
    );
  end if;

  if p_start_time < time '08:00'
     or v_end_time > time '20:00' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'outside_booking_hours'
    );
  end if;

  if not exists (
    select 1
    from public.lane_booking_durations as duration
    where duration.lane_id = p_lane_id
      and duration.duration_minutes = p_duration_minutes
      and duration.is_active
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_duration'
    );
  end if;

  select pg_catalog.count(*)
  into v_pricing_count
  from public.lane_pricing_rules as rule
  where rule.lane_id = p_lane_id
    and rule.day_group = v_pricing_day_group
    and rule.is_active
    and rule.min_shooters <= p_shooters_count
    and rule.max_shooters >= p_shooters_count
    and rule.max_shooters <= v_lane.max_shooters;

  if v_pricing_count <> 1 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'pricing_not_configured'
    );
  end if;

  select rule.*
  into strict v_pricing_rule
  from public.lane_pricing_rules as rule
  where rule.lane_id = p_lane_id
    and rule.day_group = v_pricing_day_group
    and rule.is_active
    and rule.min_shooters <= p_shooters_count
    and rule.max_shooters >= p_shooters_count
    and rule.max_shooters <= v_lane.max_shooters;

  if exists (
    select 1
    from public.lane_blocks as lane_block
    where lane_block.lane_id = p_lane_id
      and lane_block.block_date = p_reservation_date
      and lane_block.is_active
      and lane_block.start_time < v_end_time
      and lane_block.end_time > p_start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_blocked'
    );
  end if;

  if exists (
    select 1
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    where event_lane.lane_id = p_lane_id
      and event_record.is_active is true
      and event_record.event_date = p_reservation_date
      and event_record.start_time < v_end_time
      and event_record.end_time > p_start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'slot_unavailable'
    );
  end if;

  v_total_price := pg_catalog.round(
    v_pricing_rule.hourly_price * p_duration_minutes / 60.0,
    2
  );

  begin
    insert into public.reservations (
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
      attendance_status,
      reservation_note,
      shooters_count,
      pricing_rule_id,
      pricing_day_group_snapshot,
      lane_name_snapshot,
      pricing_label_snapshot,
      price_per_hour_snapshot,
      total_price,
      currency_code,
      creation_request_id
    )
    values (
      v_user_id,
      p_lane_id,
      v_customer_name,
      v_customer_email,
      v_customer_phone,
      p_reservation_date,
      p_start_time,
      v_end_time,
      p_duration_minutes,
      v_total_price,
      'confirmed',
      'pay_on_site',
      'planned',
      v_note,
      p_shooters_count,
      v_pricing_rule.id,
      v_pricing_day_group,
      pg_catalog.btrim(v_lane.name),
      pg_catalog.btrim(v_pricing_rule.label),
      v_pricing_rule.hourly_price,
      v_total_price,
      v_lane.currency_code,
      p_creation_request_id
    )
    returning *
    into v_created;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'reservations_no_overlapping_active_booking' then
        return pg_catalog.jsonb_build_object(
          'ok', false,
          'changed', false,
          'code', 'slot_unavailable'
        );
      end if;

      raise;
  end;

  insert into public.audit_logs (
    actor_user_id,
    actor_name,
    actor_role,
    action,
    target_type,
    target_id,
    target_name,
    details
  )
  values (
    v_user_id,
    v_customer_name,
    'user',
    'reservation_created',
    'reservation',
    v_created.id,
    'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'lane_id', v_created.lane_id,
      'reservation_date', v_created.reservation_date,
      'start_time', v_created.start_time,
      'end_time', v_created.end_time,
      'duration_minutes', v_created.duration_minutes,
      'shooters_count', v_created.shooters_count,
      'pricing_rule_id', v_created.pricing_rule_id,
      'pricing_day_group', v_created.pricing_day_group_snapshot,
      'total_price', v_created.total_price,
      'currency_code', v_created.currency_code
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'created',
    'reservation_id', v_created.id,
    'reservation_status', v_created.reservation_status,
    'lane_name', v_created.lane_name_snapshot,
    'shooters_count', v_created.shooters_count,
    'duration_minutes', v_created.duration_minutes,
    'pricing_day_group', v_created.pricing_day_group_snapshot,
    'price_per_hour', v_created.price_per_hour_snapshot,
    'total_price', v_created.total_price,
    'currency_code', v_created.currency_code
  );
end;
$function$;

alter function public.lock_lane_booking_configuration() owner to postgres;

comment on function public.lock_lane_booking_configuration() is
  'Serializuje zmiany konfiguracji osi z rezerwacjami i aktywnymi eventami.';

revoke all on function public.lock_lane_booking_configuration() from public;
revoke all on function public.lock_lane_booking_configuration() from anon;
revoke all on function public.lock_lane_booking_configuration() from authenticated;
grant execute on function public.lock_lane_booking_configuration() to service_role;

alter function public.create_reservation(
  uuid,date,time without time zone,integer,integer,uuid,text
) owner to postgres;

comment on function public.create_reservation(
  uuid,date,time without time zone,integer,integer,uuid,text
) is
  'Atomowo tworzy własną rezerwację z kontrolą blokad, eventów i nakładania terminów.';

revoke all on function public.create_reservation(
  uuid,date,time without time zone,integer,integer,uuid,text
) from public;
revoke all on function public.create_reservation(
  uuid,date,time without time zone,integer,integer,uuid,text
) from anon;
grant execute on function public.create_reservation(
  uuid,date,time without time zone,integer,integer,uuid,text
) to authenticated, service_role;

drop policy if exists "Admins and staff can insert lane blocks"
on public.lane_blocks;
create policy "Admins and staff can insert lane blocks"
on public.lane_blocks for insert to authenticated
with check (public.is_admin_or_employee());

drop policy if exists "Admins and staff can update lane blocks"
on public.lane_blocks;
create policy "Admins and staff can update lane blocks"
on public.lane_blocks for update to authenticated
using (public.is_admin_or_employee())
with check (public.is_admin_or_employee());

drop policy if exists "Admins and staff can delete lane blocks"
on public.lane_blocks;
create policy "Admins and staff can delete lane blocks"
on public.lane_blocks for delete to authenticated
using (public.is_admin_or_employee());

revoke insert,update,delete,truncate,references,trigger
on table public.lane_blocks from anon,public;
revoke truncate,references,trigger
on table public.lane_blocks from authenticated;
