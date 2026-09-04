\set ON_ERROR_STOP on
\pset format unaligned

select '1..24';

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
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role',p_role)::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user_id::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end;
$function$;

create function pg_temp.prepare_as(p_user_id uuid,p_type text,p_record_id uuid)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_temp.set_client('authenticated',p_user_id);
  select public.prepare_confirmation_email(p_type,p_record_id) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.complete_as_service(
  p_claim_id uuid,
  p_success boolean,
  p_provider_id text default null,
  p_error_code text default null
) returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_temp.set_client('service_role',null);
  select public.complete_confirmation_email(
    p_claim_id,p_success,p_provider_id,p_error_code
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.anon_prepare_denied(p_record_id uuid)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client('anon',null);
  perform public.prepare_confirmation_email('reservation_cancellation',p_record_id);
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

do $tests$
declare
  v_owner uuid := pg_catalog.gen_random_uuid();
  v_other uuid := pg_catalog.gen_random_uuid();
  v_employee uuid := pg_catalog.gen_random_uuid();
  v_admin uuid := pg_catalog.gen_random_uuid();
  v_instructor uuid := pg_catalog.gen_random_uuid();
  v_lane uuid := pg_catalog.gen_random_uuid();
  v_price uuid := pg_catalog.gen_random_uuid();
  v_owner_cancelled uuid := pg_catalog.gen_random_uuid();
  v_employee_cancelled uuid := pg_catalog.gen_random_uuid();
  v_admin_cancelled uuid := pg_catalog.gen_random_uuid();
  v_attempt_cancelled uuid := pg_catalog.gen_random_uuid();
  v_confirmed uuid := pg_catalog.gen_random_uuid();
  v_result jsonb;
  v_claim uuid;
  v_delivery_id uuid;
  v_attempt integer;
begin
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_owner,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec015-owner-'||v_owner||'@example.invalid','',now(),'{}','{}',now(),now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec015-other-'||v_other||'@example.invalid','',now(),'{}','{}',now(),now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec015-employee-'||v_employee||'@example.invalid','',now(),'{}','{}',now(),now()),
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec015-admin-'||v_admin||'@example.invalid','',now(),'{}','{}',now(),now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec015-instructor-'||v_instructor||'@example.invalid','',now(),'{}','{}',now(),now());

  insert into public.profiles(user_id,role,full_name,email)
  select fixture.user_id,fixture.role,'[TEST][SEC-015]',fixture.email
  from (values
    (v_owner,'user','sec015-owner-'||v_owner||'@example.invalid'),
    (v_other,'user','sec015-other-'||v_other||'@example.invalid'),
    (v_employee,'pracownik','sec015-employee-'||v_employee||'@example.invalid'),
    (v_admin,'admin','sec015-admin-'||v_admin||'@example.invalid'),
    (v_instructor,'instruktor','sec015-instructor-'||v_instructor||'@example.invalid')
  ) as fixture(user_id,role,email)
  where not exists(select 1 from public.profiles where user_id=fixture.user_id);

  update public.profiles as profile
  set role=fixture.role,full_name='[TEST][SEC-015]',email=fixture.email
  from (values
    (v_owner,'user','sec015-owner-'||v_owner||'@example.invalid'),
    (v_other,'user','sec015-other-'||v_other||'@example.invalid'),
    (v_employee,'pracownik','sec015-employee-'||v_employee||'@example.invalid'),
    (v_admin,'admin','sec015-admin-'||v_admin||'@example.invalid'),
    (v_instructor,'instruktor','sec015-instructor-'||v_instructor||'@example.invalid')
  ) as fixture(user_id,role,email)
  where profile.user_id=fixture.user_id;

  if (select count(*) from public.profiles where user_id in(v_owner,v_other,v_employee,v_admin,v_instructor)) <> 5 then
    raise exception 'SEC-015 fixture failed: expected five synthetic profiles.';
  end if;

  insert into public.shooting_lanes(
    id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,
    display_order,currency_code,resource_kind,parent_lane_id,
    whole_lane_bookable,positions_bookable
  ) values(v_lane,'[TEST][SEC-015] Lane','test',10,true,1,60,999,'PLN','lane',null,true,false);

  insert into public.lane_pricing_rules(
    id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price
  ) values(v_price,v_lane,'mon_thu',1,1,'[TEST][SEC-015]',10);

  insert into public.reservations(
    id,user_id,lane_id,customer_name,customer_email,customer_phone,
    reservation_date,start_time,end_time,duration_minutes,price,
    reservation_status,payment_status,attendance_status,shooters_count,
    pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,
    pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,
    creation_request_id
  ) values
    (v_owner_cancelled,v_owner,v_lane,'[TEST][SEC-015] Owner','sec015-owner@example.invalid','000',current_date+100,time '08:00',time '09:00',60,10,'cancelled_by_user','pay_on_site','planned',1,v_price,'mon_thu','[TEST][SEC-015] Lane','[TEST]',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_employee_cancelled,v_owner,v_lane,'[TEST][SEC-015] Owner','sec015-owner@example.invalid','000',current_date+101,time '08:00',time '09:00',60,10,'cancelled_by_admin','pay_on_site','planned',1,v_price,'mon_thu','[TEST][SEC-015] Lane','[TEST]',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_admin_cancelled,v_owner,v_lane,'[TEST][SEC-015] Owner','sec015-owner@example.invalid','000',current_date+102,time '08:00',time '09:00',60,10,'canceled','pay_on_site','planned',1,v_price,'mon_thu','[TEST][SEC-015] Lane','[TEST]',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_attempt_cancelled,v_owner,v_lane,'[TEST][SEC-015] Owner','sec015-owner@example.invalid','000',current_date+103,time '08:00',time '09:00',60,10,'cancelled','pay_on_site','planned',1,v_price,'mon_thu','[TEST][SEC-015] Lane','[TEST]',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_confirmed,v_owner,v_lane,'[TEST][SEC-015] Owner','sec015-owner@example.invalid','000',current_date+104,time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price,'mon_thu','[TEST][SEC-015] Lane','[TEST]',10,10,'PLN',pg_catalog.gen_random_uuid());

  perform pg_temp.record_result(1,'Message type constraint includes exactly three types',
    (select pg_catalog.regexp_replace(pg_catalog.pg_get_constraintdef(c.oid),'\s','','g')=
      'CHECK((message_type=ANY(ARRAY[''event_registration_confirmation''::text,''reservation_confirmation''::text,''reservation_cancellation''::text])))'
     from pg_catalog.pg_constraint c where c.conrelid='public.email_deliveries'::regclass and c.conname='email_deliveries_message_type_check'),
    'Constraint must be closed to the two confirmations and reservation cancellation.');

  perform pg_temp.record_result(2,'Prepare RPC signature has no overload',
    pg_catalog.to_regprocedure('public.prepare_confirmation_email(text,uuid)') is not null
    and (select count(*)=1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='prepare_confirmation_email'),
    'Exactly one expected signature must exist.');

  perform pg_temp.record_result(3,'Prepare RPC security properties unchanged',
    exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.prepare_confirmation_email(text,uuid)'::regprocedure
        and p.prosecdef and p.provolatile='v' and p.prorettype='jsonb'::regtype
        and p.proconfig=array['search_path=public, pg_temp']::text[] and r.rolname='postgres'),
    'SECURITY DEFINER, owner, volatility, return type and search_path remain unchanged.');

  perform pg_temp.record_result(4,'Prepare RPC remains authenticated-only',
    pg_catalog.has_function_privilege('authenticated','public.prepare_confirmation_email(text,uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.prepare_confirmation_email(text,uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.prepare_confirmation_email(text,uuid)','EXECUTE')
    and not exists(select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a where p.oid='public.prepare_confirmation_email(text,uuid)'::regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'),
    'No PUBLIC, anon or service-role prepare access.');

  v_result:=pg_temp.prepare_as(v_owner,'reservation_cancellation',v_owner_cancelled);
  v_claim:=(v_result->>'claim_id')::uuid;
  v_delivery_id:=(v_result->>'delivery_id')::uuid;
  perform pg_temp.record_result(5,'Owner prepares cancellation delivery',v_result@>'{"ok":true,"changed":true,"code":"ready","attempt_count":1}'::jsonb,'Owner receives one ready claim.');
  perform pg_temp.record_result(6,'Idempotency key is stable and opaque',v_result->>'idempotency_key'='confirmation/reservation_cancellation/'||v_delivery_id,'Key derives from delivery id, never PII.');
  perform pg_temp.record_result(7,'Recipient identity comes from reservation owner',(select recipient_user_id=v_owner from public.email_deliveries where id=v_delivery_id),'Delivery row stores owner id, not operator or client email.');
  perform pg_temp.record_result(8,'Parallel repeat is in progress',pg_temp.prepare_as(v_owner,'reservation_cancellation',v_owner_cancelled)@>'{"ok":false,"changed":false,"code":"in_progress"}'::jsonb,'Active lease prevents a parallel send.');
  perform pg_temp.record_result(9,'Service completion records success',pg_temp.complete_as_service(v_claim,true,'sec015-provider-id',null)@>'{"ok":true,"changed":true,"code":"sent"}'::jsonb,'Successful provider result completes the claim.');
  perform pg_temp.record_result(10,'Repeat after success is already sent',pg_temp.prepare_as(v_owner,'reservation_cancellation',v_owner_cancelled)@>'{"ok":true,"changed":false,"code":"already_sent"}'::jsonb,'Repeat cannot create a second delivery.');
  perform pg_temp.record_result(11,'Successful delivery state is singular',(select count(*)=1 and bool_and(sent_at is not null) and bool_and(provider_message_id='sec015-provider-id') from public.email_deliveries where message_type='reservation_cancellation' and record_id=v_owner_cancelled),'Exactly one sent row exists.');

  v_result:=pg_temp.prepare_as(v_employee,'reservation_cancellation',v_employee_cancelled);
  perform pg_temp.record_result(12,'Employee can prepare owner cancellation email',v_result@>'{"ok":true,"changed":true,"code":"ready"}'::jsonb,'Existing staff role remains allowed.');
  perform pg_temp.record_result(13,'Employee does not become recipient',(select recipient_user_id=v_owner from public.email_deliveries where message_type='reservation_cancellation' and record_id=v_employee_cancelled),'Recipient remains the reservation owner.');
  perform pg_temp.complete_as_service((v_result->>'claim_id')::uuid,false,null,'email_send_failed');

  v_result:=pg_temp.prepare_as(v_admin,'reservation_cancellation',v_admin_cancelled);
  perform pg_temp.record_result(14,'Admin can prepare owner cancellation email',v_result@>'{"ok":true,"changed":true,"code":"ready"}'::jsonb,'Existing admin role remains allowed.');
  perform pg_temp.complete_as_service((v_result->>'claim_id')::uuid,false,null,'email_send_failed');

  perform pg_temp.record_result(15,'Ordinary foreign user is fail-closed',pg_temp.prepare_as(v_other,'reservation_cancellation',v_employee_cancelled)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Foreign record is not disclosed.');
  perform pg_temp.record_result(16,'Instructor foreign access is fail-closed',pg_temp.prepare_as(v_instructor,'reservation_cancellation',v_employee_cancelled)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Instructor has no global cancellation email access.');
  perform pg_temp.record_result(17,'Anon cannot execute prepare',pg_temp.anon_prepare_denied(v_owner_cancelled),'ACL must reject anon before business logic.');
  perform pg_temp.record_result(18,'Non-cancelled reservation is rejected',pg_temp.prepare_as(v_owner,'reservation_cancellation',v_confirmed)@>'{"ok":false,"changed":false,"code":"invalid_status"}'::jsonb,'Email requires an already-cancelled reservation.');
  perform pg_temp.record_result(19,'Unknown message type is rejected',pg_temp.prepare_as(v_owner,'unknown',v_owner_cancelled)@>'{"ok":false,"changed":false,"code":"invalid_status"}'::jsonb,'Message-type contract is closed.');

  for v_attempt in 1..3 loop
    v_result:=pg_temp.prepare_as(v_owner,'reservation_cancellation',v_attempt_cancelled);
    if not (v_result@>pg_catalog.jsonb_build_object('ok',true,'changed',true,'code','ready','attempt_count',v_attempt)) then
      raise exception 'SEC-015 attempt fixture failed at attempt %.',v_attempt;
    end if;
    perform pg_temp.complete_as_service((v_result->>'claim_id')::uuid,false,null,'email_send_failed');
  end loop;
  perform pg_temp.record_result(20,'Three failed provider attempts are bounded',(select attempt_count=3 and sent_at is null and claim_id is null and last_error_code='email_send_failed' from public.email_deliveries where message_type='reservation_cancellation' and record_id=v_attempt_cancelled),'Failure completion clears lease without marking sent.');
  perform pg_temp.record_result(21,'Fourth attempt is denied',pg_temp.prepare_as(v_owner,'reservation_cancellation',v_attempt_cancelled)@>'{"ok":false,"changed":false,"code":"attempt_limit_reached"}'::jsonb,'24-hour attempt limit is enforced.');
  perform pg_temp.record_result(22,'No cancellation email audit is created',not exists(select 1 from public.audit_logs where action ilike '%email%' and (target_id in(v_owner_cancelled,v_employee_cancelled,v_admin_cancelled,v_attempt_cancelled) or details::text like '%[TEST][SEC-015]%')),'Delivery repeats must not duplicate the trusted cancellation business audit.');
  perform pg_temp.record_result(23,'Delivery rows contain no email content or token columns',not exists(select 1 from information_schema.columns where table_schema='public' and table_name='email_deliveries' and column_name in('email','recipient_email','html','text','body','token','jwt')),'Technical delivery state must not store message PII or secrets.');
  perform pg_temp.record_result(24,'Legacy confirmation branches remain present',pg_catalog.pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::regprocedure) like '%event_registration_confirmation%' and pg_catalog.pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::regprocedure) like '%reservation_confirmation%','Existing confirmation contracts remain supported.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order::text||' - '||test_name
  ||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order)
  into v_failures from pg_temp.test_results where passed is false;
  if v_failures is not null then
    raise exception 'SEC-015 tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
