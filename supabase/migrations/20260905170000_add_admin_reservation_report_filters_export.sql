-- REPORTS-6B: backend filters shared by KPI/details and PII-minimal export.

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.admin_get_reservation_report_v1(date,date,integer,integer)') is null then
    raise exception 'REPORTS-6B preflight failed: REPORTS-6A v1 is absent.';
  end if;
  if pg_catalog.to_regprocedure('public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text)') is not null
     or pg_catalog.to_regprocedure('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)') is not null
     or pg_catalog.to_regprocedure('public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)') is not null then
    raise exception 'REPORTS-6B preflight failed: target signature already exists.';
  end if;
  if exists (
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in (
      '_admin_reservation_report_rows_v2',
      'admin_get_reservation_report_v2',
      'admin_get_reservation_report_export_v1'
    )
  ) then
    raise exception 'REPORTS-6B preflight failed: target function name already exists.';
  end if;
end
$preflight$;

create function public._admin_reservation_report_rows_v2(
  p_start_date date,
  p_end_date date,
  p_resource_id uuid,
  p_reservation_status text,
  p_payment_status text,
  p_booking_type text
)
returns table(
  id uuid,
  lane_id uuid,
  lane_name_snapshot text,
  customer_name text,
  customer_email text,
  customer_phone text,
  reservation_date date,
  start_time time without time zone,
  end_time time without time zone,
  duration_minutes integer,
  total_price numeric,
  reservation_status text,
  payment_status text,
  resource_kind text,
  parent_lane_id uuid,
  lane_display_name text,
  booking_type text
)
language sql
stable
set search_path = pg_catalog, public, pg_temp
as $function$
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
    pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)),
    pg_catalog.lower(pg_catalog.btrim(reservation.payment_status)),
    resource.resource_kind,
    resource.parent_lane_id,
    case
      when resource.resource_kind='position' and parent.id is not null
        then parent.name || ' — ' || reservation.lane_name_snapshot
      else reservation.lane_name_snapshot
    end,
    case when resource.resource_kind='position' then 'single_position' else 'whole_lane' end
  from public.reservations reservation
  join public.shooting_lanes resource on resource.id=reservation.lane_id
  left join public.shooting_lanes parent on parent.id=resource.parent_lane_id
  where reservation.reservation_date between p_start_date and p_end_date
    and (
      p_resource_id is null
      or resource.id=p_resource_id
      or resource.parent_lane_id=p_resource_id
    )
    and (
      p_reservation_status is null
      or pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))=p_reservation_status
      or (
        p_reservation_status='cancelled'
        and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)) in
          ('cancelled','canceled','cancelled_by_admin','cancelled_by_user')
      )
    )
    and (
      p_payment_status is null
      or pg_catalog.lower(pg_catalog.btrim(reservation.payment_status))=p_payment_status
    )
    and (
      p_booking_type is null
      or case when resource.resource_kind='position' then 'single_position' else 'whole_lane' end=p_booking_type
    );
$function$;

alter function public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text) owner to postgres;
revoke all on function public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text) from public, anon, authenticated, service_role;

create function public.admin_get_reservation_report_v2(
  p_start_date date,
  p_end_date date,
  p_resource_id uuid default null,
  p_reservation_status text default null,
  p_payment_status text default null,
  p_booking_type text default null,
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
  v_user_id uuid:=auth.uid();
  v_role text;
  v_days integer;
  v_status text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_reservation_status)),'');
  v_payment text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_payment_status)),'');
  v_type text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_booking_type)),'');
  v_result jsonb;
begin
  if v_user_id is null then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text)) into v_role
  from public.profiles profile where profile.user_id=v_user_id;
  if v_role is distinct from 'admin' then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;

  if p_start_date is null or p_end_date is null or p_end_date<p_start_date
     or p_end_date-p_start_date+1>366
     or p_detail_limit is null or p_detail_limit<1 or p_detail_limit>100
     or p_detail_offset is null or p_detail_offset<0 or p_detail_offset>1000000
     or (v_status is not null and v_status not in ('confirmed','completed','cancelled','no_show'))
     or (v_payment is not null and v_payment not in ('pay_on_site','paid','paid_on_site','unpaid','free','voucher'))
     or (v_type is not null and v_type not in ('whole_lane','single_position'))
     or (p_resource_id is not null and not exists(select 1 from public.shooting_lanes where id=p_resource_id)) then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_days:=p_end_date-p_start_date+1;

  with filtered_reservations as materialized (
    select * from public._admin_reservation_report_rows_v2(
      p_start_date,p_end_date,p_resource_id,v_status,v_payment,v_type
    )
  ), reportable_reservations as materialized (
    select * from filtered_reservations where reservation_status in ('confirmed','completed')
  ), resource_configuration as (
    select r.id,r.resource_kind,r.parent_lane_id,r.is_active,r.positions_bookable,
      coalesce(rule.online_bookable,false) online_bookable
    from public.shooting_lanes r left join public.lane_booking_rules rule on rule.lane_id=r.id
  ), root_modes as (
    select root.id root_id,root.is_active root_is_active,
      root.positions_bookable and exists(
        select 1 from resource_configuration child
        where child.resource_kind='position' and child.parent_lane_id=root.id
          and child.is_active and child.online_bookable
      ) uses_position_units
    from resource_configuration root where root.resource_kind='lane' and root.parent_lane_id is null
  ), effective_units as (
    select root.root_id,case when root.uses_position_units then child.id else root.root_id end unit_id
    from root_modes root
    left join resource_configuration child on root.uses_position_units
      and child.resource_kind='position' and child.parent_lane_id=root.root_id
      and child.is_active and child.online_bookable
    where root.root_is_active and (not root.uses_position_units or child.id is not null)
  ), resource_units as (
    select unit.root_id resource_id,unit.unit_id from effective_units unit
    union all
    select child.id,case when root.uses_position_units then child.id else root.root_id end
    from resource_configuration child join root_modes root on root.root_id=child.parent_lane_id
    where child.resource_kind='position' and root.root_is_active and child.is_active
      and (not root.uses_position_units or child.online_bookable)
  ), selected_resource_ids as (
    select r.id from public.shooting_lanes r
    where p_resource_id is null or r.id=p_resource_id or r.parent_lane_id=p_resource_id
  ), selected_units as (
    select distinct mapping.unit_id from resource_units mapping
    join selected_resource_ids selected on selected.id=mapping.resource_id
  ), reservation_unit_ranges as (
    select reservation.reservation_date,mapping.unit_id,
      pg_catalog.int4range(
        case when reservation.start_time<time '08:00' then 480 else pg_catalog.date_part('hour',reservation.start_time)::integer*60+pg_catalog.date_part('minute',reservation.start_time)::integer end,
        case when reservation.end_time>time '20:00' then 1200 else pg_catalog.date_part('hour',reservation.end_time)::integer*60+pg_catalog.date_part('minute',reservation.end_time)::integer end,
        '[)'
      ) occupied_range
    from reportable_reservations reservation join resource_units mapping on mapping.resource_id=reservation.lane_id
    where reservation.start_time<time '20:00' and reservation.end_time>time '08:00'
  ), unit_multiranges as (
    select reservation_date,unit_id,pg_catalog.range_agg(occupied_range) occupied_ranges
    from reservation_unit_ranges where not pg_catalog.isempty(occupied_range)
    group by reservation_date,unit_id
  ), merged_ranges as (
    select merged.occupied_range from unit_multiranges ranges
    cross join lateral pg_catalog.unnest(ranges.occupied_ranges) merged(occupied_range)
  ), occupancy as (
    select coalesce(pg_catalog.sum(pg_catalog.upper(occupied_range)-pg_catalog.lower(occupied_range)),0)::integer occupied_minutes from merged_ranges
  ), capacity as (
    select pg_catalog.count(*)::integer effective_capacity from selected_units
  ), totals as (
    select
      pg_catalog.count(*) filter(where reservation_status='confirmed')::integer active_reservation_count,
      pg_catalog.count(*) filter(where reservation_status='completed')::integer completed_reservation_count,
      pg_catalog.count(*) filter(where reservation_status in ('cancelled','canceled','cancelled_by_admin','cancelled_by_user'))::integer cancelled_reservation_count,
      pg_catalog.count(*) filter(where reservation_status='no_show')::integer no_show_reservation_count,
      coalesce(pg_catalog.sum(total_price) filter(where reservation_status in ('confirmed','completed')),0)::numeric planned_revenue,
      coalesce(pg_catalog.sum(total_price) filter(where reservation_status in ('confirmed','completed') and payment_status in ('paid','paid_on_site')),0)::numeric paid_revenue,
      coalesce(pg_catalog.sum(total_price) filter(where reservation_status in ('confirmed','completed') and payment_status in ('unpaid','pay_on_site')),0)::numeric outstanding_revenue,
      pg_catalog.count(*)::integer detail_total
    from filtered_reservations
  ), daily_values as (
    select reservation_date,pg_catalog.sum(total_price)::numeric planned_revenue
    from reportable_reservations group by reservation_date
  ), best_day as (
    select reservation_date,planned_revenue from daily_values order by planned_revenue desc,reservation_date limit 1
  ), resource_values as (
    select lane_id,pg_catalog.count(*)::integer reservation_count,
      (pg_catalog.array_agg(lane_name_snapshot order by reservation_date desc,start_time desc,id desc))[1] lane_name
    from reportable_reservations group by lane_id
  ), top_resource as (
    select lane_id,lane_name,reservation_count from resource_values order by reservation_count desc,lane_id limit 1
  ), detail_page as (
    select * from filtered_reservations order by reservation_date,start_time,id
    limit p_detail_limit offset p_detail_offset
  ), resource_options as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',r.id,'name',r.name,'resource_kind',r.resource_kind,'parent_lane_id',r.parent_lane_id,
      'display_name',case when r.resource_kind='position' and parent.id is not null then parent.name||' — '||r.name else r.name end
    ) order by coalesce(parent.display_order,r.display_order),case when r.resource_kind='lane' then 0 else 1 end,r.display_order,r.id),'[]'::jsonb) resources
    from public.shooting_lanes r left join public.shooting_lanes parent on parent.id=r.parent_lane_id
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',2,
    'filters',pg_catalog.jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'resource_id',p_resource_id,'reservation_status',v_status,'payment_status',v_payment,'booking_type',v_type),
    'filter_options',pg_catalog.jsonb_build_object('resources',resource_options.resources),
    'range',pg_catalog.jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'end_inclusive',true,'days',v_days,'time_zone','Europe/Warsaw','opening_start','08:00','opening_end','20:00','opening_minutes_per_day',720),
    'summary',pg_catalog.jsonb_build_object(
      'active_reservation_count',totals.active_reservation_count,'completed_reservation_count',totals.completed_reservation_count,
      'cancelled_reservation_count',totals.cancelled_reservation_count,'no_show_reservation_count',totals.no_show_reservation_count,
      'planned_revenue',totals.planned_revenue,'paid_revenue',totals.paid_revenue,'outstanding_revenue',totals.outstanding_revenue,
      'effective_capacity',capacity.effective_capacity,'occupied_minutes',occupancy.occupied_minutes,
      'available_minutes',capacity.effective_capacity*720*v_days,
      'occupancy_percent',case when capacity.effective_capacity*720*v_days=0 then 0 else greatest(0,least(100,pg_catalog.round(occupancy.occupied_minutes::numeric*100/(capacity.effective_capacity*720*v_days))::integer)) end,
      'best_day',case when best_day.reservation_date is null then null else pg_catalog.jsonb_build_object('date',best_day.reservation_date,'planned_revenue',best_day.planned_revenue) end,
      'top_resource',case when top_resource.lane_id is null then null else pg_catalog.jsonb_build_object('lane_id',top_resource.lane_id,'lane_name',top_resource.lane_name,'reservation_count',top_resource.reservation_count) end
    ),
    'details',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',d.id,'lane_id',d.lane_id,'lane_name_snapshot',d.lane_name_snapshot,'lane_display_name',d.lane_display_name,
      'resource_kind',d.resource_kind,'parent_lane_id',d.parent_lane_id,'customer_name',d.customer_name,'customer_email',d.customer_email,
      'customer_phone',d.customer_phone,'reservation_date',d.reservation_date,'start_time',d.start_time,'end_time',d.end_time,
      'duration_minutes',d.duration_minutes,'total_price',d.total_price,'reservation_status',d.reservation_status,'payment_status',d.payment_status
    ) order by d.reservation_date,d.start_time,d.id) from detail_page d),'[]'::jsonb),
    'pagination',pg_catalog.jsonb_build_object('total',totals.detail_total,'limit',p_detail_limit,'offset',p_detail_offset),
    'history',pg_catalog.jsonb_build_object('name_basis','reservation_snapshot','position_parent_name_basis','current_configuration','capacity_basis','current_configuration')
  ) into v_result
  from totals cross join capacity cross join occupancy cross join resource_options
  left join best_day on true left join top_resource on true;
  return v_result;
end
$function$;

alter function public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer) owner to postgres;
revoke all on function public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer) from public, anon, authenticated, service_role;
grant execute on function public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer) to authenticated;

create function public.admin_get_reservation_report_export_v1(
  p_start_date date,
  p_end_date date,
  p_resource_id uuid default null,
  p_reservation_status text default null,
  p_payment_status text default null,
  p_booking_type text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_user_id uuid:=auth.uid(); v_role text; v_total integer;
  v_status text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_reservation_status)),'');
  v_payment text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_payment_status)),'');
  v_type text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_booking_type)),'');
  v_rows jsonb;
begin
  if v_user_id is null then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text)) into v_role from public.profiles profile where profile.user_id=v_user_id;
  if v_role is distinct from 'admin' then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;
  if p_start_date is null or p_end_date is null or p_end_date<p_start_date or p_end_date-p_start_date+1>366
    or (v_status is not null and v_status not in ('confirmed','completed','cancelled','no_show'))
    or (v_payment is not null and v_payment not in ('pay_on_site','paid','paid_on_site','unpaid','free','voucher'))
    or (v_type is not null and v_type not in ('whole_lane','single_position'))
    or (p_resource_id is not null and not exists(select 1 from public.shooting_lanes where id=p_resource_id)) then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  select pg_catalog.count(*)::integer into v_total from public._admin_reservation_report_rows_v2(p_start_date,p_end_date,p_resource_id,v_status,v_payment,v_type);
  if v_total>5000 then return pg_catalog.jsonb_build_object('ok',false,'code','export_too_large','total',v_total,'max_rows',5000); end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'reservation_date',row.reservation_date,'start_time',row.start_time,'end_time',row.end_time,
    'resource_label',row.lane_display_name,'booking_type',row.booking_type,
    'reservation_status',row.reservation_status,'payment_status',row.payment_status,'total_price',row.total_price
  ) order by row.reservation_date,row.start_time,row.id),'[]'::jsonb) into v_rows
  from public._admin_reservation_report_rows_v2(p_start_date,p_end_date,p_resource_id,v_status,v_payment,v_type) row;
  return pg_catalog.jsonb_build_object('ok',true,'code','ok','contract_version',1,'total',v_total,'max_rows',5000,'rows',v_rows);
end
$function$;

alter function public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text) owner to postgres;
revoke all on function public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text) to authenticated;

comment on function public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer) is
  'Admin-only reservation report v2. Applies the same server-side filters to canonical KPI and bounded details.';
comment on function public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text) is
  'Admin-only PII-minimal export rows for up to 5000 filtered reservations. CSV encoding and formula neutralization are performed by the trusted client helper.';

do $postflight$
begin
  if not pg_catalog.has_function_privilege('authenticated','public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','EXECUTE')
    or not pg_catalog.has_function_privilege('authenticated','public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','EXECUTE')
    or pg_catalog.has_function_privilege('anon','public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','EXECUTE')
    or pg_catalog.has_function_privilege('anon','public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','EXECUTE')
    or pg_catalog.has_function_privilege('service_role','public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','EXECUTE')
    or pg_catalog.has_function_privilege('service_role','public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','EXECUTE')
    or exists(
      select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
      where p.oid in (
        'public._admin_reservation_report_rows_v2(date,date,uuid,text,text,text)'::regprocedure,
        'public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)'::regprocedure,
        'public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)'::regprocedure
      ) and acl.grantee=0 and acl.privilege_type='EXECUTE'
    ) then
    raise exception 'REPORTS-6B postflight failed: function ACL differs.';
  end if;
end
$postflight$;
