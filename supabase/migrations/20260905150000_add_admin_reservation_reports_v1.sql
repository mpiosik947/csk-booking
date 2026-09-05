-- REPORTS-6A: authoritative, bounded and admin-only reservation reporting.

do $preflight$
begin
  if pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.lane_booking_rules') is null
     or pg_catalog.to_regclass('public.profiles') is null then
    raise exception 'REPORTS-6A preflight failed: required relations are absent.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.admin_get_reservation_report_v1(date,date,integer,integer)'
     ) is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'admin_get_reservation_report_v1'
     ) then
    raise exception 'REPORTS-6A preflight failed: function name is already in use.';
  end if;

  if pg_catalog.to_regclass(
       'public.reservations_reporting_date_time_idx'
     ) is not null then
    raise exception 'REPORTS-6A preflight failed: reporting index name is already in use.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'reservations'
      and policyname = 'Admins and staff can view all reservations'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and qual = 'is_admin_or_employee()'
  ) then
    raise exception 'REPORTS-6A preflight failed: reservation read policy differs.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_attribute
    where attrelid = 'public.reservations'::pg_catalog.regclass
      and attname in (
        'reservation_date', 'start_time', 'end_time', 'duration_minutes',
        'reservation_status', 'payment_status', 'lane_id',
        'lane_name_snapshot', 'total_price'
      )
      and not attisdropped
    group by attrelid
    having pg_catalog.count(*) = 9
  ) then
    raise exception 'REPORTS-6A preflight failed: reservation reporting columns differ.';
  end if;
end;
$preflight$;

create index reservations_reporting_date_time_idx
on public.reservations (reservation_date, start_time, id);

create function public.admin_get_reservation_report_v1(
  p_start_date date,
  p_end_date date,
  p_detail_limit integer default 50,
  p_detail_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_days integer;
  v_result jsonb;
begin
  if v_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'code', 'not_allowed'
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_role
  from public.profiles as profile
  where profile.user_id = v_user_id;

  if v_role is distinct from 'admin' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'code', 'not_allowed'
    );
  end if;

  if p_start_date is null
     or p_end_date is null
     or p_end_date < p_start_date
     or p_end_date - p_start_date + 1 > 366
     or p_detail_limit is null
     or p_detail_limit < 1
     or p_detail_limit > 100
     or p_detail_offset is null
     or p_detail_offset < 0
     or p_detail_offset > 1000000 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'code', 'invalid_input'
    );
  end if;

  v_days := p_end_date - p_start_date + 1;

  with filtered_reservations as materialized (
    select
      reservation.id,
      reservation.lane_id,
      reservation.lane_name_snapshot,
      reservation.customer_name,
      reservation.customer_email,
      reservation.customer_phone,
      reservation.reservation_date,
      reservation.start_time,
      reservation.end_time,
      reservation.duration_minutes,
      reservation.total_price,
      pg_catalog.lower(
        pg_catalog.btrim(reservation.reservation_status)
      ) as reservation_status,
      pg_catalog.lower(
        pg_catalog.btrim(reservation.payment_status)
      ) as payment_status
    from public.reservations as reservation
    where reservation.reservation_date >= p_start_date
      and reservation.reservation_date <= p_end_date
  ), reportable_reservations as materialized (
    select *
    from filtered_reservations
    where reservation_status in ('confirmed', 'completed')
  ), resource_configuration as (
    select
      resource.id,
      resource.resource_kind,
      resource.parent_lane_id,
      resource.is_active,
      resource.positions_bookable,
      coalesce(booking_rule.online_bookable, false) as online_bookable
    from public.shooting_lanes as resource
    left join public.lane_booking_rules as booking_rule
      on booking_rule.lane_id = resource.id
  ), root_modes as (
    select
      root.id as root_id,
      root.is_active as root_is_active,
      root.positions_bookable
        and exists (
          select 1
          from resource_configuration as child
          where child.resource_kind = 'position'
            and child.parent_lane_id = root.id
            and child.is_active
            and child.online_bookable
        ) as uses_position_units
    from resource_configuration as root
    where root.resource_kind = 'lane'
      and root.parent_lane_id is null
  ), effective_units as (
    select
      root.root_id,
      case
        when root.uses_position_units then child.id
        else root.root_id
      end as unit_id
    from root_modes as root
    left join resource_configuration as child
      on root.uses_position_units
     and child.resource_kind = 'position'
     and child.parent_lane_id = root.root_id
     and child.is_active
     and child.online_bookable
    where root.root_is_active
      and (not root.uses_position_units or child.id is not null)
  ), resource_units as (
    select unit.root_id as resource_id, unit.unit_id
    from effective_units as unit

    union all

    select
      child.id as resource_id,
      case
        when root.uses_position_units then child.id
        else root.root_id
      end as unit_id
    from resource_configuration as child
    join root_modes as root
      on root.root_id = child.parent_lane_id
    where child.resource_kind = 'position'
      and root.root_is_active
      and child.is_active
      and (
        not root.uses_position_units
        or child.online_bookable
      )
  ), reservation_unit_ranges as (
    select
      reservation.reservation_date,
      mapping.unit_id,
      pg_catalog.int4range(
        case
          when reservation.start_time < time '08:00' then 8 * 60
          else (
            pg_catalog.date_part('hour', reservation.start_time)::integer * 60
            + pg_catalog.date_part('minute', reservation.start_time)::integer
          )
        end,
        case
          when reservation.end_time > time '20:00' then 20 * 60
          else (
            pg_catalog.date_part('hour', reservation.end_time)::integer * 60
            + pg_catalog.date_part('minute', reservation.end_time)::integer
          )
        end,
        '[)'
      ) as occupied_range
    from reportable_reservations as reservation
    join resource_units as mapping
      on mapping.resource_id = reservation.lane_id
    where reservation.start_time < time '20:00'
      and reservation.end_time > time '08:00'
  ), unit_multiranges as (
    select
      reservation_date,
      unit_id,
      pg_catalog.range_agg(occupied_range) as occupied_ranges
    from reservation_unit_ranges
    where not pg_catalog.isempty(occupied_range)
    group by reservation_date, unit_id
  ), merged_ranges as (
    select merged.occupied_range
    from unit_multiranges as unit_ranges
    cross join lateral pg_catalog.unnest(
      unit_ranges.occupied_ranges
    ) as merged(occupied_range)
  ), occupancy as (
    select coalesce(
      pg_catalog.sum(
        pg_catalog.upper(occupied_range)
        - pg_catalog.lower(occupied_range)
      ),
      0
    )::integer as occupied_minutes
    from merged_ranges
  ), capacity as (
    select pg_catalog.count(distinct unit_id)::integer as effective_capacity
    from effective_units
  ), totals as (
    select
      pg_catalog.count(*) filter (
        where reservation_status = 'confirmed'
      )::integer as active_reservation_count,
      pg_catalog.count(*) filter (
        where reservation_status = 'completed'
      )::integer as completed_reservation_count,
      pg_catalog.count(*) filter (
        where reservation_status in (
          'cancelled', 'canceled', 'cancelled_by_admin', 'cancelled_by_user'
        )
      )::integer as cancelled_reservation_count,
      pg_catalog.count(*) filter (
        where reservation_status = 'no_show'
      )::integer as no_show_reservation_count,
      coalesce(pg_catalog.sum(total_price) filter (
        where reservation_status in ('confirmed', 'completed')
      ), 0)::numeric as planned_revenue,
      coalesce(pg_catalog.sum(total_price) filter (
        where reservation_status in ('confirmed', 'completed')
          and payment_status in ('paid', 'paid_on_site')
      ), 0)::numeric as paid_revenue,
      coalesce(pg_catalog.sum(total_price) filter (
        where reservation_status in ('confirmed', 'completed')
          and payment_status in ('unpaid', 'pay_on_site')
      ), 0)::numeric as outstanding_revenue,
      pg_catalog.count(*)::integer as detail_total
    from filtered_reservations
  ), daily_values as (
    select
      reservation_date,
      pg_catalog.sum(total_price)::numeric as planned_revenue
    from reportable_reservations
    group by reservation_date
  ), best_day as (
    select reservation_date, planned_revenue
    from daily_values
    order by planned_revenue desc, reservation_date
    limit 1
  ), resource_values as (
    select
      lane_id,
      pg_catalog.count(*)::integer as reservation_count,
      (
        pg_catalog.array_agg(
          lane_name_snapshot
          order by reservation_date desc, start_time desc, id desc
        )
      )[1] as lane_name
    from reportable_reservations
    group by lane_id
  ), top_resource as (
    select lane_id, lane_name, reservation_count
    from resource_values
    order by reservation_count desc, lane_id
    limit 1
  ), detail_page as (
    select
      reservation.id,
      reservation.lane_id,
      reservation.lane_name_snapshot,
      reservation.customer_name,
      reservation.customer_email,
      reservation.customer_phone,
      reservation.reservation_date,
      reservation.start_time,
      reservation.end_time,
      reservation.duration_minutes,
      reservation.total_price,
      reservation.reservation_status,
      reservation.payment_status,
      resource.resource_kind,
      resource.parent_lane_id,
      case
        when resource.resource_kind = 'position' and parent.id is not null
          then parent.name || ' — ' || reservation.lane_name_snapshot
        else reservation.lane_name_snapshot
      end as lane_display_name
    from filtered_reservations as reservation
    left join public.shooting_lanes as resource
      on resource.id = reservation.lane_id
    left join public.shooting_lanes as parent
      on parent.id = resource.parent_lane_id
    order by
      reservation.reservation_date,
      reservation.start_time,
      reservation.id
    limit p_detail_limit
    offset p_detail_offset
  )
  select pg_catalog.jsonb_build_object(
    'ok', true,
    'code', 'ok',
    'contract_version', 1,
    'range', pg_catalog.jsonb_build_object(
      'start_date', p_start_date,
      'end_date', p_end_date,
      'end_inclusive', true,
      'days', v_days,
      'time_zone', 'Europe/Warsaw',
      'opening_start', '08:00',
      'opening_end', '20:00',
      'opening_minutes_per_day', 720
    ),
    'summary', pg_catalog.jsonb_build_object(
      'active_reservation_count', totals.active_reservation_count,
      'completed_reservation_count', totals.completed_reservation_count,
      'cancelled_reservation_count', totals.cancelled_reservation_count,
      'no_show_reservation_count', totals.no_show_reservation_count,
      'planned_revenue', totals.planned_revenue,
      'paid_revenue', totals.paid_revenue,
      'outstanding_revenue', totals.outstanding_revenue,
      'effective_capacity', capacity.effective_capacity,
      'occupied_minutes', occupancy.occupied_minutes,
      'available_minutes', capacity.effective_capacity * 720 * v_days,
      'occupancy_percent', case
        when capacity.effective_capacity * 720 * v_days = 0 then 0
        when pg_catalog.round(
          occupancy.occupied_minutes::numeric * 100
          / (capacity.effective_capacity * 720 * v_days)
        ) < 0 then 0
        when pg_catalog.round(
          occupancy.occupied_minutes::numeric * 100
          / (capacity.effective_capacity * 720 * v_days)
        ) > 100 then 100
        else pg_catalog.round(
          occupancy.occupied_minutes::numeric * 100
          / (capacity.effective_capacity * 720 * v_days)
        )::integer
      end,
      'best_day', case
        when best_day.reservation_date is null then null
        else pg_catalog.jsonb_build_object(
          'date', best_day.reservation_date,
          'planned_revenue', best_day.planned_revenue
        )
      end,
      'top_resource', case
        when top_resource.lane_id is null then null
        else pg_catalog.jsonb_build_object(
          'lane_id', top_resource.lane_id,
          'lane_name', top_resource.lane_name,
          'reservation_count', top_resource.reservation_count
        )
      end
    ),
    'details', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', detail.id,
          'lane_id', detail.lane_id,
          'lane_name_snapshot', detail.lane_name_snapshot,
          'lane_display_name', detail.lane_display_name,
          'resource_kind', detail.resource_kind,
          'parent_lane_id', detail.parent_lane_id,
          'customer_name', detail.customer_name,
          'customer_email', detail.customer_email,
          'customer_phone', detail.customer_phone,
          'reservation_date', detail.reservation_date,
          'start_time', detail.start_time,
          'end_time', detail.end_time,
          'duration_minutes', detail.duration_minutes,
          'total_price', detail.total_price,
          'reservation_status', detail.reservation_status,
          'payment_status', detail.payment_status
        ) order by detail.reservation_date, detail.start_time, detail.id
      )
      from detail_page as detail
    ), '[]'::jsonb),
    'pagination', pg_catalog.jsonb_build_object(
      'total', totals.detail_total,
      'limit', p_detail_limit,
      'offset', p_detail_offset
    ),
    'history', pg_catalog.jsonb_build_object(
      'name_basis', 'reservation_snapshot',
      'position_parent_name_basis', 'current_configuration',
      'capacity_basis', 'current_configuration'
    )
  )
  into v_result
  from totals
  cross join capacity
  cross join occupancy
  left join best_day on true
  left join top_resource on true;

  return v_result;
end;
$function$;

alter function public.admin_get_reservation_report_v1(
  date, date, integer, integer
) owner to postgres;

revoke all on function public.admin_get_reservation_report_v1(
  date, date, integer, integer
) from public, anon, authenticated, service_role;

grant execute on function public.admin_get_reservation_report_v1(
  date, date, integer, integer
) to authenticated;

comment on function public.admin_get_reservation_report_v1(
  date, date, integer, integer
) is
  'Admin-only bounded reservation report. Uses 08:00-20:00, inclusive civil dates, canonical statuses and reservation snapshots; historical capacity is explicitly based on current configuration.';

do $postflight$
declare
  v_function_oid oid := pg_catalog.to_regprocedure(
    'public.admin_get_reservation_report_v1(date,date,integer,integer)'
  );
begin
  if v_function_oid is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'admin_get_reservation_report_v1'
     ) <> 1
     or not exists (
       select 1
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = procedure.proowner
       where procedure.oid = v_function_oid
         and procedure.prosecdef
         and procedure.provolatile = 's'
         and procedure.prorettype = 'jsonb'::pg_catalog.regtype
         and procedure.proconfig =
           array['search_path=pg_catalog, public, pg_temp']::text[]
         and owner_role.rolname = 'postgres'
     ) then
    raise exception 'REPORTS-6A postflight failed: function properties differ.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class as index_relation
    join pg_catalog.pg_index as index_metadata
      on index_metadata.indexrelid = index_relation.oid
    where index_relation.oid =
      'public.reservations_reporting_date_time_idx'::pg_catalog.regclass
      and index_metadata.indrelid = 'public.reservations'::pg_catalog.regclass
      and index_metadata.indisvalid
      and index_metadata.indisready
      and pg_catalog.pg_get_indexdef(index_relation.oid) =
        'CREATE INDEX reservations_reporting_date_time_idx ON public.reservations USING btree (reservation_date, start_time, id)'
  ) then
    raise exception 'REPORTS-6A postflight failed: reporting index differs.';
  end if;

  if not pg_catalog.has_function_privilege(
       'authenticated', v_function_oid, 'EXECUTE'
     )
     or pg_catalog.has_function_privilege('anon', v_function_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege(
       'service_role', v_function_oid, 'EXECUTE'
     )
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
    raise exception 'REPORTS-6A postflight failed: function ACL differs.';
  end if;
end;
$postflight$;
