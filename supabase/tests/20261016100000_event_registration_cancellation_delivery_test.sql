\set ON_ERROR_STOP on
begin;
create temp table c2_results(label text) on commit drop;
create function pg_temp.check_c2(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into c2_results values(label); end;$$;
create function pg_temp.invoke_c2(actor uuid,dbrole text,statement text) returns jsonb language plpgsql as $$
declare result jsonb; begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',dbrole)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 execute format('set local role %I',dbrole); execute statement into result;
 reset role; return jsonb_build_object('state','00000','value',result);
exception when others then reset role; return jsonb_build_object('state',sqlstate,'diagnostic',sqlerrm); end;$$;
create function pg_temp.reject_c2() returns trigger language plpgsql as $$begin
 if new.message_type='event_registration_cancellation' then raise exception 'synthetic insert failure'; end if; return new; end;$$;

-- Separate owner fixture preserves ownership while the original actor changes role/status.
create function pg_temp.pam_keeper(t uuid) returns void language plpgsql as $keeper$
declare u uuid:=md5(t::text||':pam1b-test-keeper')::uuid;
begin
 insert into auth.users(id,email,email_confirmed_at) values(u,u||'@example.invalid',now()) on conflict(id) do nothing;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(t,u,'admin','active') on conflict(tenant_id,user_id) do nothing;
end;$keeper$;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); ua uuid:=gen_random_uuid(); ub uuid:=gen_random_uuid();
 staff uuid:=gen_random_uuid(); ea uuid:=gen_random_uuid(); eb uuid:=gen_random_uuid(); ra uuid:=gen_random_uuid(); rb uuid:=gen_random_uuid();
 r jsonb; c jsonb; retry jsonb; marker timestamptz; role_name text; denied boolean; token text:=gen_random_uuid()::text;
begin
 insert into public.tenants(id,slug,name,status) values(a,'c2-a-'||a,'Synthetic A','active'),(b,'c2-b-'||b,'Synthetic B','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
 select t,id,'active' from public.saas_plans cross join unnest(array[a,b]) t where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at) select id,'c2-'||id||'@example.invalid',now() from unnest(array[ua,ub,staff]) id;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,ua,'user','active'),(a,staff,'admin','active'),(b,ub,'user','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,max_participants,is_active)
 values(ea,a,'Synthetic A',current_date+30,'10:00','11:00',5,true),(eb,b,'Synthetic B',current_date+30,'10:00','11:00',5,true);
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(ra,a,ea,ua,'Synthetic','a@example.invalid','000','registered','pending'),(rb,b,eb,ub,'Synthetic','b@example.invalid','000','registered','pending');
 perform set_config('app.product10d_test_enforce','on',true);
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
 perform pg_temp.check_c2('non cancelled denied',r->>'state'='42501');
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',gen_random_uuid()));
 perform pg_temp.check_c2('missing denied',r->>'state'='42501');
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.cancel_event_registration(%L)',ra));
 perform pg_temp.check_c2('own cancellation legal',r->>'state'='00000' and r->'value'->>'new_status'='cancelled');
 perform pg_temp.check_c2('future cancellation marker initially null',(select cancellation_email_initialized_at is null from public.event_registrations where id=ra));
 foreach role_name in array array['anon','service_role'] loop
  r:=pg_temp.invoke_c2(ua,role_name,format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
  perform pg_temp.check_c2(role_name||' prepare denied',r->>'state'='42501');
 end loop;
 perform pg_temp.check_c2('PUBLIC prepare denied',not has_function_privilege('public','public.prepare_event_registration_cancellation_email_v1(uuid)','EXECUTE'));
 perform pg_temp.check_c2('authenticated marker direct write denied',not has_column_privilege('authenticated','public.event_registrations','cancellation_email_initialized_at','UPDATE'));
 perform pg_temp.check_c2('safe search path', (select proconfig=array['search_path=pg_catalog, public, pg_temp'] from pg_proc where oid='public.prepare_event_registration_cancellation_email_v1(uuid)'::regprocedure));
 r:=pg_temp.invoke_c2(ub,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
 perform pg_temp.check_c2('other user denied',r->>'state'='42501');
 r:=pg_temp.invoke_c2(ub,'authenticated',format('select public.cancel_event_registration(%L)',rb));
 perform pg_temp.check_c2('B cancellation legal',r->>'state'='00000');
 foreach role_name in array array['admin','employee'] loop
  perform pg_temp.pam_keeper(a);
 update public.tenant_memberships set role=role_name where user_id=staff;
  r:=pg_temp.invoke_c2(staff,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',rb));
  perform pg_temp.check_c2(role_name||' cross tenant denied',r->>'state'='42501');
 end loop;
 create trigger synthetic_c2_failure before insert on public.email_deliveries for each row execute function pg_temp.reject_c2();
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
 perform pg_temp.check_c2('insert failure aborts prepare',r->>'state'='P0001');
 perform pg_temp.check_c2('failed insert rolls back marker',
  (select cancellation_email_initialized_at is null and registration_status='cancelled' from public.event_registrations where id=ra)
  and not exists(select 1 from public.email_deliveries where record_id=ra));
 drop trigger synthetic_c2_failure on public.email_deliveries;
 foreach role_name in array array['dormant','disabled'] loop
  update public.tenants set status=role_name where id=a;
  r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
  perform pg_temp.check_c2(role_name||' denied',r->>'state'='42501');
 end loop;
 update public.tenants set status='suspended' where id=a;
 c:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
 if c->>'state'<>'00000' then raise exception 'Prepare diagnostic %',c; end if; c:=c->'value';
 perform pg_temp.check_c2('suspended cancelled first receipt allowed',c->>'code'='ready');
 select cancellation_email_initialized_at into marker from public.event_registrations where id=ra;
 perform pg_temp.check_c2('atomic marker and bound delivery',marker is not null and exists(select 1 from public.email_deliveries
  where record_id=ra and tenant_id=a and recipient_user_id=ua and delivery_state='sending'));
 foreach role_name in array array['admin','employee'] loop
  update public.tenant_memberships set role=role_name where user_id=staff;
  r:=pg_temp.invoke_c2(staff,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
  perform pg_temp.check_c2(role_name||' same tenant existing receipt authorized',r->'value'->>'code'='in_progress');
 end loop;
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.complete_event_registration_cancellation_email_v1(%L,true,%L)',c->>'claim_id','fake'));
 perform pg_temp.check_c2('authenticated completion denied',r->>'state'='42501');
 r:=pg_temp.invoke_c2(null,'service_role',format('select public.complete_event_registration_cancellation_email_v1(%L,false,null)',c->>'claim_id'));
 perform pg_temp.check_c2('provider failure recorded',r->'value'->>'code'='failed');
 retry:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra)); retry:=retry->'value';
 perform pg_temp.check_c2('retry same key different lease',retry->>'idempotency_key'=c->>'idempotency_key' and retry->>'claim_id'<>c->>'claim_id');
 perform pg_temp.check_c2('marker unchanged one delivery',(select cancellation_email_initialized_at=marker from public.event_registrations where id=ra)
  and (select count(*)=1 from public.email_deliveries where record_id=ra));
 r:=pg_temp.invoke_c2(null,'service_role',format('select public.complete_event_registration_cancellation_email_v1(%L,true,%L)',retry->>'claim_id','synthetic-provider'));
 perform pg_temp.check_c2('sent marker',r->'value'->>'code'='sent');
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
 perform pg_temp.check_c2('sent replay no resend',r->'value'->>'code'='already_sent');
 update public.email_deliveries set updated_at=now()-interval '91 days' where record_id=ra;
 perform pg_temp.check_c2('purge removes completed receipt',public.purge_event_registration_cancellation_deliveries_v1()=1);
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
 perform pg_temp.check_c2('purged receipt cannot be recreated',r->'value'->>'code'='retired' and not exists(select 1 from public.email_deliveries where record_id=ra));
 perform pg_temp.check_c2('purge retains marker',(select cancellation_email_initialized_at=marker from public.event_registrations where id=ra));
 denied:=false; begin update public.event_registrations set cancellation_email_initialized_at=null where id=ra;
 exception when insufficient_privilege then denied:=true; end;
 perform pg_temp.check_c2('marker cannot reset',denied);
 -- Independent B receipt; three lifetime attempts, no reset after 23 hours.
 c:=pg_temp.invoke_c2(ub,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',rb));
 c:=c->'value';
 perform pg_temp.check_c2('B owner first receipt',c->>'code'='ready');
 for i in 1..2 loop
  update public.email_deliveries set claim_expires_at=now()-interval '1 second' where record_id=rb;
  retry:=pg_temp.invoke_c2(ub,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',rb));
  perform pg_temp.check_c2('reclaim stable key '||i,retry->'value'->>'idempotency_key'=c->>'idempotency_key');
 end loop;
 update public.email_deliveries set claim_expires_at=now()-interval '1 second' where record_id=rb;
 r:=pg_temp.invoke_c2(ub,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',rb));
 perform pg_temp.check_c2('three attempts bounded',r->'value'->>'code'='retry_exhausted');
 update public.email_deliveries set attempt_count=1,attempt_window_started_at=now()-interval '24 hours' where record_id=rb;
 r:=pg_temp.invoke_c2(ub,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',rb));
 perform pg_temp.check_c2('no reset after provider idempotency window',r->'value'->>'code'='retry_exhausted');
 update public.tenants set status='active' where id=a;
 r:=pg_temp.invoke_c2(ua,'authenticated','select public.anonymize_my_account_v1()');
 perform pg_temp.check_c2('actual account anonymization succeeds',r->>'state'='00000' and (r->'value'->>'ok')::boolean);
 perform pg_temp.check_c2('anonymization retains marker',(select cancellation_email_initialized_at=marker from public.event_registrations where id=ra));
 r:=pg_temp.invoke_c2(ua,'authenticated',format('select public.prepare_event_registration_cancellation_email_v1(%L)',ra));
 perform pg_temp.check_c2('anonymized resource cannot send',r->>'state'='42501');
 perform pg_temp.check_c2('account deletion still purges recipient deliveries',strpos(pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure),'delete from public.email_deliveries')>0);
 r:=pg_temp.invoke_c2(ub,'authenticated','select public.anonymize_my_account_v1()');
 perform pg_temp.check_c2('B account anonymization with existing cancellation delivery',r->>'state'='00000' and (r->'value'->>'ok')::boolean);
 perform pg_temp.check_c2('account deletion removes cancellation delivery',not exists(select 1 from public.email_deliveries where record_id=rb));
 perform pg_temp.check_c2('account anonymization preserves anti replay marker',(select cancellation_email_initialized_at is not null and pii_anonymized_at is not null from public.event_registrations where id=rb));
 perform pg_temp.check_c2('no body email token columns',not exists(select 1 from information_schema.columns where table_schema='public'
  and table_name='email_deliveries' and column_name in ('body','email_body','recipient_email','promotion_token','auth_token')));
end;$$;
select 'ok '||row_number() over()||' - '||label from c2_results;
select '1..'||count(*) from c2_results;
rollback;
