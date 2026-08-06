do $preflight$
declare
  v_function_oid oid;
  v_function_definition text;
  v_function_statuses text[];
  v_constraint_statuses text[];
begin
  select function_record.oid
  into v_function_oid
  from pg_catalog.pg_proc as function_record
  join pg_catalog.pg_namespace as namespace_record
    on namespace_record.oid = function_record.pronamespace
  where namespace_record.nspname = 'public'
    and function_record.proname = 'get_lane_booking_busy_ranges'
    and function_record.prokind = 'f'
    and function_record.proargtypes = '2950 1082'::pg_catalog.oidvector;

  if v_function_oid is null then
    raise exception 'Brak public.get_lane_booking_busy_ranges(uuid,date).';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = function_record.pronamespace
    where namespace_record.nspname = 'public'
      and function_record.proname = 'get_lane_booking_busy_ranges'
  ) <> 1 then
    raise exception 'Nieoczekiwana liczba przeciążeń get_lane_booking_busy_ranges.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function_oid
      and function_record.prorettype = 'pg_catalog.record'::pg_catalog.regtype
      and function_record.proallargtypes = array[
        'pg_catalog.uuid'::pg_catalog.regtype,
        'pg_catalog.date'::pg_catalog.regtype,
        'time without time zone'::pg_catalog.regtype,
        'time without time zone'::pg_catalog.regtype
      ]::oid[]
      and function_record.proargmodes = array['i','i','t','t']::"char"[]
      and function_record.proargnames = array[
        'p_lane_id','p_reservation_date','start_time','end_time'
      ]::text[]
      and language_record.lanname = 'sql'
      and function_record.provolatile = 's'
      and function_record.prosecdef
      and pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
      and function_record.proconfig = array[
        'search_path=pg_catalog, public, pg_temp'
      ]::text[]
  ) then
    raise exception 'Krytyczny kontrakt get_lane_booking_busy_ranges różni się od oczekiwanego.';
  end if;

  if not pg_catalog.has_function_privilege(
       'authenticated', v_function_oid, 'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'service_role', v_function_oid, 'EXECUTE'
     )
     or pg_catalog.has_function_privilege('anon', v_function_oid, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           function_record.proacl,
           pg_catalog.acldefault('f', function_record.proowner)
         )
       ) as privilege_record
       where function_record.oid = v_function_oid
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'ACL get_lane_booking_busy_ranges różni się od oczekiwanego.';
  end if;

  if pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_lanes') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.lane_blocks') is null then
    raise exception 'Brak tabel wymaganych do rozszerzenia busy ranges.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.reservations'::pg_catalog.regclass
      and constraint_record.conname = 'reservations_no_overlapping_active_booking'
      and constraint_record.contype = 'x'
      and constraint_record.convalidated
  ) then
    raise exception 'Brak aktywnego exclusion constraint rezerwacji.';
  end if;

  select pg_catalog.lower(pg_catalog.pg_get_functiondef(v_function_oid))
  into v_function_definition;

  if v_function_definition !~ 'from[[:space:]]+public[.]reservations'
     or v_function_definition !~ 'from[[:space:]]+public[.]lane_blocks'
     or v_function_definition ~ 'public[.]event_lanes' then
    raise exception 'Definicja źródeł busy ranges różni się od oczekiwanego stanu bazowego.';
  end if;

  select pg_catalog.array_agg(status_match[1] order by status_match[1])
  into v_function_statuses
  from pg_catalog.regexp_matches(
    v_function_definition,
    '''(completed|no_show|cancelled|canceled|cancelled_by_admin|cancelled_by_user)''',
    'g'
  ) as status_match;

  select pg_catalog.array_agg(status_match[1] order by status_match[1])
  into v_constraint_statuses
  from pg_catalog.pg_constraint as constraint_record
  cross join lateral pg_catalog.regexp_matches(
    pg_catalog.lower(
      pg_catalog.pg_get_constraintdef(constraint_record.oid)
    ),
    '''(completed|no_show|cancelled|canceled|cancelled_by_admin|cancelled_by_user)''',
    'g'
  ) as status_match
  where constraint_record.conrelid = 'public.reservations'::pg_catalog.regclass
    and constraint_record.conname = 'reservations_no_overlapping_active_booking';

  if v_function_statuses is distinct from array[
       'canceled','cancelled','cancelled_by_admin','cancelled_by_user',
       'completed','no_show'
     ]::text[]
     or v_constraint_statuses is distinct from v_function_statuses then
    raise exception 'Statusy busy ranges i exclusion constraint nie są zgodne.';
  end if;
end;
$preflight$;

create or replace function public.get_lane_booking_busy_ranges(
  p_lane_id uuid,
  p_reservation_date date
)
returns table (
  start_time time without time zone,
  end_time time without time zone
)
language sql
stable
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.get_lane_booking_busy_ranges(uuid, date)
owner to postgres;

alter function public.get_lane_booking_busy_ranges(uuid, date)
set search_path to pg_catalog, public, pg_temp;

comment on function public.get_lane_booking_busy_ranges(uuid, date) is
  'Zwraca bez danych klienta zajęte przedziały aktywnej osi do informacyjnego podglądu dostępności.';

revoke all on function public.get_lane_booking_busy_ranges(uuid, date)
from public;
revoke all on function public.get_lane_booking_busy_ranges(uuid, date)
from anon;
revoke all on function public.get_lane_booking_busy_ranges(uuid, date)
from authenticated;
revoke all on function public.get_lane_booking_busy_ranges(uuid, date)
from service_role;

grant execute on function public.get_lane_booking_busy_ranges(uuid, date)
to authenticated;
grant execute on function public.get_lane_booking_busy_ranges(uuid, date)
to service_role;
