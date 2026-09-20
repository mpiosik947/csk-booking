-- SAAS-9E-C2-A: selected-tenant Admin Events contracts. DB-first, legacy callers unchanged.
set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
declare v_function regprocedure; v_expected text;
begin
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>76 then
    raise exception 'C2-A preflight: SECURITY DEFINER baseline differs';
  end if;
  if (select count(*) from information_schema.columns
      where table_schema='public' and table_name in
        ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'C2-A preflight: compatibility defaults differ';
  end if;
  for v_function,v_expected in values
    ('public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer)'::regprocedure,'487d9f6b036494428269724d60c7ac89'),
    ('public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::regprocedure,'7e47e4f37f2d4daf872348743f4d4adb'),
    ('public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)'::regprocedure,'e72a9091bc97086756ff2b29fb035d81'),
    ('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::regprocedure,'b87b87d6842c77238f4806073436fabb'),
    ('public.admin_set_event_active_v2(uuid,boolean)'::regprocedure,'6c9df46f20e0caf905d65c9928cb63d1'),
    ('public.approve_event_registration(uuid)'::regprocedure,'4e4e9b3584ab4e4a28b94ab56f20a46f'),
    ('public.cancel_event_registration(uuid)'::regprocedure,'5c45f09d89167548262908f84690f6f4'),
    ('public.mark_event_registration_paid(uuid)'::regprocedure,'3e4ba58f3265e8871430e3a36b728a97')
  loop
    if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(v_function),E'\r\n',E'\n'),E'\r',E'\n'))<>v_expected then
      raise exception 'C2-A preflight: source function drifted: %',v_function;
    end if;
  end loop;
  if exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in
        ('admin_list_events_v2','admin_list_event_registrations_v2','admin_create_event_v3',
         'admin_create_event_v3__saas9ec2a_core','admin_update_event_v3',
         'admin_set_event_active_v3','approve_event_registration_v2',
         'cancel_event_registration_v2','mark_event_registration_paid_v2')) then
    raise exception 'C2-A preflight: target name already exists';
  end if;
end;
$preflight$;

-- Existing staff SELECT RLS plus this INVOKER's explicit T filter, before totals/page.
create function public.admin_list_events_v2(
  p_tenant_id uuid,p_search text default null,p_scope text default 'upcoming',
  p_sort text default 'nearest',p_page integer default 1,p_page_size integer default 20
) returns jsonb language plpgsql stable security invoker
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_role text:=public.get_my_tenant_role_v1(p_tenant_id);
  v_search text:=nullif(pg_catalog.btrim(p_search),'');
  v_scope text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_scope,'')));
  v_sort text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort,'')));
  v_offset integer;
  v_now timestamp without time zone:=transaction_timestamp() at time zone 'Europe/Warsaw';
  v_result jsonb;
begin
  if auth.uid() is null or coalesce(v_role,'') not in ('admin','employee','instructor') then
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
    select event_record.* from public.events event_record
    where event_record.tenant_id=p_tenant_id
      and (v_search is null or event_record.title ilike '%'||v_search||'%')
      and case v_scope
        when 'upcoming' then event_record.is_active and (event_record.event_date+event_record.end_time)>v_now
        when 'past' then (event_record.event_date+event_record.end_time)<=v_now
        when 'inactive' then not event_record.is_active
        else true end
  ), totals as (
    select pg_catalog.count(*)::integer total,
      pg_catalog.count(*) filter(where is_active and (event_date+end_time)>v_now)::integer upcoming,
      pg_catalog.count(*) filter(where (event_date+end_time)<=v_now)::integer past,
      pg_catalog.count(*) filter(where not is_active)::integer inactive
    from public.events where tenant_id=p_tenant_id
  ), page_rows as (
    select * from base order by
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
        'display_order',lane.display_order,'resource_kind',lane.resource_kind,
        'parent_lane_id',lane.parent_lane_id,'parent_name',parent.name
      ) order by coalesce(parent.display_order,lane.display_order),
        case when lane.resource_kind='lane' then 0 else 1 end,lane.display_order,lane.id)
      from public.event_lanes relation
      join public.shooting_lanes lane on lane.id=relation.lane_id and lane.tenant_id=row.tenant_id
      left join public.shooting_lanes parent on parent.id=lane.parent_lane_id and parent.tenant_id=row.tenant_id
      where relation.event_id=row.id and relation.tenant_id=row.tenant_id),'[]'::jsonb) lanes
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
  ) into v_result from totals;
  return v_result;
end;
$function$;

-- Copy the atomically tested create core with exact guards; remove both legacy
-- authorities while retaining conflict locks, response shape and explicit T DML.
do $clone_create$
declare v_source text; v_target text; v_global_role text;
begin
  v_source:=pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
    'public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::regprocedure
  ),E'\r\n',E'\n'),E'\r',E'\n');
  v_global_role:=E'  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))\n  into v_actor_role\n  from public.profiles as profile\n  where profile.user_id = v_actor_id;';
  if pg_catalog.strpos(v_source,'public.admin_create_event_v2__saas9d2b1_core(p_title text,')=0
     or pg_catalog.strpos(v_source,'v_tenant_id uuid := public.active_single_tenant_id_v1();')=0
     or pg_catalog.strpos(v_source,v_global_role)=0
     or pg_catalog.strpos(v_source,$role$('admin', 'pracownik')$role$)=0 then
    raise exception 'C2-A clone: source anchors differ';
  end if;
  v_target:=pg_catalog.replace(v_source,
    'public.admin_create_event_v2__saas9d2b1_core(p_title text,',
    'public.admin_create_event_v3__saas9ec2a_core(p_tenant_id uuid, p_title text,');
  v_target:=pg_catalog.replace(v_target,
    'v_tenant_id uuid := public.active_single_tenant_id_v1();',
    'v_tenant_id uuid := p_tenant_id;');
  v_target:=pg_catalog.replace(v_target,v_global_role,
    '  v_actor_role := public.get_my_tenant_role_v1(v_tenant_id);');
  v_target:=pg_catalog.replace(v_target,$old_role$('admin', 'pracownik')$old_role$,$new_role$('admin', 'employee')$new_role$);
  if pg_catalog.strpos(v_target,'active_single_tenant_id_v1')>0
     or pg_catalog.strpos(v_target,'profile.role')>0
     or pg_catalog.strpos(v_target,'v_tenant_id uuid := p_tenant_id;')=0
     or pg_catalog.strpos(v_target,'tenant_id,')=0 then
    raise exception 'C2-A clone: target tenant predicate failed';
  end if;
  execute v_target;
end;
$clone_create$;
alter function public.admin_create_event_v3__saas9ec2a_core(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) owner to postgres;
alter function public.admin_create_event_v3__saas9ec2a_core(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) security invoker;
revoke all on function public.admin_create_event_v3__saas9ec2a_core(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) from public,anon,authenticated,service_role;

create function public.admin_create_event_v3(
  p_tenant_id uuid,p_title text,p_description text,p_event_date date,
  p_start_time time without time zone,p_end_time time without time zone,
  p_location text,p_price numeric,p_max_participants integer,p_lane_ids uuid[] default '{}'::uuid[]
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $function$
begin
  if coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',null);
  end if;
  if exists(select 1 from pg_catalog.unnest(coalesce(p_lane_ids,'{}'::uuid[])) requested(id)
    left join public.shooting_lanes lane on lane.id=requested.id
    where lane.id is null or lane.tenant_id is distinct from p_tenant_id) then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',null);
  end if;
  return public.admin_create_event_v3__saas9ec2a_core(
    p_tenant_id,p_title,p_description,p_event_date,p_start_time,p_end_time,
    p_location,p_price,p_max_participants,p_lane_ids);
end;
$function$;

create function public.admin_list_event_registrations_v2(
  p_tenant_id uuid,p_event_id uuid,p_status text default null,p_payment_status text default null,
  p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp as $function$
begin
  if coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee','instructor')
     or not exists(select 1 from public.events event_record where event_record.id=p_event_id and event_record.tenant_id=p_tenant_id) then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed');
  end if;
  return public.admin_list_event_registrations_v1(p_event_id,p_status,p_payment_status,p_page,p_page_size);
end;
$function$;

create function public.admin_update_event_v3(
  p_tenant_id uuid,p_event_id uuid,p_title text,p_description text,p_event_date date,
  p_start_time time without time zone,p_end_time time without time zone,
  p_location text,p_price numeric,p_max_participants integer,p_lane_ids uuid[] default '{}'::uuid[]
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $function$
begin
  if coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee')
     or not exists(select 1 from public.events e where e.id=p_event_id and e.tenant_id=p_tenant_id)
     or exists(select 1 from pg_catalog.unnest(coalesce(p_lane_ids,'{}'::uuid[])) requested(id)
       left join public.shooting_lanes lane on lane.id=requested.id
       where lane.id is null or lane.tenant_id is distinct from p_tenant_id) then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',p_event_id);
  end if;
  return public.admin_update_event_v2(p_event_id,p_title,p_description,p_event_date,p_start_time,p_end_time,
    p_location,p_price,p_max_participants,p_lane_ids);
end;
$function$;

create function public.admin_set_event_active_v3(p_tenant_id uuid,p_event_id uuid,p_is_active boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $function$
begin
  if coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee')
     or not exists(select 1 from public.events e where e.id=p_event_id and e.tenant_id=p_tenant_id) then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',p_event_id);
  end if;
  return public.admin_set_event_active_v2(p_event_id,p_is_active);
end;
$function$;

create function public.approve_event_registration_v2(p_tenant_id uuid,p_registration_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $function$
begin
  if coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee')
     or not exists(select 1 from public.event_registrations r
       join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
       where r.id=p_registration_id and r.tenant_id=p_tenant_id) then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  return public.approve_event_registration(p_registration_id);
end;
$function$;

create function public.cancel_event_registration_v2(p_tenant_id uuid,p_registration_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $function$
begin
  if public.get_my_tenant_role_v1(p_tenant_id) is null
     or not exists(select 1 from public.event_registrations r
       join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
       where r.id=p_registration_id and r.tenant_id=p_tenant_id) then
    raise exception 'Brak uprawnień do anulowania tego zapisu na szkolenie.' using errcode='42501';
  end if;
  -- The unchanged hardened RPC rechecks owner/staff and the cancellation window.
  return public.cancel_event_registration(p_registration_id);
end;
$function$;

create function public.mark_event_registration_paid_v2(p_tenant_id uuid,p_registration_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $function$
begin
  if coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee')
     or not exists(select 1 from public.event_registrations r
       join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
       where r.id=p_registration_id and r.tenant_id=p_tenant_id) then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  return public.mark_event_registration_paid(p_registration_id);
end;
$function$;

do $acl$
declare v_function regprocedure;
begin
  for v_function in select pg_catalog.to_regprocedure(signature) from (values
    ('public.admin_list_events_v2(uuid,text,text,text,integer,integer)'),
    ('public.admin_create_event_v3(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
    ('public.admin_list_event_registrations_v2(uuid,uuid,text,text,integer,integer)'),
    ('public.admin_update_event_v3(uuid,uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
    ('public.admin_set_event_active_v3(uuid,uuid,boolean)'),
    ('public.approve_event_registration_v2(uuid,uuid)'),
    ('public.cancel_event_registration_v2(uuid,uuid)'),
    ('public.mark_event_registration_paid_v2(uuid,uuid)')
  ) names(signature) loop
    if v_function is null then raise exception 'C2-A ACL: target absent'; end if;
    execute pg_catalog.format('alter function %s owner to postgres',v_function);
    execute pg_catalog.format('revoke all on function %s from public,anon,authenticated,service_role',v_function);
    execute pg_catalog.format('grant execute on function %s to authenticated',v_function);
  end loop;
end;
$acl$;

do $postflight$
begin
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>83 then
    raise exception 'C2-A postflight: DEFINER count is not 83';
  end if;
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in
        ('admin_list_events_v2','admin_list_event_registrations_v2','admin_create_event_v3',
         'admin_update_event_v3','admin_set_event_active_v3','approve_event_registration_v2',
         'cancel_event_registration_v2','mark_event_registration_paid_v2')
        and p.proowner='postgres'::regrole and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
        and pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
        and not pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE')
        and not pg_catalog.has_function_privilege('service_role',p.oid,'EXECUTE')
        and p.prosecdef=(p.proname<>'admin_list_events_v2'))<>8 then
    raise exception 'C2-A postflight: metadata/ACL differ';
  end if;
end;
$postflight$;
