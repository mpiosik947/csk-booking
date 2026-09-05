-- EVENTS-8B: bounded, filterable event read contracts without browser fetch-all.

do $preflight$
declare
  v_name text;
begin
  foreach v_name in array array[
    'get_public_event_list_v2',
    'admin_list_events_v1',
    'admin_list_event_registrations_v1',
    'get_my_event_registrations_v1'
  ] loop
    if exists (
      select 1 from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.proname=v_name
    ) then
      raise exception 'EVENTS-8B preflight failed: function % already exists.',v_name;
    end if;
  end loop;

  if pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_registrations') is null
     or pg_catalog.to_regclass('public.event_lanes') is null
     or pg_catalog.to_regprocedure('public.get_public_event_availability_v1()') is null then
    raise exception 'EVENTS-8B preflight failed: required event contracts are absent.';
  end if;
end
$preflight$;

create index if not exists events_active_date_time_id_idx
  on public.events(is_active,event_date,start_time,id);
create index if not exists event_registrations_user_created_id_idx
  on public.event_registrations(user_id,created_at desc,id);
create index if not exists event_registrations_event_payment_created_id_idx
  on public.event_registrations(event_id,payment_status,created_at desc,id);

create function public.get_public_event_list_v2(
  p_search text default null,
  p_scope text default 'upcoming',
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_search text:=nullif(pg_catalog.btrim(p_search),'');
  v_scope text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_scope,'')));
  v_offset integer;
  v_now timestamp without time zone:=transaction_timestamp() at time zone 'Europe/Warsaw';
  v_result jsonb;
begin
  if (v_search is not null and pg_catalog.char_length(v_search)>100)
     or v_scope not in ('upcoming','all')
     or p_page is null or p_page<1 or p_page>100000
     or p_page_size is null or p_page_size<1 or p_page_size>50 then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_offset:=(p_page-1)*p_page_size;

  with filtered as materialized (
    select event_record.id,event_record.title,coalesce(event_record.description,'') description,
      event_record.event_date,event_record.start_time,event_record.end_time,
      coalesce(event_record.location,'') location,event_record.price,event_record.max_participants
    from public.events event_record
    where event_record.is_active
      and (v_search is null or event_record.title ilike '%'||v_search||'%')
      and (v_scope='all' or (event_record.event_date+event_record.end_time)>v_now)
  ), page_events as materialized (
    select * from filtered order by event_date,start_time,id limit p_page_size offset v_offset
  ), registration_counts as (
    select registration.event_id,
      pg_catalog.count(*) filter(where pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in ('registered','approved'))::integer registered_count,
      pg_catalog.count(*) filter(where pg_catalog.lower(pg_catalog.btrim(registration.registration_status))='reserve')::integer reserve_count
    from public.event_registrations registration
    where registration.event_id in(select page_event.id from page_events page_event)
    group by registration.event_id
  ), page_rows as (
    select page_event.*,coalesce(counts.registered_count,0) registered_count,coalesce(counts.reserve_count,0) reserve_count
    from page_events page_event left join registration_counts counts on counts.event_id=page_event.id
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',2,
    'filters',pg_catalog.jsonb_build_object('search',v_search,'scope',v_scope),
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,'total',(select pg_catalog.count(*) from filtered)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'event_id',row.id,'title',row.title,'description',row.description,'event_date',row.event_date,
      'start_time',row.start_time,'end_time',row.end_time,'location',row.location,'price',row.price,
      'max_participants',row.max_participants,'registered_count',row.registered_count,'reserve_count',row.reserve_count,
      'available_spots',greatest(row.max_participants-row.registered_count,0),
      'sold_out',row.registered_count>=row.max_participants
    ) order by row.event_date,row.start_time,row.id) from page_rows row),'[]'::jsonb)
  ) into v_result;
  return v_result;
end
$function$;

create function public.admin_list_events_v1(
  p_search text default null,
  p_scope text default 'upcoming',
  p_sort text default 'nearest',
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_actor uuid:=auth.uid();
  v_role text;
  v_search text:=nullif(pg_catalog.btrim(p_search),'');
  v_scope text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_scope,'')));
  v_sort text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort,'')));
  v_offset integer;
  v_now timestamp without time zone:=transaction_timestamp() at time zone 'Europe/Warsaw';
  v_result jsonb;
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text)) into v_role
  from public.profiles profile where profile.user_id=v_actor;
  if v_actor is null or v_role not in ('admin','pracownik','instruktor') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed');
  end if;
  if (v_search is not null and pg_catalog.char_length(v_search)>100)
     or v_scope not in ('all','upcoming','past','inactive')
     or v_sort not in ('nearest','latest')
     or p_page is null or p_page<1 or p_page>100000
     or p_page_size is null or p_page_size<1 or p_page_size>50 then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_offset:=(p_page-1)*p_page_size;

  with base as materialized (
    select event_record.*
    from public.events event_record
    where (v_search is null or event_record.title ilike '%'||v_search||'%')
      and case v_scope
        when 'upcoming' then event_record.is_active and (event_record.event_date+event_record.end_time)>v_now
        when 'past' then (event_record.event_date+event_record.end_time)<=v_now
        when 'inactive' then not event_record.is_active
        else true
      end
  ), totals as (
    select pg_catalog.count(*)::integer total,
      pg_catalog.count(*) filter(where is_active and (event_date+end_time)>v_now)::integer upcoming,
      pg_catalog.count(*) filter(where (event_date+end_time)<=v_now)::integer past,
      pg_catalog.count(*) filter(where not is_active)::integer inactive
    from public.events
  ), page_rows as (
    select * from base
    order by
      case when v_sort='nearest' then event_date end asc,
      case when v_sort='nearest' then start_time end asc,
      case when v_sort='nearest' then created_at end asc,
      case when v_sort='latest' then event_date end desc,
      case when v_sort='latest' then start_time end desc,
      case when v_sort='latest' then created_at end desc,
      case when v_sort='nearest' then id end asc,
      case when v_sort='latest' then id end desc
    limit p_page_size offset v_offset
  ), item_rows as (
    select row.*,
      coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id',lane.id,'name',lane.name,'type',lane.type,'is_active',lane.is_active,
        'display_order',lane.display_order,'resource_kind',lane.resource_kind,'parent_lane_id',lane.parent_lane_id,
        'parent_name',parent.name
      ) order by coalesce(parent.display_order,lane.display_order),case when lane.resource_kind='lane' then 0 else 1 end,lane.display_order,lane.id)
      from public.event_lanes relation
      join public.shooting_lanes lane on lane.id=relation.lane_id
      left join public.shooting_lanes parent on parent.id=lane.parent_lane_id
      where relation.event_id=row.id),'[]'::jsonb) lanes
    from page_rows row
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',1,
    'filters',pg_catalog.jsonb_build_object('search',v_search,'scope',v_scope,'sort',v_sort),
    'summary',pg_catalog.jsonb_build_object('all_count',totals.total,'upcoming_count',totals.upcoming,'past_count',totals.past,'inactive_count',totals.inactive),
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,'total',(select pg_catalog.count(*) from base)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',item.id,'title',item.title,'description',item.description,'event_date',item.event_date,
      'start_time',item.start_time,'end_time',item.end_time,'location',item.location,'price',item.price,
      'max_participants',item.max_participants,'is_active',item.is_active,'created_at',item.created_at,
      'lanes',item.lanes
    ) order by case when v_sort='nearest' then item.event_date end asc,
      case when v_sort='nearest' then item.start_time end asc,
      case when v_sort='nearest' then item.created_at end asc,
      case when v_sort='latest' then item.event_date end desc,
      case when v_sort='latest' then item.start_time end desc,
      case when v_sort='latest' then item.created_at end desc,
      case when v_sort='nearest' then item.id end asc,
      case when v_sort='latest' then item.id end desc) from item_rows item),'[]'::jsonb)
  ) into v_result
  from totals;
  return v_result;
end
$function$;

create function public.admin_list_event_registrations_v1(
  p_event_id uuid,
  p_status text default null,
  p_payment_status text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_actor uuid:=auth.uid();
  v_role text;
  v_status text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_status)),'');
  v_payment text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_payment_status)),'');
  v_offset integer;
  v_result jsonb;
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text)) into v_role
  from public.profiles profile where profile.user_id=v_actor;
  if v_actor is null or v_role not in ('admin','pracownik','instruktor') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed');
  end if;
  if p_event_id is null or not exists(select 1 from public.events where id=p_event_id)
     or (v_status is not null and v_status not in ('registered','approved','reserve','cancelled','participant'))
     or (v_payment is not null and v_payment not in ('pay_on_site','paid','paid_on_site','unpaid','free','voucher'))
     or p_page is null or p_page<1 or p_page>100000
     or p_page_size is null or p_page_size<1 or p_page_size>50 then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_offset:=(p_page-1)*p_page_size;

  with event_rows as materialized (
    select registration.id,registration.customer_name,registration.customer_email,registration.customer_phone,
      pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) registration_status,
      pg_catalog.lower(pg_catalog.btrim(registration.payment_status)) payment_status,registration.created_at
    from public.event_registrations registration where registration.event_id=p_event_id
  ), filtered as materialized (
    select * from event_rows
    where (v_status is null or registration_status=v_status)
      and (v_payment is null or payment_status=v_payment)
  ), summary as (
    select
      pg_catalog.count(*) filter(where registration_status in ('registered','approved'))::integer registered_count,
      pg_catalog.count(*) filter(where registration_status='reserve')::integer reserve_count,
      pg_catalog.count(*) filter(where registration_status='cancelled')::integer cancelled_count,
      pg_catalog.count(*) filter(where payment_status in ('paid','paid_on_site') and registration_status in ('registered','approved'))::integer paid_count
    from event_rows
  ), page_rows as (
    select * from filtered
    order by case registration_status when 'registered' then 0 when 'approved' then 0 when 'participant' then 0 when 'reserve' then 1 else 2 end,
      case when registration_status='reserve' then created_at end asc,
      case when registration_status<>'reserve' then created_at end desc,
      id
    limit p_page_size offset v_offset
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',1,'event_id',p_event_id,
    'filters',pg_catalog.jsonb_build_object('status',v_status,'payment_status',v_payment),
    'summary',pg_catalog.jsonb_build_object('registered_count',summary.registered_count,'reserve_count',summary.reserve_count,'cancelled_count',summary.cancelled_count,'paid_count',summary.paid_count),
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,'total',(select pg_catalog.count(*) from filtered)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',row.id,'customer_name',row.customer_name,'customer_email',row.customer_email,'customer_phone',row.customer_phone,
      'registration_status',row.registration_status,'payment_status',row.payment_status,'created_at',row.created_at
    ) order by case row.registration_status when 'registered' then 0 when 'approved' then 0 when 'participant' then 0 when 'reserve' then 1 else 2 end,
      case when row.registration_status='reserve' then row.created_at end asc,
      case when row.registration_status<>'reserve' then row.created_at end desc,row.id) from page_rows row),'[]'::jsonb)
  ) into v_result from summary;
  return v_result;
end
$function$;

create function public.get_my_event_registrations_v1(
  p_scope text default 'upcoming',
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_actor uuid:=auth.uid();
  v_scope text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_scope,'')));
  v_status text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_status)),'');
  v_offset integer;
  v_now timestamp without time zone:=transaction_timestamp() at time zone 'Europe/Warsaw';
  v_result jsonb;
begin
  if v_actor is null then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;
  if v_scope not in ('upcoming','history','all')
     or (v_status is not null and v_status not in ('registered','approved','reserve','cancelled','participant'))
     or p_page is null or p_page<1 or p_page>100000
     or p_page_size is null or p_page_size<1 or p_page_size>50 then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_offset:=(p_page-1)*p_page_size;

  with owned as materialized (
    select registration.id,pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) registration_status,
      pg_catalog.lower(pg_catalog.btrim(registration.payment_status)) payment_status,registration.created_at,
      event_record.id event_id,event_record.title,coalesce(event_record.description,'') description,
      event_record.event_date,event_record.start_time,event_record.end_time,coalesce(event_record.location,'') location,event_record.price
    from public.event_registrations registration
    join public.events event_record on event_record.id=registration.event_id
    where registration.user_id=v_actor
  ), filtered as materialized (
    select * from owned
    where (v_status is null or registration_status=v_status)
      and case v_scope
        when 'upcoming' then registration_status<>'cancelled' and (event_date+end_time)>v_now
        when 'history' then registration_status='cancelled' or (event_date+end_time)<=v_now
        else true
      end
  ), page_rows as (
    select * from filtered
    order by
      case when v_scope='upcoming' then event_date end asc,
      case when v_scope='upcoming' then start_time end asc,
      case when v_scope<>'upcoming' then event_date end desc,
      case when v_scope<>'upcoming' then start_time end desc,
      case when v_scope='upcoming' then id end asc,
      case when v_scope<>'upcoming' then id end desc
    limit p_page_size offset v_offset
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',1,
    'filters',pg_catalog.jsonb_build_object('scope',v_scope,'status',v_status),
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,'total',(select pg_catalog.count(*) from filtered)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',row.id,'registration_status',row.registration_status,'payment_status',row.payment_status,'created_at',row.created_at,
      'events',pg_catalog.jsonb_build_object('id',row.event_id,'title',row.title,'description',row.description,'event_date',row.event_date,
        'start_time',row.start_time,'end_time',row.end_time,'location',row.location,'price',row.price)
    ) order by case when v_scope='upcoming' then row.event_date end asc,
      case when v_scope='upcoming' then row.start_time end asc,
      case when v_scope<>'upcoming' then row.event_date end desc,
      case when v_scope<>'upcoming' then row.start_time end desc,
      case when v_scope='upcoming' then row.id end asc,
      case when v_scope<>'upcoming' then row.id end desc) from page_rows row),'[]'::jsonb)
  ) into v_result;
  return v_result;
end
$function$;

alter function public.get_public_event_list_v2(text,text,integer,integer) owner to postgres;
alter function public.admin_list_events_v1(text,text,text,integer,integer) owner to postgres;
alter function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer) owner to postgres;
alter function public.get_my_event_registrations_v1(text,text,integer,integer) owner to postgres;

revoke all on function public.get_public_event_list_v2(text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.admin_list_events_v1(text,text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.get_my_event_registrations_v1(text,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.get_public_event_list_v2(text,text,integer,integer) to anon,authenticated;
grant execute on function public.admin_list_events_v1(text,text,text,integer,integer) to authenticated;
grant execute on function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer) to authenticated;
grant execute on function public.get_my_event_registrations_v1(text,text,integer,integer) to authenticated;

comment on function public.get_public_event_list_v2(text,text,integer,integer) is 'Bounded PII-free public event list with authoritative availability.';
comment on function public.admin_list_events_v1(text,text,text,integer,integer) is 'Bounded event list for the existing authorized admin-events role matrix.';
comment on function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer) is 'Bounded participant list and page-independent counts for the existing authorized admin-events role matrix.';
comment on function public.get_my_event_registrations_v1(text,text,integer,integer) is 'Owner-scoped bounded event registration list.';

do $postflight$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.get_public_event_list_v2(text,text,integer,integer)',
    'public.admin_list_events_v1(text,text,text,integer,integer)',
    'public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)',
    'public.get_my_event_registrations_v1(text,text,integer,integer)'
  ] loop
    if pg_catalog.to_regprocedure(v_signature) is null then raise exception 'EVENTS-8B postflight failed: % absent.',v_signature; end if;
  end loop;
  if not pg_catalog.has_function_privilege('anon','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.admin_list_events_v1(text,text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.get_my_event_registrations_v1(text,text,integer,integer)','EXECUTE') then
    raise exception 'EVENTS-8B postflight failed: ACL mismatch.';
  end if;
end
$postflight$;
