-- SAAS-9D-4E: tenant-scope the public booking configuration behind its stable wrapper.

do $preflight$
declare
  v_definers integer;
  v_wrapper_count integer;
  v_wrapper_hash text;
begin
  if pg_catalog.to_regprocedure('public.get_public_booking_configuration_v1()') is null
     or pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null
     or pg_catalog.to_regprocedure('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)') is not null then
    raise exception 'SAAS-9D-4E preflight failed: function inventory differs.';
  end if;
  select pg_catalog.count(*) into v_wrapper_count
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='get_public_booking_configuration_v1';
  select pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
    'public.get_public_booking_configuration_v1()'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
  into v_wrapper_hash;
  if v_wrapper_count<>1
     or v_wrapper_hash<>'2aee39e3d37d3d1a19f58c3626aa0365' then
    raise exception 'SAAS-9D-4E preflight failed: wrapper signature/fingerprint drift (count %, hash %).',
      v_wrapper_count,v_wrapper_hash;
  end if;
  if not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.get_public_booking_configuration_v1()'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='s' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     or pg_catalog.has_function_privilege('public','public.get_public_booking_configuration_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('anon','public.get_public_booking_configuration_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_booking_configuration_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('service_role','public.get_public_booking_configuration_v1()','EXECUTE') then
    raise exception 'SAAS-9D-4E preflight failed: wrapper metadata/ACL drift.';
  end if;
  if exists(select 1 from public.shooting_lanes where tenant_id is null)
     or exists(select 1 from public.lane_booking_rules config left join public.shooting_lanes lane on lane.id=config.lane_id where lane.id is null)
     or exists(select 1 from public.lane_booking_durations config left join public.shooting_lanes lane on lane.id=config.lane_id where lane.id is null)
     or exists(select 1 from public.lane_pricing_rules config left join public.shooting_lanes lane on lane.id=config.lane_id where lane.id is null)
     or (select pg_catalog.count(*) from pg_catalog.pg_constraint where conname in(
       'lane_booking_rules_lane_id_fkey','lane_booking_durations_lane_id_fkey','lane_pricing_rules_lane_id_fkey'
     ) and contype='f' and convalidated)<>3 then
    raise exception 'SAAS-9D-4E preflight failed: configuration ownership/FK integrity differs.';
  end if;
  select pg_catalog.count(*) into v_definers from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef;
  if v_definers<>69 then raise exception 'SAAS-9D-4E preflight failed: SECURITY DEFINER count %, expected 69.',v_definers; end if;
  if (select pg_catalog.count(*) from information_schema.columns where table_schema='public'
      and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4E preflight failed: compatibility defaults differ.';
  end if;
end;$preflight$;

create function public.get_public_booking_configuration_v1__saas9d4e_core(p_tenant_id uuid)
returns table(lane_id uuid,parent_lane_id uuid,resource_kind text,name text,display_name text,display_order integer,
  effective_online_bookable boolean,whole_lane_bookable boolean,positions_bookable boolean,max_people_online integer,
  booking_step_minutes integer,currency_code text,durations_minutes integer[],pricing jsonb)
language sql stable security invoker set search_path=pg_catalog, public, pg_temp
as $function$
with resource_configuration as (
  select resource.id,resource.parent_lane_id,resource.resource_kind,resource.name,resource.display_order,resource.is_active,
    resource.whole_lane_bookable raw_whole_lane_bookable,resource.positions_bookable raw_positions_bookable,
    resource.booking_step_minutes,resource.currency_code::text currency_code,booking_rule.online_bookable,
    booking_rule.max_people_online,parent.id parent_id,parent.name parent_name,parent.display_order parent_display_order,
    parent.resource_kind parent_resource_kind,parent.parent_lane_id parent_parent_lane_id,parent.is_active parent_is_active,
    parent.positions_bookable parent_positions_bookable,
    coalesce(duration_configuration.durations_minutes,array[]::integer[]) durations_minutes,
    coalesce(pricing_configuration.pricing,'[]'::jsonb) pricing,
    coalesce(duration_configuration.duration_valid,false) duration_valid,
    coalesce(pricing_configuration.pricing_valid,false) pricing_valid
  from public.shooting_lanes resource
  left join public.lane_booking_rules booking_rule on booking_rule.lane_id=resource.id
  left join public.shooting_lanes parent
    on parent.tenant_id=resource.tenant_id and parent.id=resource.parent_lane_id
  left join lateral (
    select pg_catalog.array_agg(distinct duration.duration_minutes order by duration.duration_minutes)
      filter(where duration.is_active and duration.duration_minutes is not null and duration.duration_minutes>0) durations_minutes,
      pg_catalog.count(*) filter(where duration.is_active)>0
      and pg_catalog.count(*) filter(where duration.is_active and duration.duration_minutes is not null and duration.duration_minutes>0)
        =pg_catalog.count(*) filter(where duration.is_active) duration_valid
    from public.lane_booking_durations duration
    where duration.lane_id=resource.id
  ) duration_configuration on true
  left join lateral (
    with active_pricing_rules as (
      select pricing_rule.id,pricing_rule.day_group,pricing_rule.min_shooters,pricing_rule.max_shooters,
        pricing_rule.hourly_price,pricing_rule.label,pricing_rule.display_order
      from public.lane_pricing_rules pricing_rule
      where pricing_rule.lane_id=resource.id and pricing_rule.is_active
    ), ordered_pricing_rules as (
      select pricing_rule.*,
        pg_catalog.row_number() over(partition by pricing_rule.day_group order by pricing_rule.min_shooters,pricing_rule.max_shooters,pricing_rule.display_order,pricing_rule.id) rule_order,
        pg_catalog.lag(pricing_rule.max_shooters) over(partition by pricing_rule.day_group order by pricing_rule.min_shooters,pricing_rule.max_shooters,pricing_rule.display_order,pricing_rule.id) previous_max_shooters
      from active_pricing_rules pricing_rule
    ), coverage_by_day_group as (
      select pricing_rule.day_group,pg_catalog.count(*)>0 and pg_catalog.bool_and(
        pricing_rule.min_shooters<=pricing_rule.max_shooters and
        ((pricing_rule.rule_order=1 and pricing_rule.min_shooters=1) or
         (pricing_rule.rule_order>1 and pricing_rule.min_shooters=pricing_rule.previous_max_shooters+1)))
        and pg_catalog.max(pricing_rule.max_shooters)=booking_rule.max_people_online coverage_valid
      from ordered_pricing_rules pricing_rule where pricing_rule.day_group in('mon_thu','fri_sun') group by pricing_rule.day_group
    )
    select (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'day_group',pricing_rule.day_group,'min_shooters',pricing_rule.min_shooters,'max_shooters',pricing_rule.max_shooters,
      'hourly_price',pricing_rule.hourly_price,'label',pricing_rule.label)
      order by pricing_rule.day_group,pricing_rule.min_shooters,pricing_rule.max_shooters,pricing_rule.display_order,pricing_rule.id)
      from active_pricing_rules pricing_rule) pricing,
      booking_rule.lane_id is not null and booking_rule.max_people_online>=1
      and not exists(select 1 from public.lane_pricing_rules invalid_rule
        where invalid_rule.lane_id=resource.id and invalid_rule.is_active
          and (invalid_rule.day_group not in('mon_thu','fri_sun') or invalid_rule.min_shooters<1
            or invalid_rule.max_shooters<invalid_rule.min_shooters or invalid_rule.max_shooters>booking_rule.max_people_online
            or invalid_rule.hourly_price::text in('NaN','Infinity','-Infinity')))
      and not exists(select 1 from (values('mon_thu'::text),('fri_sun'::text)) expected_day_group(day_group)
        left join coverage_by_day_group coverage on coverage.day_group=expected_day_group.day_group
        where coverage.day_group is null or not coverage.coverage_valid) pricing_valid
  ) pricing_configuration on true
  where resource.tenant_id=p_tenant_id
), valid_positions as (
  select configuration.* from resource_configuration configuration
  where configuration.resource_kind='position' and configuration.parent_lane_id is not null
    and configuration.parent_id=configuration.parent_lane_id and configuration.parent_resource_kind='lane'
    and configuration.parent_parent_lane_id is null and configuration.parent_is_active
    and configuration.parent_positions_bookable and configuration.is_active
    and not configuration.raw_whole_lane_bookable and not configuration.raw_positions_bookable
    and configuration.online_bookable and configuration.duration_valid and configuration.pricing_valid
), lane_modes as (
  select configuration.*,
    coalesce(configuration.resource_kind='lane' and configuration.parent_lane_id is null and configuration.is_active
      and configuration.raw_whole_lane_bookable and configuration.online_bookable
      and configuration.duration_valid and configuration.pricing_valid,false) whole_mode_available,
    exists(select 1 from valid_positions child where child.parent_lane_id=configuration.id) position_mode_available
  from resource_configuration configuration where configuration.resource_kind='lane' and configuration.parent_lane_id is null
), public_resources as (
  select lane.id lane_id,null::uuid parent_lane_id,lane.resource_kind,lane.name,lane.name display_name,lane.display_order,
    lane.whole_mode_available effective_online_bookable,lane.whole_mode_available whole_lane_bookable,
    lane.position_mode_available positions_bookable,case when lane.whole_mode_available then lane.max_people_online end max_people_online,
    lane.booking_step_minutes,lane.currency_code,case when lane.whole_mode_available then lane.durations_minutes else array[]::integer[] end durations_minutes,
    case when lane.whole_mode_available then lane.pricing else '[]'::jsonb end pricing,lane.display_order hierarchy_display_order,0 hierarchy_kind_order
  from lane_modes lane where lane.whole_mode_available or lane.position_mode_available
  union all
  select position.id,position.parent_lane_id,position.resource_kind,position.name,position.parent_name||' — '||position.name,
    position.display_order,true,false,false,position.max_people_online,position.booking_step_minutes,position.currency_code,
    position.durations_minutes,position.pricing,position.parent_display_order,1 from valid_positions position
)
select resource.lane_id,resource.parent_lane_id,resource.resource_kind,resource.name,resource.display_name,resource.display_order,
  resource.effective_online_bookable,resource.whole_lane_bookable,resource.positions_bookable,resource.max_people_online,
  resource.booking_step_minutes,resource.currency_code,resource.durations_minutes,resource.pricing
from public_resources resource
order by resource.hierarchy_display_order,resource.hierarchy_kind_order,resource.display_order,resource.name,resource.lane_id;
$function$;

alter function public.get_public_booking_configuration_v1__saas9d4e_core(uuid) owner to postgres;
revoke all on function public.get_public_booking_configuration_v1__saas9d4e_core(uuid) from public,anon,authenticated,service_role;

create or replace function public.get_public_booking_configuration_v1()
returns table(lane_id uuid,parent_lane_id uuid,resource_kind text,name text,display_name text,display_order integer,
  effective_online_bookable boolean,whole_lane_bookable boolean,positions_bookable boolean,max_people_online integer,
  booking_step_minutes integer,currency_code text,durations_minutes integer[],pricing jsonb)
language sql stable security definer set search_path=pg_catalog, public, pg_temp
as $function$
  select * from public.get_public_booking_configuration_v1__saas9d4e_core(public.active_single_tenant_id_v1());
$function$;
alter function public.get_public_booking_configuration_v1() owner to postgres;
revoke all on function public.get_public_booking_configuration_v1() from public,anon,authenticated,service_role;
grant execute on function public.get_public_booking_configuration_v1() to anon,authenticated;
comment on function public.get_public_booking_configuration_v1() is 'Returns PII-free booking configuration for the exact active tenant.';
comment on function public.get_public_booking_configuration_v1__saas9d4e_core(uuid) is 'Owner-only tenant-scoped implementation for the public booking configuration wrapper.';

do $postflight$
declare v_definers integer;
begin
  if not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.get_public_booking_configuration_v1()'::pg_catalog.regprocedure and p.prosecdef and p.provolatile='s'
        and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     or not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::pg_catalog.regprocedure and not p.prosecdef and p.provolatile='s'
        and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) then
    raise exception 'SAAS-9D-4E postflight failed: wrapper/core metadata differs.';
  end if;
  if pg_catalog.has_function_privilege('public','public.get_public_booking_configuration_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('anon','public.get_public_booking_configuration_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_booking_configuration_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_booking_configuration_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE') then
    raise exception 'SAAS-9D-4E postflight failed: ACL differs.';
  end if;
  select pg_catalog.count(*) into v_definers from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef;
  if v_definers<>69 then raise exception 'SAAS-9D-4E postflight failed: SECURITY DEFINER count %, expected 69.',v_definers; end if;
end;$postflight$;
