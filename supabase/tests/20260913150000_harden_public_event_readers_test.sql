\set ON_ERROR_STOP on
\pset format unaligned

select '1..40';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.ok(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.as_json(p_role text,p_user uuid,p_sql text)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
  execute p_sql into v_result;
  reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_result;
exception when others then
  reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  raise;
end;
$function$;

create function pg_temp.denied(p_role text,p_sql text)
returns boolean language plpgsql as $function$
begin
  execute pg_catalog.format('set local role %I',p_role);
  execute p_sql;
  reset role;
  return false;
exception when insufficient_privilege then
  reset role;
  return true;
end;
$function$;

create function pg_temp.fails_closed(p_role text,p_sql text)
returns boolean language plpgsql as $function$
begin
  execute pg_catalog.format('set local role %I',p_role);
  execute p_sql;
  reset role;
  return false;
exception when others then
  reset role;
  return true;
end;
$function$;

create function pg_temp.raises_fk(p_sql text)
returns boolean language plpgsql as $function$
begin
  execute p_sql;
  return false;
exception when foreign_key_violation then
  return true;
end;
$function$;

do $tests$
declare
  csk constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid:=pg_catalog.gen_random_uuid();
  user_a uuid:=pg_catalog.gen_random_uuid();
  lane_a uuid:=pg_catalog.gen_random_uuid();
  lane_b uuid:=pg_catalog.gen_random_uuid();
  event_a uuid:=pg_catalog.gen_random_uuid();
  event_a_past uuid:=pg_catalog.gen_random_uuid();
  event_a_inactive uuid:=pg_catalog.gen_random_uuid();
  event_b uuid:=pg_catalog.gen_random_uuid();
  run_id text:=pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  marker text;
  list_a jsonb;
  list_repeat jsonb;
  availability_a jsonb;
  availability_b jsonb;
  result jsonb;
  event_a_row jsonb;
  total_a integer;
begin
  marker:='[TEST][SAAS-9D-2B-2]['||run_id||']';

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(user_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d2b2-'||run_id||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());
  insert into public.profiles(id,user_id,email,role,verification_status)
  select auth_user.id,auth_user.id,auth_user.email,'user','verified'
  from auth.users auth_user left join public.profiles profile on profile.user_id=auth_user.id
  where auth_user.id=user_a and profile.user_id is null;
  update public.profiles set first_name='[TEST]',last_name='SAAS9D2B2',full_name=marker,phone='000' where user_id=user_a;
  if (select pg_catalog.count(*) from public.profiles where user_id=user_a)<>1 then
    raise exception 'SAAS-9D-2B-2 fixture profile count differs.';
  end if;

  insert into public.tenants(id,name,slug,status)
  values(tenant_b,marker||' Tenant B','saas9d2b2-'||pg_catalog.left(run_id,16),'dormant');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (lane_a,csk,marker||' Lane A','test',true,10,60,9960,'lane',null,true,false),
    (lane_b,tenant_b,marker||' Lane B','test',true,10,60,9961,'lane',null,true,false);
  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values
    (event_a,csk,marker||' Event A','<script>pii@example.invalid</script>',date '2099-11-01',time '10:00',time '11:00','Test A',100,10,true),
    (event_a_past,csk,marker||' Event A past','Past',date '2020-01-01',time '10:00',time '11:00','Test A',100,10,true),
    (event_a_inactive,csk,marker||' Event A inactive','Inactive',date '2099-11-02',time '10:00',time '11:00','Test A',100,10,false),
    (event_b,tenant_b,marker||' Event B','B',date '2099-11-03',time '10:00',time '11:00','Test B',100,20,true);
  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  select pg_catalog.gen_random_uuid(),csk,marker||' Page '||pg_catalog.lpad(number::text,3,'0'),'Page',date '2100-01-01'+number,time '12:00',time '13:00','Test A',50,5,true
  from pg_catalog.generate_series(1,52) number;
  insert into public.event_lanes(tenant_id,event_id,lane_id)
  values(csk,event_a,lane_a),(tenant_b,event_b,lane_b);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values
    (pg_catalog.gen_random_uuid(),csk,event_a,null,marker||' Registered','registered-'||run_id||'@example.invalid','000','registered','pay_on_site'),
    (pg_catalog.gen_random_uuid(),csk,event_a,null,marker||' Approved','approved-'||run_id||'@example.invalid','000','approved','pay_on_site'),
    (pg_catalog.gen_random_uuid(),csk,event_a,null,marker||' Reserve','reserve-'||run_id||'@example.invalid','000','reserve','pay_on_site'),
    (pg_catalog.gen_random_uuid(),csk,event_a,null,marker||' Cancelled','cancelled-'||run_id||'@example.invalid','000','cancelled','pay_on_site'),
    (pg_catalog.gen_random_uuid(),tenant_b,event_b,null,marker||' B registered','b-'||run_id||'@example.invalid','000','registered','pay_on_site');

  perform pg_temp.ok(1,'exact public signatures remain',
    pg_catalog.to_regprocedure('public.get_public_event_availability_v2(uuid)') is not null
    and pg_catalog.to_regprocedure('public.get_public_event_list_v3(uuid,text,text,integer,integer)') is not null
    and (select pg_catalog.count(*)=2 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname in('get_public_event_availability_v2','get_public_event_list_v3')),
    'Public signature inventory differs.');
  perform pg_temp.ok(2,'public wrappers are postgres-owned stable SP1 definers',
    (select pg_catalog.count(*)=2 and pg_catalog.bool_and(procedure.prosecdef) and pg_catalog.bool_and(procedure.provolatile='s') and pg_catalog.bool_and(owner_role.rolname='postgres') and pg_catalog.bool_and(procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
     where namespace.nspname='public' and procedure.proname in('get_public_event_availability_v2','get_public_event_list_v3')),
    'Wrapper metadata differs.');
  perform pg_temp.ok(3,'public wrapper ACL is anon and authenticated only',
    (select pg_catalog.count(*)=2 and pg_catalog.bool_and(pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')) and pg_catalog.bool_and(pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE'))
     from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
     where namespace.nspname='public' and procedure.proname in('get_public_event_availability_v2','get_public_event_list_v3')),
    'Public wrapper grants differ.');
  perform pg_temp.ok(4,'two exact private core signatures exist',
    pg_catalog.to_regprocedure('public.get_public_event_availability_v1__saas9d2b2_core(uuid)') is not null
    and pg_catalog.to_regprocedure('public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)') is not null,
    'Core function inventory differs.');
  perform pg_temp.ok(5,'cores are postgres-owned stable SP1 invokers',
    (select pg_catalog.count(*)=2 and pg_catalog.bool_and(not procedure.prosecdef) and pg_catalog.bool_and(procedure.provolatile='s') and pg_catalog.bool_and(owner_role.rolname='postgres') and pg_catalog.bool_and(procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
     where namespace.nspname='public' and procedure.proname like '%__saas9d2b2_core'),
    'Core metadata differs.');
  perform pg_temp.ok(6,'core EXECUTE is denied to all application roles',
    (select pg_catalog.count(*)=2 and pg_catalog.bool_and(not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE'))
     from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
     where namespace.nspname='public' and procedure.proname like '%__saas9d2b2_core'),
    'A core is directly callable.');
  perform pg_temp.ok(7,'anon cannot invoke availability core directly',pg_temp.denied('anon','select public.get_public_event_availability_v1__saas9d2b2_core(null)'),'Anon core execution was allowed.');
  perform pg_temp.ok(8,'authenticated cannot invoke list core directly',pg_temp.denied('authenticated','select public.get_public_event_list_v2__saas9d2b2_core(null,null,''all'',1,20)'),'Authenticated core execution was allowed.');
  perform pg_temp.ok(9,'wrapper and core fingerprints are exact',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_public_event_availability_v2(uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='783e1dc37ea222888be7ecb54fb6fa04'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_public_event_list_v3(uuid,text,text,integer,integer)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='5c455312be9f3b6a2e9bd26fc15ded0a'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_public_event_availability_v1__saas9d2b2_core(uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='bac4afc5c5a26fc63d019304b7903f4b'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='abe6f9d8e77655b1b5987825caee4c68'
    and pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null,
    'Definition drift detected.');
  perform pg_temp.ok(10,'core bodies explicitly filter events and registrations by tenant',
    pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.get_public_event_availability_v1__saas9d2b2_core(uuid)'::pg_catalog.regprocedure),'event_record.tenant_id=p_tenant_id')>0
    and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.get_public_event_availability_v1__saas9d2b2_core(uuid)'::pg_catalog.regprocedure),'registration.tenant_id=p_tenant_id')>0
    and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)'::pg_catalog.regprocedure),'event_record.tenant_id=p_tenant_id')>0
    and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)'::pg_catalog.regprocedure),'registration.tenant_id=p_tenant_id')>0,
    'Tenant predicates are absent.');

  list_a:=pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''upcoming'',1,50)',csk,marker));
  availability_a:=pg_temp.as_json('anon',null,pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(row_record) order by row_record.event_date,row_record.start_time,row_record.event_id),''[]''::jsonb) from public.get_public_event_availability_v2(%L) row_record',csk));
  total_a:=(list_a#>>'{pagination,total}')::integer;
  perform pg_temp.ok(11,'one active Tenant A returns only Tenant A list rows',list_a->>'code'='ok' and total_a=53 and not exists(select 1 from pg_catalog.jsonb_array_elements(list_a->'items') item where item->>'event_id'=event_b::text),'Tenant B leaked into Tenant A list.');
  perform pg_temp.ok(12,'one active Tenant A returns only Tenant A availability',availability_a @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_a)) and not availability_a @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_b)),'Tenant B leaked into Tenant A availability.');
  select item into event_a_row from pg_catalog.jsonb_array_elements(list_a->'items') item where item->>'event_id'=event_a::text;
  perform pg_temp.ok(13,'availability counts canonical statuses only',event_a_row @> '{"registered_count":2,"reserve_count":1,"available_spots":8,"sold_out":false}'::jsonb,'registered/approved/reserve/cancelled semantics differ.');
  perform pg_temp.ok(14,'availability reader matches list aggregate',(select item @> '{"registered_count":2,"reserve_count":1,"available_spots":8,"sold_out":false}'::jsonb from pg_catalog.jsonb_array_elements(availability_a) item where item->>'event_id'=event_a::text),'Reader aggregates disagree.');
  perform pg_temp.ok(15,'authenticated and anon list contracts are identical',pg_temp.as_json('authenticated',user_a,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''upcoming'',1,50)',csk,marker))=list_a,'Membership or identity changed public list.');
  perform pg_temp.ok(16,'authenticated and anon availability contracts are identical',pg_temp.as_json('authenticated',user_a,pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(row_record) order by row_record.event_date,row_record.start_time,row_record.event_id),''[]''::jsonb) from public.get_public_event_availability_v2(%L) row_record',csk))=availability_a,'Membership or identity changed public availability.');
  perform pg_temp.ok(17,'public list DTO is unchanged',not exists(select 1 from pg_catalog.jsonb_array_elements(list_a->'items') item cross join lateral pg_catalog.jsonb_object_keys(item) key_name where key_name not in('event_id','title','description','event_date','start_time','end_time','location','price','max_participants','registered_count','reserve_count','available_spots','sold_out')),'Unexpected public list field exists.');
  perform pg_temp.ok(18,'public availability DTO is unchanged',not exists(select 1 from pg_catalog.jsonb_array_elements(availability_a) item cross join lateral pg_catalog.jsonb_object_keys(item) key_name where key_name not in('event_id','title','description','event_date','start_time','end_time','location','price','max_participants','registered_count','reserve_count','available_spots','sold_out')),'Unexpected availability field exists.');
  perform pg_temp.ok(19,'public payload exposes no identity or internal metadata',(list_a||availability_a)::text !~* 'customer|user_id|registration_id|tenant_id|membership|admin_note|audit|phone|token|saas9d2b2-[a-z0-9]+@example\.invalid','PII or internal metadata leaked.');
  perform pg_temp.ok(20,'public description remains product data, not registration PII',event_a_row->>'description'='<script>pii@example.invalid</script>','Reader altered the established event DTO.');
  perform pg_temp.ok(21,'pagination page one is bounded to 50',pg_catalog.jsonb_array_length(list_a->'items')=50 and list_a#>>'{pagination,page_size}'='50','Page size contract regressed.');
  result:=pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''upcoming'',2,50)',csk,marker));
  perform pg_temp.ok(22,'pagination page two returns remaining rows',pg_catalog.jsonb_array_length(result->'items')=3 and result#>>'{pagination,total}'='53','Second page contract regressed.');
  perform pg_temp.ok(23,'pages contain no duplicates',not exists(select 1 from pg_catalog.jsonb_array_elements(list_a->'items') first_item join pg_catalog.jsonb_array_elements(result->'items') second_item on first_item->>'event_id'=second_item->>'event_id'),'Pagination duplicated rows.');
  list_repeat:=pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''upcoming'',1,50)',csk,marker));
  perform pg_temp.ok(24,'date/time/id ordering is stable',list_repeat->'items'=list_a->'items','Repeated ordering differs.');
  result:=pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''all'',1,50)',csk,marker));
  perform pg_temp.ok(25,'all scope includes past active event and excludes inactive event',result#>>'{pagination,total}'='54' and result->'items' @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_a_past)) and not result->'items' @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_a_inactive)),'Scope/is_active behavior changed.');
  perform pg_temp.ok(26,'invalid filters and oversized pages fail safely',(pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,null,''invalid'',1,20)',csk))->>'code')='invalid_input' and (pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,null,''all'',1,51)',csk))->>'code')='invalid_input','Invalid input broadened the query.');

  update public.tenants set status='dormant' where id=csk;
  update public.tenants set status='active' where id=tenant_b;
  result:=pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''upcoming'',1,50)',tenant_b,marker));
  availability_b:=pg_temp.as_json('anon',null,pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(row_record) order by row_record.event_date,row_record.start_time,row_record.event_id),''[]''::jsonb) from public.get_public_event_availability_v2(%L) row_record',tenant_b));
  perform pg_temp.ok(27,'one active Tenant B returns only Tenant B list rows',result#>>'{pagination,total}'='1' and result->'items' @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_b)) and not result->'items' @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_a)),'Tenant A leaked into Tenant B list.');
  perform pg_temp.ok(28,'one active Tenant B returns only Tenant B availability',availability_b @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_b,'registered_count',1)) and not availability_b @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_a)),'Tenant A leaked into Tenant B availability.');

  update public.tenants set status='dormant' where id=tenant_b;
  result:=pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''upcoming'',1,50)',csk,marker));
  perform pg_temp.ok(29,'zero active tenants returns controlled not_found for public list selector',result @> '{"ok":false,"code":"not_found"}'::jsonb,'Zero-active list did not fail closed.');
  perform pg_temp.ok(30,'zero active tenants rejects public availability selector',pg_temp.fails_closed('anon',pg_catalog.format('select * from public.get_public_event_availability_v2(%L)',csk)),'Zero-active availability did not fail closed.');

  update public.tenants set status='active' where id=csk;
  drop index if exists public.tenants_single_active_runtime_guard;
  update public.tenants set status='active' where id=tenant_b;
  result:=pg_temp.as_json('anon',null,pg_catalog.format('select public.get_public_event_list_v3(%L,%L,''upcoming'',1,50)',csk,marker));
  perform pg_temp.ok(31,'two active tenants preserve explicit list isolation',result->>'code'='ok' and (result#>>'{pagination,total}')::integer>0 and not result->'items' @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_b)),'Explicit Tenant A list leaked Tenant B.');
  result:=pg_temp.as_json('anon',null,pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(row_record)),''[]''::jsonb) from public.get_public_event_availability_v2(%L) row_record',csk));
  perform pg_temp.ok(32,'two active tenants preserve explicit availability isolation',not result @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_b)) and result @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id',event_a)),'Explicit Tenant A availability leaked Tenant B.');
  update public.tenants set status='dormant' where id=tenant_b;

  perform pg_temp.ok(33,'Event A plus Registration B is rejected by tenant FK',pg_temp.raises_fk(pg_catalog.format('insert into public.event_registrations(id,tenant_id,event_id,customer_name,customer_email,customer_phone,registration_status,payment_status) values(%L,%L,%L,%L,%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),tenant_b,event_a,marker||' Invalid','invalid-'||run_id||'@example.invalid','000','registered','pay_on_site')),'Cross-tenant registration was accepted.');
  perform pg_temp.ok(34,'Tenant B registrations do not affect Event A availability',(select item @> '{"registered_count":2,"reserve_count":1,"available_spots":8}'::jsonb from pg_catalog.jsonb_array_elements(pg_temp.as_json('anon',null,pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(row_record)),''[]''::jsonb) from public.get_public_event_availability_v2(%L) row_record',csk))) item where item->>'event_id'=event_a::text),'Tenant B registration changed Event A count.');
  perform pg_temp.ok(35,'Event A plus Lane B is rejected by tenant FK',pg_temp.raises_fk(pg_catalog.format('insert into public.event_lanes(tenant_id,event_id,lane_id) values(%L,%L,%L)',csk,event_a,lane_b)),'Cross-tenant lane relation was accepted.');
  perform pg_temp.ok(36,'existing event-lane relations remain tenant-consistent',not exists(select 1 from public.event_lanes relation join public.events event_record on event_record.id=relation.event_id join public.shooting_lanes lane on lane.id=relation.lane_id where relation.tenant_id<>event_record.tenant_id or relation.tenant_id<>lane.tenant_id),'A cross-tenant relation exists.');
  perform pg_temp.ok(37,'registration composite FK remains validated',exists(select 1 from pg_catalog.pg_constraint constraint_record where constraint_record.conrelid='public.event_registrations'::pg_catalog.regclass and constraint_record.conname='event_registrations_event_id_fkey' and constraint_record.contype='f' and constraint_record.convalidated),'Registration tenant FK differs.');
  perform pg_temp.ok(38,'event-lane composite FKs remain validated',(select pg_catalog.count(*)=2 from pg_catalog.pg_constraint constraint_record where constraint_record.conrelid='public.event_lanes'::pg_catalog.regclass and constraint_record.conname in('event_lanes_event_id_fkey','event_lanes_lane_id_fkey') and constraint_record.contype='f' and constraint_record.convalidated),'Event-lane tenant FKs differ.');
  perform pg_temp.ok(39,'SECURITY DEFINER inventory includes PRODUCT-10B public readers',(select pg_catalog.count(*)=77 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef),'Unexpected definer drift exists.');
  perform pg_temp.ok(40,'fixture is transaction scoped',(select pg_catalog.count(*)=1 from public.tenants where id=tenant_b) and (select pg_catalog.count(*)=56 from public.events where title like marker||'%') and (select pg_catalog.count(*)=5 from public.event_registrations where customer_name like marker||'%'),'Fixture count differs before rollback.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order::text||' - '||test_name||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order) into v_failures from pg_temp.test_results where not passed;
  if v_failures is not null then raise exception 'SAAS-9D-2B-2 public event reader hardening failed: %',v_failures; end if;
end;
$assertions$;

rollback;
