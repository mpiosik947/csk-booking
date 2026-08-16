-- Add controlled display-name editing to the versioned lane-family writer.
-- Resource UUIDs and hierarchy remain authoritative technical identity.

do $preflight$
declare
  v_writer pg_catalog.regprocedure :=
    pg_catalog.to_regprocedure(
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'
    );
  v_procedure pg_catalog.pg_proc%rowtype;
begin
  if v_writer is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'admin_set_lane_booking_family_configuration_v2'
     ) <> 1 then
    raise exception 'Pricing order hotfix preflight failed: unexpected V2 writer overloads.';
  end if;

  select procedure.*
  into strict v_procedure
  from pg_catalog.pg_proc as procedure
  where procedure.oid = v_writer;

  if v_procedure.prolang <> (
       select language.oid
       from pg_catalog.pg_language as language
       where language.lanname = 'plpgsql'
     )
     or not v_procedure.prosecdef
     or v_procedure.provolatile <> 'v'
     or v_procedure.proowner <> (
       select role.oid from pg_catalog.pg_roles as role where role.rolname = 'postgres'
     )
     or v_procedure.prorettype <> 'pg_catalog.jsonb'::pg_catalog.regtype
     or v_procedure.proconfig is distinct from
        array['search_path=pg_catalog, public, pg_temp']::text[]
     or not pg_catalog.has_function_privilege('authenticated', v_writer, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_writer, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_writer, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.aclexplode(
         coalesce(
           v_procedure.proacl,
           pg_catalog.acldefault('f', v_procedure.proowner)
         )
       ) as acl
       where acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Pricing order hotfix preflight failed: V2 writer security contract drift.';
  end if;
end;
$preflight$;

create or replace function public.lane_booking_family_business_snapshot_v2(p_root_lane_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.lane_booking_family_business_snapshot_v2(uuid) owner to postgres;
revoke all on function public.lane_booking_family_business_snapshot_v2(uuid) from public;
revoke all on function public.lane_booking_family_business_snapshot_v2(uuid) from anon;
revoke all on function public.lane_booking_family_business_snapshot_v2(uuid) from authenticated;
revoke all on function public.lane_booking_family_business_snapshot_v2(uuid) from service_role;

create or replace function public.normalize_lane_booking_family_payload_v2(p_resources jsonb)
returns jsonb
language plpgsql
immutable
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.normalize_lane_booking_family_payload_v2(jsonb) owner to postgres;
revoke all on function public.normalize_lane_booking_family_payload_v2(jsonb) from public;
revoke all on function public.normalize_lane_booking_family_payload_v2(jsonb) from anon;
revoke all on function public.normalize_lane_booking_family_payload_v2(jsonb) from authenticated;
revoke all on function public.normalize_lane_booking_family_payload_v2(jsonb) from service_role;

create or replace function public.admin_set_lane_booking_family_configuration_v2(
  p_root_lane_id uuid,
  p_expected_version bigint,
  p_resources jsonb,
  p_acknowledge_future_obligations boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;


alter function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
owner to postgres;

comment on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean) is
  'Atomically replaces one complete lane-family target, including display names, with optimistic concurrency and controlled confirmation.';

revoke all on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
from public;
revoke all on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
from anon;
revoke all on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
from authenticated;
revoke all on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
from service_role;
grant execute on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
to authenticated;

do $postflight$
declare
  v_writer pg_catalog.regprocedure :=
    'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)';
  v_definition text := pg_catalog.lower(
    pg_catalog.regexp_replace(
      pg_catalog.pg_get_functiondef(v_writer),
      '[[:space:]]+',
      ' ',
      'g'
    )
  );
begin
  if pg_catalog.strpos(
       v_definition,
       'target_price.hourly_price, target_price.display_order, true from target_price'
     ) = 0 then
    raise exception 'Pricing order hotfix postflight failed: canonical target ordering is missing.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated', v_writer, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_writer, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_writer, 'EXECUTE') then
    raise exception 'Pricing order hotfix postflight failed: V2 writer ACL drift.';
  end if;
end;
$postflight$;
