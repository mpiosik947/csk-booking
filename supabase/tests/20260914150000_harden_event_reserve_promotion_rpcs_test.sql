\set ON_ERROR_STOP on
\pset format unaligned

select '1..36';

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

create function pg_temp.as_prepare(p_event uuid)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  set local role service_role;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(candidate)),'[]'::jsonb)
  into v_result from public.prepare_event_reserve_promotions(p_event) candidate;
  reset role;
  return v_result;
exception when others then reset role; raise;
end;
$function$;

create function pg_temp.as_complete(p_registration uuid,p_claim uuid,p_success boolean,p_error text default null)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  set local role service_role;
  select public.complete_event_reserve_promotion(p_registration,p_claim,p_success,p_error) into v_result;
  reset role;
  return v_result;
exception when others then reset role; raise;
end;
$function$;

create function pg_temp.as_confirm(p_user uuid,p_token text)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated;
  select public.confirm_event_reserve_promotion(p_token) into v_result;
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

create function pg_temp.raises(p_sql text,p_state text)
returns boolean language plpgsql as $function$
begin
  execute p_sql;
  return false;
exception when others then return sqlstate=p_state;
end;
$function$;

do $tests$
declare
  csk constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid:=pg_catalog.gen_random_uuid();
  user_occupied uuid:=pg_catalog.gen_random_uuid();
  user_first uuid:=pg_catalog.gen_random_uuid();
  user_second uuid:=pg_catalog.gen_random_uuid();
  user_b uuid:=pg_catalog.gen_random_uuid();
  event_a uuid:=pg_catalog.gen_random_uuid();
  event_b uuid:=pg_catalog.gen_random_uuid();
  reg_occupied uuid:=pg_catalog.gen_random_uuid();
  reg_first uuid:=pg_catalog.gen_random_uuid();
  reg_second uuid:=pg_catalog.gen_random_uuid();
  reg_b uuid:=pg_catalog.gen_random_uuid();
  run_id text:=pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  marker text;
  prepared jsonb;
  first_claim uuid;
  second_claim uuid;
  first_token text;
  second_token text;
  result jsonb;
begin
  marker:='[TEST][SAAS-9D-2C-2]['||run_id||']';

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||run_id||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()
  from (values(user_occupied,'occupied'),(user_first,'first'),(user_second,'second'),(user_b,'tenant-b')) fixture(id,label);
  insert into public.profiles(id,user_id,email,phone,first_name,last_name,full_name,role,verification_status)
  select auth_user.id,auth_user.id,auth_user.email,'000','Test','2C2',marker,'user','verified'
  from auth.users auth_user left join public.profiles profile on profile.user_id=auth_user.id
  where auth_user.id in(user_occupied,user_first,user_second,user_b) and profile.user_id is null;
  update public.profiles set phone='000',first_name='Test',last_name='2C2',full_name=marker,verification_status='verified'
  where user_id in(user_occupied,user_first,user_second,user_b);

  insert into public.tenants(id,name,slug,status)
  values(tenant_b,marker||' Tenant B','saas9d2c2-'||pg_catalog.left(run_id,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(tenant_b,user_b,'user','active');

  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(event_a,csk,marker||' Event A','A',date '2099-12-10',time '10:00',time '11:00','A',0,2,true),
        (event_b,tenant_b,marker||' Event B','B',date '2099-12-11',time '10:00',time '11:00','B',0,5,true);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,created_at)
  values(reg_occupied,csk,event_a,user_occupied,marker,'occupied@example.invalid','000','registered','pay_on_site',pg_catalog.now()-interval '3 hours'),
        (reg_first,csk,event_a,user_first,marker,'first@example.invalid','000','reserve','pay_on_site',pg_catalog.now()-interval '2 hours'),
        (reg_second,csk,event_a,user_second,marker,'second@example.invalid','000','reserve','pay_on_site',pg_catalog.now()-interval '1 hour'),
        (reg_b,tenant_b,event_b,user_b,marker,'b@example.invalid','000','reserve','pay_on_site',pg_catalog.now()-interval '4 hours');

  perform pg_temp.ok(1,'exact promotion signatures remain',(select pg_catalog.count(*)=2 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('prepare_event_reserve_promotions','complete_event_reserve_promotion')),'Target signature inventory differs.');
  perform pg_temp.ok(2,'prepare is postgres-owned volatile SP1 invoker',exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner where p.oid='public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure and not p.prosecdef and p.provolatile='v' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]),'Prepare metadata differs.');
  perform pg_temp.ok(3,'complete is postgres-owned volatile SP1 invoker',exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner where p.oid='public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure and not p.prosecdef and p.provolatile='v' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]),'Complete metadata differs.');
  perform pg_temp.ok(4,'both ACLs are service-only',pg_catalog.has_function_privilege('service_role','public.prepare_event_reserve_promotions(uuid)','EXECUTE') and pg_catalog.has_function_privilege('service_role','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE') and not pg_catalog.has_function_privilege('public','public.prepare_event_reserve_promotions(uuid)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.prepare_event_reserve_promotions(uuid)','EXECUTE') and not pg_catalog.has_function_privilege('authenticated','public.prepare_event_reserve_promotions(uuid)','EXECUTE') and not pg_catalog.has_function_privilege('public','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE') and not pg_catalog.has_function_privilege('authenticated','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE'),'Target ACL differs.');
  perform pg_temp.ok(5,'service invoker table rights are sufficient',pg_catalog.has_table_privilege('service_role','public.events','SELECT') and pg_catalog.has_table_privilege('service_role','public.event_registrations','SELECT,UPDATE'),'Service table ACL differs.');
  perform pg_temp.ok(6,'target normalized fingerprints are exact',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='cdc7abeb7f8ced41cde0f5524a8953ef' and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='2c78ac26c5c55df3aac54360b610d39b','Target body differs.');
  perform pg_temp.ok(7,'SECURITY DEFINER count is 70',(select pg_catalog.count(*)=70 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'Definer count differs.');
  perform pg_temp.ok(8,'all seven compatibility defaults remain',(select pg_catalog.count(*)=7 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'Compatibility defaults changed.');
  perform pg_temp.ok(9,'anon and authenticated cannot invoke prepare',pg_temp.denied('anon',pg_catalog.format('select * from public.prepare_event_reserve_promotions(%L)',event_a)) and pg_temp.denied('authenticated',pg_catalog.format('select * from public.prepare_event_reserve_promotions(%L)',event_a)),'Client invoked prepare.');
  perform pg_temp.ok(10,'anon and authenticated cannot invoke completion',pg_temp.denied('anon',pg_catalog.format('select public.complete_event_reserve_promotion(%L,%L,true,null)',reg_first,pg_catalog.gen_random_uuid())) and pg_temp.denied('authenticated',pg_catalog.format('select public.complete_event_reserve_promotion(%L,%L,true,null)',reg_first,pg_catalog.gen_random_uuid())),'Client invoked completion.');

  prepared:=pg_temp.as_prepare(event_a);
  first_claim:=(prepared->0->>'claim_id')::uuid;
  second_claim:=(prepared->1->>'claim_id')::uuid;
  first_token:=prepared->0->>'promotion_token';
  second_token:=prepared->1->>'promotion_token';
  perform pg_temp.ok(11,'prepare returns both eligible notifications',pg_catalog.jsonb_array_length(prepared)=2,'Multiple-notification count changed.');
  perform pg_temp.ok(12,'FIFO order is unchanged',(prepared->0->>'registration_id')::uuid=reg_first and (prepared->1->>'registration_id')::uuid=reg_second,'FIFO ordering changed.');
  perform pg_temp.ok(13,'Tenant B registration never enters Event A candidate set',not exists(select 1 from pg_catalog.jsonb_array_elements(prepared) candidate where candidate->>'registration_id'=reg_b::text),'Cross-tenant candidate leaked.');
  perform pg_temp.ok(14,'claims and tokens are unique',first_claim<>second_claim and first_token<>second_token,'Claims or tokens collided.');
  perform pg_temp.ok(15,'token and claim TTLs remain bounded',(select pg_catalog.bool_and(promotion_token_expires_at between pg_catalog.now()+interval '23 hours 59 minutes' and pg_catalog.now()+interval '24 hours 1 minute') and pg_catalog.bool_and(promotion_claim_expires_at between pg_catalog.now()+interval '9 minutes' and pg_catalog.now()+interval '11 minutes') from public.event_registrations where id in(reg_first,reg_second)),'TTL contract changed.');
  perform pg_temp.ok(16,'duplicate prepare creates no second claim',pg_catalog.jsonb_array_length(pg_temp.as_prepare(event_a))=0 and (select pg_catalog.count(distinct promotion_claim_id)=2 from public.event_registrations where id in(reg_first,reg_second)),'Duplicate prepare changed claims.');
  perform pg_temp.ok(17,'prepare response contains no participant PII',not exists(select 1 from pg_catalog.jsonb_array_elements(prepared) candidate cross join lateral pg_catalog.jsonb_object_keys(candidate) key where key not in('registration_id','claim_id','promotion_token','promotion_token_expires_at','token_reused')),'Prepare DTO expanded.');
  perform pg_temp.ok(18,'promotion flow creates no email_deliveries',(select pg_catalog.count(*)=0 from public.email_deliveries where record_id in(reg_first,reg_second,reg_b)),'Unexpected delivery row created.');

  perform pg_temp.ok(19,'wrong active claim fails closed',pg_temp.raises(pg_catalog.format('select public.complete_event_reserve_promotion(%L,%L,true,null)',reg_first,second_claim),'55000'),'Wrong claim completed.');
  result:=pg_temp.as_complete(reg_first,first_claim,true,null);
  perform pg_temp.ok(20,'valid success completes exact claim once',result@>pg_catalog.jsonb_build_object('registration_id',reg_first,'changed',true,'success',true,'claim_cleared',true,'email_sent_recorded',true) and (select promotion_email_sent_at is not null and promotion_claim_id is null from public.event_registrations where id=reg_first),'Success completion differs.');
  perform pg_temp.ok(21,'success replay has no duplicate effect',pg_temp.as_complete(reg_first,first_claim,true,null)@>'{"changed":false,"success":true,"claim_cleared":true,"email_sent_recorded":true}'::jsonb,'Success replay changed state.');
  result:=pg_temp.as_complete(reg_second,second_claim,false,'email_provider_error');
  perform pg_temp.ok(22,'valid failure clears exact claim and stores bounded code',result@>pg_catalog.jsonb_build_object('registration_id',reg_second,'changed',true,'success',false,'claim_cleared',true) and (select promotion_claim_id is null and promotion_last_error_code='email_provider_error' from public.event_registrations where id=reg_second),'Failure completion differs.');
  perform pg_temp.ok(23,'failure replay is idempotent',pg_temp.as_complete(reg_second,second_claim,false,'email_provider_error')@>'{"changed":false,"success":false,"claim_cleared":true}'::jsonb,'Failure replay changed state.');

  update public.event_registrations
  set promotion_claim_id=pg_catalog.gen_random_uuid(),
      promotion_last_attempt_at=pg_catalog.now()-interval '2 minutes',
      promotion_claim_expires_at=pg_catalog.now()-interval '1 minute'
  where id=reg_second;
  select promotion_claim_id into second_claim from public.event_registrations where id=reg_second;
  perform pg_temp.ok(24,'expired claim fails closed',pg_temp.raises(pg_catalog.format('select public.complete_event_reserve_promotion(%L,%L,true,null)',reg_second,second_claim),'55000'),'Expired claim completed.');
  update public.event_registrations set promotion_claim_id=null,promotion_claim_expires_at=null,promotion_last_error_code=null where id=reg_second;

  prepared:=pg_temp.as_prepare(event_a); second_claim:=(prepared->0->>'claim_id')::uuid; second_token:=prepared->0->>'promotion_token';
  update public.event_registrations set registration_status='cancelled' where id=reg_second;
  result:=pg_temp.as_complete(reg_second,second_claim,true,null);
  perform pg_temp.ok(25,'completion after cancellation records delivery but never restores status',result->>'success'='true' and (select registration_status='cancelled' and promotion_email_sent_at is not null from public.event_registrations where id=reg_second),'Cancellation race changed status or lost delivery outcome.');

  update public.event_registrations set registration_status='reserve',promotion_email_sent_at=null,promotion_token=null,promotion_token_expires_at=null where id=reg_second;
  prepared:=pg_temp.as_prepare(event_a); second_claim:=(prepared->0->>'claim_id')::uuid;
  update public.events set is_active=false where id=event_a;
  result:=pg_temp.as_complete(reg_second,second_claim,true,null);
  perform pg_temp.ok(26,'completion after event deactivation cannot mutate event or registration status',result->>'success'='true' and (select registration_status='reserve' from public.event_registrations where id=reg_second) and not (select is_active from public.events where id=event_a),'Event-state race changed business state.');
  update public.events set is_active=true where id=event_a;

  update public.event_registrations set registration_status='reserve',promotion_email_sent_at=case id when reg_first then pg_catalog.now() else null end,promotion_claim_id=null,promotion_claim_expires_at=null where id in(reg_first,reg_second);
  perform pg_temp.ok(27,'tenant/event relationship is explicit in both bodies',pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure),'registration.tenant_id=v_event.tenant_id')>0 and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure),'event_record.tenant_id=v_tenant_id')>0,'Tenant binding is absent.');
  perform pg_temp.ok(28,'completion response exposes no email user or tenant PII',not (result ?| array['email','recipient','recipient_email','user_id','tenant_id','customer_name','phone']),'Completion exposed PII.');
  perform pg_temp.ok(29,'Event B remains unchanged',(select registration_status='reserve' and promotion_claim_id is null and promotion_email_sent_at is null from public.event_registrations where id=reg_b),'Tenant B was changed.');

  update public.event_registrations set promotion_email_sent_at=null,promotion_token=case id when reg_first then first_token else second_token end,promotion_token_expires_at=pg_catalog.now()+interval '1 hour',promotion_claim_id=null,promotion_claim_expires_at=null where id in(reg_first,reg_second);
  result:=pg_temp.as_confirm(user_first,first_token);
  perform pg_temp.ok(30,'first confirmed reserve candidate wins',result->>'code'='confirmed' and (select registration_status='registered' from public.event_registrations where id=reg_first),'First confirmation failed.');
  result:=pg_temp.as_confirm(user_second,second_token);
  perform pg_temp.ok(31,'second confirmation cannot exceed capacity',result->>'code'='full' and (select registration_status='reserve' from public.event_registrations where id=reg_second),'Capacity was exceeded.');
  perform pg_temp.ok(32,'capacity invariant remains exact',(select pg_catalog.count(*)=2 from public.event_registrations where event_id=event_a and tenant_id=csk and registration_status in('registered','approved')),'Final capacity differs.');
  perform pg_temp.ok(33,'registration/event tenant integrity remains global',not exists(select 1 from public.event_registrations registration left join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where event_record.id is null),'Tenant relationship broke.');
  perform pg_temp.ok(34,'2C-1 fingerprints remain unchanged',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='17d8b973c9e3df0839f692fd8d9efbde' and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='c8450fe37a991fda41e8a30ce66732b3','2C-1 drifted.');
  perform pg_temp.ok(35,'public confirmation remains authenticated-only',pg_catalog.has_function_privilege('authenticated','public.confirm_event_reserve_promotion(text)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.confirm_event_reserve_promotion(text)','EXECUTE'),'Public confirmation ACL changed.');
  perform pg_temp.ok(36,'fixture is transaction-scoped',(select pg_catalog.strpos(title,marker)=1 from public.events where id=event_a),'Fixture marker differs.');
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
  if v_failures is not null then raise exception 'SAAS-9D-2C-2 tests failed: %',v_failures; end if;
end;
$assertions$;

rollback;
