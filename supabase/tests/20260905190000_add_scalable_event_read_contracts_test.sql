\set ON_ERROR_STOP on
\pset format unaligned

select '1..28';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.set_client(p_role text,p_user_id uuid)
returns void language plpgsql as $function$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user_id,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user_id::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end;
$function$;

create function pg_temp.call_json(p_role text,p_user_id uuid,p_sql text)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_temp.set_client(p_role,p_user_id);
  execute p_sql into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_denied(p_role text,p_sql text)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client(p_role,null);
  execute p_sql;
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

do $tests$
declare
  v_run text:=pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  v_marker text;
  v_admin uuid:=pg_catalog.gen_random_uuid();
  v_employee uuid:=pg_catalog.gen_random_uuid();
  v_instructor uuid:=pg_catalog.gen_random_uuid();
  v_user uuid:=pg_catalog.gen_random_uuid();
  v_event uuid:=pg_catalog.gen_random_uuid();
  v_public jsonb;
  v_admin_result jsonb;
  v_participants jsonb;
  v_my jsonb;
  v_repeat jsonb;
begin
  v_marker:='[TEST][EVENTS-8B]['||v_run||']';

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','events8b-admin-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','events8b-employee-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','events8b-instructor-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','events8b-user-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(id,user_id,email,role,verification_status)
  select auth_user.id,auth_user.id,auth_user.email,'user','pending'
  from auth.users auth_user left join public.profiles profile on profile.user_id=auth_user.id
  where auth_user.id in(v_admin,v_employee,v_instructor,v_user) and profile.user_id is null;

  update public.profiles set role=case user_id when v_admin then 'admin' when v_employee then 'pracownik' when v_instructor then 'instruktor' else 'user' end,
    first_name='[TEST]',last_name='Events 8B',full_name='[TEST] Events 8B',phone='000000000'
  where user_id in(v_admin,v_employee,v_instructor,v_user);
  if (select pg_catalog.count(*) from public.profiles where user_id in(v_admin,v_employee,v_instructor,v_user))<>4 then
    raise exception 'EVENTS-8B fixture failed: expected four profiles.';
  end if;

  insert into public.events(id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active,created_at)
  select case when number=1 then v_event else pg_catalog.gen_random_uuid() end,
    v_marker||' Event '||pg_catalog.lpad(number::text,4,'0'),'Opis',
    case when number=499 then current_date-10 else current_date+number end,
    time '10:00',time '11:00','[TEST]',100,6000,number<>500,
    pg_catalog.now()+(number||' milliseconds')::interval
  from pg_catalog.generate_series(1,500) number;

  insert into public.event_registrations(event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,created_at)
  select v_event,null,v_marker||' Person '||number,'events8b-'||v_run||'-'||number||'@example.invalid','000',
    case when number%10=0 then 'reserve' when number%10=1 then 'cancelled' else 'registered' end,
    case when number%2=0 then 'paid_on_site' else 'pay_on_site' end,
    pg_catalog.now()+(number||' milliseconds')::interval
  from pg_catalog.generate_series(1,5000) number;

  insert into public.event_registrations(event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,created_at)
  select event_record.id,v_user,v_marker||' Owner','events8b-user-'||v_run||'@example.invalid','000',
    case when row_number() over(order by event_record.event_date)%6=0 then 'cancelled' else 'registered' end,
    'pay_on_site',pg_catalog.now()
  from public.events event_record
  where event_record.title like v_marker||'%'
    and event_record.is_active
    and event_record.event_date>current_date
  order by event_record.event_date,event_record.id limit 60;

  perform pg_temp.record_result(1,'Four exact RPC signatures exist',
    pg_catalog.to_regprocedure('public.get_public_event_list_v2(text,text,integer,integer)') is not null
    and pg_catalog.to_regprocedure('public.admin_list_events_v1(text,text,text,integer,integer)') is not null
    and pg_catalog.to_regprocedure('public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)') is not null
    and pg_catalog.to_regprocedure('public.get_my_event_registrations_v1(text,text,integer,integer)') is not null,
    'Every versioned read contract must exist.');

  perform pg_temp.record_result(2,'RPCs are STABLE SECURITY DEFINER with safe ownership and search_path',
    (select pg_catalog.count(*)=4 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
      where namespace.nspname='public' and procedure.proname in('get_public_event_list_v2','admin_list_events_v1','admin_list_event_registrations_v1','get_my_event_registrations_v1')
      and procedure.prosecdef and procedure.provolatile='s' and owner_role.rolname='postgres' and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]),
    'All readers must use the hardened function contract.');

  perform pg_temp.record_result(3,'Public RPC ACL is anon and authenticated only',
    pg_catalog.has_function_privilege('anon','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_public_event_list_v2(text,text,integer,integer)','EXECUTE')
    and not exists(select 1 from pg_catalog.pg_proc procedure cross join lateral pg_catalog.aclexplode(coalesce(procedure.proacl,pg_catalog.acldefault('f',procedure.proowner))) acl where procedure.oid='public.get_public_event_list_v2(text,text,integer,integer)'::regprocedure and acl.grantee=0),
    'The public contract needs no generic PUBLIC or service role grant.');

  perform pg_temp.record_result(4,'Private RPC ACL is authenticated only',
    (select pg_catalog.bool_and(pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE') and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE') and not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE'))
     from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname in('admin_list_events_v1','admin_list_event_registrations_v1','get_my_event_registrations_v1')),
    'Private contracts expose only the authenticated entry point.');

  v_public:=pg_temp.call_json('anon',null,pg_catalog.format('select public.get_public_event_list_v2(%L,%L,1,20)',v_marker,'upcoming'));
  perform pg_temp.record_result(5,'Public upcoming list is bounded',v_public#>>'{pagination,total}'='498' and pg_catalog.jsonb_array_length(v_public->'items')=20,'498 active future rows must produce a 20-row first page.');
  perform pg_temp.record_result(6,'Public search runs on the backend',v_public#>>'{filters,search}'=v_marker and (v_public#>>'{pagination,total}')::integer=498,'Unique marker search must isolate fixture rows.');
  perform pg_temp.record_result(7,'Public response is strictly PII-free',v_public::text !~* 'example\.invalid|customer|user_id|registration_id|token|admin_note|phone|email','No participant or internal fields may leave the public contract.');
  perform pg_temp.record_result(8,'Public availability remains authoritative',v_public->'items'->0 @> '{"registered_count":4001,"reserve_count":500,"available_spots":1999,"sold_out":false}'::jsonb,'Status counts must match canonical availability semantics, including the owner fixture row.');
  v_repeat:=pg_temp.call_json('anon',null,pg_catalog.format('select public.get_public_event_list_v2(%L,%L,1,20)',v_marker,'upcoming'));
  perform pg_temp.record_result(9,'Public sorting is stable',v_repeat->'items'=v_public->'items','Repeated reads must preserve date/time/id order.');
  v_repeat:=pg_temp.call_json('authenticated',v_user,pg_catalog.format('select public.get_public_event_list_v2(%L,%L,1,20)',v_marker,'upcoming'));
  perform pg_temp.record_result(10,'Anon and user receive identical public data',v_repeat=v_public,'Identity and owner-scoped RLS must not change availability.');
  v_repeat:=pg_temp.call_json('anon',null,pg_catalog.format('select public.get_public_event_list_v2(%L,%L,25,20)',v_marker,'upcoming'));
  perform pg_temp.record_result(11,'Public 500-row fixture remains paginated',pg_catalog.jsonb_array_length(v_repeat->'items')=18 and v_repeat#>>'{pagination,total}'='498','Last page must be bounded without fetch-all.');

  v_admin_result:=pg_temp.call_json('authenticated',v_admin,pg_catalog.format('select public.admin_list_events_v1(%L,%L,%L,1,20)',v_marker,'all','nearest'));
  perform pg_temp.record_result(12,'Admin list returns a bounded 500-row scope',v_admin_result#>>'{pagination,total}'='500' and pg_catalog.jsonb_array_length(v_admin_result->'items')=20,'Admin pagination must be backend-owned.');
  v_repeat:=pg_temp.call_json('authenticated',v_admin,pg_catalog.format('select public.admin_list_events_v1(%L,%L,%L,1,20)',v_marker,'past','latest'));
  perform pg_temp.record_result(13,'Admin past filter is backend authoritative',v_repeat#>>'{pagination,total}'='1','Exactly one fixture event is past.');
  v_repeat:=pg_temp.call_json('authenticated',v_admin,pg_catalog.format('select public.admin_list_events_v1(%L,%L,%L,1,20)',v_marker,'inactive','nearest'));
  perform pg_temp.record_result(14,'Admin inactive filter is backend authoritative',v_repeat#>>'{pagination,total}'='1','Exactly one fixture event is inactive.');
  perform pg_temp.record_result(15,'Admin list denies ordinary user',(pg_temp.call_json('authenticated',v_user,pg_catalog.format('select public.admin_list_events_v1(%L,%L,%L,1,20)',v_marker,'all','nearest')))->>'code'='not_allowed','Role check must fail closed.');
  perform pg_temp.record_result(16,'Existing employee and instructor event access is unchanged',
    (pg_temp.call_json('authenticated',v_employee,pg_catalog.format('select public.admin_list_events_v1(%L,%L,%L,1,20)',v_marker,'all','nearest')))->>'code'='ok'
    and (pg_temp.call_json('authenticated',v_instructor,pg_catalog.format('select public.admin_list_events_v1(%L,%L,%L,1,20)',v_marker,'all','nearest')))->>'code'='ok',
    'EVENTS-8B must not silently alter the established /admin/events route matrix.');

  v_participants:=pg_temp.call_json('authenticated',v_admin,pg_catalog.format('select public.admin_list_event_registrations_v1(%L,%L,%L,1,50)',v_event,null,null));
  perform pg_temp.record_result(17,'Participant list paginates 5000 rows',v_participants#>>'{pagination,total}'='5001' and pg_catalog.jsonb_array_length(v_participants->'items')=50,'Large participant list plus owner row must stay bounded.');
  perform pg_temp.record_result(18,'Participant counts are independent of current page',v_participants->'summary' @> '{"registered_count":4001,"reserve_count":500,"cancelled_count":500,"paid_count":2000}'::jsonb,'Summary must cover the event, not the current page.');
  v_repeat:=pg_temp.call_json('authenticated',v_admin,pg_catalog.format('select public.admin_list_event_registrations_v1(%L,%L,%L,1,50)',v_event,'reserve',null));
  perform pg_temp.record_result(19,'Participant status filter is backend-owned',v_repeat#>>'{pagination,total}'='500' and (select pg_catalog.bool_and(item->>'registration_status'='reserve') from pg_catalog.jsonb_array_elements(v_repeat->'items') item),'All page rows must match the requested status.');
  v_repeat:=pg_temp.call_json('authenticated',v_admin,pg_catalog.format('select public.admin_list_event_registrations_v1(%L,%L,%L,2,50)',v_event,null,'paid_on_site'));
  perform pg_temp.record_result(20,'Participant payment filter and stable page work',v_repeat#>>'{pagination,total}'='2500' and pg_catalog.jsonb_array_length(v_repeat->'items')=50 and (select pg_catalog.bool_and(item->>'payment_status'='paid_on_site') from pg_catalog.jsonb_array_elements(v_repeat->'items') item),'Second filtered page must contain only paid_on_site rows.');
  perform pg_temp.record_result(21,'Participant DTO contains only operational fields',not exists(select 1 from pg_catalog.jsonb_array_elements(v_participants->'items') item cross join lateral pg_catalog.jsonb_object_keys(item) key_name where key_name not in('id','customer_name','customer_email','customer_phone','registration_status','payment_status','created_at')),'No profile, token or internal delivery state may be returned.');
  perform pg_temp.record_result(22,'Participant list denies ordinary users without changing SEC-008',
    (pg_temp.call_json('authenticated',v_user,pg_catalog.format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',v_event)))->>'code'='not_allowed'
    and (pg_temp.call_json('authenticated',v_instructor,pg_catalog.format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',v_event)))->>'code'='ok',
    'Ordinary users are denied; deferred instructor access remains unchanged.');

  v_my:=pg_temp.call_json('authenticated',v_user,'select public.get_my_event_registrations_v1(''upcoming'',null,1,20)');
  perform pg_temp.record_result(23,'My events upcoming is owner-scoped and paginated',v_my#>>'{pagination,total}'='50' and pg_catalog.jsonb_array_length(v_my->'items')=20,'Only the caller own 50 upcoming rows are visible.');
  v_repeat:=pg_temp.call_json('authenticated',v_user,'select public.get_my_event_registrations_v1(''history'',''cancelled'',1,20)');
  perform pg_temp.record_result(24,'My events history and status filter agree',v_repeat#>>'{pagination,total}'='10' and (select pg_catalog.bool_and(item->>'registration_status'='cancelled') from pg_catalog.jsonb_array_elements(v_repeat->'items') item),'Cancelled fixture rows belong to history.');
  perform pg_temp.record_result(25,'My events contains no foreign registration',not (v_my->'items') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('id',(select id from public.event_registrations where event_id=v_event and user_id is null limit 1))),'No foreign row may enter the owner contract.');
  perform pg_temp.record_result(26,'Anonymous private calls are denied by ACL',pg_temp.call_denied('anon','select public.get_my_event_registrations_v1(''upcoming'',null,1,20)') and pg_temp.call_denied('anon',pg_catalog.format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',v_event)),'Anon receives public events only.');
  perform pg_temp.record_result(27,'Invalid filters fail safely',
    (pg_temp.call_json('anon',null,'select public.get_public_event_list_v2(null,''invalid'',1,20)')->>'code')='invalid_input'
    and (pg_temp.call_json('authenticated',v_admin,pg_catalog.format('select public.admin_list_events_v1(%L,''all'',''nearest'',0,20)',v_marker))->>'code')='invalid_input',
    'Invalid URL-derived values must not broaden a query.');
  perform pg_temp.record_result(28,'Performance indexes exist and fixture is transaction-scoped',
    pg_catalog.to_regclass('public.events_active_date_time_id_idx') is not null
    and pg_catalog.to_regclass('public.event_registrations_user_created_id_idx') is not null
    and pg_catalog.to_regclass('public.event_registrations_event_payment_created_id_idx') is not null
    and (select pg_catalog.count(*) from public.events where title like v_marker||'%')=500,
    'The final rollback removes the 500-event and 5000-participant workload.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order::text||' - '||test_name||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order) into v_failures from pg_temp.test_results where not passed;
  if v_failures is not null then raise exception 'EVENTS-8B tests failed: %',v_failures; end if;
end;
$assertions$;

rollback;
