-- Force hierarchy/resource validation before reading any busy source. The
-- public result shape and all availability semantics remain unchanged.

do $preflight$
declare
  v_v3 constant regprocedure :=
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::regprocedure;
  v_resolver constant regprocedure :=
    'public.resolve_lane_conflict_scope_v1(uuid)'::regprocedure;
begin
  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = 'get_lane_booking_busy_ranges_v3') <> 1
     or pg_catalog.md5(pg_catalog.pg_get_functiondef(v_v3))
          <> '05b59d331577a3d91e8079e908bfa380'
     or pg_catalog.md5(pg_catalog.pg_get_functiondef(v_resolver))
          <> '073eeae67ebd3d9e8dbfcd614681d000' then
    raise exception 'Availability V3 hardening preflight failed: function baseline differs.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_proc as function_record
       where function_record.oid = v_v3
         and function_record.prolang = (
           select language_record.oid
           from pg_catalog.pg_language as language_record
           where language_record.lanname = 'plpgsql'
         )
         and function_record.prorettype = 'record'::regtype
         and function_record.proretset
         and function_record.provolatile = 's'
         and function_record.prosecdef
         and pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
         and function_record.proconfig =
           array['search_path=pg_catalog, public, pg_temp']::text[]
     )
     or not pg_catalog.has_function_privilege('authenticated', v_v3, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_v3, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_v3, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           function_record.proacl,
           pg_catalog.acldefault('f', function_record.proowner)
         )
       ) as privilege_record
       where function_record.oid = v_v3
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Availability V3 hardening preflight failed: security contract differs.';
  end if;
end;
$preflight$;

create or replace function public.get_lane_booking_busy_ranges_v3(
  p_lane_id uuid,
  p_reservation_date date
)
returns table (
  start_time time without time zone,
  end_time time without time zone,
  busy_type text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.get_lane_booking_busy_ranges_v3(uuid, date)
  owner to postgres;

do $postflight$
declare
  v_v3 constant regprocedure :=
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::regprocedure;
  v_resolver constant regprocedure :=
    'public.resolve_lane_conflict_scope_v1(uuid)'::regprocedure;
  v_definition text := pg_catalog.lower(pg_catalog.pg_get_functiondef(v_v3));
begin
  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = 'get_lane_booking_busy_ranges_v3') <> 1
     or pg_catalog.strpos(
          v_definition,
          'into v_conflict_lane_ids'
        ) = 0
     or pg_catalog.strpos(
          v_definition,
          'from public.resolve_lane_conflict_scope_v1(p_lane_id)'
        ) = 0
     or pg_catalog.strpos(v_definition, 'with conflict_scope') > 0
     or pg_catalog.md5(pg_catalog.pg_get_functiondef(v_resolver))
          <> '073eeae67ebd3d9e8dbfcd614681d000' then
    raise exception 'Availability V3 hardening postflight failed: definition differs.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_proc as function_record
       where function_record.oid = v_v3
         and function_record.prolang = (
           select language_record.oid
           from pg_catalog.pg_language as language_record
           where language_record.lanname = 'plpgsql'
         )
         and function_record.prorettype = 'record'::regtype
         and function_record.proretset
         and function_record.provolatile = 's'
         and function_record.prosecdef
         and pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
         and function_record.proconfig =
           array['search_path=pg_catalog, public, pg_temp']::text[]
     )
     or not pg_catalog.has_function_privilege('authenticated', v_v3, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_v3, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_v3, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           function_record.proacl,
           pg_catalog.acldefault('f', function_record.proowner)
         )
       ) as privilege_record
       where function_record.oid = v_v3
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Availability V3 hardening postflight failed: security contract differs.';
  end if;
end;
$postflight$;
