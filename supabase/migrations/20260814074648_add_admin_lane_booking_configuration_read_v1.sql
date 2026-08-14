-- Admin-only, read-only snapshot for the lane configuration panel.
do $preflight$
declare
  v_missing_columns text;
begin
  if pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.lane_booking_rules') is null
     or pg_catalog.to_regclass('public.lane_booking_durations') is null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is null
     or pg_catalog.to_regclass('public.profiles') is null
     or pg_catalog.to_regprocedure('auth.uid()') is null then
    raise exception 'Admin lane configuration read preflight failed: required objects are missing.';
  end if;

  select pg_catalog.string_agg(
    expected.table_name || '.' || expected.column_name,
    ', ' order by expected.table_name, expected.column_name
  )
  into v_missing_columns
  from (values
    ('shooting_lanes', 'id', 'uuid', true),
    ('shooting_lanes', 'name', 'text', true),
    ('shooting_lanes', 'resource_kind', 'text', true),
    ('shooting_lanes', 'parent_lane_id', 'uuid', false),
    ('shooting_lanes', 'display_order', 'integer', true),
    ('shooting_lanes', 'is_active', 'boolean', true),
    ('shooting_lanes', 'max_shooters', 'integer', true),
    ('shooting_lanes', 'whole_lane_bookable', 'boolean', true),
    ('shooting_lanes', 'positions_bookable', 'boolean', true),
    ('shooting_lanes', 'booking_step_minutes', 'integer', true),
    ('shooting_lanes', 'currency_code', 'character(3)', true),
    ('lane_booking_rules', 'lane_id', 'uuid', true),
    ('lane_booking_rules', 'online_bookable', 'boolean', true),
    ('lane_booking_rules', 'max_people_online', 'integer', true),
    ('lane_booking_durations', 'id', 'uuid', true),
    ('lane_booking_durations', 'lane_id', 'uuid', true),
    ('lane_booking_durations', 'duration_minutes', 'integer', true),
    ('lane_booking_durations', 'display_order', 'integer', true),
    ('lane_booking_durations', 'is_active', 'boolean', true),
    ('lane_pricing_rules', 'id', 'uuid', true),
    ('lane_pricing_rules', 'lane_id', 'uuid', true),
    ('lane_pricing_rules', 'day_group', 'text', true),
    ('lane_pricing_rules', 'min_shooters', 'integer', true),
    ('lane_pricing_rules', 'max_shooters', 'integer', true),
    ('lane_pricing_rules', 'label', 'text', true),
    ('lane_pricing_rules', 'hourly_price', 'numeric(12,2)', true),
    ('lane_pricing_rules', 'display_order', 'integer', true),
    ('lane_pricing_rules', 'is_active', 'boolean', true),
    ('profiles', 'user_id', 'uuid', true),
    ('profiles', 'role', 'text', false)
  ) as expected(table_name, column_name, formatted_type, required_not_null)
  where not exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = pg_catalog.to_regclass(
            'public.' || expected.table_name
          )
      and attribute.attname = expected.column_name
      and attribute.attnum > 0
      and not attribute.attisdropped
      and pg_catalog.format_type(attribute.atttypid, attribute.atttypmod)
            = expected.formatted_type
      and (
        not expected.required_not_null
        or attribute.attnotnull
      )
  );

  if v_missing_columns is not null then
    raise exception 'Admin lane configuration read preflight failed: column contract differs: %.',
      v_missing_columns;
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid =
             'public.lane_booking_rules'::pg_catalog.regclass
         and constraint_record.conname = 'lane_booking_rules_pkey'
         and constraint_record.contype = 'p'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid =
             'public.lane_booking_durations'::pg_catalog.regclass
         and constraint_record.conname =
             'lane_booking_durations_lane_duration_key'
         and constraint_record.contype = 'u'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid =
             'public.lane_pricing_rules'::pg_catalog.regclass
         and constraint_record.conname =
             'lane_pricing_rules_active_ranges_excl'
         and constraint_record.contype = 'x'
     ) then
    raise exception 'Admin lane configuration read preflight failed: uniqueness contract differs.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.admin_get_lane_booking_configuration_v1()'
     ) is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'admin_get_lane_booking_configuration_v1'
     ) then
    raise exception 'Admin lane configuration read preflight failed: RPC already exists.';
  end if;
end;
$preflight$;

create function public.admin_get_lane_booking_configuration_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.admin_get_lane_booking_configuration_v1()
owner to postgres;

comment on function public.admin_get_lane_booking_configuration_v1() is
  'Returns one deterministic admin-only snapshot of all lane booking resources, including dormant positions and resource-owned configuration.';

revoke all on function public.admin_get_lane_booking_configuration_v1()
from public;
revoke all on function public.admin_get_lane_booking_configuration_v1()
from anon;
revoke all on function public.admin_get_lane_booking_configuration_v1()
from authenticated;
revoke all on function public.admin_get_lane_booking_configuration_v1()
from service_role;

grant execute on function public.admin_get_lane_booking_configuration_v1()
to authenticated;

do $postflight$
declare
  v_function oid := pg_catalog.to_regprocedure(
    'public.admin_get_lane_booking_configuration_v1()'
  );
begin
  if v_function is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'admin_get_lane_booking_configuration_v1'
     ) <> 1
     or (
       select owner_role.rolname <> 'postgres'
          or language_record.lanname <> 'plpgsql'
          or procedure.provolatile <> 's'
          or not procedure.prosecdef
          or procedure.prorettype <> 'pg_catalog.jsonb'::pg_catalog.regtype
          or procedure.proconfig is distinct from
               array['search_path=pg_catalog, public, pg_temp']::text[]
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = procedure.proowner
       join pg_catalog.pg_language as language_record
         on language_record.oid = procedure.prolang
       where procedure.oid = v_function
     )
     or not pg_catalog.has_function_privilege(
       'authenticated', v_function, 'EXECUTE'
     )
     or pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
     or pg_catalog.has_function_privilege(
       'service_role', v_function, 'EXECUTE'
     )
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(coalesce(
         procedure.proacl,
         pg_catalog.acldefault('f', procedure.proowner)
       )) as function_acl
       where procedure.oid = v_function
         and function_acl.grantee = 0
         and function_acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Admin lane configuration read postflight failed: function contract differs.';
  end if;
end;
$postflight$;
