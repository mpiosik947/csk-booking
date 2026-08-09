-- Additive, dormant hierarchy-aware administration RPCs for events.
-- Existing V1 RPCs and every application call-site remain unchanged.

do $preflight$
declare
  v_signature text;
  v_expected_fingerprint text;
  v_function oid;
  v_actual_fingerprint text;
begin
  if pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_lanes') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.lane_blocks') is null
     or pg_catalog.to_regclass('public.profiles') is null then
    raise exception 'Preflight failed: required event tables are missing.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.lock_lane_conflict_families_v1(uuid[])'
     ) is null then
    raise exception 'Preflight failed: multi-family lock helper is missing.';
  end if;

  for v_signature, v_expected_fingerprint in
    select baseline.signature, baseline.fingerprint
    from (values
      ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       '38505f3338b398661dbdbed48d1141b3'::text),
      ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       'e51615b3522421d9509ae4e4db0a38c9'::text),
      ('public.admin_set_event_active(uuid,boolean)'::text,
       '84847d8bd3f9db10f45b52177dc295e7'::text),
      ('public.lock_lane_conflict_families_v1(uuid[])'::text,
       '0815401da8ad1f909c26622355c0db5f'::text),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::text,
       '893c71de856609d33240d1ebad37e86c'::text),
      ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::text,
       '72cf29e567842543f37edf4e38ee37ce'::text),
      ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::text,
       '841aab21690164d7c6538d063878d5c5'::text),
      ('public.admin_set_lane_block_active(uuid,boolean)'::text,
       '918af496f7e34bd0ce21638a085f0340'::text)
    ) as baseline(signature, fingerprint)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

    if v_function is null then
      raise exception 'Preflight failed: required function % is missing.',
        v_signature;
    end if;

    select pg_catalog.md5(pg_catalog.jsonb_build_object(
      'definition', pg_catalog.pg_get_functiondef(function_record.oid),
      'owner', owner_role.rolname,
      'language', language_record.lanname,
      'volatility', function_record.provolatile,
      'security_definer', function_record.prosecdef,
      'config', coalesce(
        pg_catalog.to_jsonb(function_record.proconfig),
        '[]'::jsonb
      ),
      'acl', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'grantor', pg_catalog.pg_get_userbyid(privilege_record.grantor),
          'grantee', case when privilege_record.grantee = 0 then 'PUBLIC'
                          else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          'privilege', privilege_record.privilege_type,
          'grantable', privilege_record.is_grantable
        ) order by
          case when privilege_record.grantee = 0 then 'PUBLIC'
               else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          privilege_record.privilege_type,
          pg_catalog.pg_get_userbyid(privilege_record.grantor))
        from pg_catalog.aclexplode(coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )) as privilege_record
      ), '[]'::jsonb)
    )::text)
    into v_actual_fingerprint
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = function_record.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function;

    if v_actual_fingerprint is distinct from v_expected_fingerprint then
      raise exception 'Preflight failed: function % differs.', v_signature;
    end if;
  end loop;

  if exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname in (
           'admin_create_event_v2',
           'admin_update_event_v2',
           'admin_set_event_active_v2'
         )
     ) then
    raise exception 'Preflight failed: Event V2 RPC already exists.';
  end if;
end;
$preflight$;

create function public.admin_create_event_v2(
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
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

create function public.admin_update_event_v2(
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
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

create function public.admin_set_event_active_v2(
  p_event_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.admin_create_event_v2(
  text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) owner to postgres;
alter function public.admin_update_event_v2(
  uuid,text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) owner to postgres;
alter function public.admin_set_event_active_v2(uuid,boolean) owner to postgres;

comment on function public.admin_create_event_v2(
  text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) is 'Dormant hierarchy-aware event creation using globally ordered conflict-family locks.';
comment on function public.admin_update_event_v2(
  uuid,text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) is 'Dormant hierarchy-aware event update locking the union of old and new conflict families.';
comment on function public.admin_set_event_active_v2(uuid,boolean) is
  'Dormant hierarchy-aware event activation and deactivation.';

revoke all on function public.admin_create_event_v2(
  text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from public;
revoke all on function public.admin_create_event_v2(
  text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from anon;
revoke all on function public.admin_create_event_v2(
  text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from authenticated;
revoke all on function public.admin_create_event_v2(
  text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from service_role;
grant execute on function public.admin_create_event_v2(
  text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) to authenticated;

revoke all on function public.admin_update_event_v2(
  uuid,text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from public;
revoke all on function public.admin_update_event_v2(
  uuid,text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from anon;
revoke all on function public.admin_update_event_v2(
  uuid,text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from authenticated;
revoke all on function public.admin_update_event_v2(
  uuid,text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) from service_role;
grant execute on function public.admin_update_event_v2(
  uuid,text,text,date,time without time zone,time without time zone,
  text,numeric,integer,uuid[]
) to authenticated;

revoke all on function public.admin_set_event_active_v2(uuid,boolean) from public;
revoke all on function public.admin_set_event_active_v2(uuid,boolean) from anon;
revoke all on function public.admin_set_event_active_v2(uuid,boolean) from authenticated;
revoke all on function public.admin_set_event_active_v2(uuid,boolean) from service_role;
grant execute on function public.admin_set_event_active_v2(uuid,boolean)
to authenticated;

do $postflight$
declare
  v_signature text;
  v_expected_fingerprint text;
  v_function oid;
  v_actual_fingerprint text;
  v_definition text;
begin
  for v_signature in
    select expected.signature
    from (values
      ('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text),
      ('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text),
      ('public.admin_set_event_active_v2(uuid,boolean)'::text)
    ) as expected(signature)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

    if v_function is null then
      raise exception 'Postflight failed: function % is missing.', v_signature;
    end if;

    select pg_catalog.pg_get_functiondef(function_record.oid)
    into v_definition
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function
      and language_record.lanname = 'plpgsql'
      and function_record.provolatile = 'v'
      and function_record.prosecdef
      and pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
      and function_record.proconfig is not distinct from
        array['search_path=pg_catalog, public, pg_temp']::text[]
      and pg_catalog.pg_get_function_result(function_record.oid) = 'jsonb';

    if v_definition is null
       or v_definition !~ 'auth[.]uid[(][)]'
       or v_definition !~ 'from[[:space:]]+public[.]profiles'
       or v_definition !~ 'lock_lane_conflict_families_v1'
       or v_definition ~* '[[:<:]]execute[[:>:]]'
       or pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
       or not pg_catalog.has_function_privilege(
         'authenticated', v_function, 'EXECUTE'
       )
       or pg_catalog.has_function_privilege(
         'service_role', v_function, 'EXECUTE'
       )
       or exists (
         select 1
         from pg_catalog.pg_proc as acl_function
         cross join lateral pg_catalog.aclexplode(coalesce(
           acl_function.proacl,
           pg_catalog.acldefault('f', acl_function.proowner)
         )) as privilege_record
         where acl_function.oid = v_function
           and privilege_record.grantee = 0
           and privilege_record.privilege_type = 'EXECUTE'
       ) then
      raise exception 'Postflight failed: function % contract differs.',
        v_signature;
    end if;
  end loop;

  if (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname in (
           'admin_create_event_v2',
           'admin_update_event_v2',
           'admin_set_event_active_v2'
         )
     ) <> 3 then
    raise exception 'Postflight failed: unexpected Event V2 RPC overloads.';
  end if;

  for v_signature, v_expected_fingerprint in
    select baseline.signature, baseline.fingerprint
    from (values
      ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       '38505f3338b398661dbdbed48d1141b3'::text),
      ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       'e51615b3522421d9509ae4e4db0a38c9'::text),
      ('public.admin_set_event_active(uuid,boolean)'::text,
       '84847d8bd3f9db10f45b52177dc295e7'::text),
      ('public.lock_lane_conflict_families_v1(uuid[])'::text,
       '0815401da8ad1f909c26622355c0db5f'::text),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::text,
       '893c71de856609d33240d1ebad37e86c'::text),
      ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::text,
       '72cf29e567842543f37edf4e38ee37ce'::text),
      ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::text,
       '841aab21690164d7c6538d063878d5c5'::text),
      ('public.admin_set_lane_block_active(uuid,boolean)'::text,
       '918af496f7e34bd0ce21638a085f0340'::text)
    ) as baseline(signature, fingerprint)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

    select pg_catalog.md5(pg_catalog.jsonb_build_object(
      'definition', pg_catalog.pg_get_functiondef(function_record.oid),
      'owner', owner_role.rolname,
      'language', language_record.lanname,
      'volatility', function_record.provolatile,
      'security_definer', function_record.prosecdef,
      'config', coalesce(
        pg_catalog.to_jsonb(function_record.proconfig),
        '[]'::jsonb
      ),
      'acl', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'grantor', pg_catalog.pg_get_userbyid(privilege_record.grantor),
          'grantee', case when privilege_record.grantee = 0 then 'PUBLIC'
                          else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          'privilege', privilege_record.privilege_type,
          'grantable', privilege_record.is_grantable
        ) order by
          case when privilege_record.grantee = 0 then 'PUBLIC'
               else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          privilege_record.privilege_type,
          pg_catalog.pg_get_userbyid(privilege_record.grantor))
        from pg_catalog.aclexplode(coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )) as privilege_record
      ), '[]'::jsonb)
    )::text)
    into v_actual_fingerprint
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = function_record.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function;

    if v_actual_fingerprint is distinct from v_expected_fingerprint then
      raise exception 'Postflight failed: function % changed.', v_signature;
    end if;
  end loop;
end;
$postflight$;
