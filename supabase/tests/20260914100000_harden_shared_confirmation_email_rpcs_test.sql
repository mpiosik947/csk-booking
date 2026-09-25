\set ON_ERROR_STOP on
\pset format unaligned

select '1..44';

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

create function pg_temp.as_prepare(p_user uuid,p_type text,p_record uuid)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated;
  select public.prepare_confirmation_email(p_type,p_record) into v_result;
  reset role;
  return v_result;
exception when others then reset role; raise;
end;
$function$;

create function pg_temp.as_complete(p_claim uuid,p_success boolean,p_provider text default null,p_error text default null)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims','{"role":"service_role"}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  set local role service_role;
  select public.complete_confirmation_email(p_claim,p_success,p_provider,p_error) into v_result;
  reset role;
  return v_result;
exception when others then reset role; raise;
end;
$function$;

create function pg_temp.as_rate(p_user uuid,p_hash text)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  set local role service_role;
  select public.check_confirmation_email_rate_limit(p_user,p_hash) into v_result;
  reset role;
  return v_result;
exception when others then reset role; raise;
end;
$function$;

create function pg_temp.denied(p_role text,p_sql text)
returns boolean language plpgsql as $function$
begin
  execute pg_catalog.format('set local role %I',p_role);
  execute p_sql;
  reset role;
  return false;
exception when insufficient_privilege then reset role; return true;
end;
$function$;

create function pg_temp.rejected(p_sql text)
returns boolean language plpgsql as $function$
begin
  execute p_sql;
  return false;
exception when others then return true;
end;
$function$;

do $tests$
declare
  csk constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid:=pg_catalog.gen_random_uuid();
  owner_a uuid:=pg_catalog.gen_random_uuid();
  owner_b uuid:=pg_catalog.gen_random_uuid();
  staff_a uuid:=pg_catalog.gen_random_uuid();
  admin_b uuid:=pg_catalog.gen_random_uuid();
  global_admin uuid:=pg_catalog.gen_random_uuid();
  instructor_a uuid:=pg_catalog.gen_random_uuid();
  pending_b uuid:=pg_catalog.gen_random_uuid();
  suspended_b uuid:=pg_catalog.gen_random_uuid();
  lane_a uuid:=pg_catalog.gen_random_uuid();
  lane_b uuid:=pg_catalog.gen_random_uuid();
  price_a uuid:=pg_catalog.gen_random_uuid();
  price_b uuid:=pg_catalog.gen_random_uuid();
  res_a_confirm uuid:=pg_catalog.gen_random_uuid();
  res_a_cancel uuid:=pg_catalog.gen_random_uuid();
  res_a_retry uuid:=pg_catalog.gen_random_uuid();
  res_a_bad_tenant uuid:=pg_catalog.gen_random_uuid();
  res_a_bad_recipient uuid:=pg_catalog.gen_random_uuid();
  res_b_owner uuid:=pg_catalog.gen_random_uuid();
  res_b_admin uuid:=pg_catalog.gen_random_uuid();
  res_b_denied uuid:=pg_catalog.gen_random_uuid();
  event_a uuid:=pg_catalog.gen_random_uuid();
  event_b uuid:=pg_catalog.gen_random_uuid();
  reg_a uuid:=pg_catalog.gen_random_uuid();
  reg_b uuid:=pg_catalog.gen_random_uuid();
  run_id text:=pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  marker text;
  result jsonb;
  claim uuid;
  first_claim uuid;
  delivery uuid;
begin
  marker:='[TEST][SAAS-9D-2C-1]['||run_id||']';

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',email,'',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()
  from (values
    (owner_a,'2c1-owner-a-'||run_id||'@example.invalid'),(owner_b,'2c1-owner-b-'||run_id||'@example.invalid'),
    (staff_a,'2c1-staff-a-'||run_id||'@example.invalid'),(admin_b,'2c1-admin-b-'||run_id||'@example.invalid'),
    (global_admin,'2c1-global-'||run_id||'@example.invalid'),(instructor_a,'2c1-instructor-'||run_id||'@example.invalid'),
    (pending_b,'2c1-pending-'||run_id||'@example.invalid'),(suspended_b,'2c1-suspended-'||run_id||'@example.invalid')
  ) fixture(id,email);

  insert into public.profiles(id,user_id,email,phone,first_name,last_name,full_name,role,verification_status)
  select auth_user.id,auth_user.id,auth_user.email,'000','Test','2C1',marker,'user','verified'
  from auth.users auth_user left join public.profiles profile on profile.user_id=auth_user.id
  where auth_user.id in(owner_a,owner_b,staff_a,admin_b,global_admin,instructor_a,pending_b,suspended_b)
    and profile.user_id is null;
  update public.profiles set phone='000',first_name='Test',last_name='2C1',full_name=marker,verification_status='verified',
    role=case when user_id=staff_a then 'pracownik' when user_id=global_admin then 'admin'
              when user_id=instructor_a then 'instruktor' else 'user' end
  where user_id in(owner_a,owner_b,staff_a,admin_b,global_admin,instructor_a,pending_b,suspended_b);
  if (select pg_catalog.count(*) from public.profiles where user_id in(owner_a,owner_b,staff_a,admin_b,global_admin,instructor_a,pending_b,suspended_b))<>8 then
    raise exception 'SAAS-9D-2C-1 fixture profile count differs.';
  end if;
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  select csk,fixture.user_id,fixture.role,'active'
  from (values(owner_a,'user'),(staff_a,'employee'),(global_admin,'admin'),(instructor_a,'instructor')) fixture(user_id,role)
  on conflict (tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;

  insert into public.tenants(id,name,slug,status)
  values(tenant_b,marker||' Tenant B','saas9d2c1-'||pg_catalog.left(run_id,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_b,owner_b,'user','active'),(tenant_b,admin_b,'admin','active'),
    (tenant_b,pending_b,'admin','pending'),(tenant_b,suspended_b,'employee','suspended');

  insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(lane_a,csk,marker||' Lane A','test',10,true,1,60,9980,'PLN','lane',null,true,false),
        (lane_b,tenant_b,marker||' Lane B','test',20,true,1,60,9981,'PLN','lane',null,true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
  values(price_a,lane_a,'mon_thu',1,1,marker,10),(price_b,lane_b,'mon_thu',1,1,marker,20);

  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values
    (res_a_confirm,owner_a,csk,lane_a,marker,'a@example.invalid','000',date '2099-12-01',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (res_a_cancel,owner_a,csk,lane_a,marker,'a@example.invalid','000',date '2099-12-02',time '08:00',time '09:00',60,10,'cancelled_by_admin','pay_on_site','planned',1,price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (res_a_retry,owner_a,csk,lane_a,marker,'a@example.invalid','000',date '2099-12-03',time '08:00',time '09:00',60,10,'cancelled','pay_on_site','planned',1,price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (res_a_bad_tenant,owner_a,csk,lane_a,marker,'a@example.invalid','000',date '2099-12-04',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (res_a_bad_recipient,owner_a,csk,lane_a,marker,'a@example.invalid','000',date '2099-12-05',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (res_b_owner,owner_b,tenant_b,lane_b,marker,'b@example.invalid','000',date '2099-12-06',time '08:00',time '09:00',60,20,'confirmed','pay_on_site','planned',1,price_b,'mon_thu','B','B',20,20,'PLN',pg_catalog.gen_random_uuid()),
    (res_b_admin,owner_b,tenant_b,lane_b,marker,'b@example.invalid','000',date '2099-12-07',time '08:00',time '09:00',60,20,'cancelled_by_admin','pay_on_site','planned',1,price_b,'mon_thu','B','B',20,20,'PLN',pg_catalog.gen_random_uuid()),
    (res_b_denied,owner_b,tenant_b,lane_b,marker,'b@example.invalid','000',date '2099-12-08',time '08:00',time '09:00',60,20,'cancelled','pay_on_site','planned',1,price_b,'mon_thu','B','B',20,20,'PLN',pg_catalog.gen_random_uuid());

  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(event_a,csk,marker||' Event A','A',date '2099-12-10',time '10:00',time '11:00','A',0,10,true),
        (event_b,tenant_b,marker||' Event B','B',date '2099-12-11',time '10:00',time '11:00','B',0,10,true);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values(reg_a,csk,event_a,owner_a,marker,'a@example.invalid','000','registered','pay_on_site'),
        (reg_b,tenant_b,event_b,owner_b,marker,'b@example.invalid','000','reserve','pay_on_site');

  perform pg_temp.ok(1,'exact shared signatures remain',(select pg_catalog.count(*)=3 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('prepare_confirmation_email','complete_confirmation_email','check_confirmation_email_rate_limit')),'Shared signature inventory differs.');
  perform pg_temp.ok(2,'prepare is postgres-owned volatile SP1 definer',exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner where p.oid='public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure and p.prosecdef and p.provolatile='v' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]),'Prepare metadata differs.');
  perform pg_temp.ok(3,'complete is postgres-owned volatile SP1 invoker',exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner where p.oid='public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure and not p.prosecdef and p.provolatile='v' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]),'Complete metadata differs.');
  perform pg_temp.ok(4,'ACL is authenticated prepare and service-only complete/rate',pg_catalog.has_function_privilege('authenticated','public.prepare_confirmation_email(text,uuid)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public.prepare_confirmation_email(text,uuid)','EXECUTE') and pg_catalog.has_function_privilege('service_role','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE') and not pg_catalog.has_function_privilege('authenticated','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE') and pg_catalog.has_function_privilege('service_role','public.check_confirmation_email_rate_limit(uuid,text)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.check_confirmation_email_rate_limit(uuid,text)','EXECUTE') and not pg_catalog.has_function_privilege('public','public.check_confirmation_email_rate_limit(uuid,text)','EXECUTE'),'Shared ACL differs.');
  perform pg_temp.ok(5,'rate-limit normalized fingerprint is frozen',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.check_confirmation_email_rate_limit(uuid,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='e693411c3fc7f24510313e60a1d8e2a5','Rate-limit body changed.');
  perform pg_temp.ok(6,'target normalized fingerprints and authorization body are exact',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='17d8b973c9e3df0839f692fd8d9efbde' and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='c8450fe37a991fda41e8a30ce66732b3' and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure),'insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id)')>0 and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure),'profile.role')=0,'Target fingerprint, tenant binding or global-role removal differs.');
  perform pg_temp.ok(7,'SECURITY DEFINER inventory includes PRODUCT-10B public readers',(select pg_catalog.count(*)=  100 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'Definer inventory differs.');
  perform pg_temp.ok(8,'all seven compatibility defaults remain',(select pg_catalog.count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'A compatibility default changed.');

  result:=pg_temp.as_prepare(owner_a,'reservation_confirmation',res_a_confirm); claim:=(result->>'claim_id')::uuid; delivery:=(result->>'delivery_id')::uuid;
  perform pg_temp.ok(9,'Tenant A owner prepares own reservation confirmation',result@>'{"ok":true,"changed":true,"code":"ready","attempt_count":1}'::jsonb,'Owner prepare failed.');
  perform pg_temp.ok(10,'reservation delivery is explicitly tenant and recipient bound',(select tenant_id=csk and recipient_user_id=owner_a from public.email_deliveries where id=delivery),'Reservation delivery binding differs.');
  result:=pg_temp.as_prepare(owner_a,'event_registration_confirmation',reg_a);
  perform pg_temp.ok(11,'Tenant A owner prepares own event registration confirmation',result@>'{"ok":true,"changed":true,"code":"ready"}'::jsonb,'Event confirmation prepare failed.');
  perform pg_temp.ok(12,'event delivery follows registration and event tenant',(select tenant_id=csk and recipient_user_id=owner_a from public.email_deliveries where id=(result->>'delivery_id')::uuid),'Event delivery binding differs.');
  perform pg_temp.ok(13,'duplicate prepare is serialized as in progress',pg_temp.as_prepare(owner_a,'reservation_confirmation',res_a_confirm)@>'{"ok":false,"changed":false,"code":"in_progress"}'::jsonb,'Duplicate prepare leased twice.');
  perform pg_temp.ok(14,'service completes a bound claim once',pg_temp.as_complete(claim,true,'provider-2c1',null)@>'{"ok":true,"changed":true,"code":"sent"}'::jsonb,'Completion failed.');
  perform pg_temp.ok(15,'repeat prepare after success is already sent',pg_temp.as_prepare(owner_a,'reservation_confirmation',res_a_confirm)@>'{"ok":true,"changed":false,"code":"already_sent"}'::jsonb,'Sent delivery was leased again.');
  perform pg_temp.ok(16,'foreign user receives fail-closed not found',pg_temp.as_prepare(global_admin,'reservation_confirmation',res_a_confirm)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Foreign owner was disclosed.');

  update public.tenant_memberships set status='pending' where tenant_id=csk and user_id=owner_a;
  perform pg_temp.ok(17,'pending owner membership is denied',pg_temp.as_prepare(owner_a,'event_registration_confirmation',reg_a)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Pending owner was allowed.');
  update public.tenant_memberships set status='suspended' where tenant_id=csk and user_id=owner_a;
  perform pg_temp.ok(18,'suspended owner membership is denied',pg_temp.as_prepare(owner_a,'event_registration_confirmation',reg_a)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Suspended owner was allowed.');
  update public.tenant_memberships set status='active' where tenant_id=csk and user_id=owner_a;

  result:=pg_temp.as_prepare(staff_a,'reservation_cancellation',res_a_cancel);
  perform pg_temp.ok(19,'same-tenant employee prepares cancellation',result@>'{"ok":true,"changed":true,"code":"ready"}'::jsonb,'Employee cancellation prepare failed.');
  perform pg_temp.ok(20,'staff never becomes delivery recipient',(select recipient_user_id=owner_a and tenant_id=csk from public.email_deliveries where id=(result->>'delivery_id')::uuid),'Staff replaced recipient.');
  perform pg_temp.ok(21,'instructor is denied staff cancellation',pg_temp.as_prepare(instructor_a,'reservation_cancellation',res_a_cancel)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Instructor was allowed.');
  perform pg_temp.ok(22,'same-tenant admin remains authorized without replacing recipient',pg_temp.as_prepare(global_admin,'reservation_cancellation',res_a_cancel)@>'{"ok":false,"changed":false,"code":"in_progress"}'::jsonb,'CSK admin compatibility changed unexpectedly.');
  perform pg_temp.ok(23,'non-cancelled record rejects cancellation message',pg_temp.as_prepare(owner_a,'reservation_cancellation',res_a_confirm)@>'{"ok":false,"changed":false,"code":"invalid_status"}'::jsonb,'Invalid status was allowed.');
  perform pg_temp.ok(24,'unknown message type is rejected',pg_temp.as_prepare(owner_a,'unknown',res_a_confirm)@>'{"ok":false,"changed":false,"code":"invalid_status"}'::jsonb,'Unknown type was allowed.');

  perform pg_temp.ok(25,'schema trigger rejects delivery tenant differing from resource',pg_temp.rejected(pg_catalog.format('insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,claim_id,claim_expires_at) values(%L,%L,%L,%L,%L,pg_catalog.now()+interval ''5 minutes'')',tenant_b,'reservation_confirmation',res_a_bad_tenant,owner_a,pg_catalog.gen_random_uuid())),'Cross-tenant delivery was accepted.');
  perform pg_temp.ok(26,'complete independently revalidates typed target tenant and recipient',pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure),'v_delivery.tenant_id is distinct from v_source_tenant_id')>0 and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure),'v_delivery.recipient_user_id is distinct from v_source_user_id')>0,'Completion consistency checks are absent.');
  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,claim_id,claim_expires_at)
  values(csk,'reservation_confirmation',res_a_bad_recipient,owner_b,pg_catalog.gen_random_uuid(),pg_catalog.now()+interval '5 minutes');
  select claim_id into claim from public.email_deliveries where record_id=res_a_bad_recipient;
  perform pg_temp.ok(27,'completion rejects delivery recipient differing from resource owner',pg_temp.as_complete(claim,true,'bad',null)@>'{"ok":false,"changed":false,"code":"claim_not_found"}'::jsonb,'Wrong-recipient delivery completed.');
  delete from public.email_deliveries where record_id=res_a_bad_recipient;

  result:=pg_temp.as_prepare(owner_a,'reservation_cancellation',res_a_retry); first_claim:=(result->>'claim_id')::uuid;
  perform pg_temp.ok(28,'failed completion releases exact claim',pg_temp.as_complete(first_claim,false,null,'Provider ERROR with PII@example.invalid')@>'{"ok":true,"changed":true,"code":"failed"}'::jsonb,'Failure completion failed.');
  perform pg_temp.ok(29,'stored failure code is bounded and sanitized',(select claim_id is null and last_error_code='provider_error_with_pii_example.invalid' and pg_catalog.length(last_error_code)<=128 from public.email_deliveries where record_id=res_a_retry),'Failure code is unsafe.');
  result:=pg_temp.as_prepare(owner_a,'reservation_cancellation',res_a_retry); claim:=(result->>'claim_id')::uuid;
  perform pg_temp.ok(30,'retry gets one new claim',result@>'{"ok":true,"changed":true,"code":"ready","attempt_count":2}'::jsonb and claim<>first_claim,'Retry claim contract differs.');
  result:=pg_temp.as_complete(claim,true,'provider-final',null);
  perform pg_temp.ok(31,'success after retry creates one final effect',result@>'{"ok":true,"changed":true,"code":"sent"}'::jsonb and (select sent_at is not null and provider_message_id='provider-final' and claim_id is null from public.email_deliveries where record_id=res_a_retry),'Retry success failed.');
  perform pg_temp.ok(32,'complete twice cannot mutate final state',pg_temp.as_complete(claim,true,'provider-second',null)@>'{"ok":false,"changed":false,"code":"claim_not_found"}'::jsonb and (select provider_message_id='provider-final' from public.email_deliveries where record_id=res_a_retry),'Repeat completion mutated state.');
  perform pg_temp.ok(33,'prepare responses contain no recipient or tenant PII',not (result ?| array['email','recipient_email','recipient_user_id','tenant_id','customer_name','phone','profile']),'Prepare response exposed internal identity.');
  perform pg_temp.ok(34,'delivery table stores no message body or recipient address columns',not exists(select 1 from information_schema.columns where table_schema='public' and table_name='email_deliveries' and column_name in('email','recipient_email','html','text','body','token','jwt')),'Delivery schema exposes PII/content.');
  perform pg_temp.ok(35,'rate-limit invalid input fails closed',pg_temp.as_rate(owner_a,'not-a-hash')@>'{"ok":false,"allowed":false,"code":"invalid_input"}'::jsonb,'Invalid HMAC hash was accepted.');
  perform pg_temp.ok(36,'rate-limit service path remains atomic and allowed',pg_temp.as_rate(owner_a,pg_catalog.repeat('a',64))@>'{"ok":true,"allowed":true,"code":"allowed"}'::jsonb,'Service rate limit path failed.');
  perform pg_temp.ok(37,'service cannot invoke authenticated prepare',pg_temp.denied('service_role',pg_catalog.format('select public.prepare_confirmation_email(%L,%L)','reservation_confirmation',res_a_confirm)),'Service bypassed prepare authorization.');
  perform pg_temp.ok(38,'authenticated cannot invoke service completion',pg_temp.denied('authenticated',pg_catalog.format('select public.complete_confirmation_email(%L,true,null,null)',pg_catalog.gen_random_uuid())),'Authenticated invoked completion.');

  update public.tenants set status='dormant' where id=csk;
  update public.tenants set status='active' where id=tenant_b;
  result:=pg_temp.as_prepare(owner_b,'reservation_confirmation',res_b_owner);
  perform pg_temp.ok(39,'active Tenant B owner can prepare own delivery',result@>'{"ok":true,"changed":true,"code":"ready"}'::jsonb and (select tenant_id=tenant_b from public.email_deliveries where id=(result->>'delivery_id')::uuid),'Tenant B owner flow failed.');
  perform pg_temp.ok(40,'Tenant A caller cannot prepare Tenant B resource',pg_temp.as_prepare(owner_a,'reservation_confirmation',res_b_owner)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Cross-tenant owner was allowed.');
  result:=pg_temp.as_prepare(admin_b,'reservation_cancellation',res_b_admin);
  perform pg_temp.ok(41,'active Tenant B admin can prepare same-tenant cancellation',result@>'{"ok":true,"changed":true,"code":"ready"}'::jsonb,'Tenant B admin was denied.');
  perform pg_temp.ok(42,'global legacy admin without Tenant B membership is denied',pg_temp.as_prepare(global_admin,'reservation_cancellation',res_b_denied)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Global role bypass remains.');
  perform pg_temp.ok(43,'pending and suspended Tenant B staff are denied',pg_temp.as_prepare(pending_b,'reservation_cancellation',res_b_denied)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb and pg_temp.as_prepare(suspended_b,'reservation_cancellation',res_b_denied)@>'{"ok":false,"changed":false,"code":"not_found"}'::jsonb,'Inactive membership was allowed.');
  update public.tenants set status='dormant' where id=tenant_b;
  update public.tenants set status='active' where id=csk;

  perform pg_temp.ok(44,'typed-resource tenant integrity and cleanup scope are intact',not exists(select 1 from public.email_deliveries delivery left join public.reservations reservation on delivery.message_type in('reservation_confirmation','reservation_cancellation') and reservation.id=delivery.record_id left join public.event_registrations registration on delivery.message_type='event_registration_confirmation' and registration.id=delivery.record_id where (delivery.message_type in('reservation_confirmation','reservation_cancellation') and (reservation.id is null or delivery.tenant_id<>reservation.tenant_id or delivery.recipient_user_id<>reservation.user_id)) or (delivery.message_type='event_registration_confirmation' and (registration.id is null or delivery.tenant_id<>registration.tenant_id or delivery.recipient_user_id<>registration.user_id))),'A mismatched delivery remains.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order::text||' - '||test_name
  ||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order)
  into v_failures from pg_temp.test_results where not passed;
  if v_failures is not null then raise exception 'SAAS-9D-2C-1 tests failed: %',v_failures; end if;
end;
$assertions$;

rollback;
