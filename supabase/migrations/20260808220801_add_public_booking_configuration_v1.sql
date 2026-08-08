-- ETAP 6B-1A: expose one fail-closed, public booking configuration snapshot.

do $preflight$
declare
  v_function_count integer;
begin
  if pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.lane_booking_rules') is null
     or pg_catalog.to_regclass('public.lane_booking_durations') is null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is null then
    raise exception 'Preflight failed: required booking configuration tables are missing.';
  end if;

  select pg_catalog.count(*)
  into v_function_count
  from pg_catalog.pg_proc as procedure_record
  join pg_catalog.pg_namespace as namespace_record
    on namespace_record.oid = procedure_record.pronamespace
  where namespace_record.nspname = 'public'
    and procedure_record.proname = 'get_public_booking_configuration_v1';

  if v_function_count <> 0 then
    raise exception 'Preflight failed: get_public_booking_configuration_v1 already exists.';
  end if;

  if not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'resource_kind' and data_type = 'text'
     )
     or not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'parent_lane_id' and data_type = 'uuid'
     )
     or not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'whole_lane_bookable' and data_type = 'boolean'
     )
     or not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'positions_bookable' and data_type = 'boolean'
     )
     or not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public' and table_name = 'lane_booking_rules'
         and column_name = 'online_bookable' and data_type = 'boolean'
     )
     or not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public' and table_name = 'lane_booking_rules'
         and column_name = 'max_people_online' and data_type = 'integer'
     ) then
    raise exception 'Preflight failed: lane hierarchy or booking-rule contract is missing.';
  end if;
end;
$preflight$;

create function public.get_public_booking_configuration_v1()
returns table (
  lane_id uuid,
  parent_lane_id uuid,
  resource_kind text,
  name text,
  display_name text,
  display_order integer,
  effective_online_bookable boolean,
  whole_lane_bookable boolean,
  positions_bookable boolean,
  max_people_online integer,
  booking_step_minutes integer,
  currency_code text,
  durations_minutes integer[],
  pricing jsonb
)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
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
$function$;

alter function public.get_public_booking_configuration_v1() owner to postgres;

revoke all on function public.get_public_booking_configuration_v1() from public;
revoke all on function public.get_public_booking_configuration_v1() from anon;
revoke all on function public.get_public_booking_configuration_v1() from authenticated;
revoke all on function public.get_public_booking_configuration_v1() from service_role;

grant execute on function public.get_public_booking_configuration_v1() to anon;
grant execute on function public.get_public_booking_configuration_v1() to authenticated;
grant execute on function public.get_public_booking_configuration_v1() to service_role;

comment on function public.get_public_booking_configuration_v1() is
  'Returns the fail-closed public booking hierarchy, durations and pricing without internal identifiers or metadata.';

do $postflight$
declare
  v_function oid := pg_catalog.to_regprocedure(
    'public.get_public_booking_configuration_v1()'
  );
begin
  if v_function is null
     or (select pg_catalog.count(*)
         from pg_catalog.pg_proc as procedure_record
         join pg_catalog.pg_namespace as namespace_record
           on namespace_record.oid = procedure_record.pronamespace
         where namespace_record.nspname = 'public'
           and procedure_record.proname = 'get_public_booking_configuration_v1') <> 1 then
    raise exception 'Postflight failed: public booking configuration RPC signature is invalid.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc as procedure_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = procedure_record.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = procedure_record.prolang
    where procedure_record.oid = v_function
      and owner_role.rolname = 'postgres'
      and language_record.lanname = 'sql'
      and procedure_record.prosecdef
      and procedure_record.provolatile = 's'
      and procedure_record.prorettype = 'record'::pg_catalog.regtype
      and procedure_record.proconfig = array[
        'search_path=pg_catalog, public, pg_temp'
      ]::text[]
  ) then
    raise exception 'Postflight failed: public booking configuration RPC properties are invalid.';
  end if;

  if exists (
       select 1
       from pg_catalog.pg_proc as procedure_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           procedure_record.proacl,
           pg_catalog.acldefault('f', procedure_record.proowner)
         )
       ) as acl
       where procedure_record.oid = v_function
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     )
     or exists (
       select 1
       from (values ('anon'::text), ('authenticated'::text), ('service_role'::text))
         as required_role(role_name)
       where not pg_catalog.has_function_privilege(
         required_role.role_name,
         v_function,
         'EXECUTE'
       )
     ) then
    raise exception 'Postflight failed: public booking configuration RPC ACL is invalid.';
  end if;
end;
$postflight$;
