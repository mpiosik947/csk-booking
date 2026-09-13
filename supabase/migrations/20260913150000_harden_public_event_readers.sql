-- SAAS-9D-2B-2: tenant-scope public event readers behind stable public wrappers.

do $preflight$
declare
  v_definers integer;
begin
  if pg_catalog.to_regprocedure('public.get_public_event_availability_v1()') is null
     or pg_catalog.to_regprocedure('public.get_public_event_list_v2(text,text,integer,integer)') is null
     or pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null then
    raise exception 'SAAS-9D-2B-2 preflight failed: required functions are missing.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('get_public_event_availability_v1','get_public_event_list_v2'))<>2 then
    raise exception 'SAAS-9D-2B-2 preflight failed: public reader overload inventory drift.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.get_public_event_availability_v1()'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '40adf74cb5adec5df3b4745fc7851433'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.get_public_event_list_v2(text,text,integer,integer)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> 'fe075d7057149b0a0bad0129419a3e99' then
    raise exception 'SAAS-9D-2B-2 preflight failed: public reader fingerprint drift.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.active_single_tenant_id_v1()'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '6017112df961a334320d98dd0645e570' then
    raise exception 'SAAS-9D-2B-2 preflight failed: active tenant bridge fingerprint drift.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where n.nspname='public'
        and p.proname in ('get_public_event_availability_v1','get_public_event_list_v2')
        and p.prosecdef and p.provolatile='s' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])=2 then
    null;
  else
    raise exception 'SAAS-9D-2B-2 preflight failed: reader metadata drift.';
  end if;

  if not exists(select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.active_single_tenant_id_v1()'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='s' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     or pg_catalog.has_function_privilege('public','public.active_single_tenant_id_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.active_single_tenant_id_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.active_single_tenant_id_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.active_single_tenant_id_v1()','EXECUTE') then
    raise exception 'SAAS-9D-2B-2 preflight failed: active tenant bridge metadata or ACL drift.';
  end if;

  if not pg_catalog.has_function_privilege('anon','public.get_public_event_availability_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_event_availability_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_event_availability_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.get_public_event_availability_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('anon','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE') then
    raise exception 'SAAS-9D-2B-2 preflight failed: reader ACL drift.';
  end if;

  if pg_catalog.to_regprocedure('public.get_public_event_availability_v1__saas9d2b2_core(uuid)') is not null
     or pg_catalog.to_regprocedure('public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)') is not null then
    raise exception 'SAAS-9D-2B-2 preflight failed: core already exists.';
  end if;

  if exists(select 1 from public.events where tenant_id is null)
     or exists(select 1 from public.event_registrations where tenant_id is null)
     or pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is null
     or not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.event_registrations'::pg_catalog.regclass and conname='event_registrations_event_id_fkey' and contype='f' and convalidated) then
    raise exception 'SAAS-9D-2B-2 preflight failed: tenant integrity prerequisites differ.';
  end if;

  select pg_catalog.count(*) into v_definers
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef;
  if v_definers<>73 then
    raise exception 'SAAS-9D-2B-2 preflight failed: SECURITY DEFINER inventory is %, expected 73.',v_definers;
  end if;
end;
$preflight$;

create function public.get_public_event_availability_v1__saas9d2b2_core(p_tenant_id uuid)
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
security invoker
set search_path=pg_catalog, public, pg_temp
as $function$
  with registration_counts as (
    select
      registration.tenant_id,
      registration.event_id,
      pg_catalog.count(*) filter (
        where pg_catalog.lower(pg_catalog.btrim(registration.registration_status))
          in ('registered','approved')
      )::integer as registered_count,
      pg_catalog.count(*) filter (
        where pg_catalog.lower(pg_catalog.btrim(registration.registration_status))='reserve'
      )::integer as reserve_count
    from public.event_registrations registration
    where registration.tenant_id=p_tenant_id
      and registration.event_id is not null
    group by registration.tenant_id,registration.event_id
  ), public_events as (
    select
      event_record.id as event_id,
      event_record.title,
      coalesce(event_record.description,'') as description,
      event_record.event_date,
      event_record.start_time,
      event_record.end_time,
      coalesce(event_record.location,'') as location,
      event_record.price,
      event_record.max_participants,
      coalesce(registration_counts.registered_count,0) as registered_count,
      coalesce(registration_counts.reserve_count,0) as reserve_count
    from public.events event_record
    left join registration_counts
      on registration_counts.tenant_id=event_record.tenant_id
     and registration_counts.event_id=event_record.id
    where event_record.tenant_id=p_tenant_id
      and event_record.is_active
  )
  select
    public_events.event_id,public_events.title,public_events.description,
    public_events.event_date,public_events.start_time,public_events.end_time,
    public_events.location,public_events.price,public_events.max_participants,
    public_events.registered_count,public_events.reserve_count,
    greatest(public_events.max_participants-public_events.registered_count,0)::integer as available_spots,
    public_events.registered_count>=public_events.max_participants as sold_out
  from public_events
  order by public_events.event_date,public_events.start_time,public_events.event_id;
$function$;

alter function public.get_public_event_availability_v1__saas9d2b2_core(uuid) owner to postgres;
revoke all on function public.get_public_event_availability_v1__saas9d2b2_core(uuid)
  from public,anon,authenticated,service_role;

create function public.get_public_event_list_v2__saas9d2b2_core(
  p_tenant_id uuid,
  p_search text,
  p_scope text,
  p_page integer,
  p_page_size integer
)
returns jsonb
language plpgsql
stable
security invoker
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_search text:=nullif(pg_catalog.btrim(p_search),'');
  v_scope text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_scope,'')));
  v_offset integer;
  v_now timestamp without time zone:=pg_catalog.transaction_timestamp() at time zone 'Europe/Warsaw';
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
    select event_record.id,event_record.tenant_id,event_record.title,
      coalesce(event_record.description,'') description,
      event_record.event_date,event_record.start_time,event_record.end_time,
      coalesce(event_record.location,'') location,event_record.price,event_record.max_participants
    from public.events event_record
    where event_record.tenant_id=p_tenant_id
      and event_record.is_active
      and (v_search is null or event_record.title ilike '%'||v_search||'%')
      and (v_scope='all' or (event_record.event_date+event_record.end_time)>v_now)
  ), page_events as materialized (
    select * from filtered order by event_date,start_time,id limit p_page_size offset v_offset
  ), registration_counts as (
    select registration.tenant_id,registration.event_id,
      pg_catalog.count(*) filter(where pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in ('registered','approved'))::integer registered_count,
      pg_catalog.count(*) filter(where pg_catalog.lower(pg_catalog.btrim(registration.registration_status))='reserve')::integer reserve_count
    from public.event_registrations registration
    where registration.tenant_id=p_tenant_id
      and registration.event_id in(select page_event.id from page_events page_event)
    group by registration.tenant_id,registration.event_id
  ), page_rows as (
    select page_event.*,coalesce(counts.registered_count,0) registered_count,
      coalesce(counts.reserve_count,0) reserve_count
    from page_events page_event
    left join registration_counts counts
      on counts.tenant_id=page_event.tenant_id and counts.event_id=page_event.id
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
end;
$function$;

alter function public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer) owner to postgres;
revoke all on function public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)
  from public,anon,authenticated,service_role;

create or replace function public.get_public_event_availability_v1()
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
set search_path=pg_catalog, public, pg_temp
as $function$
  select *
  from public.get_public_event_availability_v1__saas9d2b2_core(
    public.active_single_tenant_id_v1()
  );
$function$;

create or replace function public.get_public_event_list_v2(
  p_search text default null,
  p_scope text default 'upcoming',
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path=pg_catalog, public, pg_temp
as $function$
  select public.get_public_event_list_v2__saas9d2b2_core(
    public.active_single_tenant_id_v1(),p_search,p_scope,p_page,p_page_size
  );
$function$;

alter function public.get_public_event_availability_v1() owner to postgres;
alter function public.get_public_event_list_v2(text,text,integer,integer) owner to postgres;

revoke all on function public.get_public_event_availability_v1()
  from public,anon,authenticated,service_role;
revoke all on function public.get_public_event_list_v2(text,text,integer,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.get_public_event_availability_v1() to anon,authenticated;
grant execute on function public.get_public_event_list_v2(text,text,integer,integer) to anon,authenticated;

comment on function public.get_public_event_availability_v1() is
  'Returns active events and authoritative counts for the exact active tenant, PII-free.';
comment on function public.get_public_event_list_v2(text,text,integer,integer) is
  'Returns the bounded PII-free event list for the exact active tenant.';
comment on function public.get_public_event_availability_v1__saas9d2b2_core(uuid) is
  'Owner-only tenant-scoped implementation for the public event availability wrapper.';
comment on function public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer) is
  'Owner-only tenant-scoped implementation for the public event list wrapper.';

do $postflight$
begin
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('get_public_event_availability_v1','get_public_event_list_v2'))<>2 then
    raise exception 'SAAS-9D-2B-2 postflight failed: public reader overload inventory drift.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where n.nspname='public'
        and p.proname in ('get_public_event_availability_v1','get_public_event_list_v2')
        and p.prosecdef and p.provolatile='s' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])=2 then null;
  else raise exception 'SAAS-9D-2B-2 postflight failed: wrapper metadata differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where n.nspname='public' and p.proname like '%__saas9d2b2_core'
        and not p.prosecdef and p.provolatile='s' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
        and not pg_catalog.has_function_privilege('public',p.oid,'EXECUTE')
        and not pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE')
        and not pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
        and not pg_catalog.has_function_privilege('service_role',p.oid,'EXECUTE'))=2 then null;
  else raise exception 'SAAS-9D-2B-2 postflight failed: core isolation differs.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.active_single_tenant_id_v1()'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '6017112df961a334320d98dd0645e570'
     or pg_catalog.has_function_privilege('public','public.active_single_tenant_id_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.active_single_tenant_id_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.active_single_tenant_id_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.active_single_tenant_id_v1()','EXECUTE') then
    raise exception 'SAAS-9D-2B-2 postflight failed: active tenant bridge drift.';
  end if;

  if not pg_catalog.has_function_privilege('anon','public.get_public_event_availability_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_event_availability_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_event_availability_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.get_public_event_availability_v1()','EXECUTE')
     or not pg_catalog.has_function_privilege('anon','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE') then
    raise exception 'SAAS-9D-2B-2 postflight failed: wrapper ACL differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>73 then
    raise exception 'SAAS-9D-2B-2 postflight failed: SECURITY DEFINER inventory drift.';
  end if;
end;
$postflight$;
