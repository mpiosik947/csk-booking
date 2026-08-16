CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."admin_create_event"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."admin_create_event"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_create_event"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) IS 'Atomowo tworzy event globalny lub przypisany do jednej albo wielu osi.';



CREATE OR REPLACE FUNCTION "public"."admin_create_event_v2"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_title text;
  v_description text;
  v_location text;
  v_lane_ids uuid[];
  v_conflict_lane_ids uuid[] := '{}'::uuid[];
  v_scope record;
  v_scope_count integer := 0;
  v_invalid_lane_id uuid;
  v_conflict_lane_id uuid;
  v_event_id uuid;
begin
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
     or p_max_participants is null
     or p_max_participants <= 0
     or pg_catalog.array_position(v_lane_ids, null::uuid) is not null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', null
    );
  end if;

  if p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_time_range', 'event_id', null
    );
  end if;

  select coalesce(
    pg_catalog.array_agg(distinct requested.lane_id order by requested.lane_id),
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

  if pg_catalog.cardinality(v_lane_ids) > 0 then
    begin
      for v_scope in
        select scope_record.*
        from public.lock_lane_conflict_families_v1(v_lane_ids) as scope_record
      loop
        v_scope_count := v_scope_count + 1;
        v_conflict_lane_ids := v_conflict_lane_ids || v_scope.conflict_lane_ids;
      end loop;
    exception
      when sqlstate 'P0002' then
        select requested.lane_id
        into v_invalid_lane_id
        from pg_catalog.unnest(v_lane_ids) as requested(lane_id)
        left join public.shooting_lanes as lane on lane.id = requested.lane_id
        where lane.id is null
        order by requested.lane_id
        limit 1;

        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_lane',
          'event_id', null, 'conflict_lane_id', v_invalid_lane_id
        );
      when sqlstate '55000' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
          'event_id', null
        );
      when sqlstate '22023' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_input',
          'event_id', null
        );
    end;

    if v_scope_count <> pg_catalog.cardinality(v_lane_ids) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'event_id', null
      );
    end if;

    select coalesce(
      pg_catalog.array_agg(distinct conflict.lane_id order by conflict.lane_id),
      '{}'::uuid[]
    )
    into v_conflict_lane_ids
    from pg_catalog.unnest(v_conflict_lane_ids) as conflict(lane_id);

    select requested.lane_id
    into v_invalid_lane_id
    from pg_catalog.unnest(v_lane_ids) as requested(lane_id)
    join public.shooting_lanes as lane on lane.id = requested.lane_id
    left join public.shooting_lanes as parent
      on parent.id = lane.parent_lane_id
    where lane.is_active is not true
       or (
         lane.resource_kind = 'position'
         and parent.is_active is not true
       )
    order by requested.lane_id
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
    where reservation.lane_id = any(v_conflict_lane_ids)
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
    where lane_block.lane_id = any(v_conflict_lane_ids)
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
    where event_lane.lane_id = any(v_conflict_lane_ids)
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
$$;


ALTER FUNCTION "public"."admin_create_event_v2"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_create_event_v2"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) IS 'Dormant hierarchy-aware event creation using globally ordered conflict-family locks.';



CREATE OR REPLACE FUNCTION "public"."admin_create_lane_block"("p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_lane public.shooting_lanes%rowtype;
  v_conflict_lane_ids uuid[];
  v_requested_kind text;
  v_block_id uuid;
  v_constraint_name text;
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', null
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', null
    );
  end if;

  if p_lane_id is null
     or p_block_date is null
     or p_start_time is null
     or p_end_time is null
     or p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', null
    );
  end if;

  begin
    select scope_record.conflict_lane_ids,
           scope_record.requested_resource_kind
    into v_conflict_lane_ids, v_requested_kind
    from public.lock_lane_conflict_families_v1(
      array[p_lane_id]::uuid[]
    ) as scope_record
    where scope_record.requested_lane_id = p_lane_id;
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_lane',
        'lane_block_id', null
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_block_id', null
      );
    when sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_input',
        'lane_block_id', null
      );
  end;

  if v_conflict_lane_ids is null or v_requested_kind is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', null
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'lane_block_id', null
    );
  end if;

  if v_lane.resource_kind is distinct from v_requested_kind then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', null
    );
  end if;

  if not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'lane_block_id', null
    );
  end if;

  if exists (
    select 1
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = p_block_date
      and reservation.start_time < p_end_time
      and reservation.end_time > p_start_time
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_reservation',
      'lane_block_id', null
    );
  end if;

  if exists (
    select 1
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    where event_lane.lane_id = any(v_conflict_lane_ids)
      and event_record.is_active is true
      and event_record.event_date = p_block_date
      and event_record.start_time < p_end_time
      and event_record.end_time > p_start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_event',
      'lane_block_id', null
    );
  end if;

  begin
    insert into public.lane_blocks (
      lane_id,
      block_date,
      start_time,
      end_time,
      reason,
      is_active
    )
    values (
      p_lane_id,
      p_block_date,
      p_start_time,
      p_end_time,
      p_reason,
      true
    )
    returning id into v_block_id;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'lane_blocks_no_active_reservation_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_reservation',
          'lane_block_id', null
        );
      end if;

      if v_constraint_name = 'lane_blocks_no_active_event_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_event',
          'lane_block_id', null
        );
      end if;

      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'created',
    'lane_block_id', v_block_id
  );
end;
$$;


ALTER FUNCTION "public"."admin_create_lane_block"("p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_create_lane_block"("p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text") IS 'Creates one active lane block after hierarchy-aware reservation and event conflict checks.';



CREATE OR REPLACE FUNCTION "public"."admin_get_lane_booking_configuration_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_resources jsonb;
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_id is null or coalesce(v_actor_role, '') <> 'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode = '42501';
  end if;

  if exists (
       select 1
       from public.shooting_lanes as resource
       left join public.shooting_lanes as parent
         on parent.id = resource.parent_lane_id
       where resource.resource_kind not in ('lane', 'position')
          or resource.parent_lane_id = resource.id
          or (
            resource.resource_kind = 'lane'
            and resource.parent_lane_id is not null
          )
          or (
            resource.resource_kind = 'position'
            and (
              resource.parent_lane_id is null
              or resource.whole_lane_bookable
              or resource.positions_bookable
              or parent.id is null
              or parent.resource_kind <> 'lane'
              or parent.parent_lane_id is not null
            )
          )
     )
     or exists (
       select 1
       from public.shooting_lanes as resource
       left join public.lane_booking_rules as booking_rule
         on booking_rule.lane_id = resource.id
       where booking_rule.lane_id is null
     )
     or exists (
       select 1
       from public.lane_booking_durations as duration
       group by duration.lane_id, duration.duration_minutes
       having pg_catalog.count(*) > 1
     )
     or exists (
       select 1
       from public.lane_pricing_rules as first_rule
       join public.lane_pricing_rules as second_rule
         on second_rule.lane_id = first_rule.lane_id
        and second_rule.day_group = first_rule.day_group
        and second_rule.is_active
        and second_rule.id > first_rule.id
        and second_rule.min_shooters <= first_rule.max_shooters
        and second_rule.max_shooters >= first_rule.min_shooters
       where first_rule.is_active
     ) then
    raise exception 'Lane configuration snapshot is structurally ambiguous.'
      using errcode = '55000';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'lane_id', resource.lane_id,
        'name', resource.name,
        'resource_kind', resource.resource_kind,
        'parent_lane_id', resource.parent_lane_id,
        'display_order', resource.display_order,
        'is_active', resource.is_active,
        'max_shooters', resource.max_shooters,
        'whole_lane_bookable', resource.whole_lane_bookable,
        'positions_bookable', resource.positions_bookable,
        'booking_step_minutes', resource.booking_step_minutes,
        'currency_code', resource.currency_code,
        'online_bookable', resource.online_bookable,
        'max_people_online', resource.max_people_online,
        'durations', resource.durations,
        'pricing', resource.pricing
      )
      order by
        resource.root_display_order,
        resource.root_id,
        resource.resource_depth,
        resource.display_order,
        resource.lane_id
    ),
    '[]'::jsonb
  )
  into v_resources
  from (
    select
      lane.id as lane_id,
      lane.name,
      lane.resource_kind,
      lane.parent_lane_id,
      lane.display_order,
      lane.is_active,
      lane.max_shooters,
      lane.whole_lane_bookable,
      lane.positions_bookable,
      lane.booking_step_minutes,
      lane.currency_code::text as currency_code,
      booking_rule.online_bookable,
      booking_rule.max_people_online,
      case when lane.resource_kind = 'lane' then lane.id
           else lane.parent_lane_id end as root_id,
      case when lane.resource_kind = 'lane' then lane.display_order
           else parent.display_order end as root_display_order,
      case when lane.resource_kind = 'lane' then 0 else 1 end
        as resource_depth,
      coalesce((
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'duration_minutes', duration.duration_minutes,
            'display_order', duration.display_order,
            'is_active', duration.is_active
          )
          order by duration.display_order,
                   duration.duration_minutes,
                   duration.id
        )
        from public.lane_booking_durations as duration
        where duration.lane_id = lane.id
      ), '[]'::jsonb) as durations,
      coalesce((
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'day_group', pricing.day_group,
            'min_shooters', pricing.min_shooters,
            'max_shooters', pricing.max_shooters,
            'label', pricing.label,
            'hourly_price', pricing.hourly_price,
            'display_order', pricing.display_order,
            'is_active', pricing.is_active
          )
          order by
            case pricing.day_group
              when 'mon_thu' then 0
              when 'fri_sun' then 1
              else 2
            end,
            pricing.is_active desc,
            pricing.display_order,
            pricing.min_shooters,
            pricing.max_shooters,
            pricing.id
        )
        from public.lane_pricing_rules as pricing
        where pricing.lane_id = lane.id
      ), '[]'::jsonb) as pricing
    from public.shooting_lanes as lane
    join public.lane_booking_rules as booking_rule
      on booking_rule.lane_id = lane.id
    left join public.shooting_lanes as parent
      on parent.id = lane.parent_lane_id
  ) as resource;

  return pg_catalog.jsonb_build_object(
    'contract_version', 1,
    'resources', v_resources
  );
end;
$$;


ALTER FUNCTION "public"."admin_get_lane_booking_configuration_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_get_lane_booking_configuration_v1"() IS 'Returns one deterministic admin-only snapshot of all lane booking resources, including dormant positions and resource-owned configuration.';



CREATE OR REPLACE FUNCTION "public"."admin_get_lane_booking_configuration_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_v1 jsonb;
  v_families jsonb;
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_id is null or coalesce(v_actor_role, '') <> 'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode = '42501';
  end if;

  if (select pg_catalog.count(*) from public.shooting_lanes
      where resource_kind = 'lane' and parent_lane_id is null)
     <> (select pg_catalog.count(*) from public.lane_booking_family_configuration_versions) then
    raise exception 'Lane family version snapshot is incomplete.' using errcode = '55000';
  end if;

  v_v1 := public.admin_get_lane_booking_configuration_v1();

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'root_lane_id', root.id,
      'configuration_version', version.configuration_version,
      'resources', coalesce((
        select pg_catalog.jsonb_agg(resource.value order by resource.ordinality)
        from pg_catalog.jsonb_array_elements(v_v1->'resources') with ordinality
          as resource(value, ordinality)
        where resource.value->>'lane_id' = root.id::text
           or resource.value->>'parent_lane_id' = root.id::text
      ), '[]'::jsonb)
    ) order by root.display_order, root.id
  ), '[]'::jsonb)
  into v_families
  from public.shooting_lanes as root
  join public.lane_booking_family_configuration_versions as version
    on version.root_lane_id = root.id
  where root.resource_kind = 'lane' and root.parent_lane_id is null;

  return pg_catalog.jsonb_build_object(
    'contract_version', 2,
    'families', v_families
  );
end;
$$;


ALTER FUNCTION "public"."admin_get_lane_booking_configuration_v2"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_get_lane_booking_configuration_v2"() IS 'Returns the admin-only V1 resource shape grouped into versioned top-level lane families.';



CREATE OR REPLACE FUNCTION "public"."admin_list_users_v1"("p_limit" integer DEFAULT 50, "p_offset" integer DEFAULT 0, "p_search" "text" DEFAULT NULL::"text", "p_role" "text" DEFAULT NULL::"text", "p_verification_filter" "text" DEFAULT NULL::"text", "p_sort" "text" DEFAULT 'newest'::"text") RETURNS TABLE("user_id" "uuid", "email" "text", "first_name" "text", "last_name" "text", "full_name" "text", "phone" "text", "role" "text", "verification_status" "text", "admin_note" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "postal_code" "text", "city" "text", "street" "text", "house_number" "text", "apartment_number" "text", "permission_sport" boolean, "permission_collector" boolean, "permission_hunting" boolean, "permission_training" boolean, "permission_personal_protection" boolean, "permission_other" boolean, "qualification_instructor" boolean, "qualification_range_officer" boolean, "qualification_pzss_license" boolean, "qualification_hunter" boolean, "permissions_verified" boolean, "permissions_verified_at" timestamp with time zone, "permissions_verification_note" "text", "total_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_search text := nullif(pg_catalog.btrim(p_search), '');
  v_role text := nullif(pg_catalog.lower(pg_catalog.btrim(p_role)), '');
  v_verification text := nullif(pg_catalog.lower(pg_catalog.btrim(p_verification_filter)), '');
  v_sort text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort, 'newest')));
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_id is null or coalesce(v_actor_role, '') <> 'admin' then
    raise exception 'Brak uprawnień do listy użytkowników.' using errcode = '42501';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 100
     or p_offset is null or p_offset < 0 then
    raise exception 'Nieprawidłowe parametry stronicowania.' using errcode = '22023';
  end if;

  if v_role is not null and v_role not in ('admin', 'pracownik', 'instruktor', 'user') then
    raise exception 'Nieprawidłowy filtr roli.' using errcode = '22023';
  end if;

  if v_verification is not null
     and v_verification not in ('pending', 'unverified', 'verified', 'rejected') then
    raise exception 'Nieprawidłowy filtr weryfikacji.' using errcode = '22023';
  end if;

  if v_sort not in ('newest', 'oldest', 'name', 'role') then
    raise exception 'Nieprawidłowy sposób sortowania.' using errcode = '22023';
  end if;

  return query
  with filtered as (
    select profile.*
    from public.profiles as profile
    where (v_role is null or pg_catalog.lower(pg_catalog.btrim(profile.role::text)) = v_role)
      and (
        v_verification is null
        or (v_verification = 'pending' and profile.verification_status = 'pending')
        or (v_verification = 'verified'
            and profile.verification_status = 'verified'
            and profile.permissions_verified)
        or (v_verification = 'rejected' and profile.verification_status = 'rejected')
        or (v_verification = 'unverified'
            and (profile.verification_status is distinct from 'verified'
                 or not profile.permissions_verified))
      )
      and (
        v_search is null
        or coalesce(profile.first_name, '') ilike '%' || v_search || '%'
        or coalesce(profile.last_name, '') ilike '%' || v_search || '%'
        or coalesce(profile.full_name, '') ilike '%' || v_search || '%'
        or coalesce(profile.email, '') ilike '%' || v_search || '%'
        or coalesce(profile.phone, '') ilike '%' || v_search || '%'
      )
  )
  select
    profile.user_id, profile.email, profile.first_name,
    profile.last_name, profile.full_name, profile.phone, profile.role,
    profile.verification_status, profile.admin_note, profile.created_at,
    profile.updated_at, profile.postal_code, profile.city, profile.street,
    profile.house_number, profile.apartment_number, profile.permission_sport,
    profile.permission_collector, profile.permission_hunting,
    profile.permission_training, profile.permission_personal_protection,
    profile.permission_other, profile.qualification_instructor,
    profile.qualification_range_officer, profile.qualification_pzss_license,
    profile.qualification_hunter, profile.permissions_verified,
    profile.permissions_verified_at, profile.permissions_verification_note,
    pg_catalog.count(*) over () as total_count
  from filtered as profile
  order by
    case when v_sort = 'newest' then profile.created_at end desc nulls last,
    case when v_sort = 'oldest' then profile.created_at end asc nulls last,
    case when v_sort = 'name' then pg_catalog.lower(coalesce(
      nullif(pg_catalog.btrim(profile.full_name), ''),
      nullif(pg_catalog.btrim(profile.first_name || ' ' || profile.last_name), ''),
      profile.email,
      ''
    )) end asc,
    case when v_sort = 'role' then pg_catalog.lower(profile.role::text) end asc,
    profile.user_id asc
  limit p_limit
  offset p_offset;
end;
$$;


ALTER FUNCTION "public"."admin_list_users_v1"("p_limit" integer, "p_offset" integer, "p_search" "text", "p_role" "text", "p_verification_filter" "text", "p_sort" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_event_active"("p_event_id" "uuid", "p_is_active" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."admin_set_event_active"("p_event_id" "uuid", "p_is_active" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_set_event_active"("p_event_id" "uuid", "p_is_active" boolean) IS 'Atomowo aktywuje lub dezaktywuje event z kontrolą osi i konfliktów.';



CREATE OR REPLACE FUNCTION "public"."admin_set_event_active_v2"("p_event_id" "uuid", "p_is_active" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_original public.events%rowtype;
  v_current public.events%rowtype;
  v_lane_ids uuid[];
  v_conflict_lane_ids uuid[] := '{}'::uuid[];
  v_scope record;
  v_scope_count integer := 0;
  v_invalid_lane_id uuid;
  v_conflict_lane_id uuid;
begin
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
  into v_original
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

  if pg_catalog.cardinality(v_lane_ids) > 0 then
    begin
      for v_scope in
        select scope_record.*
        from public.lock_lane_conflict_families_v1(v_lane_ids) as scope_record
      loop
        v_scope_count := v_scope_count + 1;
        v_conflict_lane_ids := v_conflict_lane_ids || v_scope.conflict_lane_ids;
      end loop;
    exception
      when sqlstate 'P0002' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
          'event_id', p_event_id
        );
      when sqlstate '55000' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
          'event_id', p_event_id
        );
      when sqlstate '22023' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_input',
          'event_id', p_event_id
        );
    end;

    if v_scope_count <> pg_catalog.cardinality(v_lane_ids) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'event_id', p_event_id
      );
    end if;

    select coalesce(
      pg_catalog.array_agg(distinct conflict.lane_id order by conflict.lane_id),
      '{}'::uuid[]
    )
    into v_conflict_lane_ids
    from pg_catalog.unnest(v_conflict_lane_ids) as conflict(lane_id);
  end if;

  select event_record.*
  into v_current
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'event_not_found', 'event_id', p_event_id
    );
  end if;

  if v_current is distinct from v_original then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error', 'event_id', p_event_id
    );
  end if;

  if v_current.is_active = p_is_active then
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

  if v_current.end_time <= v_current.start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_time_range',
      'event_id', p_event_id
    );
  end if;

  if pg_catalog.cardinality(v_lane_ids) > 0
     and (v_current.start_time < time '08:00' or v_current.end_time > time '20:00') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'outside_booking_hours',
      'event_id', p_event_id
    );
  end if;

  if pg_catalog.cardinality(v_lane_ids) > 0 then
    select requested.lane_id
    into v_invalid_lane_id
    from pg_catalog.unnest(v_lane_ids) as requested(lane_id)
    join public.shooting_lanes as lane on lane.id = requested.lane_id
    left join public.shooting_lanes as parent
      on parent.id = lane.parent_lane_id
    where lane.is_active is not true
       or (
         lane.resource_kind = 'position'
         and parent.is_active is not true
       )
    order by requested.lane_id
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
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = v_current.event_date
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
      and reservation.start_time < v_current.end_time
      and reservation.end_time > v_current.start_time
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
    where lane_block.lane_id = any(v_conflict_lane_ids)
      and lane_block.block_date = v_current.event_date
      and lane_block.is_active is true
      and lane_block.start_time < v_current.end_time
      and lane_block.end_time > v_current.start_time
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
    where event_lane.lane_id = any(v_conflict_lane_ids)
      and existing_event.id <> p_event_id
      and existing_event.is_active is true
      and existing_event.event_date = v_current.event_date
      and existing_event.start_time < v_current.end_time
      and existing_event.end_time > v_current.start_time
    order by event_lane.lane_id
    limit 1;

    if found then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'event_conflict',
        'event_id', p_event_id, 'conflict_type', 'event',
        'conflict_lane_id', v_conflict_lane_id
      );
    end if;
  end if;

  update public.events set is_active = true where id = p_event_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'activated', 'event_id', p_event_id
  );
end;
$$;


ALTER FUNCTION "public"."admin_set_event_active_v2"("p_event_id" "uuid", "p_is_active" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_set_event_active_v2"("p_event_id" "uuid", "p_is_active" boolean) IS 'Dormant hierarchy-aware event activation and deactivation.';



CREATE OR REPLACE FUNCTION "public"."admin_set_lane_block_active"("p_block_id" "uuid", "p_is_active" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_original public.lane_blocks%rowtype;
  v_current public.lane_blocks%rowtype;
  v_lane public.shooting_lanes%rowtype;
  v_conflict_lane_ids uuid[];
  v_requested_kind text;
  v_constraint_name text;
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  if p_block_id is null or p_is_active is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', p_block_id
    );
  end if;

  select lane_block.*
  into v_original
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    select scope_record.conflict_lane_ids,
           scope_record.requested_resource_kind
    into v_conflict_lane_ids, v_requested_kind
    from public.lock_lane_conflict_families_v1(
      array[v_original.lane_id]::uuid[]
    ) as scope_record
    where scope_record.requested_lane_id = v_original.lane_id;
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_lane',
        'lane_block_id', p_block_id
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_block_id', p_block_id
      );
    when sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_input',
        'lane_block_id', p_block_id
      );
  end;

  if v_conflict_lane_ids is null or v_requested_kind is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  select lane_block.*
  into v_current
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  if v_current is distinct from v_original then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error',
      'lane_block_id', p_block_id
    );
  end if;

  if v_current.is_active = p_is_active then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'lane_block_id', p_block_id
    );
  end if;

  if not p_is_active then
    update public.lane_blocks
    set is_active = false
    where id = p_block_id;

    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', true, 'code', 'deactivated',
      'lane_block_id', p_block_id
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = v_current.lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if v_lane.resource_kind is distinct from v_requested_kind then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  if not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if exists (
    select 1
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = v_current.block_date
      and reservation.start_time < v_current.end_time
      and reservation.end_time > v_current.start_time
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_reservation',
      'lane_block_id', p_block_id
    );
  end if;

  if exists (
    select 1
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    where event_lane.lane_id = any(v_conflict_lane_ids)
      and event_record.is_active is true
      and event_record.event_date = v_current.block_date
      and event_record.start_time < v_current.end_time
      and event_record.end_time > v_current.start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_event',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    update public.lane_blocks
    set is_active = true
    where id = p_block_id;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'lane_blocks_no_active_reservation_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_reservation',
          'lane_block_id', p_block_id
        );
      end if;

      if v_constraint_name = 'lane_blocks_no_active_event_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_event',
          'lane_block_id', p_block_id
        );
      end if;

      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'activated',
    'lane_block_id', p_block_id
  );
end;
$$;


ALTER FUNCTION "public"."admin_set_lane_block_active"("p_block_id" "uuid", "p_is_active" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_set_lane_block_active"("p_block_id" "uuid", "p_is_active" boolean) IS 'Activates or deactivates one lane block under a hierarchy-aware family lock.';



CREATE OR REPLACE FUNCTION "public"."admin_set_lane_booking_configuration"("p_lane_id" "uuid", "p_is_active" boolean, "p_whole_lane_bookable" boolean, "p_positions_bookable" boolean, "p_max_shooters" integer, "p_online_bookable" boolean, "p_max_people_online" integer, "p_durations_minutes" integer[], "p_pricing" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_lane public.shooting_lanes%rowtype;
  v_parent public.shooting_lanes%rowtype;
  v_booking_rule public.lane_booking_rules%rowtype;
  v_scope record;
  v_scope_count integer := 0;
  v_conflict_lane_ids uuid[] := '{}'::uuid[];
  v_durations integer[];
  v_current_durations jsonb;
  v_target_durations jsonb;
  v_current_pricing jsonb;
  v_target_pricing jsonb;
  v_has_pricing boolean;
  v_max_obligation integer;
  v_rule_preupdated boolean := false;
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_id', p_lane_id
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role <> 'admin' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_id', p_lane_id
    );
  end if;

  if p_lane_id is null
     or p_is_active is null
     or p_whole_lane_bookable is null
     or p_positions_bookable is null
     or p_max_shooters is null
     or p_max_shooters < 1
     or p_online_bookable is null
     or p_max_people_online is null
     or p_max_people_online < 1
     or p_max_people_online > p_max_shooters
     or p_durations_minutes is null
     or p_pricing is null
     or pg_catalog.jsonb_typeof(p_pricing) <> 'array' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'lane_id', p_lane_id
    );
  end if;

  begin
    for v_scope in
      select scope_record.*
      from public.lock_lane_conflict_families_v1(array[p_lane_id]) as scope_record
    loop
      v_scope_count := v_scope_count + 1;
      v_conflict_lane_ids :=
        v_conflict_lane_ids || v_scope.conflict_lane_ids;
    end loop;
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'resource_not_found',
        'lane_id', p_lane_id
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_id', p_lane_id
      );
    when sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'lane_id', p_lane_id
      );
  end;

  if v_scope_count <> 1 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_id', p_lane_id
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'resource_not_found',
      'lane_id', p_lane_id
    );
  end if;

  if v_lane.resource_kind not in ('lane', 'position')
     or v_lane.parent_lane_id = v_lane.id then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_id', p_lane_id
    );
  end if;

  if v_lane.resource_kind = 'lane' and v_lane.parent_lane_id is not null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_id', p_lane_id
    );
  end if;

  if v_lane.resource_kind = 'position' then
    if v_lane.parent_lane_id is null
       or p_whole_lane_bookable
       or p_positions_bookable then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_id', p_lane_id
      );
    end if;

    select parent.*
    into v_parent
    from public.shooting_lanes as parent
    where parent.id = v_lane.parent_lane_id;

    if not found
       or v_parent.resource_kind <> 'lane'
       or v_parent.parent_lane_id is not null then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_id', p_lane_id
      );
    end if;
  end if;

  -- The family lock is held before any configuration-row lock.
  select booking_rule.*
  into v_booking_rule
  from public.lane_booking_rules as booking_rule
  where booking_rule.lane_id = p_lane_id
  for update;

  perform duration.id
  from public.lane_booking_durations as duration
  where duration.lane_id = p_lane_id
  order by duration.duration_minutes, duration.id
  for update;

  perform pricing.id
  from public.lane_pricing_rules as pricing
  where pricing.lane_id = p_lane_id
  order by pricing.day_group, pricing.min_shooters,
           pricing.max_shooters, pricing.id
  for update;

  select coalesce(
    pg_catalog.array_agg(distinct requested.duration order by requested.duration),
    '{}'::integer[]
  )
  into v_durations
  from pg_catalog.unnest(p_durations_minutes) as requested(duration);

  if pg_catalog.array_position(p_durations_minutes, null::integer) is not null
     or pg_catalog.cardinality(v_durations)
          <> pg_catalog.cardinality(p_durations_minutes)
     or exists (
       select 1
       from pg_catalog.unnest(v_durations) as requested(duration)
       where requested.duration <= 0
          or requested.duration > 1440
          or requested.duration % v_lane.booking_step_minutes <> 0
     )
     or (p_online_bookable and pg_catalog.cardinality(v_durations) = 0) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'lane_id', p_lane_id
    );
  end if;

  if exists (
       select 1
       from pg_catalog.jsonb_array_elements(p_pricing) as item(value)
       where pg_catalog.jsonb_typeof(item.value) <> 'object'
          or (
            select pg_catalog.array_agg(key_name order by key_name)
            from pg_catalog.jsonb_object_keys(item.value) as key_record(key_name)
          ) is distinct from array[
            'day_group', 'hourly_price', 'label',
            'max_shooters', 'min_shooters'
          ]::text[]
          or pg_catalog.jsonb_typeof(item.value->'day_group') <> 'string'
          or pg_catalog.jsonb_typeof(item.value->'label') <> 'string'
          or pg_catalog.jsonb_typeof(item.value->'min_shooters') <> 'number'
          or pg_catalog.jsonb_typeof(item.value->'max_shooters') <> 'number'
          or pg_catalog.jsonb_typeof(item.value->'hourly_price') <> 'number'
          or item.value->>'min_shooters' !~ '^[0-9]+$'
          or item.value->>'max_shooters' !~ '^[0-9]+$'
          or item.value->>'day_group' not in ('mon_thu', 'fri_sun')
          or pg_catalog.btrim(item.value->>'label') = ''
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'lane_id', p_lane_id
    );
  end if;

  begin
    if exists (
         select 1
         from pg_catalog.jsonb_array_elements(p_pricing) as item(value)
         where (item.value->>'min_shooters')::integer < 1
            or (item.value->>'max_shooters')::integer
                 < (item.value->>'min_shooters')::integer
            or (item.value->>'max_shooters')::integer > p_max_people_online
            or (item.value->>'hourly_price')::numeric < 0
            or (item.value->>'hourly_price')::numeric
                 <> pg_catalog.round((item.value->>'hourly_price')::numeric, 2)
            or (item.value->>'hourly_price')::numeric > 9999999999.99
       ) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'lane_id', p_lane_id
      );
    end if;
  exception
    when sqlstate '22003' or sqlstate '22P02' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'lane_id', p_lane_id
      );
  end;

  v_has_pricing := pg_catalog.jsonb_array_length(p_pricing) > 0;

  if v_has_pricing then
    if exists (
         with parsed as (
           select
             item.value->>'day_group' as day_group,
             (item.value->>'min_shooters')::integer as min_shooters,
             (item.value->>'max_shooters')::integer as max_shooters,
             pg_catalog.lag((item.value->>'max_shooters')::integer) over (
               partition by item.value->>'day_group'
               order by (item.value->>'min_shooters')::integer,
                        (item.value->>'max_shooters')::integer
             ) as previous_max
           from pg_catalog.jsonb_array_elements(p_pricing) as item(value)
         )
         select 1
         from parsed
         where previous_max is not null
           and min_shooters <> previous_max + 1
       )
       or (
         select count(*)
         from (
           select item.value->>'day_group' as day_group
           from pg_catalog.jsonb_array_elements(p_pricing) as item(value)
           group by item.value->>'day_group'
           having pg_catalog.min((item.value->>'min_shooters')::integer) = 1
              and pg_catalog.max((item.value->>'max_shooters')::integer)
                    = p_max_people_online
         ) as valid_group
       ) <> 2 then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'lane_id', p_lane_id
      );
    end if;
  elsif p_online_bookable then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'lane_id', p_lane_id
    );
  end if;

  select pg_catalog.max(reservation.shooters_count)
  into v_max_obligation
  from public.reservations as reservation
  where reservation.lane_id = any(v_conflict_lane_ids)
    and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
      not in (
        'completed', 'no_show', 'cancelled', 'canceled',
        'cancelled_by_admin', 'cancelled_by_user'
      )
    and (
      reservation.reservation_date
        > (pg_catalog.transaction_timestamp()
             at time zone 'Europe/Warsaw')::date
      or (
        reservation.reservation_date
          = (pg_catalog.transaction_timestamp()
               at time zone 'Europe/Warsaw')::date
        and reservation.end_time
          > (pg_catalog.transaction_timestamp()
               at time zone 'Europe/Warsaw')::time
      )
    );

  if v_max_obligation is not null and p_max_shooters < v_max_obligation then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_reservation',
      'lane_id', p_lane_id
    );
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'duration_minutes', duration.duration_minutes,
        'display_order', duration.display_order
      ) order by duration.duration_minutes
    ),
    '[]'::jsonb
  )
  into v_current_durations
  from public.lane_booking_durations as duration
  where duration.lane_id = p_lane_id
    and duration.is_active is true;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'duration_minutes', requested.duration,
        'display_order', requested.ordinality * 10
      ) order by requested.duration
    ),
    '[]'::jsonb
  )
  into v_target_durations
  from pg_catalog.unnest(v_durations) with ordinality
    as requested(duration, ordinality);

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'day_group', pricing.day_group,
        'min_shooters', pricing.min_shooters,
        'max_shooters', pricing.max_shooters,
        'label', pricing.label,
        'hourly_price', pricing.hourly_price,
        'display_order', pricing.display_order
      ) order by pricing.day_group, pricing.min_shooters,
                 pricing.max_shooters
    ),
    '[]'::jsonb
  )
  into v_current_pricing
  from public.lane_pricing_rules as pricing
  where pricing.lane_id = p_lane_id
    and pricing.is_active is true;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'day_group', normalized.day_group,
        'min_shooters', normalized.min_shooters,
        'max_shooters', normalized.max_shooters,
        'label', normalized.label,
        'hourly_price', normalized.hourly_price,
        'display_order', normalized.display_order
      ) order by normalized.day_group, normalized.min_shooters,
                 normalized.max_shooters
    ),
    '[]'::jsonb
  )
  into v_target_pricing
  from (
    select
      item.value->>'day_group' as day_group,
      (item.value->>'min_shooters')::integer as min_shooters,
      (item.value->>'max_shooters')::integer as max_shooters,
      pg_catalog.btrim(item.value->>'label') as label,
      (item.value->>'hourly_price')::numeric(12, 2) as hourly_price,
      pg_catalog.row_number() over (
        partition by item.value->>'day_group'
        order by (item.value->>'min_shooters')::integer,
                 (item.value->>'max_shooters')::integer,
                 pg_catalog.btrim(item.value->>'label')
      ) * 10 as display_order
    from pg_catalog.jsonb_array_elements(p_pricing) as item(value)
  ) as normalized;

  if v_lane.is_active = p_is_active
     and v_lane.whole_lane_bookable = p_whole_lane_bookable
     and v_lane.positions_bookable = p_positions_bookable
     and v_lane.max_shooters = p_max_shooters
     and v_booking_rule.lane_id is not null
     and v_booking_rule.online_bookable = p_online_bookable
     and v_booking_rule.max_people_online = p_max_people_online
     and v_current_durations = v_target_durations
     and v_current_pricing = v_target_pricing then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'lane_id', p_lane_id
    );
  end if;

  -- The existing capacity triggers require a coordinated limit decrease to
  -- lower max_people_online before max_shooters. Both writes are protected by
  -- the already-held family/config locks and remain in this RPC transaction.
  if v_booking_rule.lane_id is not null
     and p_max_shooters < v_booking_rule.max_people_online then
    update public.lane_booking_rules
    set online_bookable = p_online_bookable,
        max_people_online = p_max_people_online
    where lane_id = p_lane_id;
    v_rule_preupdated := true;
  end if;

  update public.shooting_lanes
  set is_active = p_is_active,
      whole_lane_bookable = p_whole_lane_bookable,
      positions_bookable = p_positions_bookable,
      max_shooters = p_max_shooters
  where id = p_lane_id;

  if not v_rule_preupdated then
    insert into public.lane_booking_rules (
      lane_id, online_bookable, max_people_online
    ) values (
      p_lane_id, p_online_bookable, p_max_people_online
    )
    on conflict (lane_id) do update
    set online_bookable = excluded.online_bookable,
        max_people_online = excluded.max_people_online;
  end if;

  delete from public.lane_booking_durations
  where lane_id = p_lane_id;

  insert into public.lane_booking_durations (
    lane_id, duration_minutes, display_order, is_active
  )
  select p_lane_id, requested.duration,
         requested.ordinality * 10, true
  from pg_catalog.unnest(v_durations) with ordinality
    as requested(duration, ordinality)
  order by requested.duration;

  -- Pricing rows referenced by historical reservations cannot be deleted.
  -- Replace the active snapshot by retaining deterministic matching row IDs
  -- and keeping superseded referenced rows as inactive history.
  update public.lane_pricing_rules
  set is_active = false
  where lane_id = p_lane_id
    and is_active is true;

  with target as (
    select
      item.value->>'day_group' as day_group,
      (item.value->>'min_shooters')::integer as min_shooters,
      (item.value->>'max_shooters')::integer as max_shooters,
      pg_catalog.btrim(item.value->>'label') as label,
      (item.value->>'hourly_price')::numeric(12, 2) as hourly_price,
      pg_catalog.row_number() over (
        partition by item.value->>'day_group'
        order by (item.value->>'min_shooters')::integer,
                 (item.value->>'max_shooters')::integer,
                 pg_catalog.btrim(item.value->>'label')
      ) * 10 as display_order
    from pg_catalog.jsonb_array_elements(p_pricing) as item(value)
  ), reusable as (
    select existing.id, target.label, target.hourly_price,
           target.display_order,
           pg_catalog.row_number() over (
             partition by existing.day_group, existing.min_shooters,
                          existing.max_shooters
             order by existing.id
           ) as candidate_order
    from target
    join public.lane_pricing_rules as existing
      on existing.lane_id = p_lane_id
     and existing.day_group = target.day_group
     and existing.min_shooters = target.min_shooters
     and existing.max_shooters = target.max_shooters
  )
  update public.lane_pricing_rules as existing
  set label = reusable.label,
      hourly_price = reusable.hourly_price,
      display_order = reusable.display_order,
      is_active = true
  from reusable
  where existing.id = reusable.id
    and reusable.candidate_order = 1;

  insert into public.lane_pricing_rules (
    lane_id, day_group, min_shooters, max_shooters,
    label, hourly_price, display_order, is_active
  )
  select
    p_lane_id,
    item.value->>'day_group',
    (item.value->>'min_shooters')::integer,
    (item.value->>'max_shooters')::integer,
    pg_catalog.btrim(item.value->>'label'),
    (item.value->>'hourly_price')::numeric(12, 2),
    pg_catalog.row_number() over (
      partition by item.value->>'day_group'
      order by (item.value->>'min_shooters')::integer,
               (item.value->>'max_shooters')::integer,
               pg_catalog.btrim(item.value->>'label')
    ) * 10,
    true
  from pg_catalog.jsonb_array_elements(p_pricing) as item(value)
  where not exists (
    select 1
    from public.lane_pricing_rules as existing
    where existing.lane_id = p_lane_id
      and existing.day_group = item.value->>'day_group'
      and existing.min_shooters = (item.value->>'min_shooters')::integer
      and existing.max_shooters = (item.value->>'max_shooters')::integer
      and existing.is_active is true
  )
  order by item.value->>'day_group',
           (item.value->>'min_shooters')::integer,
           (item.value->>'max_shooters')::integer;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'lane_id', p_lane_id
  );
end;
$_$;


ALTER FUNCTION "public"."admin_set_lane_booking_configuration"("p_lane_id" "uuid", "p_is_active" boolean, "p_whole_lane_bookable" boolean, "p_positions_bookable" boolean, "p_max_shooters" integer, "p_online_bookable" boolean, "p_max_people_online" integer, "p_durations_minutes" integer[], "p_pricing" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_set_lane_booking_configuration"("p_lane_id" "uuid", "p_is_active" boolean, "p_whole_lane_bookable" boolean, "p_positions_bookable" boolean, "p_max_shooters" integer, "p_online_bookable" boolean, "p_max_people_online" integer, "p_durations_minutes" integer[], "p_pricing" "jsonb") IS 'Atomically replaces the sales configuration snapshot for one booking resource.';



CREATE OR REPLACE FUNCTION "public"."admin_set_lane_booking_family_configuration_v2"("p_root_lane_id" "uuid", "p_expected_version" bigint, "p_resources" "jsonb", "p_acknowledge_future_obligations" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_actor_role text;
  v_root public.shooting_lanes%rowtype;
  v_root_target jsonb;
  v_target jsonb;
  v_current jsonb;
  v_target_without_names jsonb;
  v_current_without_names jsonb;
  v_renamed_resources jsonb := '[]'::jsonb;
  v_name_only boolean := false;
  v_family_ids uuid[];
  v_target_ids uuid[];
  v_affected_ids uuid[] := '{}'::uuid[];
  v_version bigint;
  v_resource record;
  v_lane public.shooting_lanes%rowtype;
  v_rule public.lane_booking_rules%rowtype;
  v_price record;
  v_previous_max integer;
  v_group_count integer;
  v_position_capacity integer;
  v_max_obligation integer;
  v_future_reservations bigint := 0;
  v_future_blocks bigint := 0;
  v_future_events bigint := 0;
  v_now timestamptz := pg_catalog.transaction_timestamp();
begin
  select profile.* into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;
  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor.role::text));

  if v_actor_id is null or coalesce(v_actor_role, '') <> 'admin' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if p_root_lane_id is null or p_expected_version is null
     or p_expected_version < 1 or p_acknowledge_future_obligations is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id
    );
  end if;

  begin
    v_target := public.normalize_lane_booking_family_payload_v2(p_resources);
  exception when sqlstate '22023' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id
    );
  end;

  begin
    select scope.conflict_lane_ids into v_family_ids
    from public.lock_lane_conflict_families_v1(array[p_root_lane_id]) as scope
    where scope.requested_lane_id = p_root_lane_id
      and scope.root_lane_id = p_root_lane_id
      and scope.requested_resource_kind = 'lane';
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'family_not_found',
        'root_lane_id', p_root_lane_id
      );
    when sqlstate '55000' or sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'root_lane_id', p_root_lane_id
      );
  end;

  if v_family_ids is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id
    );
  end if;

  select root.* into v_root
  from public.shooting_lanes as root
  where root.id = p_root_lane_id;

  select version.configuration_version into v_version
  from public.lane_booking_family_configuration_versions as version
  where version.root_lane_id = p_root_lane_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if v_version <> p_expected_version then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'stale_configuration',
      'root_lane_id', p_root_lane_id,
      'current_version', v_version,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  select pg_catalog.array_agg((item.value->>'lane_id')::uuid order by (item.value->>'lane_id')::uuid)
  into v_target_ids
  from pg_catalog.jsonb_array_elements(v_target) as item(value);

  if v_target_ids is distinct from v_family_ids then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  perform rule.lane_id
  from public.lane_booking_rules as rule
  where rule.lane_id = any(v_family_ids)
  order by rule.lane_id
  for update;

  if (select pg_catalog.count(*) from public.lane_booking_rules
      where lane_id = any(v_family_ids)) <> pg_catalog.cardinality(v_family_ids) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  perform duration.id
  from public.lane_booking_durations as duration
  where duration.lane_id = any(v_family_ids)
  order by duration.lane_id, duration.duration_minutes, duration.id
  for update;

  perform pricing.id
  from public.lane_pricing_rules as pricing
  where pricing.lane_id = any(v_family_ids)
  order by pricing.lane_id, pricing.day_group, pricing.min_shooters,
           pricing.max_shooters, pricing.id
  for update;

  v_current := public.lane_booking_family_business_snapshot_v2(p_root_lane_id);
  v_root_target := (
    select item.value from pg_catalog.jsonb_array_elements(v_target) as item(value)
    where item.value->>'lane_id' = p_root_lane_id::text
  );

  select pg_catalog.jsonb_agg(item.value - 'name' order by (item.value->>'lane_id')::uuid)
  into v_current_without_names
  from pg_catalog.jsonb_array_elements(v_current) as item(value);

  select pg_catalog.jsonb_agg(item.value - 'name' order by (item.value->>'lane_id')::uuid)
  into v_target_without_names
  from pg_catalog.jsonb_array_elements(v_target) as item(value);

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'resource_id', (target.value->>'lane_id')::uuid,
      'old_name', current.value->>'name',
      'new_name', target.value->>'name'
    ) order by (target.value->>'lane_id')::uuid
  ), '[]'::jsonb)
  into v_renamed_resources
  from pg_catalog.jsonb_array_elements(v_target) as target(value)
  join pg_catalog.jsonb_array_elements(v_current) as current(value)
    on current.value->>'lane_id' = target.value->>'lane_id'
  where current.value->>'name' is distinct from target.value->>'name';

  v_name_only := v_current_without_names = v_target_without_names;

  if v_root.resource_kind <> 'lane' or v_root.parent_lane_id is not null
     or v_root_target is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  for v_resource in
    select item.value
    from pg_catalog.jsonb_array_elements(v_target) as item(value)
    order by (item.value->>'lane_id')::uuid
  loop
    select lane.* into v_lane
    from public.shooting_lanes as lane
    where lane.id = (v_resource.value->>'lane_id')::uuid;

    if not found
       or (v_lane.id = p_root_lane_id and
           (v_lane.resource_kind <> 'lane' or v_lane.parent_lane_id is not null))
       or (v_lane.id <> p_root_lane_id and
           (v_lane.resource_kind <> 'position'
            or v_lane.parent_lane_id is distinct from p_root_lane_id))
       or (v_lane.resource_kind = 'position' and
           ((v_resource.value->>'whole_lane_bookable')::boolean
            or (v_resource.value->>'positions_bookable')::boolean))
       or (v_resource.value->>'max_shooters')::integer < 1
       or (v_resource.value->>'max_people_online')::integer < 1
       or (v_resource.value->>'max_people_online')::integer
            > (v_resource.value->>'max_shooters')::integer then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    if exists (
         select 1
         from pg_catalog.jsonb_array_elements(v_resource.value->'durations_minutes') as duration(value)
         where (duration.value #>> '{}')::integer <= 0
            or (duration.value #>> '{}')::integer > 1440
            or (duration.value #>> '{}')::integer % v_lane.booking_step_minutes <> 0
       )
       or ((v_resource.value->>'online_bookable')::boolean
           and pg_catalog.jsonb_array_length(v_resource.value->'durations_minutes') = 0) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    v_previous_max := null;
    v_group_count := 0;
    for v_price in
      select
        price.value->>'day_group' as day_group,
        (price.value->>'min_shooters')::integer as min_shooters,
        (price.value->>'max_shooters')::integer as max_shooters,
        (price.value->>'hourly_price')::numeric as hourly_price
      from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      order by price.value->>'day_group',
               (price.value->>'min_shooters')::integer,
               (price.value->>'max_shooters')::integer
    loop
      if v_price.min_shooters < 1
         or v_price.max_shooters < v_price.min_shooters
         or v_price.max_shooters > (v_resource.value->>'max_people_online')::integer
         or v_price.hourly_price < 0
         or v_price.hourly_price > 9999999999.99
         or v_price.hourly_price <> pg_catalog.round(v_price.hourly_price, 2) then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', p_root_lane_id,
          'previous_version', v_version,
          'configuration_version', v_version
        );
      end if;
    end loop;

    if pg_catalog.jsonb_array_length(v_resource.value->'pricing') > 0 then
      if exists (
           with parsed as (
             select price.value->>'day_group' as day_group,
                    (price.value->>'min_shooters')::integer as min_shooters,
                    (price.value->>'max_shooters')::integer as max_shooters,
                    pg_catalog.lag((price.value->>'max_shooters')::integer) over (
                      partition by price.value->>'day_group'
                      order by (price.value->>'min_shooters')::integer,
                               (price.value->>'max_shooters')::integer
                    ) as previous_max
             from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
           )
           select 1 from parsed
           where (previous_max is null and min_shooters <> 1)
              or (previous_max is not null and min_shooters <> previous_max + 1)
         )
         or (select pg_catalog.count(*) from (
               select price.value->>'day_group'
               from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
               group by price.value->>'day_group'
               having pg_catalog.max((price.value->>'max_shooters')::integer)
                      = (v_resource.value->>'max_people_online')::integer
             ) as valid_group) <> 2 then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', p_root_lane_id,
          'previous_version', v_version,
          'configuration_version', v_version
        );
      end if;
    elsif (v_resource.value->>'online_bookable')::boolean then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    if (v_resource.value->>'online_bookable')::boolean
       and not (v_resource.value->>'is_active')::boolean then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;
  end loop;

  if (v_root_target->>'online_bookable')::boolean
     and not (v_root_target->>'whole_lane_bookable')::boolean then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if not (v_root_target->>'is_active')::boolean
     and ((v_root_target->>'online_bookable')::boolean
          or exists (
            select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
            where item.value->>'lane_id' <> p_root_lane_id::text
              and ((item.value->>'is_active')::boolean
                   or (item.value->>'online_bookable')::boolean)
          )) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'is_active')::boolean
         and not (v_root_target->>'is_active')::boolean
     )
     or exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'online_bookable')::boolean
         and (not (v_root_target->>'is_active')::boolean
              or not (v_root_target->>'positions_bookable')::boolean)
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if (v_root_target->>'positions_bookable')::boolean
     and not exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'is_active')::boolean
         and (item.value->>'online_bookable')::boolean
         and pg_catalog.jsonb_array_length(item.value->'durations_minutes') > 0
         and pg_catalog.jsonb_array_length(item.value->'pricing') > 0
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  select coalesce(pg_catalog.sum((item.value->>'max_shooters')::integer), 0)
  into v_position_capacity
  from pg_catalog.jsonb_array_elements(v_target) as item(value)
  where item.value->>'lane_id' <> p_root_lane_id::text
    and (item.value->>'is_active')::boolean
    and (item.value->>'online_bookable')::boolean;

  if (v_root_target->>'positions_bookable')::boolean
     and v_position_capacity > (v_root_target->>'max_shooters')::integer then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if v_current = v_target then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  for v_resource in
    select item.value
    from pg_catalog.jsonb_array_elements(v_target) as item(value)
  loop
    select pg_catalog.max(reservation.shooters_count)
    into v_max_obligation
    from public.reservations as reservation
    where reservation.lane_id = (v_resource.value->>'lane_id')::uuid
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)) not in (
        'completed','no_show','cancelled','canceled',
        'cancelled_by_admin','cancelled_by_user'
      )
      and (reservation.reservation_date, reservation.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    if v_max_obligation is not null
       and (v_resource.value->>'max_shooters')::integer < v_max_obligation then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'reservation_capacity_conflict',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;
  end loop;

  if v_root.is_active and not (v_root_target->>'is_active')::boolean then
    v_affected_ids := v_family_ids;
  else
    if v_root.whole_lane_bookable
       and not (v_root_target->>'whole_lane_bookable')::boolean then
      v_affected_ids := pg_catalog.array_append(v_affected_ids, p_root_lane_id);
    end if;
    if v_root.positions_bookable
       and not (v_root_target->>'positions_bookable')::boolean then
      select coalesce(pg_catalog.array_agg(id order by id), '{}'::uuid[])
      into v_affected_ids
      from (
        select distinct id from pg_catalog.unnest(
          v_affected_ids || array(
            select child.id from public.shooting_lanes as child
            where child.parent_lane_id = p_root_lane_id
          )
        ) as ids(id)
      ) as affected;
    end if;
    select coalesce(pg_catalog.array_agg(id order by id), '{}'::uuid[])
    into v_affected_ids
    from (
      select distinct (item.value->>'lane_id')::uuid as id
      from pg_catalog.jsonb_array_elements(v_target) as item(value)
      join public.shooting_lanes as current_lane
        on current_lane.id = (item.value->>'lane_id')::uuid
      where current_lane.is_active
        and not (item.value->>'is_active')::boolean
      union
      select id from pg_catalog.unnest(v_affected_ids) as ids(id)
    ) as affected;
  end if;

  if pg_catalog.cardinality(v_affected_ids) > 0 then
    select pg_catalog.count(*) into v_future_reservations
    from public.reservations as reservation
    where reservation.lane_id = any(v_affected_ids)
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)) not in (
        'completed','no_show','cancelled','canceled',
        'cancelled_by_admin','cancelled_by_user'
      )
      and (reservation.reservation_date, reservation.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    select pg_catalog.count(*) into v_future_blocks
    from public.lane_blocks as lane_block
    where lane_block.lane_id = any(v_affected_ids)
      and lane_block.is_active
      and (lane_block.block_date, lane_block.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    select pg_catalog.count(distinct event_record.id) into v_future_events
    from public.events as event_record
    join public.event_lanes as event_lane on event_lane.event_id = event_record.id
    where event_lane.lane_id = any(v_affected_ids)
      and event_record.is_active
      and (event_record.event_date, event_record.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);
  end if;

  if not p_acknowledge_future_obligations
     and (v_future_reservations + v_future_blocks + v_future_events) > 0 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'confirmation_required',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version,
      'future_reservations_count', v_future_reservations,
      'future_lane_blocks_count', v_future_blocks,
      'future_events_count', v_future_events
    );
  end if;

  begin
    if v_name_only then
      for v_resource in
        select item.value
        from pg_catalog.jsonb_array_elements(v_target) as item(value)
        order by (item.value->>'lane_id')::uuid
      loop
        update public.shooting_lanes
        set name = v_resource.value->>'name'
        where id = (v_resource.value->>'lane_id')::uuid
          and name is distinct from v_resource.value->>'name';
      end loop;
    else
    for v_resource in
      select item.value
      from pg_catalog.jsonb_array_elements(v_target) as item(value)
      order by (item.value->>'lane_id')::uuid
    loop
      select lane.* into v_lane from public.shooting_lanes as lane
      where lane.id = (v_resource.value->>'lane_id')::uuid;
      select rule.* into v_rule from public.lane_booking_rules as rule
      where rule.lane_id = v_lane.id;

      if (v_resource.value->>'max_shooters')::integer < v_rule.max_people_online then
        update public.lane_booking_rules
        set online_bookable = (v_resource.value->>'online_bookable')::boolean,
            max_people_online = (v_resource.value->>'max_people_online')::integer
        where lane_id = v_lane.id;
      end if;

      update public.shooting_lanes
      set name = v_resource.value->>'name',
          is_active = (v_resource.value->>'is_active')::boolean,
          whole_lane_bookable = (v_resource.value->>'whole_lane_bookable')::boolean,
          positions_bookable = (v_resource.value->>'positions_bookable')::boolean,
          max_shooters = (v_resource.value->>'max_shooters')::integer
      where id = v_lane.id;

      update public.lane_booking_rules
      set online_bookable = (v_resource.value->>'online_bookable')::boolean,
          max_people_online = (v_resource.value->>'max_people_online')::integer
      where lane_id = v_lane.id;

      delete from public.lane_booking_durations where lane_id = v_lane.id;
      insert into public.lane_booking_durations(
        lane_id, duration_minutes, display_order, is_active
      )
      select v_lane.id, (duration.value #>> '{}')::integer,
             duration.ordinality * 10, true
      from pg_catalog.jsonb_array_elements(v_resource.value->'durations_minutes')
        with ordinality as duration(value, ordinality)
      order by (duration.value #>> '{}')::integer;

      update public.lane_pricing_rules set is_active = false
      where lane_id = v_lane.id and is_active;

      with target_price as (
        select
          price.value->>'day_group' as day_group,
          (price.value->>'min_shooters')::integer as min_shooters,
          (price.value->>'max_shooters')::integer as max_shooters,
          pg_catalog.btrim(price.value->>'label') as label,
          (price.value->>'hourly_price')::numeric(12,2) as hourly_price,
          pg_catalog.row_number() over (
            partition by price.value->>'day_group'
            order by (price.value->>'min_shooters')::integer,
                     (price.value->>'max_shooters')::integer,
                     pg_catalog.btrim(price.value->>'label')
          ) * 10 as display_order
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      ), reusable as (
        select existing.id, target_price.display_order,
               pg_catalog.row_number() over (
                 partition by target_price.day_group, target_price.min_shooters,
                              target_price.max_shooters, target_price.label,
                              target_price.hourly_price
                 order by existing.id
               ) as candidate_order
        from target_price
        join public.lane_pricing_rules as existing
          on existing.lane_id = v_lane.id
         and existing.day_group = target_price.day_group
         and existing.min_shooters = target_price.min_shooters
         and existing.max_shooters = target_price.max_shooters
         and existing.label = target_price.label
         and existing.hourly_price = target_price.hourly_price
      )
      update public.lane_pricing_rules as existing
      set display_order = reusable.display_order, is_active = true
      from reusable
      where existing.id = reusable.id and reusable.candidate_order = 1;

      with target_price as (
        select
          price.value->>'day_group' as day_group,
          (price.value->>'min_shooters')::integer as min_shooters,
          (price.value->>'max_shooters')::integer as max_shooters,
          pg_catalog.btrim(price.value->>'label') as label,
          (price.value->>'hourly_price')::numeric(12,2) as hourly_price,
          pg_catalog.row_number() over (
            partition by price.value->>'day_group'
            order by (price.value->>'min_shooters')::integer,
                     (price.value->>'max_shooters')::integer,
                     pg_catalog.btrim(price.value->>'label')
          ) * 10 as display_order
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      )
      insert into public.lane_pricing_rules(
        lane_id, day_group, min_shooters, max_shooters,
        label, hourly_price, display_order, is_active
      )
      select v_lane.id, target_price.day_group,
             target_price.min_shooters,
             target_price.max_shooters,
             target_price.label,
             target_price.hourly_price,
             target_price.display_order,
             true
      from target_price
      where not exists (
        select 1 from public.lane_pricing_rules as existing
        where existing.lane_id = v_lane.id
          and existing.day_group = target_price.day_group
          and existing.min_shooters = target_price.min_shooters
          and existing.max_shooters = target_price.max_shooters
          and existing.label = target_price.label
          and existing.hourly_price = target_price.hourly_price
          and existing.is_active
      );
    end loop;
    end if;

    update public.lane_booking_family_configuration_versions
    set configuration_version = configuration_version + 1,
        updated_at = v_now
    where root_lane_id = p_root_lane_id
    returning configuration_version into v_version;

    insert into public.audit_logs(
      actor_user_id, actor_name, actor_role, action,
      target_type, target_id, target_name, details
    ) values (
      v_actor_id,
      coalesce(
        nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)), ''),
        nullif(pg_catalog.btrim(v_actor.full_name), ''),
        'Administrator'
      ),
      'admin', 'lane_booking_family_configuration_updated',
      'lane_booking_family', p_root_lane_id, v_root_target->>'name',
      pg_catalog.jsonb_build_object(
        'previous_version', p_expected_version,
        'new_version', v_version,
        'before', v_current,
        'after', v_target,
        'renamed_resources', v_renamed_resources
      )
    );
  exception when others then
    raise exception 'Lane family configuration update failed.' using errcode = 'P0001';
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'root_lane_id', p_root_lane_id,
    'previous_version', p_expected_version,
    'configuration_version', v_version
  );
end;
$$;


ALTER FUNCTION "public"."admin_set_lane_booking_family_configuration_v2"("p_root_lane_id" "uuid", "p_expected_version" bigint, "p_resources" "jsonb", "p_acknowledge_future_obligations" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_set_lane_booking_family_configuration_v2"("p_root_lane_id" "uuid", "p_expected_version" bigint, "p_resources" "jsonb", "p_acknowledge_future_obligations" boolean) IS 'Atomically replaces one complete lane-family target, including display names, with optimistic concurrency and controlled confirmation.';



CREATE OR REPLACE FUNCTION "public"."admin_set_user_note_v1"("p_target_user_id" "uuid", "p_admin_note" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_target public.profiles%rowtype;
  v_note text := nullif(pg_catalog.btrim(p_admin_note), '');
  v_changed_at timestamptz := pg_catalog.transaction_timestamp();
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(6202, 1);

  select profile.* into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if not found or pg_catalog.lower(pg_catalog.btrim(v_actor.role::text)) <> 'admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_target');
  end if;

  if pg_catalog.length(coalesce(v_note, '')) > 2000 then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'note_too_long');
  end if;

  select profile.* into v_target
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'target_not_found');
  end if;

  if v_target.admin_note is not distinct from v_note then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'target_user_id', p_target_user_id
    );
  end if;

  perform pg_catalog.set_config('csk.profile_note_rpc_actor', v_actor_id::text, true);
  perform pg_catalog.set_config('csk.profile_note_rpc_target', p_target_user_id::text, true);

  update public.profiles as profile
  set admin_note = v_note, updated_at = v_changed_at
  where profile.user_id = p_target_user_id;

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)), ''),
      nullif(pg_catalog.btrim(v_actor.full_name), ''),
      'Administrator'
    ),
    'admin', 'profile_admin_note_updated', 'profile', p_target_user_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_target.first_name, v_target.last_name)), ''),
      nullif(pg_catalog.btrim(v_target.full_name), ''),
      'Profil użytkownika'
    ),
    pg_catalog.jsonb_build_object(
      'previous_note_present', v_target.admin_note is not null,
      'new_note_present', v_note is not null,
      'operator_role', 'admin'
    )
  );

  perform pg_catalog.set_config('csk.profile_note_rpc_actor', '', true);
  perform pg_catalog.set_config('csk.profile_note_rpc_target', '', true);

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'target_user_id', p_target_user_id, 'admin_note', v_note,
    'updated_at', v_changed_at
  );
end;
$$;


ALTER FUNCTION "public"."admin_set_user_note_v1"("p_target_user_id" "uuid", "p_admin_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_user_role_v1"("p_target_user_id" "uuid", "p_new_role" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_target public.profiles%rowtype;
  v_new_role text := pg_catalog.lower(pg_catalog.btrim(p_new_role));
  v_current_role text;
  v_admin_count bigint;
  v_changed_at timestamptz := pg_catalog.transaction_timestamp();
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(6202, 1);

  select profile.* into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if not found or pg_catalog.lower(pg_catalog.btrim(v_actor.role::text)) <> 'admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_target');
  end if;

  if v_new_role is null or v_new_role not in ('user', 'instruktor', 'pracownik', 'admin') then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_role');
  end if;

  select profile.* into v_target
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'target_not_found');
  end if;

  v_current_role := pg_catalog.lower(pg_catalog.btrim(v_target.role::text));
  if v_current_role not in ('user', 'instruktor', 'pracownik', 'admin') then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_current_role');
  end if;

  if v_current_role = v_new_role then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'target_user_id', p_target_user_id, 'role', v_current_role
    );
  end if;

  if v_current_role = 'admin' and v_new_role <> 'admin' then
    select pg_catalog.count(*) into v_admin_count
    from public.profiles as profile
    where pg_catalog.lower(pg_catalog.btrim(profile.role::text)) = 'admin';

    if v_admin_count <= 1 then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'last_admin',
        'target_user_id', p_target_user_id, 'role', v_current_role
      );
    end if;
  end if;

  perform pg_catalog.set_config('csk.profile_role_rpc_actor', v_actor_id::text, true);
  perform pg_catalog.set_config('csk.profile_role_rpc_target', p_target_user_id::text, true);

  update public.profiles as profile
  set role = v_new_role, updated_at = v_changed_at
  where profile.user_id = p_target_user_id;

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)), ''),
      nullif(pg_catalog.btrim(v_actor.full_name), ''),
      'Administrator'
    ),
    'admin', 'profile_role_changed', 'profile', p_target_user_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_target.first_name, v_target.last_name)), ''),
      nullif(pg_catalog.btrim(v_target.full_name), ''),
      'Profil użytkownika'
    ),
    pg_catalog.jsonb_build_object(
      'previous_role', v_current_role,
      'new_role', v_new_role,
      'operator_role', 'admin'
    )
  );

  perform pg_catalog.set_config('csk.profile_role_rpc_actor', '', true);
  perform pg_catalog.set_config('csk.profile_role_rpc_target', '', true);

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'target_user_id', p_target_user_id, 'previous_role', v_current_role,
    'role', v_new_role, 'updated_at', v_changed_at
  );
end;
$$;


ALTER FUNCTION "public"."admin_set_user_role_v1"("p_target_user_id" "uuid", "p_new_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) IS 'Atomowo aktualizuje dane eventu i zastępuje jego pełny zestaw osi.';



CREATE OR REPLACE FUNCTION "public"."admin_update_event_v2"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_original public.events%rowtype;
  v_current public.events%rowtype;
  v_title text;
  v_description text;
  v_location text;
  v_old_lane_ids uuid[];
  v_new_lane_ids uuid[];
  v_lock_lane_ids uuid[];
  v_conflict_lane_ids uuid[] := '{}'::uuid[];
  v_scope record;
  v_scope_count integer := 0;
  v_new_scope_count integer := 0;
  v_invalid_lane_id uuid;
  v_conflict_lane_id uuid;
begin
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
  into v_original
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
     or p_max_participants is null
     or p_max_participants <= 0
     or pg_catalog.array_position(v_new_lane_ids, null::uuid) is not null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input', 'event_id', p_event_id
    );
  end if;

  if p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_time_range', 'event_id', p_event_id
    );
  end if;

  select coalesce(
    pg_catalog.array_agg(distinct requested.lane_id order by requested.lane_id),
    '{}'::uuid[]
  )
  into v_new_lane_ids
  from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id);

  if pg_catalog.cardinality(v_new_lane_ids) > 0
     and (p_start_time < time '08:00' or p_end_time > time '20:00') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'outside_booking_hours',
      'event_id', p_event_id
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
    select old_lane.lane_id
    from pg_catalog.unnest(v_old_lane_ids) as old_lane(lane_id)
    union
    select new_lane.lane_id
    from pg_catalog.unnest(v_new_lane_ids) as new_lane(lane_id)
  ) as candidate;

  if pg_catalog.cardinality(v_lock_lane_ids) > 0 then
    begin
      for v_scope in
        select scope_record.*
        from public.lock_lane_conflict_families_v1(v_lock_lane_ids) as scope_record
      loop
        v_scope_count := v_scope_count + 1;
        if v_scope.requested_lane_id = any(v_new_lane_ids) then
          v_new_scope_count := v_new_scope_count + 1;
          v_conflict_lane_ids :=
            v_conflict_lane_ids || v_scope.conflict_lane_ids;
        end if;
      end loop;
    exception
      when sqlstate 'P0002' then
        select requested.lane_id
        into v_invalid_lane_id
        from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id)
        left join public.shooting_lanes as lane on lane.id = requested.lane_id
        where lane.id is null
        order by requested.lane_id
        limit 1;

        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code',
          case when v_invalid_lane_id is null then 'invalid_hierarchy'
               else 'invalid_lane' end,
          'event_id', p_event_id,
          'conflict_lane_id', v_invalid_lane_id
        );
      when sqlstate '55000' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
          'event_id', p_event_id
        );
      when sqlstate '22023' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_input',
          'event_id', p_event_id
        );
    end;

    if v_scope_count <> pg_catalog.cardinality(v_lock_lane_ids)
       or v_new_scope_count <> pg_catalog.cardinality(v_new_lane_ids) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'event_id', p_event_id
      );
    end if;
  end if;

  select event_record.*
  into v_current
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'event_not_found', 'event_id', p_event_id
    );
  end if;

  if v_current is distinct from v_original then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error', 'event_id', p_event_id
    );
  end if;

  if pg_catalog.cardinality(v_new_lane_ids) > 0 then
    select coalesce(
      pg_catalog.array_agg(distinct conflict.lane_id order by conflict.lane_id),
      '{}'::uuid[]
    )
    into v_conflict_lane_ids
    from pg_catalog.unnest(v_conflict_lane_ids) as conflict(lane_id);

    select requested.lane_id
    into v_invalid_lane_id
    from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id)
    join public.shooting_lanes as lane on lane.id = requested.lane_id
    left join public.shooting_lanes as parent
      on parent.id = lane.parent_lane_id
    where (
        lane.is_active is not true
        or (
          lane.resource_kind = 'position'
          and parent.is_active is not true
        )
      )
      and not (requested.lane_id = any(v_old_lane_ids))
    order by requested.lane_id
    limit 1;

    if found then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'inactive_lane',
        'event_id', p_event_id, 'conflict_lane_id', v_invalid_lane_id
      );
    end if;
  end if;

  if v_original.title is not distinct from v_title
     and v_original.description is not distinct from v_description
     and v_original.event_date is not distinct from p_event_date
     and v_original.start_time is not distinct from p_start_time
     and v_original.end_time is not distinct from p_end_time
     and v_original.location is not distinct from v_location
     and v_original.price is not distinct from p_price
     and v_original.max_participants is not distinct from p_max_participants
     and v_old_lane_ids = v_new_lane_ids then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change', 'event_id', p_event_id
    );
  end if;

  if v_original.is_active and pg_catalog.cardinality(v_new_lane_ids) > 0 then
    select reservation.lane_id
    into v_conflict_lane_id
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
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
    where lane_block.lane_id = any(v_conflict_lane_ids)
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
    where event_lane.lane_id = any(v_conflict_lane_ids)
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
  where event_lane.event_id = p_event_id;

  insert into public.event_lanes (event_id, lane_id)
  select p_event_id, requested.lane_id
  from pg_catalog.unnest(v_new_lane_ids) as requested(lane_id)
  order by requested.lane_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated', 'event_id', p_event_id
  );
end;
$$;


ALTER FUNCTION "public"."admin_update_event_v2"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_update_event_v2"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) IS 'Dormant hierarchy-aware event update locking the union of old and new conflict families.';



CREATE OR REPLACE FUNCTION "public"."admin_update_lane_block"("p_block_id" "uuid", "p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text", "p_is_active" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_original public.lane_blocks%rowtype;
  v_current public.lane_blocks%rowtype;
  v_lane public.shooting_lanes%rowtype;
  v_conflict_lane_ids uuid[];
  v_requested_kind text;
  v_constraint_name text;
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  if p_block_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', null
    );
  end if;

  select lane_block.*
  into v_original
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  if p_lane_id is null
     or p_block_date is null
     or p_start_time is null
     or p_end_time is null
     or p_is_active is null
     or p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    select scope_record.conflict_lane_ids,
           scope_record.requested_resource_kind
    into v_conflict_lane_ids, v_requested_kind
    from public.lock_lane_conflict_families_v1(
      array[v_original.lane_id, p_lane_id]::uuid[]
    ) as scope_record
    where scope_record.requested_lane_id = p_lane_id;
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_lane',
        'lane_block_id', p_block_id
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_block_id', p_block_id
      );
    when sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_input',
        'lane_block_id', p_block_id
      );
  end;

  if v_conflict_lane_ids is null or v_requested_kind is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  select lane_block.*
  into v_current
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  if v_current is distinct from v_original then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error',
      'lane_block_id', p_block_id
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if v_lane.resource_kind is distinct from v_requested_kind then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  if p_is_active and not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if p_is_active and exists (
    select 1
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = p_block_date
      and reservation.start_time < p_end_time
      and reservation.end_time > p_start_time
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_reservation',
      'lane_block_id', p_block_id
    );
  end if;

  if p_is_active and exists (
    select 1
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    where event_lane.lane_id = any(v_conflict_lane_ids)
      and event_record.is_active is true
      and event_record.event_date = p_block_date
      and event_record.start_time < p_end_time
      and event_record.end_time > p_start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_event',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    update public.lane_blocks
    set lane_id = p_lane_id,
        block_date = p_block_date,
        start_time = p_start_time,
        end_time = p_end_time,
        reason = p_reason,
        is_active = p_is_active
    where id = p_block_id;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'lane_blocks_no_active_reservation_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_reservation',
          'lane_block_id', p_block_id
        );
      end if;

      if v_constraint_name = 'lane_blocks_no_active_event_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_event',
          'lane_block_id', p_block_id
        );
      end if;

      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'lane_block_id', p_block_id
  );
end;
$$;


ALTER FUNCTION "public"."admin_update_lane_block"("p_block_id" "uuid", "p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text", "p_is_active" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_update_lane_block"("p_block_id" "uuid", "p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text", "p_is_active" boolean) IS 'Updates one lane block under globally ordered old/new hierarchy family locks.';



CREATE OR REPLACE FUNCTION "public"."approve_event_registration"("p_registration_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  actor_user_id uuid := auth.uid();
  actor_role text;
  target_event_id uuid;
  target_event public.events%rowtype;
  target_registration public.event_registrations%rowtype;
  normalized_status text;
  action_time timestamptz := pg_catalog.transaction_timestamp();
begin
  if actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'unauthorized'
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into actor_role
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found or coalesce(actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'unauthorized'
    );
  end if;

  if p_registration_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'registration_not_found'
    );
  end if;

  select registration.event_id
  into target_event_id
  from public.event_registrations as registration
  where registration.id = p_registration_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'registration_not_found'
    );
  end if;

  if target_event_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_not_found'
    );
  end if;

  select event_record.*
  into target_event
  from public.events as event_record
  where event_record.id = target_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_not_found'
    );
  end if;

  select registration.*
  into target_registration
  from public.event_registrations as registration
  where registration.id = p_registration_id
    and registration.event_id = target_event.id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'registration_not_found'
    );
  end if;

  normalized_status :=
    pg_catalog.lower(pg_catalog.btrim(target_registration.registration_status));

  if normalized_status = 'approved' then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'unchanged',
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'previous_status', 'approved',
      'new_status', 'approved'
    );
  end if;

  if normalized_status <> 'registered' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'invalid_transition'
    );
  end if;

  update public.event_registrations as registration
  set registration_status = 'approved'
  where registration.id = target_registration.id;

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
    actor_user_id,
    'Obsługa',
    actor_role,
    'event_registration_approved_by_staff',
    'event_registration',
    target_registration.id,
    'Zapis na szkolenie',
    pg_catalog.jsonb_build_object(
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'previous_status', normalized_status,
      'new_status', 'approved',
      'operator_role', actor_role,
      'changed_at', action_time
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'updated',
    'registration_id', target_registration.id,
    'event_id', target_registration.event_id,
    'previous_status', normalized_status,
    'new_status', 'approved'
  );
end;
$$;


ALTER FUNCTION "public"."approve_event_registration"("p_registration_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."approve_event_registration"("p_registration_id" "uuid") IS 'Atomowo zatwierdza istniejący zapis registered dla administratora lub pracownika i zapisuje audit log.';



CREATE OR REPLACE FUNCTION "public"."cancel_event_registration"("p_registration_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_registration public.event_registrations%rowtype;
  target_event public.events%rowtype;
  target_event_id uuid;
  actor_role text;
  normalized_status text;
  actor_name text;
  audit_action text;
  is_self_service_actor boolean;
  freed_participant_place boolean := false;
  event_start_at timestamptz;
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  if p_registration_id is null then
    raise exception 'Brak identyfikatora zapisu na szkolenie.'
      using errcode = '22023';
  end if;

  select profile.*
  into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found then
    raise exception 'Brak profilu operatora.'
      using errcode = '42501';
  end if;

  actor_role := lower(btrim(actor_profile.role::text));
  is_self_service_actor := actor_role in ('user', 'instruktor');

  if coalesce(actor_role, '') not in (
    'user',
    'instruktor',
    'admin',
    'pracownik'
  ) then
    raise exception 'Brak uprawnień do anulowania zapisu na szkolenie.'
      using errcode = '42501';
  end if;

  select registration.event_id
  into target_event_id
  from public.event_registrations as registration
  where registration.id = p_registration_id;

  if not found then
    raise exception 'Nie znaleziono zapisu na szkolenie.'
      using errcode = 'P0002';
  end if;

  if target_event_id is null then
    raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
      using errcode = '55000';
  end if;

  select event_item.*
  into target_event
  from public.events as event_item
  where event_item.id = target_event_id
  for update;

  if not found then
    raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
      using errcode = '55000';
  end if;

  select registration.*
  into target_registration
  from public.event_registrations as registration
  where registration.id = p_registration_id
    and registration.event_id = target_event.id
  for update;

  if not found then
    raise exception 'Nie znaleziono zapisu na szkolenie.'
      using errcode = 'P0002';
  end if;

  if is_self_service_actor
     and target_registration.user_id is distinct from actor_user_id then
    raise exception 'Brak uprawnień do anulowania tego zapisu na szkolenie.'
      using errcode = '42501';
  end if;

  normalized_status := lower(btrim(target_registration.registration_status));

  if normalized_status = 'cancelled' then
    return jsonb_build_object(
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'changed', false,
      'previous_status', normalized_status,
      'new_status', normalized_status,
      'operator_role', actor_role,
      'freed_participant_place', false
    );
  end if;

  if coalesce(normalized_status, '') not in (
    'registered',
    'approved',
    'reserve',
    'participant'
  ) then
    raise exception 'Zapisu w tym statusie nie można anulować.'
      using errcode = '55000';
  end if;

  -- Status participant jest przejściowy. Jego semantyka i wpływ na limit miejsc
  -- wymagają późniejszego uporządkowania; obecnie anulowanie nie zwalnia miejsca.
  freed_participant_place := normalized_status in ('registered', 'approved');

  if is_self_service_actor then
    if target_event.event_date is null
       or target_event.start_time is null then
      raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
        using errcode = '55000';
    end if;

    event_start_at :=
      (target_event.event_date + target_event.start_time)
        at time zone 'Europe/Warsaw';

    if event_start_at is null then
      raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
        using errcode = '55000';
    end if;

    if event_start_at - transaction_timestamp() < interval '72 hours' then
      raise exception 'Zapis można anulować najpóźniej 72 godziny przed rozpoczęciem szkolenia.'
        using errcode = '55000';
    end if;
  end if;

  update public.event_registrations
  set registration_status = 'cancelled'
  where id = target_registration.id;

  if is_self_service_actor then
    actor_name := 'Użytkownik';
    audit_action := 'event_registration_cancelled_by_user';
  else
    actor_name := 'Obsługa';
    audit_action := 'event_registration_cancelled_by_staff';
  end if;

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
    actor_user_id,
    actor_name,
    actor_role,
    audit_action,
    'event_registration',
    target_registration.id,
    'Zapis na szkolenie',
    jsonb_build_object(
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'previous_status', normalized_status,
      'new_status', 'cancelled',
      'operator_role', actor_role,
      'freed_participant_place', freed_participant_place
    )
  );

  return jsonb_build_object(
    'registration_id', target_registration.id,
    'event_id', target_registration.event_id,
    'changed', true,
    'previous_status', normalized_status,
    'new_status', 'cancelled',
    'operator_role', actor_role,
    'freed_participant_place', freed_participant_place
  );
end;
$$;


ALTER FUNCTION "public"."cancel_event_registration"("p_registration_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cancel_event_registration"("p_registration_id" "uuid") IS 'Kontrolowanie anuluje zapis na szkolenie i zwraca flagę informującą, czy zwolniono miejsce uczestnika.';



CREATE OR REPLACE FUNCTION "public"."cancel_reservation"("p_reservation_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_reservation public.reservations%rowtype;
  actor_role text;
  actor_name text;
  current_status text;
  result_status text;
  cancelled_by_value text;
  audit_action text;
  reservation_start_at timestamptz;
  cancellation_window_hours_raw numeric;
  cancellation_window_hours_rounded numeric;
  within_client_cancellation_window boolean;
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.' using errcode = '42501';
  end if;
  if p_reservation_id is null then
    raise exception 'Brak identyfikatora rezerwacji.' using errcode = '22023';
  end if;

  select profile.* into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;
  if not found then
    raise exception 'Brak profilu operatora.' using errcode = '42501';
  end if;

  actor_role := pg_catalog.lower(pg_catalog.btrim(actor_profile.role::text));
  if coalesce(actor_role, '') not in ('user', 'admin', 'pracownik') then
    raise exception 'Brak uprawnień do anulowania rezerwacji.' using errcode = '42501';
  end if;

  select reservation.* into target_reservation
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;
  if not found then
    raise exception 'Nie znaleziono rezerwacji.' using errcode = 'P0002';
  end if;

  if actor_role = 'user'
     and target_reservation.user_id is distinct from actor_user_id then
    raise exception 'Brak uprawnień do anulowania tej rezerwacji.' using errcode = '42501';
  end if;

  current_status := pg_catalog.lower(pg_catalog.btrim(target_reservation.reservation_status));
  reservation_start_at :=
    (target_reservation.reservation_date + target_reservation.start_time)
      at time zone 'Europe/Warsaw';
  cancellation_window_hours_raw := extract(
    epoch from (reservation_start_at - pg_catalog.transaction_timestamp())
  ) / 3600.0;
  cancellation_window_hours_rounded := pg_catalog.round(cancellation_window_hours_raw, 2);
  within_client_cancellation_window := cancellation_window_hours_raw >= 12;

  if current_status in (
    'cancelled', 'canceled', 'cancelled_by_user', 'cancelled_by_admin'
  ) then
    cancelled_by_value := case current_status
      when 'cancelled_by_user' then 'user'
      when 'cancelled_by_admin' then 'staff'
      else null
    end;
    return pg_catalog.jsonb_build_object(
      'reservation_id', target_reservation.id, 'changed', false,
      'previous_status', target_reservation.reservation_status,
      'new_status', target_reservation.reservation_status,
      'cancelled_by', cancelled_by_value, 'operator_role', actor_role,
      'cancellation_window_hours', cancellation_window_hours_rounded,
      'within_client_cancellation_window', within_client_cancellation_window
    );
  end if;

  if current_status is distinct from 'confirmed' then
    raise exception 'Rezerwacji w tym statusie nie można anulować.' using errcode = '55000';
  end if;
  if coalesce(target_reservation.attendance_status, 'planned') <> 'planned'
     or target_reservation.checked_in_at is not null
     or target_reservation.completed_at is not null then
    raise exception 'Rozpoczętej wizyty nie można anulować.' using errcode = '55000';
  end if;
  if actor_role = 'user' and not within_client_cancellation_window then
    raise exception 'Rezerwację można anulować najpóźniej 12 godzin przed rozpoczęciem.' using errcode = '55000';
  end if;

  if actor_role = 'user' then
    result_status := 'cancelled_by_user';
    cancelled_by_value := 'user';
    audit_action := 'reservation_cancelled_by_user';
  else
    result_status := 'cancelled_by_admin';
    cancelled_by_value := 'staff';
    audit_action := 'reservation_cancelled_by_staff';
  end if;

  update public.reservations as reservation
  set reservation_status = result_status
  where reservation.id = p_reservation_id
  returning reservation.reservation_status into result_status;

  actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(actor_profile.full_name), ''),
    nullif(pg_catalog.btrim(actor_profile.email), ''),
    'Nieznany użytkownik'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    actor_user_id, actor_name, actor_role, audit_action,
    'reservation', target_reservation.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'previous_status', target_reservation.reservation_status,
      'new_status', result_status, 'operator_role', actor_role,
      'cancellation_window_hours', cancellation_window_hours_rounded,
      'within_client_cancellation_window', within_client_cancellation_window
    )
  );

  return pg_catalog.jsonb_build_object(
    'reservation_id', target_reservation.id, 'changed', true,
    'previous_status', target_reservation.reservation_status,
    'new_status', result_status, 'cancelled_by', cancelled_by_value,
    'operator_role', actor_role,
    'cancellation_window_hours', cancellation_window_hours_rounded,
    'within_client_cancellation_window', within_client_cancellation_window
  );
end;
$$;


ALTER FUNCTION "public"."cancel_reservation"("p_reservation_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cancel_reservation"("p_reservation_id" "uuid") IS 'Atomowo anuluje nierozpoczętą rezerwację z kontrolą sesji, roli, własności, statusu i limitu czasu oraz zapisuje audit log.';



CREATE OR REPLACE FUNCTION "public"."check_confirmation_email_rate_limit"("p_user_id" "uuid", "p_ip_hash" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_window_start timestamptz := v_now - interval '10 minutes';
  v_user_key text;
  v_ip_hash text := pg_catalog.lower(pg_catalog.btrim(p_ip_hash));
  v_user_timestamps timestamptz[];
  v_ip_timestamps timestamptz[];
  v_user_retry integer := 0;
  v_ip_retry integer := 0;
  v_retry_after integer;
begin
  if p_user_id is null
     or v_ip_hash is null
     or v_ip_hash !~ '^[0-9a-f]{64}$' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'invalid_input',
      'allowed', false
    );
  end if;

  v_user_key := p_user_id::text;

  insert into public.confirmation_email_rate_limits (
    scope_type,
    scope_key
  )
  values ('ip', v_ip_hash)
  on conflict (scope_type, scope_key) do nothing;

  insert into public.confirmation_email_rate_limits (
    scope_type,
    scope_key
  )
  values ('user', v_user_key)
  on conflict (scope_type, scope_key) do nothing;

  perform 1
  from public.confirmation_email_rate_limits as rate_limit
  where (rate_limit.scope_type, rate_limit.scope_key) in (
    ('ip', v_ip_hash),
    ('user', v_user_key)
  )
  order by rate_limit.scope_type, rate_limit.scope_key
  for update;

  select
    rate_limit.request_timestamps
  into v_user_timestamps
  from public.confirmation_email_rate_limits as rate_limit
  where rate_limit.scope_type = 'user'
    and rate_limit.scope_key = v_user_key;

  select
    rate_limit.request_timestamps
  into v_ip_timestamps
  from public.confirmation_email_rate_limits as rate_limit
  where rate_limit.scope_type = 'ip'
    and rate_limit.scope_key = v_ip_hash;

  v_user_timestamps := array(
    select timestamp_value
    from pg_catalog.unnest(
      coalesce(
        v_user_timestamps,
        '{}'::timestamptz[]
      )
    ) as timestamp_record(timestamp_value)
    where timestamp_value > v_window_start
    order by timestamp_value
  );

  v_ip_timestamps := array(
    select timestamp_value
    from pg_catalog.unnest(
      coalesce(
        v_ip_timestamps,
        '{}'::timestamptz[]
      )
    ) as timestamp_record(timestamp_value)
    where timestamp_value > v_window_start
    order by timestamp_value
  );

  update public.confirmation_email_rate_limits as rate_limit
  set
    request_timestamps = case rate_limit.scope_type
      when 'user' then v_user_timestamps
      else v_ip_timestamps
    end,
    updated_at = v_now
  where (rate_limit.scope_type, rate_limit.scope_key) in (
    ('ip', v_ip_hash),
    ('user', v_user_key)
  );

  if pg_catalog.cardinality(v_user_timestamps) >= 10 then
    v_user_retry := pg_catalog.ceil(
      extract(
        epoch from (
          v_user_timestamps[
            pg_catalog.cardinality(v_user_timestamps) - 10 + 1
          ] + interval '10 minutes' - v_now
        )
      )
    )::integer;
  end if;

  if pg_catalog.cardinality(v_ip_timestamps) >= 30 then
    v_ip_retry := pg_catalog.ceil(
      extract(
        epoch from (
          v_ip_timestamps[
            pg_catalog.cardinality(v_ip_timestamps) - 30 + 1
          ] + interval '10 minutes' - v_now
        )
      )
    )::integer;
  end if;

  if v_user_retry > 0 or v_ip_retry > 0 then
    v_retry_after := least(
      600,
      greatest(1, v_user_retry, v_ip_retry)
    );

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'code', 'rate_limited',
      'allowed', false,
      'retry_after_seconds', v_retry_after
    );
  end if;

  update public.confirmation_email_rate_limits as rate_limit
  set
    request_timestamps = case rate_limit.scope_type
      when 'user' then
        pg_catalog.array_append(v_user_timestamps, v_now)
      else
        pg_catalog.array_append(v_ip_timestamps, v_now)
    end,
    updated_at = v_now
  where (rate_limit.scope_type, rate_limit.scope_key) in (
    ('ip', v_ip_hash),
    ('user', v_user_key)
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'code', 'allowed',
    'allowed', true
  );
end;
$_$;


ALTER FUNCTION "public"."check_confirmation_email_rate_limit"("p_user_id" "uuid", "p_ip_hash" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."check_confirmation_email_rate_limit"("p_user_id" "uuid", "p_ip_hash" "text") IS 'Atomically enforces 10 user and 30 HMAC IP requests per sliding 10-minute window.';



CREATE OR REPLACE FUNCTION "public"."complete_confirmation_email"("p_claim_id" "uuid", "p_success" boolean, "p_provider_message_id" "text" DEFAULT NULL::"text", "p_error_code" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_delivery public.email_deliveries%rowtype;
  v_provider_message_id text;
  v_error_code text;
begin
  if p_claim_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'claim_not_found'
    );
  end if;

  select delivery.*
  into v_delivery
  from public.email_deliveries as delivery
  where delivery.claim_id = p_claim_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'claim_not_found'
    );
  end if;

  if v_delivery.sent_at is not null then
    update public.email_deliveries as delivery
    set
      claim_id = null,
      claim_expires_at = null,
      updated_at = v_now
    where delivery.id = v_delivery.id;

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'sent'
    );
  end if;

  if p_success is true then
    v_provider_message_id := nullif(
      pg_catalog.left(pg_catalog.btrim(p_provider_message_id), 256),
      ''
    );

    update public.email_deliveries as delivery
    set
      sent_at = coalesce(delivery.sent_at, v_now),
      provider_message_id = coalesce(
        delivery.provider_message_id,
        v_provider_message_id
      ),
      claim_id = null,
      claim_expires_at = null,
      last_error_code = null,
      updated_at = v_now
    where delivery.id = v_delivery.id;

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', true,
      'code', 'sent'
    );
  end if;

  v_error_code := pg_catalog.lower(pg_catalog.btrim(p_error_code));
  v_error_code := pg_catalog.regexp_replace(
    coalesce(v_error_code, 'delivery_failed'),
    '[^a-z0-9_.:-]+',
    '_',
    'g'
  );
  v_error_code := pg_catalog.left(
    coalesce(nullif(v_error_code, ''), 'delivery_failed'),
    128
  );

  update public.email_deliveries as delivery
  set
    claim_id = null,
    claim_expires_at = null,
    last_error_code = v_error_code,
    updated_at = v_now
  where delivery.id = v_delivery.id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'failed'
  );
end;
$$;


ALTER FUNCTION "public"."complete_confirmation_email"("p_claim_id" "uuid", "p_success" boolean, "p_provider_message_id" "text", "p_error_code" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."complete_confirmation_email"("p_claim_id" "uuid", "p_success" boolean, "p_provider_message_id" "text", "p_error_code" "text") IS 'Completes only the current opaque confirmation-email claim and stores bounded technical delivery state.';



CREATE OR REPLACE FUNCTION "public"."complete_event_reserve_promotion"("p_registration_id" "uuid", "p_claim_id" "uuid", "p_success" boolean, "p_error_code" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare
  v_registration public.event_registrations%rowtype;
  v_error_code text;
begin
  if p_registration_id is null or p_claim_id is null then
    raise exception using
      errcode = '22023',
      message = 'Identyfikator zapisu i claimu są wymagane.';
  end if;

  if p_success is null then
    raise exception using
      errcode = '22023',
      message = 'Wynik wysyłki jest wymagany.';
  end if;

  if not p_success then
    v_error_code := lower(btrim(coalesce(p_error_code, '')));

    if v_error_code = '' then
      v_error_code := 'delivery_failed';
    end if;

    if char_length(v_error_code) > 100
       or v_error_code !~ '^[a-z][a-z0-9_]{0,99}$' then
      raise exception using
        errcode = '22023',
        message = 'Nieprawidłowy techniczny kod błędu.';
    end if;
  end if;

  select registration.*
  into v_registration
  from public.event_registrations as registration
  where registration.id = p_registration_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Nie znaleziono zapisu na szkolenie.';
  end if;

  if v_registration.promotion_claim_id is null then
    if p_success and v_registration.promotion_email_sent_at is not null then
      return pg_catalog.jsonb_build_object(
        'registration_id', v_registration.id,
        'changed', false,
        'success', true,
        'claim_cleared', true,
        'email_sent_recorded', true
      );
    end if;

    if not p_success then
      return pg_catalog.jsonb_build_object(
        'registration_id', v_registration.id,
        'changed', false,
        'success', false,
        'claim_cleared', true,
        'email_sent_recorded', v_registration.promotion_email_sent_at is not null
      );
    end if;

    raise exception using
      errcode = '55000',
      message = 'Claim promocji nie jest aktywny.';
  end if;

  if v_registration.promotion_claim_id <> p_claim_id then
    raise exception using
      errcode = '55000',
      message = 'Claim promocji należy do innego procesu.';
  end if;

  if p_success then
    update public.event_registrations as registration
    set
      promotion_email_sent_at = coalesce(
        registration.promotion_email_sent_at,
        pg_catalog.transaction_timestamp()
      ),
      promotion_claim_id = null,
      promotion_claim_expires_at = null,
      promotion_last_error_code = null
    where registration.id = v_registration.id;

    return pg_catalog.jsonb_build_object(
      'registration_id', v_registration.id,
      'changed', true,
      'success', true,
      'claim_cleared', true,
      'email_sent_recorded', true
    );
  end if;

  update public.event_registrations as registration
  set
    promotion_claim_id = null,
    promotion_claim_expires_at = null,
    promotion_last_error_code = v_error_code
  where registration.id = v_registration.id;

  return pg_catalog.jsonb_build_object(
    'registration_id', v_registration.id,
    'changed', true,
    'success', false,
    'claim_cleared', true,
    'email_sent_recorded', v_registration.promotion_email_sent_at is not null
  );
end;
$_$;


ALTER FUNCTION "public"."complete_event_reserve_promotion"("p_registration_id" "uuid", "p_claim_id" "uuid", "p_success" boolean, "p_error_code" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."complete_event_reserve_promotion"("p_registration_id" "uuid", "p_claim_id" "uuid", "p_success" boolean, "p_error_code" "text") IS 'Finalizuje zgodny claim promocji po technicznej próbie wysyłki wiadomości.';



CREATE OR REPLACE FUNCTION "public"."confirm_event_reserve_promotion"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_event_id uuid;
  v_registration public.event_registrations%rowtype;
  v_event public.events%rowtype;
  v_participants_count integer;
begin
  select registration.event_id
  into v_event_id
  from public.event_registrations as registration
  where registration.promotion_token = p_token;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', 'Link jest nieprawidłowy albo nie istnieje.'
    );
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = v_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'event_not_found',
      'message', 'Nie znaleziono szkolenia.'
    );
  end if;

  select registration.*
  into v_registration
  from public.event_registrations as registration
  where registration.promotion_token = p_token
    and registration.event_id = v_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', 'Link jest nieprawidłowy albo nie istnieje.'
    );
  end if;

  if v_registration.registration_status <> 'reserve' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'not_reserve',
      'message', 'Ten zapis nie znajduje się już na liście rezerwowej.'
    );
  end if;

  if v_registration.promotion_token_expires_at is null
     or v_registration.promotion_token_expires_at
       < pg_catalog.transaction_timestamp() then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'expired',
      'message', 'Link do potwierdzenia miejsca wygasł.'
    );
  end if;

  select count(*)
  into v_participants_count
  from public.event_registrations as registration
  where registration.event_id = v_registration.event_id
    and registration.registration_status in ('registered', 'approved');

  if v_participants_count >= coalesce(v_event.max_participants, 0) then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'full',
      'message', 'Miejsce zostało już zajęte przez inną osobę.'
    );
  end if;

  update public.event_registrations as registration
  set
    registration_status = 'registered',
    promotion_confirmed_at = pg_catalog.transaction_timestamp(),
    promotion_claim_id = null,
    promotion_claim_expires_at = null,
    promotion_last_error_code = null
  where registration.id = v_registration.id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'code', 'confirmed',
    'message', 'Twoje miejsce zostało potwierdzone.',
    'event_id', v_registration.event_id,
    'registration_id', v_registration.id
  );
end;
$$;


ALTER FUNCTION "public"."confirm_event_reserve_promotion"("p_token" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."confirm_event_reserve_promotion"("p_token" "text") IS 'Potwierdza aktywny token promocji z blokadami w kolejności wydarzenie, następnie rejestracja.';



CREATE OR REPLACE FUNCTION "public"."create_reservation"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."create_reservation"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_reservation"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") IS 'Atomowo tworzy własną rezerwację z kontrolą blokad, eventów i nakładania terminów.';



CREATE OR REPLACE FUNCTION "public"."create_reservation_v2"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
declare
  v_user_id uuid := auth.uid();
  v_lane public.shooting_lanes%rowtype;
  v_parent public.shooting_lanes%rowtype;
  v_profile public.profiles%rowtype;
  v_existing public.reservations%rowtype;
  v_created public.reservations%rowtype;
  v_pricing_rule public.lane_pricing_rules%rowtype;
  v_booking_rule public.lane_booking_rules%rowtype;
  v_scope record;
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

  if v_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'unauthorized'
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
              pg_catalog.btrim(coalesce(v_existing.reservation_note, '')),
              '[[:space:]]+',
              ' ',
              'g'
            ),
            ''
          ) is distinct from v_note then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'idempotency_conflict'
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

  v_role := pg_catalog.lower(pg_catalog.btrim(coalesce(v_profile.role::text, '')));

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
    pg_catalog.btrim(coalesce(v_profile.verification_status::text, 'pending'))
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
         and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
           not in (
             'completed', 'no_show', 'cancelled', 'canceled',
             'cancelled_by_admin', 'cancelled_by_user'
           )
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'verification_limit_reached'
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_not_found'
    );
  end if;

  if not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_inactive'
    );
  end if;

  if v_lane.resource_kind = 'position' then
    if v_lane.parent_lane_id is null or v_lane.parent_lane_id = v_lane.id then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'internal_error'
      );
    end if;

    select parent.*
    into v_parent
    from public.shooting_lanes as parent
    where parent.id = v_lane.parent_lane_id;

    if not found then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'internal_error'
      );
    end if;

    if not v_parent.is_active then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'lane_inactive'
      );
    end if;
  elsif v_lane.resource_kind is distinct from 'lane'
        or v_lane.parent_lane_id is not null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error'
    );
  end if;

  begin
    select helper.*
    into strict v_scope
    from public.lock_lane_conflict_family_v1(p_lane_id) as helper;
  exception
    when no_data_found then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'internal_error'
      );
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'lane_not_found'
      );
    when sqlstate 'P1001' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'lane_inactive'
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'internal_error'
      );
  end;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if v_scope.requested_resource_kind = 'position' then
    select parent.*
    into v_parent
    from public.shooting_lanes as parent
    where parent.id = v_scope.root_lane_id;
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

  select booking_rule.*
  into v_booking_rule
  from public.lane_booking_rules as booking_rule
  where booking_rule.lane_id = p_lane_id;

  if not found or not v_booking_rule.online_bookable then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_not_bookable'
    );
  end if;

  if (
       v_scope.requested_resource_kind = 'lane'
       and (
         v_lane.parent_lane_id is not null
         or not v_lane.whole_lane_bookable
       )
     )
     or (
       v_scope.requested_resource_kind = 'position'
       and (
         v_lane.parent_lane_id is distinct from v_scope.root_lane_id
         or v_parent.resource_kind is distinct from 'lane'
         or v_parent.parent_lane_id is not null
         or not v_parent.positions_bookable
       )
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'lane_not_bookable'
    );
  end if;

  if p_shooters_count > v_lane.max_shooters then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'capacity_exceeded'
    );
  end if;

  if v_booking_rule.max_people_online < 1
     or v_booking_rule.max_people_online > v_lane.max_shooters then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error'
    );
  end if;

  if p_shooters_count > v_booking_rule.max_people_online then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'contact_required'
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
      'ok', false, 'changed', false, 'code', 'reservation_already_started'
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
    from public.reservations as reservation
    where reservation.lane_id = any(v_scope.conflict_lane_ids)
      and reservation.reservation_date = p_reservation_date
      and reservation.start_time < v_end_time
      and reservation.end_time > p_start_time
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'slot_unavailable'
    );
  end if;

  if exists (
    select 1
    from public.lane_blocks as lane_block
    where lane_block.lane_id = any(v_scope.conflict_lane_ids)
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
    where event_lane.lane_id = any(v_scope.conflict_lane_ids)
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
      user_id, lane_id, customer_name, customer_email, customer_phone,
      reservation_date, start_time, end_time, duration_minutes, price,
      reservation_status, payment_status, attendance_status,
      reservation_note, shooters_count, pricing_rule_id,
      pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
      price_per_hour_snapshot, total_price, currency_code, creation_request_id
    ) values (
      v_user_id, p_lane_id, v_customer_name, v_customer_email, v_customer_phone,
      p_reservation_date, p_start_time, v_end_time, p_duration_minutes,
      v_total_price, 'confirmed', 'pay_on_site', 'planned', v_note,
      p_shooters_count, v_pricing_rule.id, v_pricing_day_group,
      pg_catalog.btrim(v_lane.name), pg_catalog.btrim(v_pricing_rule.label),
      v_pricing_rule.hourly_price, v_total_price, v_lane.currency_code,
      p_creation_request_id
    )
    returning * into v_created;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;
      if v_constraint_name = 'reservations_no_overlapping_active_booking' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'slot_unavailable'
        );
      end if;
      raise;
  end;

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_user_id, v_customer_name, 'user', 'reservation_created',
    'reservation', v_created.id, 'Rezerwacja',
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
$_$;


ALTER FUNCTION "public"."create_reservation_v2"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_reservation_v2"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") IS 'Dormant hierarchy-aware atomic reservation writer using the shared lane-family lock protocol.';



CREATE OR REPLACE FUNCTION "public"."get_lane_booking_busy_ranges"("p_lane_id" "uuid", "p_reservation_date" "date") RETURNS TABLE("start_time" time without time zone, "end_time" time without time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  select busy_range.start_time, busy_range.end_time
  from (
    select reservation.start_time, reservation.end_time
    from public.reservations as reservation
    join public.shooting_lanes as lane
      on lane.id = reservation.lane_id
     and lane.is_active is true
    where reservation.lane_id = p_lane_id
      and reservation.reservation_date = p_reservation_date
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'cancelled',
          'canceled',
          'cancelled_by_user',
          'cancelled_by_admin',
          'completed',
          'no_show'
        )

    union all

    select block.start_time, block.end_time
    from public.lane_blocks as block
    join public.shooting_lanes as lane
      on lane.id = block.lane_id
     and lane.is_active is true
    where block.lane_id = p_lane_id
      and block.block_date = p_reservation_date
      and block.is_active is true

    union all

    select event_record.start_time, event_record.end_time
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    join public.shooting_lanes as lane
      on lane.id = event_lane.lane_id
     and lane.is_active is true
    where event_lane.lane_id = p_lane_id
      and event_record.event_date = p_reservation_date
      and event_record.is_active is true
  ) as busy_range
  order by busy_range.start_time, busy_range.end_time;
$$;


ALTER FUNCTION "public"."get_lane_booking_busy_ranges"("p_lane_id" "uuid", "p_reservation_date" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_lane_booking_busy_ranges"("p_lane_id" "uuid", "p_reservation_date" "date") IS 'Zwraca bez danych klienta zajęte przedziały aktywnej osi do informacyjnego podglądu dostępności.';



CREATE OR REPLACE FUNCTION "public"."get_lane_booking_busy_ranges_v2"("p_lane_id" "uuid", "p_reservation_date" "date") RETURNS TABLE("start_time" time without time zone, "end_time" time without time zone, "busy_type" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  select
    busy_range.start_time,
    busy_range.end_time,
    busy_range.busy_type
  from (
    select
      reservation.start_time,
      reservation.end_time,
      'reservation'::text as busy_type
    from public.reservations as reservation
    join public.shooting_lanes as lane
      on lane.id = reservation.lane_id
     and lane.is_active is true
    where reservation.lane_id = p_lane_id
      and reservation.reservation_date = p_reservation_date
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'cancelled',
          'canceled',
          'cancelled_by_user',
          'cancelled_by_admin',
          'completed',
          'no_show'
        )

    union all

    select
      block.start_time,
      block.end_time,
      'lane_block'::text as busy_type
    from public.lane_blocks as block
    join public.shooting_lanes as lane
      on lane.id = block.lane_id
     and lane.is_active is true
    where block.lane_id = p_lane_id
      and block.block_date = p_reservation_date
      and block.is_active is true

    union all

    select
      event_record.start_time,
      event_record.end_time,
      'event'::text as busy_type
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    join public.shooting_lanes as lane
      on lane.id = event_lane.lane_id
     and lane.is_active is true
    where event_lane.lane_id = p_lane_id
      and event_record.event_date = p_reservation_date
      and event_record.is_active is true
  ) as busy_range
  order by
    busy_range.start_time,
    busy_range.end_time,
    busy_range.busy_type;
$$;


ALTER FUNCTION "public"."get_lane_booking_busy_ranges_v2"("p_lane_id" "uuid", "p_reservation_date" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_lane_booking_busy_ranges_v2"("p_lane_id" "uuid", "p_reservation_date" "date") IS 'Returns typed busy ranges for an active lane without identifiers or personal data.';



CREATE OR REPLACE FUNCTION "public"."get_lane_booking_busy_ranges_v3"("p_lane_id" "uuid", "p_reservation_date" "date") RETURNS TABLE("start_time" time without time zone, "end_time" time without time zone, "busy_type" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_conflict_lane_ids uuid[];
begin
  if p_reservation_date is null then
    raise exception 'Reservation date is required.' using errcode = '22023';
  end if;

  -- This standalone statement is intentionally executed before RETURN QUERY.
  -- It makes resolver validation unconditional even when all busy tables are
  -- empty and a later query plan could otherwise skip the scope CTE.
  select pg_catalog.array_agg(
    scope_record.conflict_lane_id
    order by scope_record.conflict_lane_id
  )
  into v_conflict_lane_ids
  from public.resolve_lane_conflict_scope_v1(p_lane_id) as scope_record;

  if v_conflict_lane_ids is null
     or pg_catalog.cardinality(v_conflict_lane_ids) = 0 then
    raise exception 'Shooting-lane conflict scope is empty.' using errcode = '55000';
  end if;

  return query
  with busy_ranges as (
    select
      reservation.start_time,
      reservation.end_time,
      'reservation'::text as busy_type
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = p_reservation_date
      and reservation.booking_period && pg_catalog.tsrange(
        p_reservation_date::timestamp without time zone,
        (p_reservation_date + 1)::timestamp without time zone,
        '[)'
      )
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed',
          'no_show',
          'cancelled',
          'canceled',
          'cancelled_by_admin',
          'cancelled_by_user'
        )

    union all

    select
      block.start_time,
      block.end_time,
      'lane_block'::text as busy_type
    from public.lane_blocks as block
    where block.lane_id = any(v_conflict_lane_ids)
      and block.block_date = p_reservation_date
      and block.is_active is true

    union all

    select
      event_record.start_time,
      event_record.end_time,
      'event'::text as busy_type
    from public.events as event_record
    where event_record.event_date = p_reservation_date
      and event_record.is_active is true
      and exists (
        select 1
        from public.event_lanes as event_lane
        where event_lane.event_id = event_record.id
          and event_lane.lane_id = any(v_conflict_lane_ids)
      )
  )
  select
    busy_range.start_time,
    busy_range.end_time,
    busy_range.busy_type
  from busy_ranges as busy_range
  order by
    busy_range.start_time,
    busy_range.end_time,
    busy_range.busy_type;
end;
$$;


ALTER FUNCTION "public"."get_lane_booking_busy_ranges_v3"("p_lane_id" "uuid", "p_reservation_date" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_lane_booking_busy_ranges_v3"("p_lane_id" "uuid", "p_reservation_date" "date") IS 'Returns hierarchy-aware typed busy ranges without identifiers or personal data.';



CREATE OR REPLACE FUNCTION "public"."get_my_reservations_v2"() RETURNS TABLE("id" "uuid", "reservation_date" "date", "start_time" time without time zone, "end_time" time without time zone, "price" numeric, "reservation_status" "text", "payment_status" "text", "check_in_token" "uuid", "attendance_status" "text", "checked_in_at" timestamp with time zone, "lane_display_name" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  return query
  select
    reservation.id,
    reservation.reservation_date,
    reservation.start_time,
    reservation.end_time,
    reservation.price,
    reservation.reservation_status,
    reservation.payment_status,
    reservation.check_in_token,
    reservation.attendance_status,
    reservation.checked_in_at,
    case
      when lane.resource_kind = 'lane'
       and lane.parent_lane_id is null
       and pg_catalog.btrim(lane.name) <> ''
        then lane.name
      when lane.resource_kind = 'position'
       and lane.parent_lane_id is not null
       and parent.id = lane.parent_lane_id
       and parent.resource_kind = 'lane'
       and parent.parent_lane_id is null
       and pg_catalog.btrim(parent.name) <> ''
       and pg_catalog.btrim(lane.name) <> ''
        then parent.name || ' — ' || lane.name
      else null
    end as lane_display_name
  from public.reservations as reservation
  left join public.shooting_lanes as lane
    on lane.id = reservation.lane_id
  left join public.shooting_lanes as parent
    on parent.id = lane.parent_lane_id
  where reservation.user_id = v_user_id
  order by reservation.reservation_date desc,
           reservation.start_time desc,
           reservation.id desc;
end;
$$;


ALTER FUNCTION "public"."get_my_reservations_v2"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_my_reservations_v2"() IS 'Returns only auth.uid() reservations with an ownership-scoped hierarchy label, including inactive resources.';



CREATE OR REPLACE FUNCTION "public"."get_my_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select role::text
  from public.profiles
  where user_id = auth.uid()
  limit 1;
$$;


ALTER FUNCTION "public"."get_my_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_public_booking_configuration_v1"() RETURNS TABLE("lane_id" "uuid", "parent_lane_id" "uuid", "resource_kind" "text", "name" "text", "display_name" "text", "display_order" integer, "effective_online_bookable" boolean, "whole_lane_bookable" boolean, "positions_bookable" boolean, "max_people_online" integer, "booking_step_minutes" integer, "currency_code" "text", "durations_minutes" integer[], "pricing" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  with resource_configuration as (
    select
      resource.id,
      resource.parent_lane_id,
      resource.resource_kind,
      resource.name,
      resource.display_order,
      resource.is_active,
      resource.whole_lane_bookable as raw_whole_lane_bookable,
      resource.positions_bookable as raw_positions_bookable,
      resource.booking_step_minutes,
      resource.currency_code::text as currency_code,
      booking_rule.online_bookable,
      booking_rule.max_people_online,
      parent.id as parent_id,
      parent.name as parent_name,
      parent.display_order as parent_display_order,
      parent.resource_kind as parent_resource_kind,
      parent.parent_lane_id as parent_parent_lane_id,
      parent.is_active as parent_is_active,
      parent.positions_bookable as parent_positions_bookable,
      coalesce(duration_configuration.durations_minutes, array[]::integer[])
        as durations_minutes,
      coalesce(pricing_configuration.pricing, '[]'::jsonb) as pricing,
      coalesce(duration_configuration.duration_valid, false) as duration_valid,
      coalesce(pricing_configuration.pricing_valid, false) as pricing_valid
    from public.shooting_lanes as resource
    left join public.lane_booking_rules as booking_rule
      on booking_rule.lane_id = resource.id
    left join public.shooting_lanes as parent
      on parent.id = resource.parent_lane_id
    left join lateral (
      select
        pg_catalog.array_agg(
          distinct duration.duration_minutes
          order by duration.duration_minutes
        ) filter (
          where duration.is_active
            and duration.duration_minutes is not null
            and duration.duration_minutes > 0
        ) as durations_minutes,
        pg_catalog.count(*) filter (where duration.is_active) > 0
          and pg_catalog.count(*) filter (
            where duration.is_active
              and duration.duration_minutes is not null
              and duration.duration_minutes > 0
          ) = pg_catalog.count(*) filter (where duration.is_active)
          as duration_valid
      from public.lane_booking_durations as duration
      where duration.lane_id = resource.id
    ) as duration_configuration on true
    left join lateral (
      with active_pricing_rules as (
        select
          pricing_rule.id,
          pricing_rule.day_group,
          pricing_rule.min_shooters,
          pricing_rule.max_shooters,
          pricing_rule.hourly_price,
          pricing_rule.label,
          pricing_rule.display_order
        from public.lane_pricing_rules as pricing_rule
        where pricing_rule.lane_id = resource.id
          and pricing_rule.is_active
      ),
      ordered_pricing_rules as (
        select
          pricing_rule.*,
          pg_catalog.row_number() over (
            partition by pricing_rule.day_group
            order by pricing_rule.min_shooters,
                     pricing_rule.max_shooters,
                     pricing_rule.display_order,
                     pricing_rule.id
          ) as rule_order,
          pg_catalog.lag(pricing_rule.max_shooters) over (
            partition by pricing_rule.day_group
            order by pricing_rule.min_shooters,
                     pricing_rule.max_shooters,
                     pricing_rule.display_order,
                     pricing_rule.id
          ) as previous_max_shooters
        from active_pricing_rules as pricing_rule
      ),
      coverage_by_day_group as (
        select
          pricing_rule.day_group,
          pg_catalog.count(*) > 0
            and pg_catalog.bool_and(
              pricing_rule.min_shooters <= pricing_rule.max_shooters
              and (
                (
                  pricing_rule.rule_order = 1
                  and pricing_rule.min_shooters = 1
                )
                or (
                  pricing_rule.rule_order > 1
                  and pricing_rule.min_shooters
                    = pricing_rule.previous_max_shooters + 1
                )
              )
            )
            and pg_catalog.max(pricing_rule.max_shooters)
              = booking_rule.max_people_online
            as coverage_valid
        from ordered_pricing_rules as pricing_rule
        where pricing_rule.day_group in ('mon_thu', 'fri_sun')
        group by pricing_rule.day_group
      )
      select
        (
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'day_group', pricing_rule.day_group,
              'min_shooters', pricing_rule.min_shooters,
              'max_shooters', pricing_rule.max_shooters,
              'hourly_price', pricing_rule.hourly_price,
              'label', pricing_rule.label
            )
            order by pricing_rule.day_group,
                     pricing_rule.min_shooters,
                     pricing_rule.max_shooters,
                     pricing_rule.display_order,
                     pricing_rule.id
          )
          from active_pricing_rules as pricing_rule
        ) as pricing,
        booking_rule.lane_id is not null
          and booking_rule.max_people_online >= 1
          and not exists (
            select 1
            from public.lane_pricing_rules as invalid_rule
            where invalid_rule.lane_id = resource.id
              and invalid_rule.is_active
              and (
                invalid_rule.day_group not in ('mon_thu', 'fri_sun')
                or invalid_rule.min_shooters < 1
                or invalid_rule.max_shooters < invalid_rule.min_shooters
                or invalid_rule.max_shooters > booking_rule.max_people_online
                or invalid_rule.hourly_price::text in ('NaN', 'Infinity', '-Infinity')
              )
          )
          and not exists (
            select 1
            from (
              values ('mon_thu'::text), ('fri_sun'::text)
            ) as expected_day_group(day_group)
            left join coverage_by_day_group as coverage
              on coverage.day_group = expected_day_group.day_group
            where coverage.day_group is null
              or not coverage.coverage_valid
          ) as pricing_valid
    ) as pricing_configuration on true
  ),
  valid_positions as (
    select configuration.*
    from resource_configuration as configuration
    where configuration.resource_kind = 'position'
      and configuration.parent_lane_id is not null
      and configuration.parent_id = configuration.parent_lane_id
      and configuration.parent_resource_kind = 'lane'
      and configuration.parent_parent_lane_id is null
      and configuration.parent_is_active
      and configuration.parent_positions_bookable
      and configuration.is_active
      and not configuration.raw_whole_lane_bookable
      and not configuration.raw_positions_bookable
      and configuration.online_bookable
      and configuration.duration_valid
      and configuration.pricing_valid
  ),
  lane_modes as (
    select
      configuration.*,
      coalesce((
        configuration.resource_kind = 'lane'
        and configuration.parent_lane_id is null
        and configuration.is_active
        and configuration.raw_whole_lane_bookable
        and configuration.online_bookable
        and configuration.duration_valid
        and configuration.pricing_valid
      ), false) as whole_mode_available,
      exists (
        select 1
        from valid_positions as child
        where child.parent_lane_id = configuration.id
      ) as position_mode_available
    from resource_configuration as configuration
    where configuration.resource_kind = 'lane'
      and configuration.parent_lane_id is null
  ),
  public_resources as (
    select
      lane.id as lane_id,
      null::uuid as parent_lane_id,
      lane.resource_kind,
      lane.name,
      lane.name as display_name,
      lane.display_order,
      lane.whole_mode_available as effective_online_bookable,
      lane.whole_mode_available as whole_lane_bookable,
      lane.position_mode_available as positions_bookable,
      case when lane.whole_mode_available then lane.max_people_online end
        as max_people_online,
      lane.booking_step_minutes,
      lane.currency_code,
      case when lane.whole_mode_available
        then lane.durations_minutes else array[]::integer[] end
        as durations_minutes,
      case when lane.whole_mode_available
        then lane.pricing else '[]'::jsonb end as pricing,
      lane.display_order as hierarchy_display_order,
      0 as hierarchy_kind_order
    from lane_modes as lane
    where lane.whole_mode_available or lane.position_mode_available

    union all

    select
      position.id,
      position.parent_lane_id,
      position.resource_kind,
      position.name,
      position.parent_name || ' — ' || position.name,
      position.display_order,
      true,
      false,
      false,
      position.max_people_online,
      position.booking_step_minutes,
      position.currency_code,
      position.durations_minutes,
      position.pricing,
      position.parent_display_order,
      1
    from valid_positions as position
  )
  select
    resource.lane_id,
    resource.parent_lane_id,
    resource.resource_kind,
    resource.name,
    resource.display_name,
    resource.display_order,
    resource.effective_online_bookable,
    resource.whole_lane_bookable,
    resource.positions_bookable,
    resource.max_people_online,
    resource.booking_step_minutes,
    resource.currency_code,
    resource.durations_minutes,
    resource.pricing
  from public_resources as resource
  order by resource.hierarchy_display_order,
           resource.hierarchy_kind_order,
           resource.display_order,
           resource.name,
           resource.lane_id;
$$;


ALTER FUNCTION "public"."get_public_booking_configuration_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_public_booking_configuration_v1"() IS 'Returns the fail-closed public booking hierarchy, durations and pricing without internal identifiers or metadata.';



CREATE OR REPLACE FUNCTION "public"."get_reservation_customer_profiles_v1"("p_reservation_ids" "uuid"[]) RETURNS TABLE("reservation_id" "uuid", "user_id" "uuid", "email" "text", "full_name" "text", "phone" "text", "role" "text", "verification_status" "text", "postal_code" "text", "city" "text", "street" "text", "house_number" "text", "apartment_number" "text", "permission_sport" boolean, "permission_collector" boolean, "permission_hunting" boolean, "permission_training" boolean, "permission_personal_protection" boolean, "permission_other" boolean, "qualification_instructor" boolean, "qualification_range_officer" boolean, "qualification_pzss_license" boolean, "qualification_hunter" boolean, "permissions_verified" boolean, "permissions_verified_at" timestamp with time zone, "permissions_verification_note" "text", "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_requested_count integer;
  v_distinct_count integer;
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_id is null or coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    raise exception 'Brak uprawnień do danych operacyjnych profilu.' using errcode = '42501';
  end if;

  v_requested_count := coalesce(pg_catalog.cardinality(p_reservation_ids), 0);
  if v_requested_count < 1 or v_requested_count > 200
     or pg_catalog.array_position(p_reservation_ids, null) is not null then
    raise exception 'Nieprawidłowy zakres rezerwacji.' using errcode = '22023';
  end if;

  select pg_catalog.count(distinct requested.id)::integer
  into v_distinct_count
  from pg_catalog.unnest(p_reservation_ids) as requested(id);

  if v_distinct_count <> v_requested_count then
    raise exception 'Identyfikatory rezerwacji nie mogą się powtarzać.' using errcode = '22023';
  end if;

  return query
  select
    reservation.id, profile.user_id, profile.email, profile.full_name,
    profile.phone, profile.role, profile.verification_status,
    profile.postal_code, profile.city, profile.street, profile.house_number,
    profile.apartment_number, profile.permission_sport,
    profile.permission_collector, profile.permission_hunting,
    profile.permission_training, profile.permission_personal_protection,
    profile.permission_other, profile.qualification_instructor,
    profile.qualification_range_officer, profile.qualification_pzss_license,
    profile.qualification_hunter, profile.permissions_verified,
    profile.permissions_verified_at, profile.permissions_verification_note,
    profile.updated_at
  from public.reservations as reservation
  join public.profiles as profile on profile.user_id = reservation.user_id
  where reservation.id = any(p_reservation_ids)
  order by reservation.id;
end;
$$;


ALTER FUNCTION "public"."get_reservation_customer_profiles_v1"("p_reservation_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  profile_first_name text;
  profile_last_name text;
  profile_full_name text;
  profile_phone text;
begin
  profile_first_name := nullif(btrim(new.raw_user_meta_data->>'first_name'), '');
  profile_last_name := nullif(btrim(new.raw_user_meta_data->>'last_name'), '');
  profile_full_name := coalesce(
    nullif(btrim(new.raw_user_meta_data->>'full_name'), ''),
    nullif(btrim(concat_ws(' ', profile_first_name, profile_last_name)), ''),
    ''
  );
  profile_phone := coalesce(new.raw_user_meta_data->>'phone', '');

  insert into public.profiles as existing (
    id,
    user_id,
    email,
    full_name,
    first_name,
    last_name,
    phone,
    role,
    verification_status,
    created_at,
    updated_at
  )
  values (
    new.id,
    new.id,
    new.email,
    profile_full_name,
    profile_first_name,
    profile_last_name,
    profile_phone,
    'user',
    'pending',
    now(),
    now()
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    full_name = case
      when nullif(btrim(existing.full_name), '') is null then excluded.full_name
      else existing.full_name
    end,
    first_name = case
      when nullif(btrim(existing.first_name), '') is null then excluded.first_name
      else existing.first_name
    end,
    last_name = case
      when nullif(btrim(existing.last_name), '') is null then excluded.last_name
      else existing.last_name
    end,
    phone = case
      when nullif(btrim(existing.phone), '') is null then excluded.phone
      else existing.phone
    end,
    updated_at = now();

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles
    where user_id = auth.uid()
      and role::text = 'admin'
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin_or_employee"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles
    where user_id = auth.uid()
      and lower(btrim(role::text)) in ('admin', 'pracownik')
  );
$$;


ALTER FUNCTION "public"."is_admin_or_employee"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin_or_staff"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles
    where user_id = auth.uid()
      and role::text in ('admin', 'pracownik', 'instruktor')
  );
$$;


ALTER FUNCTION "public"."is_admin_or_staff"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lane_booking_family_business_snapshot_v2"("p_root_lane_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'lane_id', resource.id,
      'name', pg_catalog.btrim(resource.name),
      'is_active', resource.is_active,
      'whole_lane_bookable', resource.whole_lane_bookable,
      'positions_bookable', resource.positions_bookable,
      'max_shooters', resource.max_shooters,
      'online_bookable', rule.online_bookable,
      'max_people_online', rule.max_people_online,
      'durations_minutes', coalesce((
        select pg_catalog.jsonb_agg(duration.duration_minutes order by duration.duration_minutes)
        from public.lane_booking_durations as duration
        where duration.lane_id = resource.id and duration.is_active
      ), '[]'::jsonb),
      'pricing', coalesce((
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'day_group', pricing.day_group,
            'min_shooters', pricing.min_shooters,
            'max_shooters', pricing.max_shooters,
            'label', pg_catalog.btrim(pricing.label),
            'hourly_price', pricing.hourly_price
          ) order by pricing.day_group, pricing.min_shooters,
                     pricing.max_shooters, pricing.label
        )
        from public.lane_pricing_rules as pricing
        where pricing.lane_id = resource.id and pricing.is_active
      ), '[]'::jsonb)
    ) order by resource.id
  ), '[]'::jsonb)
  from public.shooting_lanes as resource
  join public.lane_booking_rules as rule on rule.lane_id = resource.id
  where resource.id = p_root_lane_id
     or resource.parent_lane_id = p_root_lane_id;
$$;


ALTER FUNCTION "public"."lane_booking_family_business_snapshot_v2"("p_root_lane_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lock_lane_booking_configuration"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."lock_lane_booking_configuration"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."lock_lane_booking_configuration"() IS 'Serializuje zmiany konfiguracji osi z rezerwacjami i aktywnymi eventami.';



CREATE OR REPLACE FUNCTION "public"."lock_lane_conflict_families_v1"("p_lane_ids" "uuid"[]) RETURNS TABLE("requested_lane_id" "uuid", "root_lane_id" "uuid", "requested_resource_kind" "text", "conflict_lane_ids" "uuid"[])
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_requested_ids uuid[];
  v_expected_root_ids uuid[] := array[]::uuid[];
  v_expected_kinds text[] := array[]::text[];
  v_root_ids uuid[];
  v_full_root_ids uuid[];
  v_requested_id uuid;
  v_requested_kind text;
  v_requested_parent_id uuid;
  v_parent_kind text;
  v_parent_parent_id uuid;
  v_root_id uuid;
  v_current_kind text;
  v_current_parent_id uuid;
  v_index integer;
begin
  if p_lane_ids is null then
    raise exception 'Lane identifiers are required.' using errcode = '22023';
  end if;

  if pg_catalog.cardinality(p_lane_ids) = 0 then
    raise exception 'At least one lane identifier is required.' using errcode = '22023';
  end if;

  if pg_catalog.array_position(p_lane_ids, null::uuid) is not null then
    raise exception 'Lane identifiers cannot contain NULL.' using errcode = '22023';
  end if;

  select pg_catalog.array_agg(distinct input_record.lane_id order by input_record.lane_id)
  into v_requested_ids
  from pg_catalog.unnest(p_lane_ids) as input_record(lane_id);

  -- Preliminary topology resolution only. No lock and no bookability validation.
  for v_requested_id in
    select input_record.lane_id
    from pg_catalog.unnest(v_requested_ids) as input_record(lane_id)
    order by input_record.lane_id
  loop
    select lane.resource_kind, lane.parent_lane_id
    into v_requested_kind, v_requested_parent_id
    from public.shooting_lanes as lane
    where lane.id = v_requested_id;

    if not found then
      raise exception 'Shooting-lane resource does not exist.' using errcode = 'P0002';
    end if;

    if v_requested_kind not in ('lane', 'position')
       or v_requested_kind is null then
      raise exception 'Malformed shooting-lane resource kind.' using errcode = '55000';
    end if;

    if v_requested_kind = 'lane' then
      if v_requested_parent_id is not null then
        raise exception 'Malformed top-level shooting lane.' using errcode = '55000';
      end if;

      v_root_id := v_requested_id;
    else
      if v_requested_parent_id is null
         or v_requested_parent_id = v_requested_id then
        raise exception 'Malformed shooting-lane position parent.' using errcode = '55000';
      end if;

      select parent.resource_kind, parent.parent_lane_id
      into v_parent_kind, v_parent_parent_id
      from public.shooting_lanes as parent
      where parent.id = v_requested_parent_id;

      if not found
         or v_parent_kind is distinct from 'lane'
         or v_parent_parent_id is not null then
        raise exception 'Position parent must be an existing top-level lane.'
          using errcode = '55000';
      end if;

      v_root_id := v_requested_parent_id;
    end if;

    if exists (
         select 1
         from public.shooting_lanes as child
         where child.parent_lane_id = v_root_id
           and (
             child.id = v_root_id
             or child.resource_kind is distinct from 'position'
           )
       )
       or exists (
         select 1
         from public.shooting_lanes as child
         join public.shooting_lanes as grandchild
           on grandchild.parent_lane_id = child.id
         where child.parent_lane_id = v_root_id
       ) then
      raise exception 'Malformed shooting-lane hierarchy depth.' using errcode = '55000';
    end if;

    v_expected_root_ids := pg_catalog.array_append(v_expected_root_ids, v_root_id);
    v_expected_kinds := pg_catalog.array_append(v_expected_kinds, v_requested_kind);
  end loop;

  select pg_catalog.array_agg(distinct root_record.root_id order by root_record.root_id)
  into v_root_ids
  from pg_catalog.unnest(v_expected_root_ids) as root_record(root_id);

  select pg_catalog.array_agg(mode_record.root_id order by mode_record.root_id)
  into v_full_root_ids
  from (
    select distinct v_expected_root_ids[index_record.index_value] as root_id
    from pg_catalog.generate_subscripts(v_requested_ids, 1) as index_record(index_value)
    where v_requested_ids[index_record.index_value]
          = v_expected_root_ids[index_record.index_value]
  ) as mode_record;

  -- Phase 1: lock every root globally before taking any child lock.
  for v_root_id in
    select root_record.root_id
    from pg_catalog.unnest(v_root_ids) as root_record(root_id)
    order by root_record.root_id
  loop
    if pg_catalog.array_position(v_full_root_ids, v_root_id) is not null then
      perform root.id
      from public.shooting_lanes as root
      where root.id = v_root_id
      for update;
    else
      perform root.id
      from public.shooting_lanes as root
      where root.id = v_root_id
      for share;
    end if;

    if not found then
      raise exception 'Resolved shooting-lane root disappeared.' using errcode = '55000';
    end if;
  end loop;

  -- Phase 2: only after all roots, lock children root-by-root and child-id ordered.
  for v_root_id in
    select root_record.root_id
    from pg_catalog.unnest(v_root_ids) as root_record(root_id)
    order by root_record.root_id
  loop
    if pg_catalog.array_position(v_full_root_ids, v_root_id) is not null then
      perform child.id
      from public.shooting_lanes as child
      where child.parent_lane_id = v_root_id
      order by child.id
      for update;
    else
      perform child.id
      from public.shooting_lanes as child
      where child.parent_lane_id = v_root_id
        and child.id = any(v_requested_ids)
      order by child.id
      for update;
    end if;
  end loop;

  -- Re-read the locked resources and fail closed if topology changed.
  for v_index in 1..pg_catalog.cardinality(v_requested_ids) loop
    select lane.resource_kind, lane.parent_lane_id
    into v_current_kind, v_current_parent_id
    from public.shooting_lanes as lane
    where lane.id = v_requested_ids[v_index];

    if not found
       or v_current_kind is distinct from v_expected_kinds[v_index]
       or (
         v_current_kind = 'lane'
         and (
           v_current_parent_id is not null
           or v_requested_ids[v_index] is distinct from v_expected_root_ids[v_index]
         )
       )
       or (
         v_current_kind = 'position'
         and (
           v_current_parent_id is distinct from v_expected_root_ids[v_index]
           or v_current_parent_id = v_requested_ids[v_index]
         )
       ) then
      raise exception 'Shooting-lane topology changed during locking.' using errcode = '55000';
    end if;
  end loop;

  for v_root_id in
    select root_record.root_id
    from pg_catalog.unnest(v_root_ids) as root_record(root_id)
    order by root_record.root_id
  loop
    select root.resource_kind, root.parent_lane_id
    into v_current_kind, v_current_parent_id
    from public.shooting_lanes as root
    where root.id = v_root_id;

    if not found
       or v_current_kind is distinct from 'lane'
       or v_current_parent_id is not null
       or exists (
         select 1
         from public.shooting_lanes as child
         where child.parent_lane_id = v_root_id
           and (
             child.id = v_root_id
             or child.resource_kind is distinct from 'position'
           )
       )
       or exists (
         select 1
         from public.shooting_lanes as child
         join public.shooting_lanes as grandchild
           on grandchild.parent_lane_id = child.id
         where child.parent_lane_id = v_root_id
       ) then
      raise exception 'Shooting-lane hierarchy changed during locking.' using errcode = '55000';
    end if;
  end loop;

  return query
  select
    v_requested_ids[index_record.index_value],
    v_expected_root_ids[index_record.index_value],
    v_expected_kinds[index_record.index_value],
    case v_expected_kinds[index_record.index_value]
      when 'lane' then (
        select pg_catalog.array_agg(
          scope_record.lane_id
          order by scope_record.scope_order, scope_record.lane_id
        )
        from (
          select v_expected_root_ids[index_record.index_value] as lane_id, 0 as scope_order
          union all
          select child.id, 1
          from public.shooting_lanes as child
          where child.parent_lane_id = v_expected_root_ids[index_record.index_value]
        ) as scope_record
      )
      else array[
        v_expected_root_ids[index_record.index_value],
        v_requested_ids[index_record.index_value]
      ]::uuid[]
    end
  from pg_catalog.generate_subscripts(v_requested_ids, 1) as index_record(index_value)
  order by
    v_expected_root_ids[index_record.index_value],
    v_requested_ids[index_record.index_value];
end;
$$;


ALTER FUNCTION "public"."lock_lane_conflict_families_v1"("p_lane_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."lock_lane_conflict_families_v1"("p_lane_ids" "uuid"[]) IS 'Privately locks one or more lane-position conflict families in a global root-first order.';



CREATE OR REPLACE FUNCTION "public"."lock_lane_conflict_family_v1"("p_lane_id" "uuid") RETURNS TABLE("requested_lane_id" "uuid", "root_lane_id" "uuid", "requested_resource_kind" "text", "conflict_lane_ids" "uuid"[])
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_preliminary_kind text;
  v_preliminary_parent_id uuid;
  v_requested_kind text;
  v_requested_parent_id uuid;
  v_requested_active boolean;
  v_root_id uuid;
  v_root_kind text;
  v_root_parent_id uuid;
  v_root_active boolean;
  v_scope uuid[];
begin
  if p_lane_id is null then
    raise exception 'Lane identifier is required.' using errcode = '22023';
  end if;

  select lane.resource_kind, lane.parent_lane_id
  into v_preliminary_kind, v_preliminary_parent_id
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    raise exception 'Shooting-lane resource does not exist.' using errcode = 'P0002';
  end if;

  if v_preliminary_kind not in ('lane', 'position')
     or v_preliminary_kind is null then
    raise exception 'Malformed shooting-lane resource kind.' using errcode = '55000';
  end if;

  if v_preliminary_kind = 'lane' then
    if v_preliminary_parent_id is not null then
      raise exception 'Malformed top-level shooting lane.' using errcode = '55000';
    end if;

    select lane.resource_kind, lane.parent_lane_id, lane.is_active
    into v_root_kind, v_root_parent_id, v_root_active
    from public.shooting_lanes as lane
    where lane.id = p_lane_id
    for update;

    if not found then
      raise exception 'Shooting-lane resource does not exist.' using errcode = 'P0002';
    end if;

    if v_root_kind is distinct from 'lane' or v_root_parent_id is not null then
      raise exception 'Malformed top-level shooting lane.' using errcode = '55000';
    end if;

    if not v_root_active then
      raise exception 'Requested shooting-lane resource is inactive.' using errcode = 'P1001';
    end if;

    v_root_id := p_lane_id;

    perform child.id
    from public.shooting_lanes as child
    where child.parent_lane_id = v_root_id
    order by child.id
    for update;

    if exists (
         select 1
         from public.shooting_lanes as child
         where child.parent_lane_id = v_root_id
           and (
             child.id = v_root_id
             or child.resource_kind is distinct from 'position'
           )
       )
       or exists (
         select 1
         from public.shooting_lanes as child
         join public.shooting_lanes as grandchild
           on grandchild.parent_lane_id = child.id
         where child.parent_lane_id = v_root_id
       ) then
      raise exception 'Malformed shooting-lane hierarchy depth.' using errcode = '55000';
    end if;

    select pg_catalog.array_agg(scope_record.lane_id order by scope_record.scope_order, scope_record.lane_id)
    into v_scope
    from (
      select v_root_id as lane_id, 0 as scope_order
      union all
      select child.id, 1
      from public.shooting_lanes as child
      where child.parent_lane_id = v_root_id
    ) as scope_record;

    return query select p_lane_id, v_root_id, 'lane'::text, v_scope;
    return;
  end if;

  if v_preliminary_parent_id is null
     or v_preliminary_parent_id = p_lane_id then
    raise exception 'Malformed shooting-lane position parent.' using errcode = '55000';
  end if;

  v_root_id := v_preliminary_parent_id;

  select parent.resource_kind, parent.parent_lane_id, parent.is_active
  into v_root_kind, v_root_parent_id, v_root_active
  from public.shooting_lanes as parent
  where parent.id = v_root_id
  for share;

  if not found
     or v_root_kind is distinct from 'lane'
     or v_root_parent_id is not null then
    raise exception 'Position parent must be a top-level shooting lane.' using errcode = '55000';
  end if;

  if not v_root_active then
    raise exception 'Position parent is inactive.' using errcode = 'P1001';
  end if;

  select lane.resource_kind, lane.parent_lane_id, lane.is_active
  into v_requested_kind, v_requested_parent_id, v_requested_active
  from public.shooting_lanes as lane
  where lane.id = p_lane_id
  for update;

  if not found then
    raise exception 'Shooting-lane resource does not exist.' using errcode = 'P0002';
  end if;

  if v_requested_kind is distinct from 'position'
     or v_requested_parent_id is distinct from v_root_id
     or v_requested_parent_id = p_lane_id then
    raise exception 'Malformed shooting-lane position hierarchy.' using errcode = '55000';
  end if;

  if not v_requested_active then
    raise exception 'Requested shooting-lane resource is inactive.' using errcode = 'P1001';
  end if;

  if exists (
       select 1
       from public.shooting_lanes as child
       where child.parent_lane_id = v_root_id
         and (
           child.id = v_root_id
           or child.resource_kind is distinct from 'position'
         )
     )
     or exists (
       select 1
       from public.shooting_lanes as child
       join public.shooting_lanes as grandchild
         on grandchild.parent_lane_id = child.id
       where child.parent_lane_id = v_root_id
     ) then
    raise exception 'Malformed shooting-lane hierarchy depth.' using errcode = '55000';
  end if;

  v_scope := array[v_root_id, p_lane_id]::uuid[];
  return query select p_lane_id, v_root_id, 'position'::text, v_scope;
end;
$$;


ALTER FUNCTION "public"."lock_lane_conflict_family_v1"("p_lane_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."lock_lane_conflict_family_v1"("p_lane_id" "uuid") IS 'Locks a lane-position conflict family in root-first order and returns a typed conflict scope.';



CREATE OR REPLACE FUNCTION "public"."normalize_lane_booking_family_payload_v2"("p_resources" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
declare
  v_resource jsonb;
  v_pricing jsonb;
  v_result jsonb;
begin
  if p_resources is null
     or pg_catalog.jsonb_typeof(p_resources) <> 'array'
     or pg_catalog.jsonb_array_length(p_resources) = 0 then
    raise exception 'Invalid family payload.' using errcode = '22023';
  end if;

  for v_resource in
    select item.value from pg_catalog.jsonb_array_elements(p_resources) as item(value)
  loop
    if pg_catalog.jsonb_typeof(v_resource) <> 'object'
       or (select pg_catalog.array_agg(key order by key)
           from pg_catalog.jsonb_object_keys(v_resource) as keys(key))
          is distinct from array[
            'durations_minutes','is_active','lane_id','max_people_online',
            'max_shooters','name','online_bookable','positions_bookable','pricing',
            'whole_lane_bookable'
          ]::text[]
       or pg_catalog.jsonb_typeof(v_resource->'lane_id') <> 'string'
       or (v_resource->>'lane_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or pg_catalog.jsonb_typeof(v_resource->'name') <> 'string'
       or pg_catalog.btrim(v_resource->>'name') = ''
       or pg_catalog.char_length(pg_catalog.btrim(v_resource->>'name')) > 120
       or v_resource->>'name' ~ '[<>]'
       or v_resource->>'name' ~ '[[:cntrl:]]'
       or pg_catalog.jsonb_typeof(v_resource->'is_active') <> 'boolean'
       or pg_catalog.jsonb_typeof(v_resource->'whole_lane_bookable') <> 'boolean'
       or pg_catalog.jsonb_typeof(v_resource->'positions_bookable') <> 'boolean'
       or pg_catalog.jsonb_typeof(v_resource->'online_bookable') <> 'boolean'
       or pg_catalog.jsonb_typeof(v_resource->'max_shooters') <> 'number'
       or (v_resource->>'max_shooters') !~ '^[0-9]+$'
       or pg_catalog.jsonb_typeof(v_resource->'max_people_online') <> 'number'
       or (v_resource->>'max_people_online') !~ '^[0-9]+$'
       or pg_catalog.jsonb_typeof(v_resource->'durations_minutes') <> 'array'
       or pg_catalog.jsonb_typeof(v_resource->'pricing') <> 'array'
       or exists (
         select 1 from pg_catalog.jsonb_array_elements(v_resource->'durations_minutes') as d(value)
         where pg_catalog.jsonb_typeof(d.value) <> 'number'
            or d.value #>> '{}' !~ '^[0-9]+$'
       )
       or (select pg_catalog.count(*)
           from pg_catalog.jsonb_array_elements(v_resource->'durations_minutes'))
          <> (select pg_catalog.count(distinct d.value #>> '{}')
              from pg_catalog.jsonb_array_elements(v_resource->'durations_minutes') as d(value)) then
      raise exception 'Invalid family payload.' using errcode = '22023';
    end if;

    for v_pricing in
      select item.value from pg_catalog.jsonb_array_elements(v_resource->'pricing') as item(value)
    loop
      if pg_catalog.jsonb_typeof(v_pricing) <> 'object'
         or (select pg_catalog.array_agg(key order by key)
             from pg_catalog.jsonb_object_keys(v_pricing) as keys(key))
            is distinct from array[
              'day_group','hourly_price','label','max_shooters','min_shooters'
            ]::text[]
         or pg_catalog.jsonb_typeof(v_pricing->'day_group') <> 'string'
         or v_pricing->>'day_group' not in ('mon_thu','fri_sun')
         or pg_catalog.jsonb_typeof(v_pricing->'label') <> 'string'
         or pg_catalog.btrim(v_pricing->>'label') = ''
         or pg_catalog.jsonb_typeof(v_pricing->'min_shooters') <> 'number'
         or v_pricing->>'min_shooters' !~ '^[0-9]+$'
         or pg_catalog.jsonb_typeof(v_pricing->'max_shooters') <> 'number'
         or v_pricing->>'max_shooters' !~ '^[0-9]+$'
         or pg_catalog.jsonb_typeof(v_pricing->'hourly_price') <> 'number'
         or v_pricing->>'hourly_price' !~ '^[0-9]+([.][0-9]{1,2})?$' then
        raise exception 'Invalid family payload.' using errcode = '22023';
      end if;
    end loop;
  end loop;

  if (select pg_catalog.count(*) from pg_catalog.jsonb_array_elements(p_resources))
     <> (select pg_catalog.count(distinct (item.value->>'lane_id')::uuid)
         from pg_catalog.jsonb_array_elements(p_resources) as item(value)) then
    raise exception 'Invalid family payload.' using errcode = '22023';
  end if;

  select pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'lane_id', (resource.value->>'lane_id')::uuid,
      'name', pg_catalog.btrim(resource.value->>'name'),
      'is_active', (resource.value->>'is_active')::boolean,
      'whole_lane_bookable', (resource.value->>'whole_lane_bookable')::boolean,
      'positions_bookable', (resource.value->>'positions_bookable')::boolean,
      'max_shooters', (resource.value->>'max_shooters')::integer,
      'online_bookable', (resource.value->>'online_bookable')::boolean,
      'max_people_online', (resource.value->>'max_people_online')::integer,
      'durations_minutes', coalesce((
        select pg_catalog.jsonb_agg((duration.value #>> '{}')::integer order by (duration.value #>> '{}')::integer)
        from pg_catalog.jsonb_array_elements(resource.value->'durations_minutes') as duration(value)
      ), '[]'::jsonb),
      'pricing', coalesce((
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'day_group', price.value->>'day_group',
            'min_shooters', (price.value->>'min_shooters')::integer,
            'max_shooters', (price.value->>'max_shooters')::integer,
            'label', pg_catalog.btrim(price.value->>'label'),
            'hourly_price', (price.value->>'hourly_price')::numeric(12,2)
          ) order by price.value->>'day_group',
                     (price.value->>'min_shooters')::integer,
                     (price.value->>'max_shooters')::integer,
                     pg_catalog.btrim(price.value->>'label')
        )
        from pg_catalog.jsonb_array_elements(resource.value->'pricing') as price(value)
      ), '[]'::jsonb)
    ) order by (resource.value->>'lane_id')::uuid
  ) into v_result
  from pg_catalog.jsonb_array_elements(p_resources) as resource(value);

  return v_result;
exception
  when sqlstate '22003' or sqlstate '22P02' then
    raise exception 'Invalid family payload.' using errcode = '22023';
end;
$_$;


ALTER FUNCTION "public"."normalize_lane_booking_family_payload_v2"("p_resources" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prepare_confirmation_email"("p_message_type" "text", "p_record_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_actor_user_id uuid := auth.uid();
  v_message_type text := pg_catalog.lower(pg_catalog.btrim(p_message_type));
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_source_user_id uuid;
  v_source_status text;
  v_delivery public.email_deliveries%rowtype;
  v_attempt_count integer;
  v_attempt_window_started_at timestamptz;
  v_claim_id uuid;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'unauthorized'
    );
  end if;

  if p_record_id is null
     or v_message_type is null
     or v_message_type not in (
       'event_registration_confirmation',
       'reservation_confirmation'
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'invalid_status'
    );
  end if;

  if v_message_type = 'event_registration_confirmation' then
    select
      registration.user_id,
      pg_catalog.lower(pg_catalog.btrim(registration.registration_status))
    into
      v_source_user_id,
      v_source_status
    from public.event_registrations as registration
    where registration.id = p_record_id
      and registration.user_id = v_actor_user_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'not_found'
      );
    end if;

    if v_source_status not in ('registered', 'reserve') then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'invalid_status'
      );
    end if;
  else
    select
      reservation.user_id,
      pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
    into
      v_source_user_id,
      v_source_status
    from public.reservations as reservation
    where reservation.id = p_record_id
      and reservation.user_id = v_actor_user_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'not_found'
      );
    end if;

    if v_source_status <> 'confirmed' then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'invalid_status'
      );
    end if;
  end if;

  insert into public.email_deliveries (
    message_type,
    record_id,
    recipient_user_id
  )
  values (
    v_message_type,
    p_record_id,
    v_source_user_id
  )
  on conflict (message_type, record_id) do nothing;

  select delivery.*
  into v_delivery
  from public.email_deliveries as delivery
  where delivery.message_type = v_message_type
    and delivery.record_id = p_record_id
  for update;

  if not found
     or v_delivery.recipient_user_id is distinct from v_actor_user_id then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'not_found'
    );
  end if;

  if v_delivery.sent_at is not null then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'already_sent'
    );
  end if;

  if v_delivery.claim_id is not null
     and v_delivery.claim_expires_at > v_now then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'in_progress'
    );
  end if;

  v_attempt_count := v_delivery.attempt_count;
  v_attempt_window_started_at := v_delivery.attempt_window_started_at;

  if v_attempt_window_started_at is null
     or v_attempt_window_started_at <= v_now - interval '24 hours' then
    v_attempt_count := 0;
    v_attempt_window_started_at := v_now;
  end if;

  if v_attempt_count >= 3 then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'attempt_limit_reached'
    );
  end if;

  v_claim_id := pg_catalog.gen_random_uuid();
  v_attempt_count := v_attempt_count + 1;

  update public.email_deliveries as delivery
  set
    claim_id = v_claim_id,
    claim_expires_at = v_now + interval '5 minutes',
    attempt_count = v_attempt_count,
    attempt_window_started_at = v_attempt_window_started_at,
    last_attempt_at = v_now,
    last_error_code = null,
    updated_at = v_now
  where delivery.id = v_delivery.id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'ready',
    'delivery_id', v_delivery.id,
    'claim_id', v_claim_id,
    'claim_expires_at', v_now + interval '5 minutes',
    'attempt_count', v_attempt_count,
    'idempotency_key',
      'confirmation/' || v_message_type || '/' || v_delivery.id::text
  );
end;
$$;


ALTER FUNCTION "public"."prepare_confirmation_email"("p_message_type" "text", "p_record_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."prepare_confirmation_email"("p_message_type" "text", "p_record_id" "uuid") IS 'Validates ownership and status, then atomically leases one bounded confirmation-email attempt.';



CREATE OR REPLACE FUNCTION "public"."prepare_event_reserve_promotions"("p_event_id" "uuid") RETURNS TABLE("registration_id" "uuid", "claim_id" "uuid", "promotion_token" "text", "promotion_token_expires_at" timestamp with time zone, "token_reused" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_event public.events%rowtype;
  v_reserve record;
  v_participants_count integer;
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_claim_id uuid;
  v_token text;
  v_token_expires_at timestamptz;
  v_token_reused boolean;
begin
  if p_event_id is null then
    raise exception using
      errcode = '22023',
      message = 'Identyfikator szkolenia jest wymagany.';
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Nie znaleziono szkolenia.';
  end if;

  select count(*)
  into v_participants_count
  from public.event_registrations as registration
  where registration.event_id = p_event_id
    and registration.registration_status in ('registered', 'approved');

  if v_participants_count >= coalesce(v_event.max_participants, 0) then
    return;
  end if;

  for v_reserve in
    select
      registration.id,
      registration.promotion_token,
      registration.promotion_token_expires_at,
      registration.promotion_email_sent_at,
      registration.promotion_confirmed_at
    from public.event_registrations as registration
    where registration.event_id = p_event_id
      and registration.registration_status = 'reserve'
      and not (
        registration.promotion_claim_id is not null
        and registration.promotion_claim_expires_at > v_now
      )
      and not (
        registration.promotion_email_sent_at is not null
        and registration.promotion_token is not null
        and registration.promotion_token_expires_at > v_now
      )
    order by registration.created_at, registration.id
    for update
  loop
    v_token_reused :=
      v_reserve.promotion_token is not null
      and v_reserve.promotion_token_expires_at > v_now
      and v_reserve.promotion_email_sent_at is null;

    if v_token_reused then
      v_token := v_reserve.promotion_token;
      v_token_expires_at := v_reserve.promotion_token_expires_at;
    else
      v_token := pg_catalog.gen_random_uuid()::text;
      v_token_expires_at := v_now + interval '24 hours';
    end if;

    v_claim_id := pg_catalog.gen_random_uuid();

    update public.event_registrations as registration
    set
      promotion_token = v_token,
      promotion_token_expires_at = v_token_expires_at,
      promotion_email_sent_at = case
        when v_token_reused then registration.promotion_email_sent_at
        else null
      end,
      promotion_confirmed_at = case
        when v_token_reused then registration.promotion_confirmed_at
        else null
      end,
      promotion_claim_id = v_claim_id,
      promotion_claim_expires_at = v_now + interval '10 minutes',
      promotion_attempt_count = registration.promotion_attempt_count + 1,
      promotion_last_attempt_at = v_now,
      promotion_last_error_code = null
    where registration.id = v_reserve.id;

    registration_id := v_reserve.id;
    claim_id := v_claim_id;
    promotion_token := v_token;
    promotion_token_expires_at := v_token_expires_at;
    token_reused := v_token_reused;

    return next;
  end loop;
end;
$$;


ALTER FUNCTION "public"."prepare_event_reserve_promotions"("p_event_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."prepare_event_reserve_promotions"("p_event_id" "uuid") IS 'Atomowo przygotowuje i claimuje techniczne tokeny promocji listy rezerwowej.';



CREATE OR REPLACE FUNCTION "public"."prevent_non_admin_profile_privilege_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  actor_role text;
  identity_changed boolean;
  role_changed boolean := old.role is distinct from new.role;
  note_changed boolean := old.admin_note is distinct from new.admin_note;
begin
  if auth.uid() is null then
    return new;
  end if;

  if role_changed then
    if not coalesce(public.is_admin(), false)
       or pg_catalog.current_setting('csk.profile_role_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_role_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Rolę można zmieniać wyłącznie przez kontrolowaną operację administratora.'
        using errcode = '42501';
    end if;

    if (pg_catalog.to_jsonb(new) - array['role', 'updated_at'])
       is distinct from (pg_catalog.to_jsonb(old) - array['role', 'updated_at']) then
      raise exception 'Kontrolowana zmiana roli może zmieniać wyłącznie rolę i czas aktualizacji.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if note_changed then
    if not coalesce(public.is_admin(), false)
       or pg_catalog.current_setting('csk.profile_note_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_note_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Notatkę administracyjną można zmieniać wyłącznie przez kontrolowaną operację administratora.'
        using errcode = '42501';
    end if;

    if (pg_catalog.to_jsonb(new) - array['admin_note', 'updated_at'])
       is distinct from (pg_catalog.to_jsonb(old) - array['admin_note', 'updated_at']) then
      raise exception 'Kontrolowana zmiana notatki może zmieniać wyłącznie notatkę i czas aktualizacji.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  identity_changed := old.first_name is distinct from new.first_name
    or old.last_name is distinct from new.last_name
    or old.full_name is distinct from new.full_name;

  if identity_changed then
    if not coalesce(public.is_admin(), false) then
      raise exception 'Dane imienia i nazwiska może zmieniać wyłącznie administrator przez kontrolowaną operację.'
        using errcode = '42501';
    end if;
    if pg_catalog.current_setting('csk.profile_identity_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_identity_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Dane imienia i nazwiska można zmieniać wyłącznie przez kontrolowaną operację korekty tożsamości.'
        using errcode = '42501';
    end if;
    if (pg_catalog.to_jsonb(new) - array['first_name','last_name','full_name','updated_at'])
       is distinct from (pg_catalog.to_jsonb(old) - array['first_name','last_name','full_name','updated_at']) then
      raise exception 'Kontrolowana korekta tożsamości może zmieniać wyłącznie imię, nazwisko, pełną nazwę i czas aktualizacji.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if coalesce(public.is_admin(), false) then
    return new;
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text)) into actor_role
  from public.profiles as profile where profile.user_id = auth.uid();

  if actor_role = 'pracownik' and old.user_id is distinct from auth.uid() then
    if coalesce(pg_catalog.lower(pg_catalog.btrim(old.role::text)), '') = 'admin' then
      raise exception 'Pracownik nie może zmieniać profilu administratora.' using errcode = '42501';
    end if;
    if pg_catalog.current_setting('csk.profile_contact_rpc_actor', true) is not distinct from auth.uid()::text
       and pg_catalog.current_setting('csk.profile_contact_rpc_target', true) is not distinct from old.user_id::text then
      if (pg_catalog.to_jsonb(new) - array['phone','postal_code','city','street','house_number','apartment_number','updated_at'])
         is distinct from (pg_catalog.to_jsonb(old) - array['phone','postal_code','city','street','house_number','apartment_number','updated_at']) then
        raise exception 'Pracownik może zmieniać wyłącznie dane kontaktowe klienta.' using errcode = '42501';
      end if;
      return new;
    end if;
    if pg_catalog.current_setting('csk.profile_verification_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_verification_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Pola cudzego profilu można zmieniać wyłącznie przez kontrolowaną operację.' using errcode = '42501';
    end if;
    if (pg_catalog.to_jsonb(new) - array[
      'verification_status','permissions_verified','permissions_verified_at',
      'permissions_verified_by','permissions_verification_note','verified_at',
      'verified_by','unverified_at','unverified_by','updated_at'
    ]) is distinct from (pg_catalog.to_jsonb(old) - array[
      'verification_status','permissions_verified','permissions_verified_at',
      'permissions_verified_by','permissions_verification_note','verified_at',
      'verified_by','unverified_at','unverified_by','updated_at'
    ]) then
      raise exception 'Pracownik może zmieniać wyłącznie pola weryfikacyjne cudzego profilu.' using errcode = '42501';
    end if;
    return new;
  end if;

  if old.id is distinct from new.id
     or old.user_id is distinct from new.user_id
     or old.email is distinct from new.email
     or old.created_at is distinct from new.created_at
     or old.first_name is distinct from new.first_name
     or old.last_name is distinct from new.last_name
     or old.weapon_permit_number is distinct from new.weapon_permit_number
     or old.weapon_permit_type is distinct from new.weapon_permit_type
     or old.weapon_permit_issuer is distinct from new.weapon_permit_issuer
     or old.has_range_officer is distinct from new.has_range_officer
     or old.range_officer_number is distinct from new.range_officer_number
     or old.has_instructor is distinct from new.has_instructor
     or old.instructor_number is distinct from new.instructor_number then
    raise exception 'Pola tożsamościowe, techniczne i legacy profilu nie są dostępne w samoobsłudze.' using errcode = '42501';
  end if;

  if old.verification_status is distinct from new.verification_status
     or old.verification_note is distinct from new.verification_note
     or old.verified_at is distinct from new.verified_at
     or old.verified_by is distinct from new.verified_by
     or old.unverified_at is distinct from new.unverified_at
     or old.unverified_by is distinct from new.unverified_by
     or old.permissions_verified is distinct from new.permissions_verified
     or old.permissions_verified_at is distinct from new.permissions_verified_at
     or old.permissions_verified_by is distinct from new.permissions_verified_by
     or old.permissions_verification_note is distinct from new.permissions_verification_note then
    raise exception 'Pola administracyjne i weryfikacyjne profilu nie są dostępne w samoobsłudze.' using errcode = '42501';
  end if;

  if old.permission_sport is distinct from new.permission_sport
     or old.permission_collector is distinct from new.permission_collector
     or old.permission_hunting is distinct from new.permission_hunting
     or old.permission_training is distinct from new.permission_training
     or old.permission_personal_protection is distinct from new.permission_personal_protection
     or old.permission_other is distinct from new.permission_other
     or old.qualification_instructor is distinct from new.qualification_instructor
     or old.qualification_range_officer is distinct from new.qualification_range_officer
     or old.qualification_pzss_license is distinct from new.qualification_pzss_license
     or old.qualification_hunter is distinct from new.qualification_hunter then
    new.verification_status := 'pending';
    new.permissions_verified := false;
    new.permissions_verified_at := null;
    new.permissions_verified_by := null;
    new.permissions_verification_note := null;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."prevent_non_admin_profile_privilege_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_for_event"("p_event_id" "uuid", "p_as_reserve" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_profile_found boolean;
  v_auth_email text;
  v_customer_name text;
  v_customer_email text;
  v_customer_phone text;
  v_event public.events%rowtype;
  v_event_start timestamptz;
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_existing_registration public.event_registrations%rowtype;
  v_participants_count integer;
  v_has_reserve boolean;
  v_registration_status text;
  v_inserted_registration public.event_registrations%rowtype;
  v_constraint_name text;
begin
  if p_event_id is null then
    raise exception using
      errcode = '22023',
      message = 'Identyfikator szkolenia jest wymagany.';
  end if;

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Uwierzytelniona sesja jest wymagana.';
  end if;

  select profile.*
  into v_profile
  from public.profiles as profile
  where profile.user_id = v_user_id;

  v_profile_found := found;

  if v_profile_found then
    select nullif(pg_catalog.btrim(auth_user.email), '')
    into v_auth_email
    from auth.users as auth_user
    where auth_user.id = v_user_id;

    v_customer_email := coalesce(
      nullif(pg_catalog.btrim(v_profile.email), ''),
      v_auth_email
    );

    v_customer_name := coalesce(
      nullif(
        pg_catalog.btrim(
          pg_catalog.concat_ws(
            ' ',
            nullif(pg_catalog.btrim(v_profile.first_name), ''),
            nullif(pg_catalog.btrim(v_profile.last_name), '')
          )
        ),
        ''
      ),
      nullif(pg_catalog.btrim(v_profile.full_name), ''),
      v_customer_email
    );

    v_customer_phone := nullif(pg_catalog.btrim(v_profile.phone), '');
  end if;

  if not v_profile_found
     or v_customer_name is null
     or v_customer_email is null
     or v_customer_phone is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'profile_incomplete'
    );
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_not_found'
    );
  end if;

  if not v_event.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_inactive'
    );
  end if;

  v_event_start :=
    (v_event.event_date + v_event.start_time) at time zone 'Europe/Warsaw';

  if v_now >= v_event_start then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_ended'
    );
  end if;

  select registration.*
  into v_existing_registration
  from public.event_registrations as registration
  where registration.event_id = p_event_id
    and registration.user_id = v_user_id
    and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in (
      'registered',
      'approved',
      'reserve',
      'participant'
    )
  order by registration.created_at, registration.id
  limit 1
  for update;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', case
        when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
          in ('registered', 'approved')
          then 'already_registered'
        when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status)) = 'reserve'
          then 'already_reserve'
        else 'already_active'
      end,
      'registration_id', v_existing_registration.id,
      'registration_status',
        pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
    );
  end if;

  select count(*)
  into v_participants_count
  from public.event_registrations as registration
  where registration.event_id = p_event_id
    and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in (
      'registered',
      'approved'
    );

  select exists (
    select 1
    from public.event_registrations as registration
    where registration.event_id = p_event_id
      and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) = 'reserve'
  )
  into v_has_reserve;

  v_registration_status := case
    when coalesce(p_as_reserve, false)
      or v_event.max_participants <= 0
      or v_participants_count >= v_event.max_participants
      or v_has_reserve
      then 'reserve'
    else 'registered'
  end;

  begin
    insert into public.event_registrations (
      event_id,
      user_id,
      customer_name,
      customer_email,
      customer_phone,
      registration_status
    )
    values (
      p_event_id,
      v_user_id,
      v_customer_name,
      v_customer_email,
      v_customer_phone,
      v_registration_status
    )
    returning * into v_inserted_registration;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name <> 'event_registrations_one_active_per_user_event_idx' then
        raise;
      end if;

      select registration.*
      into v_existing_registration
      from public.event_registrations as registration
      where registration.event_id = p_event_id
        and registration.user_id = v_user_id
        and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in (
          'registered',
          'approved',
          'reserve',
          'participant'
        )
      order by registration.created_at, registration.id
      limit 1
      for update;

      if not found then
        return pg_catalog.jsonb_build_object(
          'ok', false,
          'changed', false,
          'code', 'conflict'
        );
      end if;

      return pg_catalog.jsonb_build_object(
        'ok', true,
        'changed', false,
        'code', case
          when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
            in ('registered', 'approved')
            then 'already_registered'
          when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status)) = 'reserve'
            then 'already_reserve'
          else 'already_active'
        end,
        'registration_id', v_existing_registration.id,
        'registration_status',
          pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
      );
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', v_registration_status,
    'registration_id', v_inserted_registration.id,
    'registration_status', v_registration_status
  );
end;
$$;


ALTER FUNCTION "public"."register_for_event"("p_event_id" "uuid", "p_as_reserve" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."register_for_event"("p_event_id" "uuid", "p_as_reserve" boolean) IS 'Atomowo rejestruje uwierzytelnionego uzytkownika na szkolenie lub liste rezerwowa.';



CREATE OR REPLACE FUNCTION "public"."resolve_lane_conflict_scope_v1"("p_lane_id" "uuid") RETURNS TABLE("conflict_lane_id" "uuid", "root_lane_id" "uuid")
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_requested_kind text;
  v_requested_parent_id uuid;
  v_requested_active boolean;
  v_root_id uuid;
  v_root_kind text;
  v_root_parent_id uuid;
  v_root_active boolean;
begin
  if p_lane_id is null then
    raise exception 'Lane identifier is required.' using errcode = '22023';
  end if;

  select lane.resource_kind, lane.parent_lane_id, lane.is_active
  into v_requested_kind, v_requested_parent_id, v_requested_active
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    raise exception 'Shooting-lane resource does not exist.' using errcode = 'P0002';
  end if;

  if v_requested_kind not in ('lane', 'position')
     or v_requested_kind is null then
    raise exception 'Malformed shooting-lane resource kind.' using errcode = '55000';
  end if;

  if not v_requested_active then
    raise exception 'Requested shooting-lane resource is inactive.' using errcode = '55000';
  end if;

  if v_requested_kind = 'lane' then
    if v_requested_parent_id is not null then
      raise exception 'Malformed top-level shooting lane.' using errcode = '55000';
    end if;
    v_root_id := p_lane_id;
    v_root_kind := v_requested_kind;
    v_root_parent_id := v_requested_parent_id;
    v_root_active := v_requested_active;
  else
    if v_requested_parent_id is null or v_requested_parent_id = p_lane_id then
      raise exception 'Malformed shooting-lane position parent.' using errcode = '55000';
    end if;

    select parent.resource_kind, parent.parent_lane_id, parent.is_active
    into v_root_kind, v_root_parent_id, v_root_active
    from public.shooting_lanes as parent
    where parent.id = v_requested_parent_id;

    if not found
       or v_root_kind <> 'lane'
       or v_root_parent_id is not null then
      raise exception 'Position parent must be a top-level shooting lane.'
        using errcode = '55000';
    end if;

    if not v_root_active then
      raise exception 'Position parent is inactive.' using errcode = '55000';
    end if;

    v_root_id := v_requested_parent_id;
  end if;

  if exists (
       select 1
       from public.shooting_lanes as child
       where child.parent_lane_id = v_root_id
         and (
           child.id = v_root_id
           or child.resource_kind is distinct from 'position'
         )
     )
     or exists (
       select 1
       from public.shooting_lanes as child
       join public.shooting_lanes as grandchild
         on grandchild.parent_lane_id = child.id
       where child.parent_lane_id = v_root_id
     ) then
    raise exception 'Malformed shooting-lane hierarchy depth.' using errcode = '55000';
  end if;

  if v_requested_kind = 'position' then
    return query
      select scope_record.conflict_lane_id, v_root_id
      from (
        values
          (v_root_id, 0),
          (p_lane_id, 1)
      ) as scope_record(conflict_lane_id, scope_order)
      order by scope_record.scope_order, scope_record.conflict_lane_id;
    return;
  end if;

  return query
    select scope_record.conflict_lane_id, v_root_id
    from (
      select v_root_id as conflict_lane_id, 0 as scope_order
      union all
      select child.id, 1
      from public.shooting_lanes as child
      where child.parent_lane_id = v_root_id
    ) as scope_record
    order by scope_record.scope_order, scope_record.conflict_lane_id;
end;
$$;


ALTER FUNCTION "public"."resolve_lane_conflict_scope_v1"("p_lane_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."resolve_lane_conflict_scope_v1"("p_lane_id" "uuid") IS 'Resolves the private parent-position conflict scope and fails closed for malformed or unavailable resources.';



CREATE OR REPLACE FUNCTION "public"."set_booking_configuration_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog'
    AS $$
begin
  new.updated_at := pg_catalog.transaction_timestamp();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_booking_configuration_updated_at"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."set_booking_configuration_updated_at"() IS 'Ustawia updated_at dla konfiguracji osi przed każdą aktualizacją.';



CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_profile_contact_details"("p_target_user_id" "uuid", "p_phone" "text", "p_postal_code" "text", "p_city" "text", "p_street" "text", "p_house_number" "text", "p_apartment_number" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_profile public.profiles%rowtype;
  updated_profile public.profiles%rowtype;
  actor_role text;
  target_role text;
  actor_name text;
  target_name text;
  action_time timestamptz := now();
  normalized_phone text := nullif(btrim(p_phone), '');
  normalized_postal_code text := nullif(btrim(p_postal_code), '');
  normalized_city text := nullif(btrim(p_city), '');
  normalized_street text := nullif(btrim(p_street), '');
  normalized_house_number text := nullif(btrim(p_house_number), '');
  normalized_apartment_number text := nullif(btrim(p_apartment_number), '');
  changed_fields text[] := array[]::text[];
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  select profile.*
  into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found then
    raise exception 'Nie znaleziono profilu operatora.'
      using errcode = '42501';
  end if;

  actor_role := lower(btrim(actor_profile.role::text));

  if coalesce(actor_role, '') not in ('admin', 'pracownik') then
    raise exception 'Brak uprawnień do aktualizacji danych kontaktowych.'
      using errcode = '42501';
  end if;

  if p_target_user_id is null then
    raise exception 'Identyfikator profilu docelowego jest wymagany.'
      using errcode = '22023';
  end if;

  if length(normalized_phone) > 32 then
    raise exception 'Numer telefonu jest zbyt długi.'
      using errcode = '22023';
  end if;

  if length(normalized_postal_code) > 20 then
    raise exception 'Kod pocztowy jest zbyt długi.'
      using errcode = '22023';
  end if;

  if length(normalized_city) > 120 then
    raise exception 'Nazwa miasta jest zbyt długa.'
      using errcode = '22023';
  end if;

  if length(normalized_street) > 160 then
    raise exception 'Nazwa ulicy jest zbyt długa.'
      using errcode = '22023';
  end if;

  if length(normalized_house_number) > 30 then
    raise exception 'Numer domu jest zbyt długi.'
      using errcode = '22023';
  end if;

  if length(normalized_apartment_number) > 30 then
    raise exception 'Numer mieszkania jest zbyt długi.'
      using errcode = '22023';
  end if;

  select profile.*
  into target_profile
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    raise exception 'Nie znaleziono profilu docelowego.'
      using errcode = 'P0002';
  end if;

  target_role := lower(btrim(target_profile.role::text));

  if actor_role = 'pracownik'
    and p_target_user_id = actor_user_id
  then
    raise exception 'Pracownik nie może aktualizować własnego profilu w tym module.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik'
    and coalesce(target_role, '') = 'admin'
  then
    raise exception 'Pracownik nie może aktualizować profilu administratora.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik'
    and coalesce(target_role, '') <> 'user'
  then
    raise exception 'Pracownik może aktualizować dane kontaktowe wyłącznie klienta.'
      using errcode = '42501';
  end if;

  if target_profile.phone is distinct from normalized_phone then
    changed_fields := array_append(changed_fields, 'phone');
  end if;

  if target_profile.postal_code is distinct from normalized_postal_code then
    changed_fields := array_append(changed_fields, 'postal_code');
  end if;

  if target_profile.city is distinct from normalized_city then
    changed_fields := array_append(changed_fields, 'city');
  end if;

  if target_profile.street is distinct from normalized_street then
    changed_fields := array_append(changed_fields, 'street');
  end if;

  if target_profile.house_number is distinct from normalized_house_number then
    changed_fields := array_append(changed_fields, 'house_number');
  end if;

  if target_profile.apartment_number is distinct from normalized_apartment_number then
    changed_fields := array_append(changed_fields, 'apartment_number');
  end if;

  if cardinality(changed_fields) = 0 then
    return jsonb_build_object(
      'user_id', target_profile.user_id,
      'phone', target_profile.phone,
      'postal_code', target_profile.postal_code,
      'city', target_profile.city,
      'street', target_profile.street,
      'house_number', target_profile.house_number,
      'apartment_number', target_profile.apartment_number,
      'updated_at', target_profile.updated_at,
      'changed_fields', to_jsonb(changed_fields)
    );
  end if;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_actor',
      actor_user_id::text,
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_target',
      p_target_user_id::text,
      true
    );
  end if;

  update public.profiles as profile
  set
    phone = normalized_phone,
    postal_code = normalized_postal_code,
    city = normalized_city,
    street = normalized_street,
    house_number = normalized_house_number,
    apartment_number = normalized_apartment_number,
    updated_at = action_time
  where profile.user_id = p_target_user_id
  returning profile.* into updated_profile;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_actor',
      '',
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_target',
      '',
      true
    );
  end if;

  actor_name := coalesce(
    nullif(btrim(concat_ws(' ', actor_profile.first_name, actor_profile.last_name)), ''),
    nullif(btrim(actor_profile.full_name), ''),
    nullif(btrim(actor_profile.email), ''),
    'Nieznany użytkownik'
  );

  target_name := coalesce(
    nullif(btrim(concat_ws(' ', target_profile.first_name, target_profile.last_name)), ''),
    nullif(btrim(target_profile.full_name), ''),
    nullif(btrim(target_profile.email), ''),
    'Nieznany profil'
  );

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
    actor_user_id,
    actor_name,
    actor_role,
    'profile_contact_details_updated',
    'profile',
    target_profile.user_id,
    target_name,
    jsonb_build_object(
      'changed_fields', to_jsonb(changed_fields),
      'changed_field_count', cardinality(changed_fields),
      'operator_role', actor_role
    )
  );

  return jsonb_build_object(
    'user_id', updated_profile.user_id,
    'phone', updated_profile.phone,
    'postal_code', updated_profile.postal_code,
    'city', updated_profile.city,
    'street', updated_profile.street,
    'house_number', updated_profile.house_number,
    'apartment_number', updated_profile.apartment_number,
    'updated_at', updated_profile.updated_at,
    'changed_fields', to_jsonb(changed_fields)
  );
end;
$$;


ALTER FUNCTION "public"."update_profile_contact_details"("p_target_user_id" "uuid", "p_phone" "text", "p_postal_code" "text", "p_city" "text", "p_street" "text", "p_house_number" "text", "p_apartment_number" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_profile_contact_details"("p_target_user_id" "uuid", "p_phone" "text", "p_postal_code" "text", "p_city" "text", "p_street" "text", "p_house_number" "text", "p_apartment_number" "text") IS 'Kontrolowana, transakcyjna aktualizacja danych kontaktowych klienta przez administratora lub pracownika wraz z wpisem audit log.';



CREATE OR REPLACE FUNCTION "public"."update_profile_identity"("p_target_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_profile public.profiles%rowtype;
  updated_profile public.profiles%rowtype;
  actor_role text;
  actor_name text;
  target_name text;
  normalized_first_name text := nullif(
    regexp_replace(btrim(p_first_name), '[[:space:]]+', ' ', 'g'),
    ''
  );
  normalized_last_name text := nullif(
    regexp_replace(btrim(p_last_name), '[[:space:]]+', ' ', 'g'),
    ''
  );
  normalized_full_name text;
  action_time timestamptz := now();
  changed_fields text[] := array[]::text[];
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  select profile.*
  into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found then
    raise exception 'Nie znaleziono profilu operatora.'
      using errcode = '42501';
  end if;

  actor_role := actor_profile.role::text;

  if coalesce(actor_role, '') <> 'admin' then
    raise exception 'Brak uprawnień do korekty imienia i nazwiska.'
      using errcode = '42501';
  end if;

  if p_target_user_id is null then
    raise exception 'Identyfikator profilu docelowego jest wymagany.'
      using errcode = '22023';
  end if;

  if normalized_first_name is null then
    raise exception 'Imię jest wymagane.'
      using errcode = '22023';
  end if;

  if normalized_last_name is null then
    raise exception 'Nazwisko jest wymagane.'
      using errcode = '22023';
  end if;

  if char_length(normalized_first_name) > 120 then
    raise exception 'Imię jest zbyt długie.'
      using errcode = '22023';
  end if;

  if char_length(normalized_last_name) > 160 then
    raise exception 'Nazwisko jest zbyt długie.'
      using errcode = '22023';
  end if;

  normalized_full_name := concat_ws(
    ' ',
    normalized_first_name,
    normalized_last_name
  );

  select profile.*
  into target_profile
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    raise exception 'Nie znaleziono profilu docelowego.'
      using errcode = 'P0002';
  end if;

  if target_profile.first_name is distinct from normalized_first_name then
    changed_fields := array_append(changed_fields, 'first_name');
  end if;

  if target_profile.last_name is distinct from normalized_last_name then
    changed_fields := array_append(changed_fields, 'last_name');
  end if;

  if target_profile.full_name is distinct from normalized_full_name then
    changed_fields := array_append(changed_fields, 'full_name');
  end if;

  if cardinality(changed_fields) = 0 then
    return jsonb_build_object(
      'user_id', target_profile.user_id,
      'first_name', target_profile.first_name,
      'last_name', target_profile.last_name,
      'full_name', target_profile.full_name,
      'updated_at', target_profile.updated_at,
      'changed_fields', to_jsonb(changed_fields)
    );
  end if;

  perform pg_catalog.set_config(
    'csk.profile_identity_rpc_actor',
    actor_user_id::text,
    true
  );

  perform pg_catalog.set_config(
    'csk.profile_identity_rpc_target',
    p_target_user_id::text,
    true
  );

  update public.profiles as profile
  set
    first_name = normalized_first_name,
    last_name = normalized_last_name,
    full_name = normalized_full_name,
    updated_at = action_time
  where profile.user_id = p_target_user_id
  returning profile.* into updated_profile;

  perform pg_catalog.set_config(
    'csk.profile_identity_rpc_actor',
    '',
    true
  );

  perform pg_catalog.set_config(
    'csk.profile_identity_rpc_target',
    '',
    true
  );

  actor_name := coalesce(
    nullif(btrim(concat_ws(' ', actor_profile.first_name, actor_profile.last_name)), ''),
    nullif(btrim(actor_profile.full_name), ''),
    nullif(btrim(actor_profile.email), ''),
    'Nieznany użytkownik'
  );

  target_name := coalesce(
    nullif(btrim(concat_ws(' ', updated_profile.first_name, updated_profile.last_name)), ''),
    nullif(btrim(updated_profile.full_name), ''),
    nullif(btrim(updated_profile.email), ''),
    'Nieznany profil'
  );

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
    actor_user_id,
    actor_name,
    actor_role,
    'profile_identity_updated',
    'profile',
    updated_profile.user_id,
    target_name,
    jsonb_build_object(
      'changed_fields', to_jsonb(changed_fields),
      'changed_field_count', cardinality(changed_fields),
      'operator_role', actor_role
    )
  );

  return jsonb_build_object(
    'user_id', updated_profile.user_id,
    'first_name', updated_profile.first_name,
    'last_name', updated_profile.last_name,
    'full_name', updated_profile.full_name,
    'updated_at', updated_profile.updated_at,
    'changed_fields', to_jsonb(changed_fields)
  );
end;
$$;


ALTER FUNCTION "public"."update_profile_identity"("p_target_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_profile_identity"("p_target_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") IS 'Kontrolowana, transakcyjna korekta imienia i nazwiska użytkownika przez administratora wraz z wpisem audit log.';



CREATE OR REPLACE FUNCTION "public"."update_profile_verification"("p_target_user_id" "uuid", "p_action" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_profile public.profiles%rowtype;
  updated_profile public.profiles%rowtype;
  normalized_action text := lower(btrim(p_action));
  normalized_note text := nullif(btrim(p_note), '');
  actor_role text;
  audit_action text;
  actor_name text;
  target_name text;
  action_time timestamptz := now();
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  select profile.*
  into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found then
    raise exception 'Nie znaleziono profilu operatora.'
      using errcode = '42501';
  end if;

  actor_role := lower(btrim(actor_profile.role::text));

  if coalesce(actor_role, '') not in ('admin', 'pracownik') then
    raise exception 'Brak uprawnień do weryfikacji profili.'
      using errcode = '42501';
  end if;

  if length(normalized_note) > 2000 then
    raise exception 'Notatka weryfikacyjna jest zbyt długa.'
      using errcode = '22023';
  end if;

  if p_target_user_id is null then
    raise exception 'Identyfikator profilu docelowego jest wymagany.'
      using errcode = '22023';
  end if;

  if normalized_action is null
    or normalized_action not in ('verify', 'mark_pending', 'reject')
  then
    raise exception 'Nieprawidłowe działanie weryfikacyjne.'
      using errcode = '22023';
  end if;

  select profile.*
  into target_profile
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    raise exception 'Nie znaleziono profilu docelowego.'
      using errcode = 'P0002';
  end if;

  if actor_role = 'pracownik'
    and p_target_user_id = actor_user_id
  then
    raise exception 'Pracownik nie może weryfikować własnego konta.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik'
    and lower(btrim(target_profile.role::text)) = 'admin'
  then
    raise exception 'Pracownik nie może zmieniać weryfikacji administratora.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_actor',
      actor_user_id::text,
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_target',
      p_target_user_id::text,
      true
    );
  end if;

  update public.profiles as profile
  set
    verification_status = case normalized_action
      when 'verify' then 'verified'
      when 'mark_pending' then 'pending'
      when 'reject' then 'rejected'
    end,
    permissions_verified = normalized_action = 'verify',
    permissions_verified_at = case
      when normalized_action = 'verify' then action_time
      else null
    end,
    permissions_verified_by = case
      when normalized_action = 'verify' then actor_profile.id
      else null
    end,
    permissions_verification_note = case normalized_action
      when 'verify' then coalesce(
        normalized_note,
        'Sprawdzono uprawnienia klienta podczas pierwszej wizyty. Dokumenty okazane do wglądu, bez kopiowania i zapisywania numerów. Klient zapoznany z regulaminem i zasadami bezpieczeństwa. Konto zweryfikowane.'
      )
      when 'mark_pending' then coalesce(
        normalized_note,
        'Nie zakończono pełnej weryfikacji uprawnień. Klient poinformowany o konieczności okazania wymaganych dokumentów przy kolejnej wizycie. Konto pozostaje niezweryfikowane.'
      )
      when 'reject' then coalesce(
        normalized_note,
        'Weryfikacja konta została odrzucona. Wymagane dane lub dokumenty nie zostały potwierdzone.'
      )
    end,
    verified_at = case
      when normalized_action = 'verify' then action_time
      else null
    end,
    verified_by = case
      when normalized_action = 'verify' then actor_profile.id
      else null
    end,
    unverified_at = case
      when normalized_action = 'verify' then null
      else action_time
    end,
    unverified_by = case
      when normalized_action = 'verify' then null
      else actor_profile.id::text
    end,
    updated_at = action_time
  where profile.user_id = p_target_user_id
  returning profile.* into updated_profile;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_actor',
      '',
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_target',
      '',
      true
    );
  end if;

  audit_action := case normalized_action
    when 'verify' then 'profile_verification_verified'
    when 'mark_pending' then 'profile_verification_marked_pending'
    when 'reject' then 'profile_verification_rejected'
  end;

  actor_name := coalesce(
    nullif(btrim(concat_ws(' ', actor_profile.first_name, actor_profile.last_name)), ''),
    nullif(btrim(actor_profile.full_name), ''),
    nullif(btrim(actor_profile.email), ''),
    'Nieznany użytkownik'
  );

  target_name := coalesce(
    nullif(btrim(concat_ws(' ', target_profile.first_name, target_profile.last_name)), ''),
    nullif(btrim(target_profile.full_name), ''),
    nullif(btrim(target_profile.email), ''),
    'Nieznany profil'
  );

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
    actor_user_id,
    actor_name,
    actor_role,
    audit_action,
    'profile',
    target_profile.user_id,
    target_name,
    jsonb_build_object(
      'previous_verification_status', target_profile.verification_status,
      'new_verification_status', updated_profile.verification_status,
      'previous_permissions_verified', target_profile.permissions_verified,
      'new_permissions_verified', updated_profile.permissions_verified,
      'note_changed', target_profile.permissions_verification_note
        is distinct from updated_profile.permissions_verification_note,
      'operator_role', actor_role
    )
  );

  return jsonb_build_object(
    'user_id', updated_profile.user_id,
    'verification_status', updated_profile.verification_status,
    'permissions_verified', updated_profile.permissions_verified,
    'permissions_verified_at', updated_profile.permissions_verified_at,
    'permissions_verified_by', updated_profile.permissions_verified_by,
    'permissions_verification_note', updated_profile.permissions_verification_note,
    'verified_at', updated_profile.verified_at,
    'verified_by', updated_profile.verified_by,
    'unverified_at', updated_profile.unverified_at,
    'unverified_by', updated_profile.unverified_by,
    'updated_at', updated_profile.updated_at
  );
end;
$$;


ALTER FUNCTION "public"."update_profile_verification"("p_target_user_id" "uuid", "p_action" "text", "p_note" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_profile_verification"("p_target_user_id" "uuid", "p_action" "text", "p_note" "text") IS 'Kontrolowana, transakcyjna weryfikacja profilu przez administratora lub pracownika wraz z wpisem audit log.';



CREATE OR REPLACE FUNCTION "public"."update_reservation_admin_note"("p_reservation_id" "uuid", "p_admin_note" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_profile public.profiles%rowtype;
  v_target public.reservations%rowtype;
  v_actor_role text;
  v_actor_name text;
  v_admin_note text := case
    when p_admin_note is null then null
    when pg_catalog.btrim(p_admin_note) = '' then null
    else p_admin_note
  end;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  if p_reservation_id is null or pg_catalog.char_length(v_admin_note) > 4000 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input'
    );
  end if;

  select profile.*
  into v_actor_profile
  from public.profiles as profile
  where profile.user_id = v_actor_user_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor_profile.role::text));
  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  select reservation.*
  into v_target
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_not_found'
    );
  end if;

  if v_target.admin_note is not distinct from v_admin_note then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'already_set',
      'reservation_id', v_target.id
    );
  end if;

  update public.reservations as reservation
  set admin_note = v_admin_note
  where reservation.id = v_target.id;

  v_actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(v_actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(v_actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(v_actor_profile.full_name), ''),
    'Operator'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_user_id, v_actor_name, v_actor_role,
    'RESERVATION_ADMIN_NOTE_CHANGED',
    'reservation', v_target.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'operator_role', v_actor_role,
      'previous_note_present', v_target.admin_note is not null,
      'new_note_present', v_admin_note is not null,
      'changed_at', pg_catalog.transaction_timestamp()
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'reservation_id', v_target.id,
    'admin_note_is_null', v_admin_note is null
  );
end;
$$;


ALTER FUNCTION "public"."update_reservation_admin_note"("p_reservation_id" "uuid", "p_admin_note" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_reservation_admin_note"("p_reservation_id" "uuid", "p_admin_note" "text") IS 'Atomowo zmienia wyłącznie notatkę administracyjną rezerwacji z row lockiem i auditem bez treści notatki w audicie.';



CREATE OR REPLACE FUNCTION "public"."update_reservation_attendance"("p_reservation_id" "uuid", "p_action" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_profile public.profiles%rowtype;
  v_target public.reservations%rowtype;
  v_updated public.reservations%rowtype;
  v_actor_role text;
  v_actor_name text;
  v_action text := pg_catalog.lower(pg_catalog.btrim(p_action));
  v_now timestamptz;
  v_audit_action text;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  if p_reservation_id is null or coalesce(v_action, '') not in (
    'start', 'reset', 'complete', 'no_show'
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input'
    );
  end if;

  select profile.*
  into v_actor_profile
  from public.profiles as profile
  where profile.user_id = v_actor_user_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor_profile.role::text));

  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  select reservation.*
  into v_target
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_not_found'
    );
  end if;

  if not (
    (
      v_target.reservation_status = 'confirmed'
      and (
        (
          coalesce(v_target.attendance_status, 'planned') = 'planned'
          and v_target.checked_in_at is null
          and v_target.completed_at is null
        )
        or (
          v_target.attendance_status = 'present'
          and v_target.checked_in_at is not null
          and v_target.completed_at is null
        )
      )
    )
    or (
      v_target.reservation_status = 'completed'
      and v_target.attendance_status = 'completed'
      and v_target.checked_in_at is not null
      and v_target.completed_at is not null
      and v_target.completed_at >= v_target.checked_in_at
    )
    or (
      v_target.reservation_status = 'no_show'
      and v_target.attendance_status = 'no_show'
      and v_target.checked_in_at is null
      and v_target.completed_at is null
    )
    or (
      v_target.reservation_status in (
        'cancelled', 'canceled', 'cancelled_by_admin', 'cancelled_by_user'
      )
      and coalesce(v_target.attendance_status, 'planned') = 'planned'
      and v_target.checked_in_at is null
      and v_target.completed_at is null
    )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_state',
      'reservation_id', v_target.id, 'action', v_action
    );
  end if;

  if v_action = 'start' then
    if v_target.reservation_status = 'confirmed'
       and v_target.attendance_status = 'present' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_started',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', v_target.attendance_status,
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or coalesce(v_target.attendance_status, 'planned') <> 'planned' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'RESERVATION_STARTED';
  elsif v_action = 'reset' then
    if v_target.reservation_status = 'confirmed'
       and coalesce(v_target.attendance_status, 'planned') = 'planned' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_planned',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', coalesce(v_target.attendance_status, 'planned'),
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or v_target.attendance_status <> 'present' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'RESERVATION_ATTENDANCE_RESET';
  elsif v_action = 'complete' then
    if v_target.reservation_status = 'completed'
       and v_target.attendance_status = 'completed' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_completed',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', v_target.attendance_status,
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or v_target.attendance_status <> 'present'
       or v_target.checked_in_at is null then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'CHECK_IN_COMPLETED';
  else
    if v_target.reservation_status = 'no_show'
       and v_target.attendance_status = 'no_show' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_no_show',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', v_target.attendance_status,
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or coalesce(v_target.attendance_status, 'planned') <> 'planned' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'RESERVATION_NO_SHOW';
  end if;

  v_now := pg_catalog.transaction_timestamp();

  update public.reservations as reservation
  set reservation_status = case v_action
        when 'complete' then 'completed'
        when 'no_show' then 'no_show'
        else 'confirmed'
      end,
      attendance_status = case v_action
        when 'start' then 'present'
        when 'reset' then 'planned'
        when 'complete' then 'completed'
        else 'no_show'
      end,
      checked_in_at = case v_action
        when 'start' then v_now
        when 'reset' then null
        when 'complete' then v_target.checked_in_at
        else null
      end,
      completed_at = case v_action
        when 'complete' then v_now
        else null
      end
  where reservation.id = v_target.id
  returning reservation.* into v_updated;

  v_actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(v_actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(v_actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(v_actor_profile.full_name), ''),
    'Operator'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_user_id, v_actor_name, v_actor_role, v_audit_action,
    'reservation', v_target.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'action', v_action,
      'operator_role', v_actor_role,
      'previous_reservation_status', v_target.reservation_status,
      'new_reservation_status', v_updated.reservation_status,
      'previous_attendance_status', v_target.attendance_status,
      'new_attendance_status', v_updated.attendance_status,
      'checked_in_at_changed',
        v_target.checked_in_at is distinct from v_updated.checked_in_at,
      'completed_at_changed',
        v_target.completed_at is distinct from v_updated.completed_at,
      'changed_at', v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', case v_action
      when 'start' then 'started'
      when 'reset' then 'reset'
      when 'complete' then 'completed'
      else 'no_show'
    end,
    'reservation_id', v_updated.id, 'action', v_action,
    'reservation_status', v_updated.reservation_status,
    'attendance_status', v_updated.attendance_status,
    'payment_status', v_updated.payment_status,
    'checked_in_at', v_updated.checked_in_at,
    'completed_at', v_updated.completed_at
  );
end;
$$;


ALTER FUNCTION "public"."update_reservation_attendance"("p_reservation_id" "uuid", "p_action" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_reservation_attendance"("p_reservation_id" "uuid", "p_action" "text") IS 'Atomowo rozpoczyna, resetuje, kończy lub oznacza no-show wizyty z row lockiem i auditem.';



CREATE OR REPLACE FUNCTION "public"."update_reservation_payment"("p_reservation_id" "uuid", "p_payment_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_profile public.profiles%rowtype;
  v_target public.reservations%rowtype;
  v_updated public.reservations%rowtype;
  v_actor_role text;
  v_actor_name text;
  v_payment_status text := pg_catalog.lower(pg_catalog.btrim(p_payment_status));
  v_now timestamptz;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  if p_reservation_id is null or coalesce(v_payment_status, '') not in (
    'pay_on_site', 'paid', 'paid_on_site', 'unpaid', 'free', 'voucher'
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input'
    );
  end if;

  select profile.*
  into v_actor_profile
  from public.profiles as profile
  where profile.user_id = v_actor_user_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor_profile.role::text));
  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  select reservation.*
  into v_target
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_not_found'
    );
  end if;

  if v_target.payment_status = v_payment_status then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'already_set',
      'reservation_id', v_target.id,
      'payment_status', v_target.payment_status
    );
  end if;

  update public.reservations as reservation
  set payment_status = v_payment_status
  where reservation.id = v_target.id
  returning reservation.* into v_updated;

  v_now := pg_catalog.transaction_timestamp();
  v_actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(v_actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(v_actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(v_actor_profile.full_name), ''),
    'Operator'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_user_id, v_actor_name, v_actor_role,
    'RESERVATION_PAYMENT_STATUS_CHANGED',
    'reservation', v_target.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'operator_role', v_actor_role,
      'previous_payment_status', v_target.payment_status,
      'new_payment_status', v_updated.payment_status,
      'changed_at', v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'reservation_id', v_updated.id,
    'reservation_status', v_updated.reservation_status,
    'attendance_status', v_updated.attendance_status,
    'payment_status', v_updated.payment_status,
    'checked_in_at', v_updated.checked_in_at,
    'completed_at', v_updated.completed_at
  );
end;
$$;


ALTER FUNCTION "public"."update_reservation_payment"("p_reservation_id" "uuid", "p_payment_status" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_reservation_payment"("p_reservation_id" "uuid", "p_payment_status" "text") IS 'Atomowo zmienia wyłącznie status płatności rezerwacji z row lockiem i auditem.';



CREATE OR REPLACE FUNCTION "public"."validate_lane_booking_rule_capacity"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_max_shooters integer;
begin
  select lane.max_shooters
  into v_max_shooters
  from public.shooting_lanes as lane
  where lane.id = new.lane_id
  for update;

  if not found then
    raise exception 'Shooting lane does not exist.'
      using errcode = '23503',
            constraint = 'lane_booking_rules_lane_id_fkey';
  end if;

  if new.max_people_online > v_max_shooters then
    raise exception 'Online capacity exceeds physical lane capacity.'
      using errcode = '23514',
            constraint = 'lane_booking_rules_capacity_check';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."validate_lane_booking_rule_capacity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_shooting_lane_capacity_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_max_people_online integer;
begin
  select rule.max_people_online
  into v_max_people_online
  from public.lane_booking_rules as rule
  where rule.lane_id = new.id
  for update;

  if found and v_max_people_online > new.max_shooters then
    raise exception 'Physical lane capacity cannot be lower than online capacity.'
      using errcode = '23514',
            constraint = 'lane_booking_rules_capacity_check';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."validate_shooting_lane_capacity_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_shooting_lane_hierarchy"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_parent_kind text;
  v_parent_parent_id uuid;
begin
  if new.resource_kind = 'position' then
    if new.parent_lane_id is null or new.parent_lane_id = new.id then
      raise exception 'Position requires a different lane parent.'
        using errcode = '23514',
              constraint = 'shooting_lanes_resource_parent_check';
    end if;

    select parent.resource_kind, parent.parent_lane_id
    into v_parent_kind, v_parent_parent_id
    from public.shooting_lanes as parent
    where parent.id = new.parent_lane_id
    for update;

    if not found then
      raise exception 'Parent shooting lane does not exist.'
        using errcode = '23503',
              constraint = 'shooting_lanes_parent_lane_id_fkey';
    end if;

    if v_parent_kind <> 'lane' or v_parent_parent_id is not null then
      raise exception 'Position parent must be a top-level lane.'
        using errcode = '23514',
              constraint = 'shooting_lanes_parent_structure_check';
    end if;

    if exists (
      select 1
      from public.shooting_lanes as child
      where child.parent_lane_id = new.id
        and child.id <> new.id
    ) then
      raise exception 'A lane with children cannot become a position.'
        using errcode = '23514',
              constraint = 'shooting_lanes_parent_structure_check';
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."validate_shooting_lane_hierarchy"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "actor_user_id" "uuid",
    "actor_name" "text",
    "actor_role" "text",
    "action" "text" NOT NULL,
    "target_type" "text",
    "target_id" "uuid",
    "target_name" "text",
    "details" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."confirmation_email_rate_limits" (
    "scope_type" "text" NOT NULL,
    "scope_key" "text" NOT NULL,
    "request_timestamps" timestamp with time zone[] DEFAULT '{}'::timestamp with time zone[] NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "confirmation_email_rate_limits_scope_key_check" CHECK (((("scope_type" = 'user'::"text") AND ("scope_key" ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::"text")) OR (("scope_type" = 'ip'::"text") AND ("scope_key" ~ '^[0-9a-f]{64}$'::"text")))),
    CONSTRAINT "confirmation_email_rate_limits_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['user'::"text", 'ip'::"text"])))
);


ALTER TABLE "public"."confirmation_email_rate_limits" OWNER TO "postgres";


COMMENT ON TABLE "public"."confirmation_email_rate_limits" IS 'Active sliding-window timestamps for confirmation email user and HMAC IP scopes.';



COMMENT ON COLUMN "public"."confirmation_email_rate_limits"."scope_key" IS 'User UUID or lowercase HMAC-SHA256 IP digest; never a raw IP address.';



CREATE TABLE IF NOT EXISTS "public"."email_deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message_type" "text" NOT NULL,
    "record_id" "uuid" NOT NULL,
    "recipient_user_id" "uuid" NOT NULL,
    "sent_at" timestamp with time zone,
    "provider_message_id" "text",
    "claim_id" "uuid",
    "claim_expires_at" timestamp with time zone,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "attempt_window_started_at" timestamp with time zone,
    "last_attempt_at" timestamp with time zone,
    "last_error_code" "text",
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "email_deliveries_attempt_count_check" CHECK (("attempt_count" >= 0)),
    CONSTRAINT "email_deliveries_claim_pair_check" CHECK (((("claim_id" IS NULL) AND ("claim_expires_at" IS NULL)) OR (("claim_id" IS NOT NULL) AND ("claim_expires_at" IS NOT NULL)))),
    CONSTRAINT "email_deliveries_last_error_code_length_check" CHECK ((("last_error_code" IS NULL) OR ("char_length"("last_error_code") <= 128))),
    CONSTRAINT "email_deliveries_message_type_check" CHECK (("message_type" = ANY (ARRAY['event_registration_confirmation'::"text", 'reservation_confirmation'::"text"]))),
    CONSTRAINT "email_deliveries_provider_message_id_length_check" CHECK ((("provider_message_id" IS NULL) OR ("char_length"("provider_message_id") <= 256)))
);


ALTER TABLE "public"."email_deliveries" OWNER TO "postgres";


COMMENT ON TABLE "public"."email_deliveries" IS 'Technical delivery state for idempotent confirmation emails; contains no message content or recipient PII.';



COMMENT ON COLUMN "public"."email_deliveries"."message_type" IS 'Closed technical category of the confirmation email.';



COMMENT ON COLUMN "public"."email_deliveries"."record_id" IS 'Identifier of the source reservation or event registration.';



COMMENT ON COLUMN "public"."email_deliveries"."recipient_user_id" IS 'Authenticated owner of the source record; no recipient address is stored.';



COMMENT ON COLUMN "public"."email_deliveries"."claim_id" IS 'Opaque identifier of the currently leased delivery attempt.';



COMMENT ON COLUMN "public"."email_deliveries"."last_error_code" IS 'Bounded technical error code without provider message or personal data.';



CREATE TABLE IF NOT EXISTS "public"."event_lanes" (
    "event_id" "uuid" NOT NULL,
    "lane_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL
);


ALTER TABLE "public"."event_lanes" OWNER TO "postgres";


COMMENT ON TABLE "public"."event_lanes" IS 'Relacja eventów z zajmowanymi osiami; brak rekordów oznacza event globalny.';



COMMENT ON COLUMN "public"."event_lanes"."event_id" IS 'Event zajmujący wskazaną oś.';



COMMENT ON COLUMN "public"."event_lanes"."lane_id" IS 'Oś zajmowana przez event.';



COMMENT ON COLUMN "public"."event_lanes"."created_at" IS 'Techniczny czas utworzenia przypisania eventu do osi.';



CREATE TABLE IF NOT EXISTS "public"."event_registrations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "user_id" "uuid",
    "customer_name" "text" NOT NULL,
    "customer_email" "text" NOT NULL,
    "customer_phone" "text" NOT NULL,
    "registration_status" "text" DEFAULT 'registered'::"text" NOT NULL,
    "payment_status" "text" DEFAULT 'pay_on_site'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "promotion_token" "text",
    "promotion_token_expires_at" timestamp with time zone,
    "promotion_email_sent_at" timestamp with time zone,
    "promotion_confirmed_at" timestamp with time zone,
    "promotion_claim_id" "uuid",
    "promotion_claim_expires_at" timestamp with time zone,
    "promotion_attempt_count" integer DEFAULT 0 NOT NULL,
    "promotion_last_attempt_at" timestamp with time zone,
    "promotion_last_error_code" "text",
    CONSTRAINT "event_registrations_promotion_attempt_count_check" CHECK (("promotion_attempt_count" >= 0)),
    CONSTRAINT "event_registrations_promotion_claim_pair_check" CHECK (((("promotion_claim_id" IS NULL) AND ("promotion_claim_expires_at" IS NULL)) OR (("promotion_claim_id" IS NOT NULL) AND ("promotion_claim_expires_at" IS NOT NULL)))),
    CONSTRAINT "event_registrations_promotion_claim_timing_check" CHECK ((("promotion_claim_id" IS NULL) OR (("promotion_last_attempt_at" IS NOT NULL) AND ("promotion_claim_expires_at" > "promotion_last_attempt_at")))),
    CONSTRAINT "event_registrations_promotion_confirmed_token_check" CHECK ((("promotion_confirmed_at" IS NULL) OR ("promotion_token" IS NOT NULL))),
    CONSTRAINT "event_registrations_promotion_sent_token_check" CHECK ((("promotion_email_sent_at" IS NULL) OR ("promotion_token" IS NOT NULL))),
    CONSTRAINT "event_registrations_promotion_token_expiry_check" CHECK ((("promotion_token" IS NOT NULL) OR ("promotion_token_expires_at" IS NULL)))
);


ALTER TABLE "public"."event_registrations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."event_registrations"."promotion_claim_id" IS 'Identyfikator procesu, który atomowo przejął próbę wysyłki promocji.';



COMMENT ON COLUMN "public"."event_registrations"."promotion_claim_expires_at" IS 'Koniec dzierżawy claimu, po którym inny proces może bezpiecznie przejąć próbę.';



COMMENT ON COLUMN "public"."event_registrations"."promotion_attempt_count" IS 'Liczba prób przygotowania wysyłki promocji.';



COMMENT ON COLUMN "public"."event_registrations"."promotion_last_attempt_at" IS 'Moment ostatniego założenia claimu promocji.';



COMMENT ON COLUMN "public"."event_registrations"."promotion_last_error_code" IS 'Wyłącznie techniczny kod ostatniego błędu, bez danych osobowych i komunikatu dostawcy.';



CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "event_date" "date" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "location" "text",
    "price" numeric DEFAULT 0 NOT NULL,
    "max_participants" integer DEFAULT 10 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "events_time_range_check" CHECK (("end_time" > "start_time"))
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lane_blocks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lane_id" "uuid" NOT NULL,
    "block_date" "date" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "lane_blocks_time_range_check" CHECK (("end_time" > "start_time"))
);


ALTER TABLE "public"."lane_blocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lane_booking_durations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lane_id" "uuid" NOT NULL,
    "duration_minutes" integer NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "lane_booking_durations_display_order_check" CHECK (("display_order" >= 0)),
    CONSTRAINT "lane_booking_durations_duration_check" CHECK ((("duration_minutes" > 0) AND ("duration_minutes" <= 1440)))
);


ALTER TABLE "public"."lane_booking_durations" OWNER TO "postgres";


COMMENT ON TABLE "public"."lane_booking_durations" IS 'Konfigurowalne długości rezerwacji dostępne dla poszczególnych osi.';



CREATE TABLE IF NOT EXISTS "public"."lane_booking_family_configuration_versions" (
    "root_lane_id" "uuid" NOT NULL,
    "configuration_version" bigint DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "lane_booking_family_configuration_versions_version_check" CHECK (("configuration_version" > 0))
);


ALTER TABLE "public"."lane_booking_family_configuration_versions" OWNER TO "postgres";


COMMENT ON TABLE "public"."lane_booking_family_configuration_versions" IS 'Technical optimistic-concurrency version for each top-level shooting-lane family.';



COMMENT ON COLUMN "public"."lane_booking_family_configuration_versions"."root_lane_id" IS 'Top-level lane identifying the complete configuration family.';



COMMENT ON COLUMN "public"."lane_booking_family_configuration_versions"."configuration_version" IS 'Monotonic family configuration version; incremented once per successful changed V2 write.';



CREATE TABLE IF NOT EXISTS "public"."lane_booking_rules" (
    "lane_id" "uuid" NOT NULL,
    "online_bookable" boolean DEFAULT false NOT NULL,
    "max_people_online" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "lane_booking_rules_max_people_online_check" CHECK (("max_people_online" >= 1))
);


ALTER TABLE "public"."lane_booking_rules" OWNER TO "postgres";


COMMENT ON TABLE "public"."lane_booking_rules" IS 'Public booking publication and online capacity for each lane or position resource.';



COMMENT ON COLUMN "public"."lane_booking_rules"."online_bookable" IS 'Whether the resource is published for public online booking.';



COMMENT ON COLUMN "public"."lane_booking_rules"."max_people_online" IS 'Maximum people accepted online; never greater than shooting_lanes.max_shooters.';



CREATE TABLE IF NOT EXISTS "public"."lane_pricing_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lane_id" "uuid" NOT NULL,
    "day_group" "text" NOT NULL,
    "min_shooters" integer NOT NULL,
    "max_shooters" integer NOT NULL,
    "label" "text" NOT NULL,
    "hourly_price" numeric(12,2) NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "lane_pricing_rules_day_group_check" CHECK (("day_group" = ANY (ARRAY['mon_thu'::"text", 'fri_sun'::"text"]))),
    CONSTRAINT "lane_pricing_rules_display_order_check" CHECK (("display_order" >= 0)),
    CONSTRAINT "lane_pricing_rules_hourly_price_check" CHECK (("hourly_price" >= (0)::numeric)),
    CONSTRAINT "lane_pricing_rules_label_check" CHECK (("btrim"("label") <> ''::"text")),
    CONSTRAINT "lane_pricing_rules_min_shooters_check" CHECK (("min_shooters" >= 1)),
    CONSTRAINT "lane_pricing_rules_shooters_range_check" CHECK (("max_shooters" >= "min_shooters"))
);


ALTER TABLE "public"."lane_pricing_rules" OWNER TO "postgres";


COMMENT ON TABLE "public"."lane_pricing_rules" IS 'Aktywne i historyczne progi cenowe osi zależne od grupy dni i liczby strzelców.';



COMMENT ON COLUMN "public"."lane_pricing_rules"."day_group" IS 'Grupa dni lokalnego kalendarza: mon_thu albo fri_sun.';



COMMENT ON COLUMN "public"."lane_pricing_rules"."label" IS 'Snapshot tej etykiety jest zapisywany w reservations przy tworzeniu rezerwacji.';



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text",
    "phone" "text",
    "postal_code" "text",
    "city" "text",
    "street" "text",
    "house_number" "text",
    "apartment_number" "text",
    "weapon_permit_number" "text",
    "weapon_permit_type" "text",
    "has_range_officer" boolean DEFAULT false,
    "range_officer_number" "text",
    "has_instructor" boolean DEFAULT false,
    "instructor_number" "text",
    "verification_status" "text" DEFAULT 'niezweryfikowane'::"text",
    "verified_at" timestamp with time zone,
    "verified_by" "uuid",
    "admin_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "verification_note" "text",
    "unverified_at" timestamp with time zone,
    "unverified_by" "text",
    "email" "text",
    "role" "text" DEFAULT 'user'::"text" NOT NULL,
    "weapon_permit_issuer" "text",
    "permission_sport" boolean DEFAULT false NOT NULL,
    "permission_collector" boolean DEFAULT false NOT NULL,
    "permission_hunting" boolean DEFAULT false NOT NULL,
    "permission_training" boolean DEFAULT false NOT NULL,
    "permission_personal_protection" boolean DEFAULT false NOT NULL,
    "permission_other" boolean DEFAULT false NOT NULL,
    "qualification_instructor" boolean DEFAULT false NOT NULL,
    "qualification_range_officer" boolean DEFAULT false NOT NULL,
    "qualification_pzss_license" boolean DEFAULT false NOT NULL,
    "qualification_hunter" boolean DEFAULT false NOT NULL,
    "permissions_verified" boolean DEFAULT false NOT NULL,
    "permissions_verified_at" timestamp with time zone,
    "permissions_verified_by" "uuid",
    "permissions_verification_note" "text",
    "first_name" "text",
    "last_name" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."permission_sport" IS 'Checkbox: klient deklaruje posiadanie uprawnień/pozwolenia sportowego. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."permission_collector" IS 'Checkbox: klient deklaruje posiadanie uprawnień/pozwolenia kolekcjonerskiego. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."permission_hunting" IS 'Checkbox: klient deklaruje posiadanie uprawnień/pozwolenia myśliwskiego. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."permission_training" IS 'Checkbox: klient deklaruje uprawnienia/dopuszczenie związane ze szkoleniem lub użytkowaniem broni. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."permission_personal_protection" IS 'Checkbox: klient deklaruje uprawnienia w zakresie ochrony osobistej. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."permission_other" IS 'Checkbox: inne uprawnienia niewymienione osobno. Szczegóły mogą być sprawdzone przez pracownika podczas wizyty.';



COMMENT ON COLUMN "public"."profiles"."qualification_instructor" IS 'Checkbox: klient deklaruje kwalifikacje instruktorskie. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."qualification_range_officer" IS 'Checkbox: klient deklaruje uprawnienia prowadzącego strzelanie / range officer. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."qualification_pzss_license" IS 'Checkbox: klient deklaruje posiadanie licencji PZSS. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."qualification_hunter" IS 'Checkbox: klient deklaruje status/uprawnienia myśliwego. Bez zapisywania numeru dokumentu.';



COMMENT ON COLUMN "public"."profiles"."permissions_verified" IS 'Czy pracownik sprawdził uprawnienia klienta podczas wizyty.';



COMMENT ON COLUMN "public"."profiles"."permissions_verified_at" IS 'Data i godzina sprawdzenia uprawnień klienta przez obsługę.';



COMMENT ON COLUMN "public"."profiles"."permissions_verified_by" IS 'Profil pracownika/admina, który sprawdził uprawnienia klienta.';



COMMENT ON COLUMN "public"."profiles"."permissions_verification_note" IS 'Krótka notatka pracownika z weryfikacji. Bez numerów dokumentów i bez kopiowania danych z dokumentów.';



CREATE TABLE IF NOT EXISTS "public"."reservations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "lane_id" "uuid" NOT NULL,
    "customer_name" "text" NOT NULL,
    "customer_email" "text" NOT NULL,
    "customer_phone" "text" NOT NULL,
    "reservation_date" "date" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "duration_minutes" integer NOT NULL,
    "price" numeric DEFAULT 0 NOT NULL,
    "reservation_status" "text" DEFAULT 'confirmed'::"text" NOT NULL,
    "payment_status" "text" DEFAULT 'pay_on_site'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "attendance_status" "text" DEFAULT 'planned'::"text",
    "admin_note" "text",
    "checked_in_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "check_in_token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "reservation_note" "text",
    "shooters_count" integer NOT NULL,
    "pricing_rule_id" "uuid" NOT NULL,
    "pricing_day_group_snapshot" "text" NOT NULL,
    "lane_name_snapshot" "text" NOT NULL,
    "pricing_label_snapshot" "text" NOT NULL,
    "price_per_hour_snapshot" numeric(12,2) NOT NULL,
    "total_price" numeric(12,2) NOT NULL,
    "currency_code" character(3) NOT NULL,
    "creation_request_id" "uuid" NOT NULL,
    "booking_period" "tsrange" GENERATED ALWAYS AS ("tsrange"(("reservation_date" + "start_time"), ("reservation_date" + "end_time"), '[)'::"text")) STORED,
    CONSTRAINT "reservations_attendance_status_check" CHECK ((("attendance_status" IS NULL) OR (("attendance_status" = "lower"("btrim"("attendance_status"))) AND ("attendance_status" = ANY (ARRAY['planned'::"text", 'present'::"text", 'completed'::"text", 'no_show'::"text"]))))),
    CONSTRAINT "reservations_currency_code_check" CHECK ((("currency_code")::"text" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "reservations_duration_minutes_check" CHECK ((("duration_minutes" > 0) AND ("duration_minutes" <= 1440))),
    CONSTRAINT "reservations_lane_name_snapshot_check" CHECK (("btrim"("lane_name_snapshot") <> ''::"text")),
    CONSTRAINT "reservations_legacy_price_matches_total_check" CHECK (("price" = "total_price")),
    CONSTRAINT "reservations_operational_state_check" CHECK (((("reservation_status" = 'confirmed'::"text") AND (((COALESCE("attendance_status", 'planned'::"text") = 'planned'::"text") AND ("checked_in_at" IS NULL) AND ("completed_at" IS NULL)) OR (("attendance_status" = 'present'::"text") AND ("checked_in_at" IS NOT NULL) AND ("completed_at" IS NULL)))) OR (("reservation_status" = 'completed'::"text") AND ("attendance_status" = 'completed'::"text") AND ("checked_in_at" IS NOT NULL) AND ("completed_at" IS NOT NULL) AND ("completed_at" >= "checked_in_at")) OR (("reservation_status" = 'no_show'::"text") AND ("attendance_status" = 'no_show'::"text") AND ("checked_in_at" IS NULL) AND ("completed_at" IS NULL)) OR (("reservation_status" = ANY (ARRAY['cancelled'::"text", 'canceled'::"text", 'cancelled_by_admin'::"text", 'cancelled_by_user'::"text"])) AND (COALESCE("attendance_status", 'planned'::"text") = 'planned'::"text") AND ("checked_in_at" IS NULL) AND ("completed_at" IS NULL)))),
    CONSTRAINT "reservations_payment_status_check" CHECK ((("payment_status" = "lower"("btrim"("payment_status"))) AND ("payment_status" = ANY (ARRAY['pay_on_site'::"text", 'paid'::"text", 'paid_on_site'::"text", 'unpaid'::"text", 'free'::"text", 'voucher'::"text"])))),
    CONSTRAINT "reservations_price_per_hour_snapshot_check" CHECK (("price_per_hour_snapshot" >= (0)::numeric)),
    CONSTRAINT "reservations_pricing_day_group_snapshot_check" CHECK (("pricing_day_group_snapshot" = ANY (ARRAY['mon_thu'::"text", 'fri_sun'::"text"]))),
    CONSTRAINT "reservations_pricing_label_snapshot_check" CHECK (("btrim"("pricing_label_snapshot") <> ''::"text")),
    CONSTRAINT "reservations_reservation_status_check" CHECK ((("reservation_status" = "lower"("btrim"("reservation_status"))) AND ("reservation_status" = ANY (ARRAY['confirmed'::"text", 'completed'::"text", 'no_show'::"text", 'cancelled'::"text", 'canceled'::"text", 'cancelled_by_admin'::"text", 'cancelled_by_user'::"text"])))),
    CONSTRAINT "reservations_shooters_count_check" CHECK (("shooters_count" >= 1)),
    CONSTRAINT "reservations_time_range_check" CHECK (("end_time" > "start_time")),
    CONSTRAINT "reservations_total_price_check" CHECK (("total_price" >= (0)::numeric))
);


ALTER TABLE "public"."reservations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."reservations"."price" IS 'LEGACY alias total_price. Nowe RPC zapisuje price i total_price identycznie; kolumna zostanie usunięta po migracji wszystkich odczytów.';



COMMENT ON COLUMN "public"."reservations"."shooters_count" IS 'Liczba strzelców zadeklarowana przy utworzeniu rezerwacji.';



COMMENT ON COLUMN "public"."reservations"."pricing_rule_id" IS 'Reguła cenowa użyta do wyliczenia snapshotów rezerwacji.';



COMMENT ON COLUMN "public"."reservations"."pricing_day_group_snapshot" IS 'Historyczna grupa dni cennika użyta przy utworzeniu rezerwacji.';



COMMENT ON COLUMN "public"."reservations"."lane_name_snapshot" IS 'Historyczna nazwa osi z chwili utworzenia rezerwacji.';



COMMENT ON COLUMN "public"."reservations"."pricing_label_snapshot" IS 'Historyczna etykieta progu cenowego.';



COMMENT ON COLUMN "public"."reservations"."price_per_hour_snapshot" IS 'Historyczna stawka godzinowa użyta do wyliczenia ceny.';



COMMENT ON COLUMN "public"."reservations"."total_price" IS 'Końcowa cena rezerwacji obliczona przez bazę.';



COMMENT ON COLUMN "public"."reservations"."creation_request_id" IS 'Identyfikator idempotencji pojedynczego żądania utworzenia rezerwacji.';



COMMENT ON COLUMN "public"."reservations"."booking_period" IS 'Półotwarty przedział [start,end) używany do ochrony przed kolizjami.';



CREATE TABLE IF NOT EXISTS "public"."shooting_lanes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "description" "text",
    "price_per_hour" numeric DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "max_shooters" integer DEFAULT 1 NOT NULL,
    "booking_step_minutes" integer DEFAULT 60 NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "currency_code" character(3) DEFAULT 'PLN'::"bpchar" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "resource_kind" "text" NOT NULL,
    "parent_lane_id" "uuid",
    "whole_lane_bookable" boolean DEFAULT false NOT NULL,
    "positions_bookable" boolean DEFAULT false NOT NULL,
    CONSTRAINT "shooting_lanes_booking_step_minutes_check" CHECK ((("booking_step_minutes" > 0) AND ("booking_step_minutes" <= 1440))),
    CONSTRAINT "shooting_lanes_currency_code_check" CHECK ((("currency_code")::"text" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "shooting_lanes_display_order_check" CHECK (("display_order" >= 0)),
    CONSTRAINT "shooting_lanes_max_shooters_check" CHECK (("max_shooters" >= 1)),
    CONSTRAINT "shooting_lanes_parent_not_self_check" CHECK ((("parent_lane_id" IS NULL) OR ("parent_lane_id" <> "id"))),
    CONSTRAINT "shooting_lanes_position_booking_modes_check" CHECK ((("resource_kind" <> 'position'::"text") OR ((NOT "whole_lane_bookable") AND (NOT "positions_bookable")))),
    CONSTRAINT "shooting_lanes_resource_kind_check" CHECK (("resource_kind" = ANY (ARRAY['lane'::"text", 'position'::"text"]))),
    CONSTRAINT "shooting_lanes_resource_parent_check" CHECK (((("resource_kind" = 'lane'::"text") AND ("parent_lane_id" IS NULL)) OR (("resource_kind" = 'position'::"text") AND ("parent_lane_id" IS NOT NULL))))
);


ALTER TABLE "public"."shooting_lanes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."shooting_lanes"."price_per_hour" IS 'LEGACY: stara stawka godzinowa. Po przełączeniu formularza i raportów źródłem cen będą lane_pricing_rules oraz snapshoty reservations.';



COMMENT ON COLUMN "public"."shooting_lanes"."max_shooters" IS 'Maksymalna liczba strzelców dopuszczona dla rezerwacji osi.';



COMMENT ON COLUMN "public"."shooting_lanes"."booking_step_minutes" IS 'Krok minutowy dostępnych godzin rozpoczęcia rezerwacji.';



COMMENT ON COLUMN "public"."shooting_lanes"."display_order" IS 'Kolejność wyświetlania osi w interfejsie.';



COMMENT ON COLUMN "public"."shooting_lanes"."currency_code" IS 'Trzyliterowy kod waluty ISO używany przez cennik osi.';



COMMENT ON COLUMN "public"."shooting_lanes"."resource_kind" IS 'Structural resource kind: lane for a top-level resource or position for its direct child.';



COMMENT ON COLUMN "public"."shooting_lanes"."parent_lane_id" IS 'Direct top-level lane parent for a position; NULL for lane resources.';



COMMENT ON COLUMN "public"."shooting_lanes"."whole_lane_bookable" IS 'Whether the top-level lane supports whole-resource sales; always false for positions.';



COMMENT ON COLUMN "public"."shooting_lanes"."positions_bookable" IS 'Whether the top-level lane supports child-position sales; always false for positions.';



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."confirmation_email_rate_limits"
    ADD CONSTRAINT "confirmation_email_rate_limits_pkey" PRIMARY KEY ("scope_type", "scope_key");



ALTER TABLE ONLY "public"."email_deliveries"
    ADD CONSTRAINT "email_deliveries_message_record_key" UNIQUE ("message_type", "record_id");



ALTER TABLE ONLY "public"."email_deliveries"
    ADD CONSTRAINT "email_deliveries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_lanes"
    ADD CONSTRAINT "event_lanes_pkey" PRIMARY KEY ("event_id", "lane_id");



ALTER TABLE ONLY "public"."event_registrations"
    ADD CONSTRAINT "event_registrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lane_blocks"
    ADD CONSTRAINT "lane_blocks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lane_booking_durations"
    ADD CONSTRAINT "lane_booking_durations_lane_duration_key" UNIQUE ("lane_id", "duration_minutes");



ALTER TABLE ONLY "public"."lane_booking_durations"
    ADD CONSTRAINT "lane_booking_durations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lane_booking_family_configuration_versions"
    ADD CONSTRAINT "lane_booking_family_configuration_versions_pkey" PRIMARY KEY ("root_lane_id");



ALTER TABLE ONLY "public"."lane_booking_rules"
    ADD CONSTRAINT "lane_booking_rules_pkey" PRIMARY KEY ("lane_id");



ALTER TABLE ONLY "public"."lane_pricing_rules"
    ADD CONSTRAINT "lane_pricing_rules_active_ranges_excl" EXCLUDE USING "gist" ("lane_id" WITH =, "day_group" WITH =, "int4range"("min_shooters", "max_shooters", '[]'::"text") WITH &&) WHERE ("is_active");



ALTER TABLE ONLY "public"."lane_pricing_rules"
    ADD CONSTRAINT "lane_pricing_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_no_overlapping_active_booking" EXCLUDE USING "gist" ("lane_id" WITH =, "booking_period" WITH &&) WHERE (("lower"("btrim"("reservation_status")) <> ALL (ARRAY['completed'::"text", 'no_show'::"text", 'cancelled'::"text", 'canceled'::"text", 'cancelled_by_admin'::"text", 'cancelled_by_user'::"text"])));



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_user_creation_request_key" UNIQUE ("user_id", "creation_request_id");



ALTER TABLE ONLY "public"."shooting_lanes"
    ADD CONSTRAINT "shooting_lanes_pkey" PRIMARY KEY ("id");



CREATE INDEX "event_lanes_lane_event_idx" ON "public"."event_lanes" USING "btree" ("lane_id", "event_id");



CREATE INDEX "event_registrations_event_reserve_idx" ON "public"."event_registrations" USING "btree" ("event_id", "registration_status", "created_at");



CREATE UNIQUE INDEX "event_registrations_one_active_per_user_event_idx" ON "public"."event_registrations" USING "btree" ("event_id", "user_id") WHERE (("event_id" IS NOT NULL) AND ("user_id" IS NOT NULL) AND ("lower"("btrim"("registration_status")) = ANY (ARRAY['registered'::"text", 'approved'::"text", 'reserve'::"text", 'participant'::"text"])));



COMMENT ON INDEX "public"."event_registrations_one_active_per_user_event_idx" IS 'Ensures one active registration per user and event. Reserve participates in uniqueness; terminal records such as cancelled remain historical and do not block re-registration.';



CREATE UNIQUE INDEX "event_registrations_promotion_token_key" ON "public"."event_registrations" USING "btree" ("promotion_token") WHERE ("promotion_token" IS NOT NULL);



CREATE INDEX "lane_blocks_active_schedule_idx" ON "public"."lane_blocks" USING "btree" ("lane_id", "block_date", "is_active", "start_time", "end_time");



CREATE INDEX "lane_booking_durations_active_order_idx" ON "public"."lane_booking_durations" USING "btree" ("lane_id", "display_order", "duration_minutes") WHERE "is_active";



CREATE INDEX "lane_pricing_rules_active_order_idx" ON "public"."lane_pricing_rules" USING "btree" ("lane_id", "day_group", "display_order", "min_shooters", "max_shooters") WHERE "is_active";



CREATE INDEX "lane_pricing_rules_lane_id_idx" ON "public"."lane_pricing_rules" USING "btree" ("lane_id");



CREATE INDEX "profiles_email_idx" ON "public"."profiles" USING "btree" ("email");



CREATE INDEX "profiles_permissions_verified_idx" ON "public"."profiles" USING "btree" ("permissions_verified");



CREATE INDEX "profiles_role_idx" ON "public"."profiles" USING "btree" ("role");



CREATE INDEX "profiles_user_id_idx" ON "public"."profiles" USING "btree" ("user_id");



CREATE INDEX "profiles_verification_status_idx" ON "public"."profiles" USING "btree" ("verification_status");



CREATE UNIQUE INDEX "reservations_check_in_token_key" ON "public"."reservations" USING "btree" ("check_in_token");



CREATE INDEX "shooting_lanes_parent_lane_id_idx" ON "public"."shooting_lanes" USING "btree" ("parent_lane_id") WHERE ("parent_lane_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "lock_lane_blocks_configuration" BEFORE INSERT OR DELETE OR UPDATE ON "public"."lane_blocks" FOR EACH ROW EXECUTE FUNCTION "public"."lock_lane_booking_configuration"();



CREATE OR REPLACE TRIGGER "lock_lane_booking_durations_configuration" BEFORE INSERT OR DELETE OR UPDATE ON "public"."lane_booking_durations" FOR EACH ROW EXECUTE FUNCTION "public"."lock_lane_booking_configuration"();



CREATE OR REPLACE TRIGGER "lock_lane_pricing_rules_configuration" BEFORE INSERT OR DELETE OR UPDATE ON "public"."lane_pricing_rules" FOR EACH ROW EXECUTE FUNCTION "public"."lock_lane_booking_configuration"();



CREATE OR REPLACE TRIGGER "prevent_non_admin_profile_privilege_changes_trigger" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_non_admin_profile_privilege_changes"();



CREATE OR REPLACE TRIGGER "set_lane_booking_durations_updated_at" BEFORE UPDATE ON "public"."lane_booking_durations" FOR EACH ROW EXECUTE FUNCTION "public"."set_booking_configuration_updated_at"();



CREATE OR REPLACE TRIGGER "set_lane_booking_rules_updated_at" BEFORE UPDATE ON "public"."lane_booking_rules" FOR EACH ROW EXECUTE FUNCTION "public"."set_booking_configuration_updated_at"();



CREATE OR REPLACE TRIGGER "set_lane_pricing_rules_updated_at" BEFORE UPDATE ON "public"."lane_pricing_rules" FOR EACH ROW EXECUTE FUNCTION "public"."set_booking_configuration_updated_at"();



CREATE OR REPLACE TRIGGER "set_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_shooting_lanes_updated_at" BEFORE UPDATE ON "public"."shooting_lanes" FOR EACH ROW EXECUTE FUNCTION "public"."set_booking_configuration_updated_at"();



CREATE OR REPLACE TRIGGER "validate_lane_booking_rule_capacity_trigger" BEFORE INSERT OR UPDATE OF "lane_id", "max_people_online" ON "public"."lane_booking_rules" FOR EACH ROW EXECUTE FUNCTION "public"."validate_lane_booking_rule_capacity"();



CREATE OR REPLACE TRIGGER "validate_shooting_lane_capacity_change_trigger" BEFORE UPDATE OF "max_shooters" ON "public"."shooting_lanes" FOR EACH ROW EXECUTE FUNCTION "public"."validate_shooting_lane_capacity_change"();



CREATE OR REPLACE TRIGGER "validate_shooting_lane_hierarchy_trigger" BEFORE INSERT OR UPDATE OF "resource_kind", "parent_lane_id" ON "public"."shooting_lanes" FOR EACH ROW EXECUTE FUNCTION "public"."validate_shooting_lane_hierarchy"();



ALTER TABLE ONLY "public"."email_deliveries"
    ADD CONSTRAINT "email_deliveries_recipient_user_id_fkey" FOREIGN KEY ("recipient_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_lanes"
    ADD CONSTRAINT "event_lanes_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_lanes"
    ADD CONSTRAINT "event_lanes_lane_id_fkey" FOREIGN KEY ("lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."event_registrations"
    ADD CONSTRAINT "event_registrations_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lane_blocks"
    ADD CONSTRAINT "lane_blocks_lane_id_fkey" FOREIGN KEY ("lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."lane_booking_durations"
    ADD CONSTRAINT "lane_booking_durations_lane_id_fkey" FOREIGN KEY ("lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."lane_booking_family_configuration_versions"
    ADD CONSTRAINT "lane_booking_family_configuration_versions_root_lane_id_fkey" FOREIGN KEY ("root_lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lane_booking_rules"
    ADD CONSTRAINT "lane_booking_rules_lane_id_fkey" FOREIGN KEY ("lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."lane_pricing_rules"
    ADD CONSTRAINT "lane_pricing_rules_lane_id_fkey" FOREIGN KEY ("lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_permissions_verified_by_fkey" FOREIGN KEY ("permissions_verified_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_lane_id_fkey" FOREIGN KEY ("lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_pricing_rule_id_fkey" FOREIGN KEY ("pricing_rule_id") REFERENCES "public"."lane_pricing_rules"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."shooting_lanes"
    ADD CONSTRAINT "shooting_lanes_parent_lane_id_fkey" FOREIGN KEY ("parent_lane_id") REFERENCES "public"."shooting_lanes"("id") ON DELETE RESTRICT;



CREATE POLICY "Active lane durations are readable" ON "public"."lane_booking_durations" FOR SELECT TO "authenticated", "anon" USING (("is_active" AND (EXISTS ( SELECT 1
   FROM "public"."shooting_lanes" "lane"
  WHERE (("lane"."id" = "lane_booking_durations"."lane_id") AND "lane"."is_active")))));



CREATE POLICY "Active lane pricing rules are readable" ON "public"."lane_pricing_rules" FOR SELECT TO "authenticated", "anon" USING (("is_active" AND (EXISTS ( SELECT 1
   FROM "public"."shooting_lanes" "lane"
  WHERE (("lane"."id" = "lane_pricing_rules"."lane_id") AND "lane"."is_active")))));



CREATE POLICY "Admins and employees can view all lane durations" ON "public"."lane_booking_durations" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_employee"());



CREATE POLICY "Admins and employees can view all lane pricing rules" ON "public"."lane_pricing_rules" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_employee"());



CREATE POLICY "Admins and staff can delete event registrations" ON "public"."event_registrations" FOR DELETE TO "authenticated" USING ("public"."is_admin_or_employee"());



CREATE POLICY "Admins and staff can insert event registrations" ON "public"."event_registrations" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin_or_employee"());



CREATE POLICY "Admins and staff can update event registrations" ON "public"."event_registrations" FOR UPDATE TO "authenticated" USING ("public"."is_admin_or_employee"()) WITH CHECK ("public"."is_admin_or_employee"());



CREATE POLICY "Admins and staff can view all event registrations" ON "public"."event_registrations" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_staff"());



CREATE POLICY "Admins and staff can view all events" ON "public"."events" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_staff"());



CREATE POLICY "Admins and staff can view all lane blocks" ON "public"."lane_blocks" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_staff"());



CREATE POLICY "Admins and staff can view all reservations" ON "public"."reservations" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_employee"());



CREATE POLICY "Admins and staff can view event lanes" ON "public"."event_lanes" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_staff"());



CREATE POLICY "Admins can delete reservations" ON "public"."reservations" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "Admins can insert audit logs" ON "public"."audit_logs" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin_or_staff"());



CREATE POLICY "Admins can insert profiles" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "Admins can update all profiles" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "Admins can view all profiles" ON "public"."profiles" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "Admins can view audit logs" ON "public"."audit_logs" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "Anyone can view active lane blocks" ON "public"."lane_blocks" FOR SELECT TO "authenticated" USING (("is_active" = true));



CREATE POLICY "Public can view active events" ON "public"."events" FOR SELECT TO "anon" USING (("is_active" = true));



CREATE POLICY "Public can view active shooting lanes" ON "public"."shooting_lanes" FOR SELECT USING (("is_active" = true));



CREATE POLICY "Public can view online lane booking rules" ON "public"."lane_booking_rules" FOR SELECT TO "authenticated", "anon" USING (("online_bookable" AND (EXISTS ( SELECT 1
   FROM "public"."shooting_lanes" "lane"
  WHERE (("lane"."id" = "lane_booking_rules"."lane_id") AND "lane"."is_active" AND ((("lane"."resource_kind" = 'lane'::"text") AND "lane"."whole_lane_bookable") OR (("lane"."resource_kind" = 'position'::"text") AND (EXISTS ( SELECT 1
           FROM "public"."shooting_lanes" "parent"
          WHERE (("parent"."id" = "lane"."parent_lane_id") AND ("parent"."resource_kind" = 'lane'::"text") AND ("parent"."parent_lane_id" IS NULL) AND "parent"."is_active" AND "parent"."positions_bookable"))))))))));



CREATE POLICY "Staff can view all lane booking rules" ON "public"."lane_booking_rules" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_staff"());



CREATE POLICY "Staff can view all shooting lanes" ON "public"."shooting_lanes" FOR SELECT TO "authenticated" USING ("public"."is_admin_or_staff"());



CREATE POLICY "Users can update own basic profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view active events" ON "public"."events" FOR SELECT TO "authenticated" USING (("is_active" = true));



CREATE POLICY "Users can view own event registrations" ON "public"."event_registrations" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view own profile" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view own reservations" ON "public"."reservations" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."confirmation_email_rate_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_deliveries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_lanes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_registrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lane_blocks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lane_booking_durations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lane_booking_family_configuration_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lane_booking_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lane_pricing_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reservations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shooting_lanes" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_create_event"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_event"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_create_event_v2"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_event_v2"("p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_create_lane_block"("p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_lane_block"("p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_get_lane_booking_configuration_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_get_lane_booking_configuration_v1"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_get_lane_booking_configuration_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_get_lane_booking_configuration_v2"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_users_v1"("p_limit" integer, "p_offset" integer, "p_search" "text", "p_role" "text", "p_verification_filter" "text", "p_sort" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_users_v1"("p_limit" integer, "p_offset" integer, "p_search" "text", "p_role" "text", "p_verification_filter" "text", "p_sort" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_set_event_active"("p_event_id" "uuid", "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_event_active"("p_event_id" "uuid", "p_is_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_set_event_active_v2"("p_event_id" "uuid", "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_event_active_v2"("p_event_id" "uuid", "p_is_active" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_set_lane_block_active"("p_block_id" "uuid", "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_lane_block_active"("p_block_id" "uuid", "p_is_active" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_set_lane_booking_configuration"("p_lane_id" "uuid", "p_is_active" boolean, "p_whole_lane_bookable" boolean, "p_positions_bookable" boolean, "p_max_shooters" integer, "p_online_bookable" boolean, "p_max_people_online" integer, "p_durations_minutes" integer[], "p_pricing" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."admin_set_lane_booking_family_configuration_v2"("p_root_lane_id" "uuid", "p_expected_version" bigint, "p_resources" "jsonb", "p_acknowledge_future_obligations" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_lane_booking_family_configuration_v2"("p_root_lane_id" "uuid", "p_expected_version" bigint, "p_resources" "jsonb", "p_acknowledge_future_obligations" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_set_user_note_v1"("p_target_user_id" "uuid", "p_admin_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_user_note_v1"("p_target_user_id" "uuid", "p_admin_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_set_user_role_v1"("p_target_user_id" "uuid", "p_new_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_user_role_v1"("p_target_user_id" "uuid", "p_new_role" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_update_event_v2"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_event_v2"("p_event_id" "uuid", "p_title" "text", "p_description" "text", "p_event_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_location" "text", "p_price" numeric, "p_max_participants" integer, "p_lane_ids" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_update_lane_block"("p_block_id" "uuid", "p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text", "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_lane_block"("p_block_id" "uuid", "p_lane_id" "uuid", "p_block_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_reason" "text", "p_is_active" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."approve_event_registration"("p_registration_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_event_registration"("p_registration_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."cancel_event_registration"("p_registration_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_event_registration"("p_registration_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_event_registration"("p_registration_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancel_reservation"("p_reservation_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_reservation"("p_reservation_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_reservation"("p_reservation_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_confirmation_email_rate_limit"("p_user_id" "uuid", "p_ip_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_confirmation_email_rate_limit"("p_user_id" "uuid", "p_ip_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_confirmation_email"("p_claim_id" "uuid", "p_success" boolean, "p_provider_message_id" "text", "p_error_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_confirmation_email"("p_claim_id" "uuid", "p_success" boolean, "p_provider_message_id" "text", "p_error_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_event_reserve_promotion"("p_registration_id" "uuid", "p_claim_id" "uuid", "p_success" boolean, "p_error_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_event_reserve_promotion"("p_registration_id" "uuid", "p_claim_id" "uuid", "p_success" boolean, "p_error_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."confirm_event_reserve_promotion"("p_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."confirm_event_reserve_promotion"("p_token" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_reservation"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_reservation"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_reservation_v2"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_reservation_v2"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_reservation_v2"("p_lane_id" "uuid", "p_reservation_date" "date", "p_start_time" time without time zone, "p_duration_minutes" integer, "p_shooters_count" integer, "p_creation_request_id" "uuid", "p_reservation_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_lane_booking_busy_ranges"("p_lane_id" "uuid", "p_reservation_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_lane_booking_busy_ranges"("p_lane_id" "uuid", "p_reservation_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_lane_booking_busy_ranges"("p_lane_id" "uuid", "p_reservation_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_lane_booking_busy_ranges_v2"("p_lane_id" "uuid", "p_reservation_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_lane_booking_busy_ranges_v2"("p_lane_id" "uuid", "p_reservation_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_lane_booking_busy_ranges_v2"("p_lane_id" "uuid", "p_reservation_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_lane_booking_busy_ranges_v3"("p_lane_id" "uuid", "p_reservation_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_lane_booking_busy_ranges_v3"("p_lane_id" "uuid", "p_reservation_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_lane_booking_busy_ranges_v3"("p_lane_id" "uuid", "p_reservation_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_reservations_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_reservations_v2"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."get_my_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_role"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_public_booking_configuration_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_public_booking_configuration_v1"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_booking_configuration_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_booking_configuration_v1"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_reservation_customer_profiles_v1"("p_reservation_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_reservation_customer_profiles_v1"("p_reservation_ids" "uuid"[]) TO "authenticated";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_admin_or_employee"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_admin_or_employee"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin_or_employee"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin_or_staff"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin_or_staff"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin_or_staff"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."lane_booking_family_business_snapshot_v2"("p_root_lane_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."lock_lane_booking_configuration"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lock_lane_booking_configuration"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."lock_lane_conflict_families_v1"("p_lane_ids" "uuid"[]) FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."lock_lane_conflict_family_v1"("p_lane_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."normalize_lane_booking_family_payload_v2"("p_resources" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."prepare_confirmation_email"("p_message_type" "text", "p_record_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prepare_confirmation_email"("p_message_type" "text", "p_record_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."prepare_event_reserve_promotions"("p_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prepare_event_reserve_promotions"("p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_non_admin_profile_privilege_changes"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_non_admin_profile_privilege_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_non_admin_profile_privilege_changes"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."register_for_event"("p_event_id" "uuid", "p_as_reserve" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."register_for_event"("p_event_id" "uuid", "p_as_reserve" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."resolve_lane_conflict_scope_v1"("p_lane_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."set_booking_configuration_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_booking_configuration_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_profile_contact_details"("p_target_user_id" "uuid", "p_phone" "text", "p_postal_code" "text", "p_city" "text", "p_street" "text", "p_house_number" "text", "p_apartment_number" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_profile_contact_details"("p_target_user_id" "uuid", "p_phone" "text", "p_postal_code" "text", "p_city" "text", "p_street" "text", "p_house_number" "text", "p_apartment_number" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_profile_contact_details"("p_target_user_id" "uuid", "p_phone" "text", "p_postal_code" "text", "p_city" "text", "p_street" "text", "p_house_number" "text", "p_apartment_number" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_profile_identity"("p_target_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_profile_identity"("p_target_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_profile_identity"("p_target_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_profile_verification"("p_target_user_id" "uuid", "p_action" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_profile_verification"("p_target_user_id" "uuid", "p_action" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_profile_verification"("p_target_user_id" "uuid", "p_action" "text", "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_reservation_admin_note"("p_reservation_id" "uuid", "p_admin_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_reservation_admin_note"("p_reservation_id" "uuid", "p_admin_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_reservation_attendance"("p_reservation_id" "uuid", "p_action" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_reservation_attendance"("p_reservation_id" "uuid", "p_action" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_reservation_attendance"("p_reservation_id" "uuid", "p_action" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_reservation_payment"("p_reservation_id" "uuid", "p_payment_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_reservation_payment"("p_reservation_id" "uuid", "p_payment_status" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."validate_lane_booking_rule_capacity"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validate_lane_booking_rule_capacity"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."validate_shooting_lane_capacity_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validate_shooting_lane_capacity_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."validate_shooting_lane_hierarchy"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validate_shooting_lane_hierarchy"() TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."email_deliveries" TO "service_role";



GRANT ALL ON TABLE "public"."event_lanes" TO "service_role";
GRANT SELECT ON TABLE "public"."event_lanes" TO "authenticated";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN ON TABLE "public"."event_registrations" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN ON TABLE "public"."event_registrations" TO "authenticated";
GRANT ALL ON TABLE "public"."event_registrations" TO "service_role";



GRANT UPDATE("payment_status") ON TABLE "public"."event_registrations" TO "authenticated";



GRANT SELECT,MAINTAIN ON TABLE "public"."events" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."events" TO "anon";



GRANT SELECT("title") ON TABLE "public"."events" TO "anon";



GRANT SELECT("description") ON TABLE "public"."events" TO "anon";



GRANT SELECT("event_date") ON TABLE "public"."events" TO "anon";



GRANT SELECT("start_time") ON TABLE "public"."events" TO "anon";



GRANT SELECT("end_time") ON TABLE "public"."events" TO "anon";



GRANT SELECT("location") ON TABLE "public"."events" TO "anon";



GRANT SELECT("price") ON TABLE "public"."events" TO "anon";



GRANT SELECT("max_participants") ON TABLE "public"."events" TO "anon";



GRANT SELECT("is_active") ON TABLE "public"."events" TO "anon";



GRANT SELECT,MAINTAIN ON TABLE "public"."lane_blocks" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."lane_blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."lane_blocks" TO "service_role";



GRANT ALL ON TABLE "public"."lane_booking_durations" TO "service_role";
GRANT SELECT ON TABLE "public"."lane_booking_durations" TO "anon";
GRANT SELECT ON TABLE "public"."lane_booking_durations" TO "authenticated";



GRANT ALL ON TABLE "public"."lane_booking_rules" TO "service_role";
GRANT SELECT ON TABLE "public"."lane_booking_rules" TO "anon";
GRANT SELECT ON TABLE "public"."lane_booking_rules" TO "authenticated";



GRANT ALL ON TABLE "public"."lane_pricing_rules" TO "service_role";
GRANT SELECT ON TABLE "public"."lane_pricing_rules" TO "anon";
GRANT SELECT ON TABLE "public"."lane_pricing_rules" TO "authenticated";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."reservations" TO "anon";
GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."reservations" TO "authenticated";
GRANT ALL ON TABLE "public"."reservations" TO "service_role";



GRANT ALL ON TABLE "public"."shooting_lanes" TO "service_role";
GRANT SELECT ON TABLE "public"."shooting_lanes" TO "anon";
GRANT SELECT ON TABLE "public"."shooting_lanes" TO "authenticated";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
