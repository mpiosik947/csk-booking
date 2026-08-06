do $preflight$
begin
  if pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_lanes') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.lane_blocks') is null
     or pg_catalog.to_regclass('public.profiles') is null then
    raise exception 'Brak tabel wymaganych przez administracyjne RPC eventów.'
      using errcode = '42P01';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.reservations'::pg_catalog.regclass
      and conname = 'reservations_no_overlapping_active_booking'
      and contype = 'x'
  ) then
    raise exception 'Brak wymaganego exclusion constraint rezerwacji.'
      using errcode = '42704';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc as procedure_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = procedure_record.pronamespace
    where namespace_record.nspname = 'public'
      and procedure_record.proname in (
        'admin_create_event',
        'admin_update_event',
        'admin_set_event_active'
      )
  ) then
    raise exception 'Istnieje wcześniejsza sygnatura administracyjnego RPC eventów.'
      using errcode = '42723';
  end if;
end;
$preflight$;

create function public.admin_create_event(
  p_title text,
  p_description text,
  p_event_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_location text,
  p_price numeric,
  p_max_participants integer,
  p_lane_ids uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_actor_id uuid;
  v_actor_role text;
  v_title text;
  v_description text;
  v_location text;
  v_lane_ids uuid[];
  v_invalid_lane_id uuid;
  v_conflict_lane_id uuid;
  v_event_id uuid;
begin
  v_actor_id := auth.uid();

  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed', 'event_id', null
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed', 'event_id', null
    );
  end if;

  v_title := pg_catalog.btrim(p_title);
  v_description := nullif(pg_catalog.btrim(p_description), '');
  v_location := nullif(pg_catalog.btrim(p_location), '');
  v_lane_ids := coalesce(p_lane_ids, '{}'::uuid[]);

  if v_title is null or v_title = ''
     or p_event_date is null
     or p_start_time is null
     or p_end_time is null
     or p_price is null
     or p_price < 0
     or p_price::text in ('NaN', 'Infinity', '-Infinity')
     or p_max_participants is null or p_max_participants <= 0 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', null
    );
  end if;

  if p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_time_range', 'event_id', null
    );
  end if;

  if pg_catalog.array_position(v_lane_ids, null) is not null
     or (
       select pg_catalog.count(*)
       from pg_catalog.unnest(v_lane_ids) as requested(lane_id)
     ) <> (
       select pg_catalog.count(distinct requested.lane_id)
       from pg_catalog.unnest(v_lane_ids) as requested(lane_id)
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', null
    );
  end if;

  select coalesce(
    pg_catalog.array_agg(requested.lane_id order by requested.lane_id),
    '{}'::uuid[]
  )
  into v_lane_ids
  from pg_catalog.unnest(v_lane_ids) as requested(lane_id);

  if pg_catalog.cardinality(v_lane_ids) > 0
     and (p_start_time < time '08:00' or p_end_time > time '20:00') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'outside_booking_hours', 'event_id', null
    );
  end if;

  perform lane.id
  from public.shooting_lanes as lane
  where lane.id = any(v_lane_ids)
  order by lane.id
  for update;

  select requested.lane_id
  into v_invalid_lane_id
  from pg_catalog.unnest(v_lane_ids) as requested(lane_id)
  left join public.shooting_lanes as lane on lane.id = requested.lane_id
  where lane.id is null
  order by requested.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'event_id', null, 'conflict_lane_id', v_invalid_lane_id
    );
  end if;

  select lane.id
  into v_invalid_lane_id
  from public.shooting_lanes as lane
  where lane.id = any(v_lane_ids)
    and lane.is_active is not true
  order by lane.id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'event_id', null, 'conflict_lane_id', v_invalid_lane_id
    );
  end if;

  select reservation.lane_id
  into v_conflict_lane_id
  from public.reservations as reservation
  where reservation.lane_id = any(v_lane_ids)
    and reservation.reservation_date = p_event_date
    and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
      not in (
        'completed', 'no_show', 'cancelled', 'canceled',
        'cancelled_by_admin', 'cancelled_by_user'
      )
    and reservation.start_time < p_end_time
    and reservation.end_time > p_start_time
  order by reservation.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_conflict',
      'event_id', null, 'conflict_type', 'reservation',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  select lane_block.lane_id
  into v_conflict_lane_id
  from public.lane_blocks as lane_block
  where lane_block.lane_id = any(v_lane_ids)
    and lane_block.block_date = p_event_date
    and lane_block.is_active is true
    and lane_block.start_time < p_end_time
    and lane_block.end_time > p_start_time
  order by lane_block.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_block_conflict',
      'event_id', null, 'conflict_type', 'lane_block',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  select event_lane.lane_id
  into v_conflict_lane_id
  from public.event_lanes as event_lane
  join public.events as existing_event on existing_event.id = event_lane.event_id
  where event_lane.lane_id = any(v_lane_ids)
    and existing_event.is_active is true
    and existing_event.event_date = p_event_date
    and existing_event.start_time < p_end_time
    and existing_event.end_time > p_start_time
  order by event_lane.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'event_conflict',
      'event_id', null, 'conflict_type', 'event',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  insert into public.events (
    title, description, event_date, start_time, end_time,
    location, price, max_participants, is_active
  ) values (
    v_title, v_description, p_event_date, p_start_time, p_end_time,
    v_location, p_price, p_max_participants, true
  )
  returning id into v_event_id;

  insert into public.event_lanes (event_id, lane_id)
  select v_event_id, requested.lane_id
  from pg_catalog.unnest(v_lane_ids) as requested(lane_id)
  order by requested.lane_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'created', 'event_id', v_event_id
  );
end;
$function$;

create function public.admin_update_event(
  p_event_id uuid,
  p_title text,
  p_description text,
  p_event_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_location text,
  p_price numeric,
  p_max_participants integer,
  p_lane_ids uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_actor_id uuid;
  v_actor_role text;
  v_event public.events%rowtype;
  v_title text;
  v_description text;
  v_location text;
  v_old_lane_ids uuid[];
  v_new_lane_ids uuid[];
  v_lock_lane_ids uuid[];
  v_invalid_lane_id uuid;
  v_conflict_lane_id uuid;
begin
  v_actor_id := auth.uid();

  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed', 'event_id', p_event_id
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed', 'event_id', p_event_id
    );
  end if;

  if p_event_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', null
    );
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'event_not_found', 'event_id', p_event_id
    );
  end if;

  v_title := pg_catalog.btrim(p_title);
  v_description := nullif(pg_catalog.btrim(p_description), '');
  v_location := nullif(pg_catalog.btrim(p_location), '');
  v_new_lane_ids := coalesce(p_lane_ids, '{}'::uuid[]);

  if v_title is null or v_title = ''
     or p_event_date is null
     or p_start_time is null
     or p_end_time is null
     or p_price is null
     or p_price < 0
     or p_price::text in ('NaN', 'Infinity', '-Infinity')
     or p_max_participants is null or p_max_participants <= 0 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', p_event_id
    );
  end if;

  if p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_time_range', 'event_id', p_event_id
    );
  end if;

  if pg_catalog.array_position(v_new_lane_ids, null) is not null
     or (
       select pg_catalog.count(*)
       from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id)
     ) <> (
       select pg_catalog.count(distinct requested.lane_id)
       from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id)
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', p_event_id
    );
  end if;

  select coalesce(
    pg_catalog.array_agg(requested.lane_id order by requested.lane_id),
    '{}'::uuid[]
  )
  into v_new_lane_ids
  from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id);

  if pg_catalog.cardinality(v_new_lane_ids) > 0
     and (p_start_time < time '08:00' or p_end_time > time '20:00') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'outside_booking_hours', 'event_id', p_event_id
    );
  end if;

  select coalesce(
    pg_catalog.array_agg(event_lane.lane_id order by event_lane.lane_id),
    '{}'::uuid[]
  )
  into v_old_lane_ids
  from public.event_lanes as event_lane
  where event_lane.event_id = p_event_id;

  select coalesce(
    pg_catalog.array_agg(candidate.lane_id order by candidate.lane_id),
    '{}'::uuid[]
  )
  into v_lock_lane_ids
  from (
    select pg_catalog.unnest(v_old_lane_ids) as lane_id
    union
    select pg_catalog.unnest(v_new_lane_ids) as lane_id
  ) as candidate;

  perform lane.id
  from public.shooting_lanes as lane
  where lane.id = any(v_lock_lane_ids)
  order by lane.id
  for update;

  select requested.lane_id
  into v_invalid_lane_id
  from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id)
  left join public.shooting_lanes as lane on lane.id = requested.lane_id
  where lane.id is null
  order by requested.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'event_id', p_event_id, 'conflict_lane_id', v_invalid_lane_id
    );
  end if;

  select lane.id
  into v_invalid_lane_id
  from public.shooting_lanes as lane
  where lane.id = any(v_new_lane_ids)
    and lane.is_active is not true
    and not (lane.id = any(v_old_lane_ids))
  order by lane.id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'event_id', p_event_id, 'conflict_lane_id', v_invalid_lane_id
    );
  end if;

  if v_event.title is not distinct from v_title
     and v_event.description is not distinct from v_description
     and v_event.event_date is not distinct from p_event_date
     and v_event.start_time is not distinct from p_start_time
     and v_event.end_time is not distinct from p_end_time
     and v_event.location is not distinct from v_location
     and v_event.price is not distinct from p_price
     and v_event.max_participants is not distinct from p_max_participants
     and v_old_lane_ids = v_new_lane_ids then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change', 'event_id', p_event_id
    );
  end if;

  select reservation.lane_id
  into v_conflict_lane_id
  from public.reservations as reservation
  where reservation.lane_id = any(v_new_lane_ids)
    and reservation.reservation_date = p_event_date
    and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
      not in (
        'completed', 'no_show', 'cancelled', 'canceled',
        'cancelled_by_admin', 'cancelled_by_user'
      )
    and reservation.start_time < p_end_time
    and reservation.end_time > p_start_time
  order by reservation.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_conflict',
      'event_id', p_event_id, 'conflict_type', 'reservation',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  select lane_block.lane_id
  into v_conflict_lane_id
  from public.lane_blocks as lane_block
  where lane_block.lane_id = any(v_new_lane_ids)
    and lane_block.block_date = p_event_date
    and lane_block.is_active is true
    and lane_block.start_time < p_end_time
    and lane_block.end_time > p_start_time
  order by lane_block.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_block_conflict',
      'event_id', p_event_id, 'conflict_type', 'lane_block',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  select event_lane.lane_id
  into v_conflict_lane_id
  from public.event_lanes as event_lane
  join public.events as existing_event on existing_event.id = event_lane.event_id
  where event_lane.lane_id = any(v_new_lane_ids)
    and existing_event.id <> p_event_id
    and existing_event.is_active is true
    and existing_event.event_date = p_event_date
    and existing_event.start_time < p_end_time
    and existing_event.end_time > p_start_time
  order by event_lane.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'event_conflict',
      'event_id', p_event_id, 'conflict_type', 'event',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  update public.events
  set title = v_title,
      description = v_description,
      event_date = p_event_date,
      start_time = p_start_time,
      end_time = p_end_time,
      location = v_location,
      price = p_price,
      max_participants = p_max_participants
  where id = p_event_id;

  delete from public.event_lanes as event_lane
  where event_lane.event_id = p_event_id
    and not (event_lane.lane_id = any(v_new_lane_ids));

  insert into public.event_lanes (event_id, lane_id)
  select p_event_id, requested.lane_id
  from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id)
  where not exists (
    select 1
    from public.event_lanes as existing_link
    where existing_link.event_id = p_event_id
      and existing_link.lane_id = requested.lane_id
  )
  order by requested.lane_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated', 'event_id', p_event_id
  );
end;
$function$;

create function public.admin_set_event_active(
  p_event_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_actor_id uuid;
  v_actor_role text;
  v_event public.events%rowtype;
  v_lane_ids uuid[];
  v_invalid_lane_id uuid;
  v_conflict_lane_id uuid;
begin
  v_actor_id := auth.uid();

  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed', 'event_id', p_event_id
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed', 'event_id', p_event_id
    );
  end if;

  if p_event_id is null or p_is_active is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', p_event_id
    );
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'event_not_found', 'event_id', p_event_id
    );
  end if;

  select coalesce(
    pg_catalog.array_agg(event_lane.lane_id order by event_lane.lane_id),
    '{}'::uuid[]
  )
  into v_lane_ids
  from public.event_lanes as event_lane
  where event_lane.event_id = p_event_id;

  perform lane.id
  from public.shooting_lanes as lane
  where lane.id = any(v_lane_ids)
  order by lane.id
  for update;

  if v_event.is_active = p_is_active then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change', 'event_id', p_event_id
    );
  end if;

  if p_is_active is false then
    update public.events set is_active = false where id = p_event_id;

    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', true, 'code', 'deactivated', 'event_id', p_event_id
    );
  end if;

  if v_event.end_time <= v_event.start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_time_range', 'event_id', p_event_id
    );
  end if;

  if pg_catalog.cardinality(v_lane_ids) > 0
     and (v_event.start_time < time '08:00' or v_event.end_time > time '20:00') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'outside_booking_hours', 'event_id', p_event_id
    );
  end if;

  select lane.id
  into v_invalid_lane_id
  from public.shooting_lanes as lane
  where lane.id = any(v_lane_ids)
    and lane.is_active is not true
  order by lane.id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'event_id', p_event_id, 'conflict_lane_id', v_invalid_lane_id
    );
  end if;

  select reservation.lane_id
  into v_conflict_lane_id
  from public.reservations as reservation
  where reservation.lane_id = any(v_lane_ids)
    and reservation.reservation_date = v_event.event_date
    and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
      not in (
        'completed', 'no_show', 'cancelled', 'canceled',
        'cancelled_by_admin', 'cancelled_by_user'
      )
    and reservation.start_time < v_event.end_time
    and reservation.end_time > v_event.start_time
  order by reservation.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_conflict',
      'event_id', p_event_id, 'conflict_type', 'reservation',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  select lane_block.lane_id
  into v_conflict_lane_id
  from public.lane_blocks as lane_block
  where lane_block.lane_id = any(v_lane_ids)
    and lane_block.block_date = v_event.event_date
    and lane_block.is_active is true
    and lane_block.start_time < v_event.end_time
    and lane_block.end_time > v_event.start_time
  order by lane_block.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_block_conflict',
      'event_id', p_event_id, 'conflict_type', 'lane_block',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  select event_lane.lane_id
  into v_conflict_lane_id
  from public.event_lanes as event_lane
  join public.events as existing_event on existing_event.id = event_lane.event_id
  where event_lane.lane_id = any(v_lane_ids)
    and existing_event.id <> p_event_id
    and existing_event.is_active is true
    and existing_event.event_date = v_event.event_date
    and existing_event.start_time < v_event.end_time
    and existing_event.end_time > v_event.start_time
  order by event_lane.lane_id
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'event_conflict',
      'event_id', p_event_id, 'conflict_type', 'event',
      'conflict_lane_id', v_conflict_lane_id
    );
  end if;

  update public.events set is_active = true where id = p_event_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'activated', 'event_id', p_event_id
  );
end;
$function$;

alter function public.admin_create_event(
  text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) owner to postgres;

alter function public.admin_update_event(
  uuid, text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) owner to postgres;

alter function public.admin_set_event_active(uuid, boolean) owner to postgres;

comment on function public.admin_create_event(
  text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) is 'Atomowo tworzy event globalny lub przypisany do jednej albo wielu osi.';

comment on function public.admin_update_event(
  uuid, text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) is 'Atomowo aktualizuje dane eventu i zastępuje jego pełny zestaw osi.';

comment on function public.admin_set_event_active(uuid, boolean) is
  'Atomowo aktywuje lub dezaktywuje event z kontrolą osi i konfliktów.';

revoke all on function public.admin_create_event(
  text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) from public;
revoke all on function public.admin_create_event(
  text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) from anon;
grant execute on function public.admin_create_event(
  text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) to authenticated;

revoke all on function public.admin_update_event(
  uuid, text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) from public;
revoke all on function public.admin_update_event(
  uuid, text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) from anon;
grant execute on function public.admin_update_event(
  uuid, text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) to authenticated;

revoke all on function public.admin_set_event_active(uuid, boolean) from public;
revoke all on function public.admin_set_event_active(uuid, boolean) from anon;
grant execute on function public.admin_set_event_active(uuid, boolean)
to authenticated;
