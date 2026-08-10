-- Restrict the atomic lane booking configuration writer to administrators only.
do $preflight$
declare
  v_function oid := pg_catalog.to_regprocedure(
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
  );
  v_definition text;
begin
  if v_function is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as schema_record
         on schema_record.oid = function_record.pronamespace
       where schema_record.nspname = 'public'
         and function_record.proname = 'admin_set_lane_booking_configuration'
     ) <> 1 then
    raise exception 'Preflight failed: configuration RPC signature differs.';
  end if;

  select pg_catalog.pg_get_functiondef(function_record.oid)
  into v_definition
  from pg_catalog.pg_proc as function_record
  where function_record.oid = v_function;

  if pg_catalog.md5(v_definition) <> 'd1e69566a3021253e07f27f67ea635a2'
     or (
       select owner_role.rolname <> 'postgres'
          or language_record.lanname <> 'plpgsql'
          or function_record.provolatile <> 'v'
          or not function_record.prosecdef
          or function_record.proconfig is distinct from
               array['search_path=pg_catalog, public, pg_temp']::text[]
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = function_record.proowner
       join pg_catalog.pg_language as language_record
         on language_record.oid = function_record.prolang
       where function_record.oid = v_function
     )
     or not pg_catalog.has_function_privilege('postgres', v_function, 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', v_function, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_function, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(coalesce(
         function_record.proacl,
         pg_catalog.acldefault('f', function_record.proowner)
       )) as function_acl
       where function_record.oid = v_function
         and function_acl.grantee = 0
         and function_acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Preflight failed: configuration RPC contract differs.';
  end if;
end;
$preflight$;

create or replace function public.admin_set_lane_booking_configuration(
  p_lane_id uuid,
  p_is_active boolean,
  p_whole_lane_bookable boolean,
  p_positions_bookable boolean,
  p_max_shooters integer,
  p_online_bookable boolean,
  p_max_people_online integer,
  p_durations_minutes integer[],
  p_pricing jsonb
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
$function$;

do $postflight$
declare
  v_function oid := pg_catalog.to_regprocedure(
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
  );
  v_definition text;
  v_normalized_definition text;
begin
  select pg_catalog.pg_get_functiondef(function_record.oid)
  into v_definition
  from pg_catalog.pg_proc as function_record
  where function_record.oid = v_function;

  if v_function is null
     or (
       pg_catalog.length(v_definition)
       - pg_catalog.length(pg_catalog.replace(
           v_definition,
           'if v_actor_role is null or v_actor_role <> ''admin'' then',
           ''
         ))
     ) / pg_catalog.length(
       'if v_actor_role is null or v_actor_role <> ''admin'' then'
     ) <> 1
     or pg_catalog.strpos(v_definition, 'pracownik') <> 0 then
    raise exception 'Postflight failed: admin-only authorization differs.';
  end if;

  v_normalized_definition := pg_catalog.replace(
    pg_catalog.replace(v_definition, E'\r\n', E'\n'),
    'if v_actor_role is null or v_actor_role <> ''admin'' then',
    'if v_actor_role is null or v_actor_role not in (''admin'', ''pracownik'') then'
  );

  if pg_catalog.md5(v_normalized_definition)
       <> 'd1e69566a3021253e07f27f67ea635a2'
     or (
       select owner_role.rolname <> 'postgres'
          or language_record.lanname <> 'plpgsql'
          or function_record.provolatile <> 'v'
          or not function_record.prosecdef
          or function_record.proconfig is distinct from
               array['search_path=pg_catalog, public, pg_temp']::text[]
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = function_record.proowner
       join pg_catalog.pg_language as language_record
         on language_record.oid = function_record.prolang
       where function_record.oid = v_function
     )
     or not pg_catalog.has_function_privilege('postgres', v_function, 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', v_function, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_function, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(coalesce(
         function_record.proacl,
         pg_catalog.acldefault('f', function_record.proowner)
       )) as function_acl
       where function_record.oid = v_function
         and function_acl.grantee = 0
         and function_acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Postflight failed: non-authorization contract changed.';
  end if;
end;
$postflight$;
