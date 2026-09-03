do $preflight$
begin
  if pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.profiles') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null then
    raise exception 'SEC-005 preflight failed: required tables are missing.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = 'public.reservations'::pg_catalog.regclass
      and attribute.attname = 'check_in_token'
      and attribute.atttypid = 'uuid'::pg_catalog.regtype
      and attribute.attnotnull
      and not attribute.attisdropped
  ) then
    raise exception 'SEC-005 preflight failed: reservations.check_in_token contract differs.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.update_reservation_attendance(uuid,text)'
     ) is null then
    raise exception 'SEC-005 preflight failed: attendance writer is missing.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname in (
        'is_reservation_check_in_token_usable_v1',
        'get_public_check_in_status_v1',
        'get_check_in_reservation_v1'
      )
  ) then
    raise exception 'SEC-005 preflight failed: target function name already exists.';
  end if;
end;
$preflight$;

create function public.is_reservation_check_in_token_usable_v1(
  p_reservation_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_reservation_status text,
  p_now timestamp with time zone
)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog, public, pg_temp
as $function$
  select
    p_reservation_date is not null
    and p_start_time is not null
    and p_end_time is not null
    and p_end_time > p_start_time
    and pg_catalog.lower(pg_catalog.btrim(p_reservation_status))
      in ('confirmed', 'completed')
    and p_now >= (
      (p_reservation_date + p_start_time)
        at time zone 'Europe/Warsaw'
      - interval '24 hours'
    )
    and p_now <= (
      (p_reservation_date + p_end_time)
        at time zone 'Europe/Warsaw'
      + interval '2 hours'
    );
$function$;

alter function public.is_reservation_check_in_token_usable_v1(
  date,
  time without time zone,
  time without time zone,
  text,
  timestamp with time zone
) owner to postgres;

comment on function public.is_reservation_check_in_token_usable_v1(
  date,
  time without time zone,
  time without time zone,
  text,
  timestamp with time zone
) is 'Private shared SEC-005 check-in window and cancellation-state predicate.';

revoke all on function public.is_reservation_check_in_token_usable_v1(
  date,
  time without time zone,
  time without time zone,
  text,
  timestamp with time zone
) from public, anon, authenticated, service_role;

create function public.get_public_check_in_status_v1(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_attendance_status text;
  v_checked_in_at timestamp with time zone;
begin
  if p_token is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'unavailable'
    );
  end if;

  select
    reservation.attendance_status,
    reservation.checked_in_at
  into
    v_attendance_status,
    v_checked_in_at
  from public.reservations as reservation
  where reservation.check_in_token = p_token
    and public.is_reservation_check_in_token_usable_v1(
      reservation.reservation_date,
      reservation.start_time,
      reservation.end_time,
      reservation.reservation_status,
      pg_catalog.transaction_timestamp()
    );

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'unavailable'
    );
  end if;

  if v_checked_in_at is not null
     or coalesce(v_attendance_status, 'planned')
       in ('present', 'completed') then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'code', 'already_checked_in'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'code', 'ready'
  );
end;
$function$;

alter function public.get_public_check_in_status_v1(uuid) owner to postgres;

comment on function public.get_public_check_in_status_v1(uuid) is
  'Returns only a neutral check-in token state; never reservation identifiers or personal data.';

revoke all on function public.get_public_check_in_status_v1(uuid)
from public, authenticated, service_role;
grant execute on function public.get_public_check_in_status_v1(uuid) to anon;

create function public.get_check_in_reservation_v1(p_token uuid)
returns table (
  reservation_id uuid,
  user_id uuid,
  customer_name text,
  customer_email text,
  customer_phone text,
  reservation_date date,
  start_time time without time zone,
  end_time time without time zone,
  reservation_status text,
  attendance_status text,
  payment_status text,
  checked_in_at timestamp with time zone,
  completed_at timestamp with time zone,
  price numeric,
  lane_id uuid,
  lane_name text,
  lane_resource_kind text,
  lane_parent_lane_id uuid,
  lane_display_order integer,
  lane_is_active boolean,
  parent_lane_id uuid,
  parent_lane_name text,
  parent_lane_resource_kind text,
  parent_lane_parent_lane_id uuid,
  parent_lane_display_order integer,
  parent_lane_is_active boolean
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role text;
begin
  if v_actor_user_id is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_user_id;

  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    raise exception 'Check-in staff access is required.'
      using errcode = '42501';
  end if;

  if p_token is null then
    return;
  end if;

  return query
  select
    reservation.id,
    reservation.user_id,
    reservation.customer_name,
    reservation.customer_email,
    reservation.customer_phone,
    reservation.reservation_date,
    reservation.start_time,
    reservation.end_time,
    reservation.reservation_status,
    reservation.attendance_status,
    reservation.payment_status,
    reservation.checked_in_at,
    reservation.completed_at,
    reservation.price,
    lane.id,
    lane.name,
    lane.resource_kind,
    lane.parent_lane_id,
    lane.display_order,
    lane.is_active,
    parent.id,
    parent.name,
    parent.resource_kind,
    parent.parent_lane_id,
    parent.display_order,
    parent.is_active
  from public.reservations as reservation
  left join public.shooting_lanes as lane
    on lane.id = reservation.lane_id
  left join public.shooting_lanes as parent
    on parent.id = lane.parent_lane_id
  where reservation.check_in_token = p_token
    and public.is_reservation_check_in_token_usable_v1(
      reservation.reservation_date,
      reservation.start_time,
      reservation.end_time,
      reservation.reservation_status,
      pg_catalog.transaction_timestamp()
    );
end;
$function$;

alter function public.get_check_in_reservation_v1(uuid) owner to postgres;

comment on function public.get_check_in_reservation_v1(uuid) is
  'Resolves an active-window check-in token to an allowlisted operational DTO for admin or employee only.';

revoke all on function public.get_check_in_reservation_v1(uuid)
from public, anon, service_role;
grant execute on function public.get_check_in_reservation_v1(uuid)
to authenticated;
