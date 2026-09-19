-- SAAS-9E-C1: additive, selected-tenant public and owner readers.
-- Old CSK bridge functions and all compatibility defaults remain unchanged.
do $preflight$
declare v_definers integer; v_bridge integer;
begin
  if (select count(*) from public.tenants where status='active')<>1
     or not exists(select 1 from public.tenants where slug='csk' and status='active') then
    raise exception 'SAAS-9E-C1 active tenant baseline differs';
  end if;
  select count(*) into v_definers from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef;
  select count(*) into v_bridge from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosrc like '%active_single_tenant_id_v1%';
  if v_definers<>70 or v_bridge<>22 then
    raise exception 'SAAS-9E-C1 function inventory differs (%,%)',v_definers,v_bridge;
  end if;
  if (select count(*) from information_schema.columns where table_schema='public'
      and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9E-C1 compatibility defaults differ';
  end if;
  if pg_catalog.to_regprocedure('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)') is null
     or pg_catalog.to_regprocedure('public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)') is null
     or pg_catalog.to_regprocedure('public.get_public_event_availability_v1__saas9d2b2_core(uuid)') is null
     or pg_catalog.to_regprocedure('public.get_my_active_tenant_verification_v1()') is null
     or pg_catalog.to_regprocedure('public.get_my_reservations_v2()') is null
     or pg_catalog.to_regprocedure('public.get_my_event_registrations_v1(text,text,integer,integer)') is null then
    raise exception 'SAAS-9E-C1 input function missing';
  end if;
  if exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in
      ('get_public_booking_configuration_v2','get_public_event_list_v3','get_public_event_availability_v2',
       'get_my_tenant_verification_v2','get_my_reservations_v3','get_my_event_registrations_v2')) then
    raise exception 'SAAS-9E-C1 target function already exists';
  end if;
end $preflight$;

create function public.get_public_booking_configuration_v2(p_tenant_id uuid)
returns table(lane_id uuid,parent_lane_id uuid,resource_kind text,name text,display_name text,display_order integer,
  effective_online_bookable boolean,whole_lane_bookable boolean,positions_bookable boolean,max_people_online integer,
  booking_step_minutes integer,currency_code text,durations_minutes integer[],pricing jsonb)
language plpgsql stable security definer set search_path=pg_catalog, public, pg_temp
as $function$
begin
  if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
    raise exception 'Lokalizacja jest niedostępna.' using errcode='42501';
  end if;
  return query select * from public.get_public_booking_configuration_v1__saas9d4e_core(p_tenant_id);
end $function$;

create function public.get_public_event_list_v3(
  p_tenant_id uuid,p_search text default null,p_scope text default 'upcoming',
  p_page integer default 1,p_page_size integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog, public, pg_temp
as $function$
begin
  if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_found');
  end if;
  return public.get_public_event_list_v2__saas9d2b2_core(p_tenant_id,p_search,p_scope,p_page,p_page_size);
end $function$;

create function public.get_public_event_availability_v2(p_tenant_id uuid)
returns table(event_id uuid,title text,description text,event_date date,start_time time without time zone,
  end_time time without time zone,location text,price numeric,max_participants integer,
  registered_count integer,reserve_count integer,available_spots integer,sold_out boolean)
language plpgsql stable security definer set search_path=pg_catalog, public, pg_temp
as $function$
begin
  if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
    raise exception 'Lokalizacja jest niedostępna.' using errcode='42501';
  end if;
  return query select * from public.get_public_event_availability_v1__saas9d2b2_core(p_tenant_id);
end $function$;

create function public.get_my_tenant_verification_v2(p_tenant_id uuid)
returns table(verification_status text,permissions_verified boolean,
  permissions_verified_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog, public, pg_temp
as $function$
declare v_user_id uuid:=auth.uid();
begin
  if v_user_id is null or p_tenant_id is null
     or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
    raise exception 'Brak kontekstu weryfikacji.' using errcode='42501';
  end if;
  return query
    select coalesce(verification.verification_status,'pending'),
      coalesce(verification.permissions_verified,false),
      verification.permissions_verified_at,verification.updated_at
    from (select 1) anchor
    left join public.tenant_user_verifications verification
      on verification.tenant_id=p_tenant_id and verification.user_id=v_user_id;
end $function$;

create function public.get_my_reservations_v3(
  p_tenant_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_actor uuid:=auth.uid();
  v_offset integer;
  v_result jsonb;
begin
  if v_actor is null then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;
  if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_found');
  end if;
  if p_page is null or p_page<1 or p_page>100000
     or p_page_size is null or p_page_size<1 or p_page_size>500 then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_offset:=(p_page-1)*p_page_size;
  with owned as materialized (
    select reservation.id,reservation.reservation_date,reservation.start_time,reservation.end_time,
      reservation.price,reservation.reservation_status,reservation.payment_status,
      reservation.check_in_token,reservation.attendance_status,reservation.checked_in_at,
      case
        when lane.resource_kind='lane' and lane.parent_lane_id is null
         and pg_catalog.btrim(lane.name)<>'' then lane.name
        when lane.resource_kind='position' and lane.parent_lane_id is not null
         and parent.id=lane.parent_lane_id and parent.resource_kind='lane'
         and parent.parent_lane_id is null and pg_catalog.btrim(parent.name)<>''
         and pg_catalog.btrim(lane.name)<>'' then parent.name||' — '||lane.name
        else null
      end as lane_display_name
    from public.reservations reservation
    left join public.shooting_lanes lane on lane.id=reservation.lane_id and lane.tenant_id=p_tenant_id
    left join public.shooting_lanes parent on parent.id=lane.parent_lane_id and parent.tenant_id=p_tenant_id
    where reservation.user_id=v_actor and reservation.tenant_id=p_tenant_id
  ), page_rows as (
    select * from owned order by reservation_date desc,start_time desc,id desc
    limit p_page_size offset v_offset
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',3,
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,
      'total',(select pg_catalog.count(*) from owned)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row)
      order by row.reservation_date desc,row.start_time desc,row.id desc)
      from page_rows row),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $function$;

create function public.get_my_event_registrations_v2(
  p_tenant_id uuid,p_scope text default 'upcoming',p_status text default null,
  p_page integer default 1,p_page_size integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog, public, pg_temp
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
  if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_found');
  end if;
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
      event_record.event_date,event_record.start_time,event_record.end_time,
      coalesce(event_record.location,'') location,event_record.price
    from public.event_registrations registration
    join public.events event_record
      on event_record.id=registration.event_id and event_record.tenant_id=p_tenant_id
    where registration.user_id=v_actor and registration.tenant_id=p_tenant_id
  ), filtered as materialized (
    select * from owned where (v_status is null or registration_status=v_status)
      and case v_scope
        when 'upcoming' then registration_status<>'cancelled' and (event_date+end_time)>v_now
        when 'history' then registration_status='cancelled' or (event_date+end_time)<=v_now
        else true
      end
  ), page_rows as (
    select * from filtered
    order by case when v_scope='upcoming' then event_date end asc,
      case when v_scope='upcoming' then start_time end asc,
      case when v_scope<>'upcoming' then event_date end desc,
      case when v_scope<>'upcoming' then start_time end desc,
      case when v_scope='upcoming' then id end asc,
      case when v_scope<>'upcoming' then id end desc
    limit p_page_size offset v_offset
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',2,
    'filters',pg_catalog.jsonb_build_object('scope',v_scope,'status',v_status),
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,
      'total',(select pg_catalog.count(*) from filtered)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',row.id,'registration_status',row.registration_status,
      'payment_status',row.payment_status,'created_at',row.created_at,
      'events',pg_catalog.jsonb_build_object('id',row.event_id,'title',row.title,
        'description',row.description,'event_date',row.event_date,
        'start_time',row.start_time,'end_time',row.end_time,'location',row.location,'price',row.price)
    ) order by case when v_scope='upcoming' then row.event_date end asc,
      case when v_scope='upcoming' then row.start_time end asc,
      case when v_scope<>'upcoming' then row.event_date end desc,
      case when v_scope<>'upcoming' then row.start_time end desc,
      case when v_scope='upcoming' then row.id end asc,
      case when v_scope<>'upcoming' then row.id end desc) from page_rows row),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $function$;

alter function public.get_public_booking_configuration_v2(uuid) owner to postgres;
alter function public.get_public_event_list_v3(uuid,text,text,integer,integer) owner to postgres;
alter function public.get_public_event_availability_v2(uuid) owner to postgres;
alter function public.get_my_tenant_verification_v2(uuid) owner to postgres;
alter function public.get_my_reservations_v3(uuid,integer,integer) owner to postgres;
alter function public.get_my_event_registrations_v2(uuid,text,text,integer,integer) owner to postgres;
revoke all on function public.get_public_booking_configuration_v2(uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_public_event_list_v3(uuid,text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.get_public_event_availability_v2(uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_my_tenant_verification_v2(uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_my_reservations_v3(uuid,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.get_my_event_registrations_v2(uuid,text,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.get_public_booking_configuration_v2(uuid) to anon,authenticated;
grant execute on function public.get_public_event_list_v3(uuid,text,text,integer,integer) to anon,authenticated;
grant execute on function public.get_public_event_availability_v2(uuid) to anon,authenticated;
grant execute on function public.get_my_tenant_verification_v2(uuid) to authenticated;
grant execute on function public.get_my_reservations_v3(uuid,integer,integer) to authenticated;
grant execute on function public.get_my_event_registrations_v2(uuid,text,text,integer,integer) to authenticated;

do $postflight$
declare v_definers integer; v_bridge integer;
begin
  select count(*) into v_definers from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef;
  select count(*) into v_bridge from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosrc like '%active_single_tenant_id_v1%';
  if v_definers<>76 or v_bridge<>22 then
    raise exception 'SAAS-9E-C1 function inventory differs after migration (%,%)',v_definers,v_bridge;
  end if;
  if (select count(*) from information_schema.columns where table_schema='public'
      and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9E-C1 compatibility defaults changed';
  end if;
end $postflight$;
