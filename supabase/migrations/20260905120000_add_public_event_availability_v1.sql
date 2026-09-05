-- Public event availability must be computed from the complete registration set,
-- independently of owner-scoped event_registrations RLS, without exposing PII.

do $preflight$
begin
  if pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_registrations') is null then
    raise exception 'Public event availability preflight failed: required tables are absent.';
  end if;

  if pg_catalog.to_regprocedure('public.get_public_event_availability_v1()') is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'get_public_event_availability_v1'
     ) then
    raise exception 'Public event availability preflight failed: function name is already in use.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'event_registrations'
      and policyname = 'Users can view own event registrations'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and qual = '(user_id = auth.uid())'
  ) then
    raise exception 'Public event availability preflight failed: owner-scoped registration policy differs.';
  end if;

  if pg_catalog.to_regprocedure('public.register_for_event(uuid,boolean)') is null
     or pg_catalog.to_regprocedure('public.confirm_event_reserve_promotion(text)') is null
     or pg_catalog.to_regprocedure('public.cancel_event_registration(uuid)') is null then
    raise exception 'Public event availability preflight failed: capacity writers are incomplete.';
  end if;
end;
$preflight$;

create function public.get_public_event_availability_v1()
returns table (
  event_id uuid,
  title text,
  description text,
  event_date date,
  start_time time without time zone,
  end_time time without time zone,
  location text,
  price numeric,
  max_participants integer,
  registered_count integer,
  reserve_count integer,
  available_spots integer,
  sold_out boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  with registration_counts as (
    select
      registration.event_id,
      pg_catalog.count(*) filter (
        where pg_catalog.lower(pg_catalog.btrim(registration.registration_status))
          in ('registered', 'approved')
      )::integer as registered_count,
      pg_catalog.count(*) filter (
        where pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) = 'reserve'
      )::integer as reserve_count
    from public.event_registrations as registration
    where registration.event_id is not null
    group by registration.event_id
  ), public_events as (
    select
      event_record.id as event_id,
      event_record.title,
      coalesce(event_record.description, '') as description,
      event_record.event_date,
      event_record.start_time,
      event_record.end_time,
      coalesce(event_record.location, '') as location,
      event_record.price,
      event_record.max_participants,
      coalesce(registration_counts.registered_count, 0) as registered_count,
      coalesce(registration_counts.reserve_count, 0) as reserve_count
    from public.events as event_record
    left join registration_counts
      on registration_counts.event_id = event_record.id
    where event_record.is_active
  )
  select
    public_events.event_id,
    public_events.title,
    public_events.description,
    public_events.event_date,
    public_events.start_time,
    public_events.end_time,
    public_events.location,
    public_events.price,
    public_events.max_participants,
    public_events.registered_count,
    public_events.reserve_count,
    greatest(
      public_events.max_participants - public_events.registered_count,
      0
    )::integer as available_spots,
    public_events.registered_count >= public_events.max_participants as sold_out
  from public_events
  order by
    public_events.event_date,
    public_events.start_time,
    public_events.event_id;
$function$;

alter function public.get_public_event_availability_v1() owner to postgres;

revoke all on function public.get_public_event_availability_v1()
  from public, anon, authenticated, service_role;
grant execute on function public.get_public_event_availability_v1()
  to anon, authenticated;

comment on function public.get_public_event_availability_v1() is
  'Returns active public events with authoritative capacity and reserve counts, without registration rows or PII.';

do $postflight$
declare
  v_function_oid oid :=
    pg_catalog.to_regprocedure('public.get_public_event_availability_v1()');
begin
  if v_function_oid is null
     or not exists (
       select 1
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = procedure.proowner
       where procedure.oid = v_function_oid
         and procedure.prosecdef
         and procedure.provolatile = 's'
         and procedure.prorettype = 'record'::pg_catalog.regtype
         and procedure.proconfig =
           array['search_path=pg_catalog, public, pg_temp']::text[]
         and owner_role.rolname = 'postgres'
     ) then
    raise exception 'Public event availability postflight failed: function properties differ.';
  end if;

  if not pg_catalog.has_function_privilege('anon', v_function_oid, 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', v_function_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_function_oid, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           procedure.proacl,
           pg_catalog.acldefault('f', procedure.proowner)
         )
       ) as acl
       where procedure.oid = v_function_oid
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Public event availability postflight failed: ACL differs.';
  end if;
end;
$postflight$;
