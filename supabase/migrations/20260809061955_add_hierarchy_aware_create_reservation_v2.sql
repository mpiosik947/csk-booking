-- Additive dormant hierarchy-aware reservation writer. The existing
-- public.create_reservation(...) remains unchanged until a later client switch.

do $preflight$
declare
  v_v1 oid := pg_catalog.to_regprocedure(
    'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
  );
  v_resolver oid := pg_catalog.to_regprocedure(
    'public.resolve_lane_conflict_scope_v1(uuid)'
  );
  v_availability_v3 oid := pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'
  );
begin
  if pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.profiles') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.lane_booking_rules') is null
     or pg_catalog.to_regclass('public.lane_booking_durations') is null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is null
     or pg_catalog.to_regclass('public.lane_blocks') is null
     or pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_lanes') is null
     or pg_catalog.to_regclass('public.audit_logs') is null then
    raise exception 'Preflight failed: required reservation tables are missing.';
  end if;

  if v_v1 is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'create_reservation'
     ) <> 1 then
    raise exception 'Preflight failed: expected exactly one create_reservation overload.';
  end if;

  if pg_catalog.md5(pg_catalog.pg_get_functiondef(v_v1))
       <> '3212b32f37ebc8e665a9a94e94260976'
     or (
       select language_record.lanname <> 'plpgsql'
         or function_record.provolatile <> 'v'
         or not function_record.prosecdef
         or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
         or function_record.proconfig is distinct from
              array['search_path=pg_catalog, public, pg_temp']::text[]
         or pg_catalog.pg_get_function_result(function_record.oid) <> 'jsonb'
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_language as language_record
         on language_record.oid = function_record.prolang
       where function_record.oid = v_v1
     ) then
    raise exception 'Preflight failed: create_reservation fingerprint or properties differ.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated', v_v1, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_v1, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_v1, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_v1
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Preflight failed: create_reservation ACL differs.';
  end if;

  if v_resolver is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'resolve_lane_conflict_scope_v1'
     ) <> 1
     or v_availability_v3 is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'get_lane_booking_busy_ranges_v3'
     ) <> 1 then
    raise exception 'Preflight failed: hierarchy resolver or availability v3 differs.';
  end if;

  if (
       select language_record.lanname <> 'plpgsql'
         or function_record.provolatile <> 's'
         or function_record.prosecdef
         or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
         or function_record.proconfig is distinct from
              array['search_path=pg_catalog, public, pg_temp']::text[]
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_language as language_record
         on language_record.oid = function_record.prolang
       where function_record.oid = v_resolver
     )
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_resolver
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     )
     or pg_catalog.has_function_privilege('anon', v_resolver, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', v_resolver, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_resolver, 'EXECUTE') then
    raise exception 'Preflight failed: hierarchy resolver contract differs.';
  end if;

  if (
       select not function_record.prosecdef
         or function_record.provolatile <> 's'
         or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
         or function_record.proconfig is distinct from
              array['search_path=pg_catalog, public, pg_temp']::text[]
       from pg_catalog.pg_proc as function_record
       where function_record.oid = v_availability_v3
     )
     or not pg_catalog.has_function_privilege('authenticated', v_availability_v3, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_availability_v3, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_availability_v3, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_availability_v3
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Preflight failed: availability v3 contract differs.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.reservations'::pg_catalog.regclass
         and constraint_record.conname = 'reservations_user_creation_request_key'
         and constraint_record.contype = 'u'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.reservations'::pg_catalog.regclass
         and constraint_record.conname = 'reservations_no_overlapping_active_booking'
         and constraint_record.contype = 'x'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_resource_kind_check'
         and constraint_record.contype = 'c'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_resource_parent_check'
         and constraint_record.contype = 'c'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_parent_lane_id_fkey'
         and constraint_record.contype = 'f'
     )
     or pg_catalog.to_regclass('public.shooting_lanes_parent_lane_id_idx') is null
     or pg_catalog.to_regclass('public.lane_blocks_active_schedule_idx') is null
     or pg_catalog.to_regclass('public.event_lanes_lane_event_idx') is null then
    raise exception 'Preflight failed: required hierarchy/conflict constraints or indexes differ.';
  end if;

  if (
       select pg_catalog.count(*)
       from information_schema.columns
       where table_schema = 'public'
         and table_name = 'lane_booking_rules'
         and (
           (column_name = 'lane_id' and data_type = 'uuid' and is_nullable = 'NO')
           or (column_name = 'online_bookable' and data_type = 'boolean' and is_nullable = 'NO')
           or (column_name = 'max_people_online' and data_type = 'integer' and is_nullable = 'NO')
         )
     ) <> 3 then
    raise exception 'Preflight failed: lane_booking_rules contract differs.';
  end if;

  if pg_catalog.to_regprocedure('public.lock_lane_conflict_family_v1(uuid)') is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'lock_lane_conflict_family_v1'
     )
     or pg_catalog.to_regprocedure(
       'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
     ) is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'create_reservation_v2'
     ) then
    raise exception 'Preflight failed: dormant v2 objects already exist.';
  end if;
end;
$preflight$;

create function public.lock_lane_conflict_family_v1(p_lane_id uuid)
returns table (
  requested_lane_id uuid,
  root_lane_id uuid,
  requested_resource_kind text,
  conflict_lane_ids uuid[]
)
language plpgsql
volatile
security invoker
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.lock_lane_conflict_family_v1(uuid) owner to postgres;
alter function public.lock_lane_conflict_family_v1(uuid)
  set search_path to pg_catalog, public, pg_temp;
comment on function public.lock_lane_conflict_family_v1(uuid) is
  'Locks a lane-position conflict family in root-first order and returns a typed conflict scope.';
revoke all on function public.lock_lane_conflict_family_v1(uuid) from public;
revoke all on function public.lock_lane_conflict_family_v1(uuid) from anon;
revoke all on function public.lock_lane_conflict_family_v1(uuid) from authenticated;
revoke all on function public.lock_lane_conflict_family_v1(uuid) from service_role;

create function public.create_reservation_v2(
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
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) owner to postgres;
alter function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) set search_path to pg_catalog, public, pg_temp;
comment on function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) is 'Dormant hierarchy-aware atomic reservation writer using the shared lane-family lock protocol.';
revoke all on function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) from public;
revoke all on function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) from anon;
revoke all on function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) from authenticated;
revoke all on function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) from service_role;
grant execute on function public.create_reservation_v2(
  uuid,date,time without time zone,integer,integer,uuid,text
) to authenticated, service_role;

do $postflight$
declare
  v_v1 oid := 'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure;
  v_v2 oid := 'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure;
  v_helper oid := 'public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure;
begin
  if pg_catalog.md5(pg_catalog.pg_get_functiondef(v_v1))
       <> '3212b32f37ebc8e665a9a94e94260976'
     or not pg_catalog.has_function_privilege('authenticated', v_v1, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_v1, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_v1, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_v1
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Postflight failed: existing create_reservation changed.';
  end if;

  if (
       select language_record.lanname <> 'plpgsql'
         or function_record.provolatile <> 'v'
         or not function_record.prosecdef
         or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
         or function_record.proconfig is distinct from
              array['search_path=pg_catalog, public, pg_temp']::text[]
         or pg_catalog.pg_get_function_result(function_record.oid) <> 'jsonb'
         or pg_catalog.pg_get_function_identity_arguments(function_record.oid)
              <> 'p_lane_id uuid, p_reservation_date date, p_start_time time without time zone, p_duration_minutes integer, p_shooters_count integer, p_creation_request_id uuid, p_reservation_note text'
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_language as language_record
         on language_record.oid = function_record.prolang
       where function_record.oid = v_v2
     )
     or not pg_catalog.has_function_privilege('authenticated', v_v2, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_v2, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_v2, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_v2
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Postflight failed: create_reservation_v2 contract differs.';
  end if;

  if (
       select language_record.lanname <> 'plpgsql'
         or function_record.provolatile <> 'v'
         or function_record.prosecdef
         or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
         or function_record.proconfig is distinct from
              array['search_path=pg_catalog, public, pg_temp']::text[]
         or pg_catalog.pg_get_function_result(function_record.oid)
              <> 'TABLE(requested_lane_id uuid, root_lane_id uuid, requested_resource_kind text, conflict_lane_ids uuid[])'
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_language as language_record
         on language_record.oid = function_record.prolang
       where function_record.oid = v_helper
     )
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_helper
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     )
     or pg_catalog.has_function_privilege('anon', v_helper, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', v_helper, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_helper, 'EXECUTE') then
    raise exception 'Postflight failed: lane-family lock helper contract differs.';
  end if;

  if (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'create_reservation'
     ) <> 1
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'create_reservation_v2'
     ) <> 1
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'lock_lane_conflict_family_v1'
     ) <> 1 then
    raise exception 'Postflight failed: unexpected function overloads.';
  end if;
end;
$postflight$;
