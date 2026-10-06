\set ON_ERROR_STOP on
begin;
create temp table acceptance_results(label text) on commit drop;
create function pg_temp.check_acceptance(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into acceptance_results values(label);
end;$$;
create function pg_temp.invoke_acceptance(actor uuid,dbrole text,statement text) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',dbrole)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 execute format('set local role %I',dbrole);
 execute statement into result;
 reset role; return jsonb_build_object('state','00000','value',result);
exception when others then reset role; return jsonb_build_object('state',sqlstate,'diagnostic',sqlerrm); end;$$;
create function pg_temp.reject_receipt() returns trigger language plpgsql as $$begin
 if new.message_type='event_reserve_acceptance_confirmation' then raise exception 'synthetic insert failure'; end if;
 return new; end;$$;

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
 ta text:=gen_random_uuid()::text; tb text:=gen_random_uuid()::text; r jsonb; c jsonb; retry jsonb; k text; role_name text; denied boolean;
begin
 insert into public.tenants(id,slug,name,status) values(a,'10gc-a-'||a,'Synthetic A','active'),(b,'10gc-b-'||b,'Synthetic B','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
 select t,id,'active' from public.saas_plans cross join unnest(array[a,b]) t where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at) select id,'10gc-'||id||'@example.invalid',now() from unnest(array[ua,ub,staff]) id;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,ua,'user','active'),(a,staff,'admin','active'),(b,ub,'user','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,price,max_participants,is_active)
 values(ea,a,'Synthetic A event',current_date+30,'10:00','11:00',10,5,true),(eb,b,'Synthetic B event',current_date+30,'10:00','11:00',10,5,true);
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,
 registration_status,payment_status,promotion_token,promotion_token_expires_at)
 values(ra,a,ea,ua,'Synthetic','a@example.invalid','000','reserve','pending',ta,now()+interval '24 hours'),
 (rb,b,eb,ub,'Synthetic','b@example.invalid','000','reserve','pending',tb,now()+interval '24 hours');
 perform set_config('app.product10d_test_enforce','on',true);
 denied:=false; begin
  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,delivery_state)
  values(a,'event_reserve_acceptance_confirmation',ra,ua,'pending');
 exception when check_violation then denied:=true; end;
 perform pg_temp.check_acceptance('active fresh delivery without acceptance denied',denied);

 foreach role_name in array array['anon','authenticated'] loop
  r:=pg_temp.invoke_acceptance(staff,role_name,format('select public.claim_event_reserve_acceptance_email_v1(%L)',ra));
  perform pg_temp.check_acceptance(role_name||' claim denied',r->>'state'='42501');
  r:=pg_temp.invoke_acceptance(staff,role_name,format('select public.complete_event_reserve_acceptance_email_v1(%L,true,%L)',gen_random_uuid(),'provider-test'));
  perform pg_temp.check_acceptance(role_name||' completion denied',r->>'state'='42501');
 end loop;
 perform pg_temp.check_acceptance('PUBLIC claim denied',not has_function_privilege('public','public.claim_event_reserve_acceptance_email_v1(uuid)','EXECUTE'));
 perform pg_temp.check_acceptance('claim definer owner and fixed path',exists(select 1 from pg_proc where oid='public.claim_event_reserve_acceptance_email_v1(uuid)'::regprocedure and prosecdef and proowner='postgres'::regrole and proconfig=array['search_path=pg_catalog, public, pg_temp']));
 perform pg_temp.check_acceptance('no tenant direct grant added',not has_table_privilege('service_role','public.tenants','SELECT'));
 perform pg_temp.check_acceptance('claim accepts resource only',(select proargnames=array['p_registration_id'] from pg_proc where oid='public.claim_event_reserve_acceptance_email_v1(uuid)'::regprocedure));
 insert into public.platform_admins(user_id,status) values(staff,'active');
 r:=pg_temp.invoke_acceptance(staff,'authenticated',format('select public.claim_event_reserve_acceptance_email_v1(%L)',ra));
 perform pg_temp.check_acceptance('Platform Admin claim denied',r->>'state'='42501');
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',gen_random_uuid()));
 perform pg_temp.check_acceptance('unknown registration no send',r->'value'->>'code'='not_found');
 r:=pg_temp.invoke_acceptance(staff,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',tb));
 perform pg_temp.check_acceptance('admin A cannot accept user B seat',r->>'state'='42501');
 perform pg_temp.pam_keeper(a);
 update public.tenant_memberships set role='employee' where user_id=staff;
 r:=pg_temp.invoke_acceptance(staff,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',tb));
 perform pg_temp.check_acceptance('employee A cannot accept user B seat',r->>'state'='42501');
 r:=pg_temp.invoke_acceptance(ua,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',tb));
 perform pg_temp.check_acceptance('user A cannot accept user B seat',r->>'state'='42501');

 create trigger synthetic_receipt_failure before insert on public.email_deliveries for each row execute function pg_temp.reject_receipt();
 r:=pg_temp.invoke_acceptance(ua,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',ta));
 perform pg_temp.check_acceptance('pending insert failure aborts RPC',r->>'state'='P0001');
 perform pg_temp.check_acceptance('rollback leaves reserve and no receipt',
  (select registration_status='reserve' and promotion_confirmed_at is null from public.event_registrations where id=ra)
  and not exists(select 1 from public.email_deliveries where record_id=ra));
 drop trigger synthetic_receipt_failure on public.email_deliveries;
 r:=pg_temp.invoke_acceptance(ua,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',ta));
 perform pg_temp.check_acceptance('owner accepts A',r->'value'->>'code'='confirmed');
 perform pg_temp.check_acceptance('atomic resource-derived pending',exists(select 1 from public.email_deliveries d
  join public.event_registrations r on r.id=d.record_id where d.record_id=ra and d.tenant_id=a and d.recipient_user_id=ua
  and d.delivery_state='pending' and d.attempt_count=0 and r.registration_status='registered'));
 r:=pg_temp.invoke_acceptance(ua,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',ta));
 perform pg_temp.check_acceptance('duplicate acceptance no duplicate delivery',r->'value'->>'code'='not_reserve' and (select count(*)=1 from public.email_deliveries where record_id=ra));

 foreach role_name in array array['dormant','disabled'] loop
  update public.tenants set status=role_name where id=a;
  r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',ra));
  perform pg_temp.check_acceptance(role_name||' existing receipt claim denied',r->'value'->>'code'='unavailable');
 end loop;
 update public.tenants set status='active' where id=a;
 c:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',ra));
 if c->>'state'<>'00000' then raise exception 'Synthetic claim failed: %',c; end if;
 c:=c->'value'; k:=c->>'idempotency_key';
 perform pg_temp.check_acceptance('service claim resource binding',c->>'code'='ready' and c->>'tenant_id'=a::text and c->>'recipient_user_id'=ua::text);
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',ra));
 perform pg_temp.check_acceptance('live lease denies second claimant',r->'value'->>'code'='in_progress');
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.complete_event_reserve_acceptance_email_v1(%L,false,null)',c->>'claim_id'));
 perform pg_temp.check_acceptance('provider failure persisted',r->'value'->>'code'='failed' and (select delivery_state='failed' from public.email_deliveries where record_id=ra));
 perform pg_temp.check_acceptance('mail failure never rolls back accepted seat',(select registration_status='registered' from public.event_registrations where id=ra));
 retry:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',ra)); retry:=retry->'value';
 perform pg_temp.check_acceptance('retry stable key rotating lease',retry->>'idempotency_key'=k and retry->>'claim_id'<>c->>'claim_id');
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.complete_event_reserve_acceptance_email_v1(%L,true,%L)',c->>'claim_id','old-claim'));
 perform pg_temp.check_acceptance('stale completion denied',r->'value'->>'code'='claim_not_found');
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.complete_event_reserve_acceptance_email_v1(%L,true,%L)',retry->>'claim_id','provider-test'));
 perform pg_temp.check_acceptance('sent marker recorded',r->'value'->>'code'='sent' and (select delivery_state='sent' and sent_at is not null and provider_message_id='provider-test' from public.email_deliveries where record_id=ra));
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',ra));
 perform pg_temp.check_acceptance('sent never resent',r->'value'->>'code'='already_sent');

 update public.tenants set status='suspended' where id=b;
 r:=pg_temp.invoke_acceptance(ub,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',tb));
 perform pg_temp.check_acceptance('suspended acceptance denied',r->>'state'='42501');
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.prepare_event_reserve_promotions(%L)',eb));
 perform pg_temp.check_acceptance('suspended promotion denied',r->>'state'='42501');
 perform pg_temp.check_acceptance('suspended rejection no receipt',not exists(select 1 from public.email_deliveries where record_id=rb));
 denied:=false; begin
  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,delivery_state)
  values(b,'event_reserve_acceptance_confirmation',rb,ub,'pending');
 exception when insufficient_privilege then denied:=true; end;
 perform pg_temp.check_acceptance('suspended fresh delivery without prior acceptance denied',denied);
 update public.tenants set status='active' where id=b;
 r:=pg_temp.invoke_acceptance(ub,'authenticated',format('select public.confirm_event_reserve_promotion(%L)',tb));
 perform pg_temp.check_acceptance('owner accepts B',r->'value'->>'code'='confirmed');
 update public.tenants set status='suspended' where id=b;
 c:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',rb)); c:=c->'value';
 perform pg_temp.check_acceptance('existing accepted receipt allowed on suspended',c->>'code'='ready');
 perform pg_temp.check_acceptance('tenant B separate key and recipient',c->>'idempotency_key'<>k and c->>'tenant_id'=b::text and c->>'recipient_user_id'=ub::text);
 r:=pg_temp.invoke_acceptance(ua,'authenticated',format('select public.claim_event_reserve_acceptance_email_v1(%L)',rb));
 perform pg_temp.check_acceptance('actor A cannot retry tenant B delivery',r->>'state'='42501');
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.complete_event_reserve_acceptance_email_v1(%L,false,null)',c->>'claim_id'));
 retry:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',rb)); retry:=retry->'value';
 perform pg_temp.check_acceptance('suspended failed receipt retry allowed',retry->>'code'='ready' and retry->>'idempotency_key'=c->>'idempotency_key');
 perform pg_temp.check_acceptance('retry does not mutate accepted obligation or create another delivery',
  (select registration_status='registered' from public.event_registrations where id=rb)
  and (select count(*)=1 from public.email_deliveries where record_id=rb));
 update public.email_deliveries set claim_expires_at=now()-interval '1 second' where record_id=rb;
 retry:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',rb)); retry:=retry->'value';
 perform pg_temp.check_acceptance('expired lease reclaim same key',retry->>'code'='ready' and retry->>'idempotency_key'=c->>'idempotency_key');
 update public.email_deliveries set claim_expires_at=now()-interval '1 second' where record_id=rb;
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',rb));
 perform pg_temp.check_acceptance('bounded three attempts',r->'value'->>'code'='retry_exhausted' and (select attempt_count=3 and delivery_state='failed' from public.email_deliveries where record_id=rb));
 update public.email_deliveries set attempt_count=1,attempt_window_started_at=now()-interval '24 hours' where record_id=rb;
 r:=pg_temp.invoke_acceptance(null,'service_role',format('select public.claim_event_reserve_acceptance_email_v1(%L)',rb));
 perform pg_temp.check_acceptance('provider dedup window prevents blind resend',r->'value'->>'code'='retry_exhausted');
 denied:=false; begin update public.email_deliveries set tenant_id=a where record_id=rb; exception when check_violation then denied:=true; end;
 perform pg_temp.check_acceptance('forged tenant rejected',denied);
 denied:=false; begin update public.email_deliveries set recipient_user_id=ua where record_id=rb; exception when check_violation then denied:=true; end;
 perform pg_temp.check_acceptance('forged user rejected',denied);
 perform pg_temp.check_acceptance('no body email token columns',not exists(select 1 from information_schema.columns
 where table_schema='public' and table_name='email_deliveries' and column_name in ('body','html','text','recipient_email','promotion_token','auth_token','metadata')));
 perform pg_temp.check_acceptance('old confirmation is not acceptance receipt',not exists(select 1 from public.email_deliveries where record_id in(ra,rb) and message_type='event_registration_confirmation'));
 perform pg_temp.check_acceptance('no retention service/browser execute',not has_function_privilege('service_role','public.purge_event_reserve_acceptance_deliveries_v1()','EXECUTE') and not has_function_privilege('authenticated','public.purge_event_reserve_acceptance_deliveries_v1()','EXECUTE'));
 perform public.purge_event_reserve_acceptance_deliveries_v1();
 perform pg_temp.check_acceptance('retention preserves recent rows',(select count(*)=2 from public.email_deliveries where record_id in(ra,rb)));
 update public.email_deliveries set updated_at=now()-interval '91 days' where record_id in(ra,rb);
 perform public.purge_event_reserve_acceptance_deliveries_v1();
 perform pg_temp.check_acceptance('retention purges sent and failed after 90d',not exists(select 1 from public.email_deliveries where record_id in(ra,rb)));
 insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,delivery_state,updated_at)
 values(a,'event_reserve_acceptance_confirmation',ra,ua,'pending',now()-interval '91 days');
 perform public.purge_event_reserve_acceptance_deliveries_v1();
 perform pg_temp.check_acceptance('retention does not discard pending obligation',exists(select 1 from public.email_deliveries where record_id=ra));
 r:=pg_temp.invoke_acceptance(ua,'authenticated','select public.anonymize_my_account_v1()');
 perform pg_temp.check_acceptance('existing account deletion succeeds with acceptance delivery',r->>'state'='00000' and (r->'value'->>'ok')::boolean);
 perform pg_temp.check_acceptance('account deletion removes new delivery type',not exists(select 1 from public.email_deliveries where recipient_user_id=ua));
 perform pg_temp.check_acceptance('account deletion preserves other tenant account',exists(select 1 from public.profiles where user_id=ub));
end;$$;
select '1..'||count(*) from acceptance_results;
select 'ok '||row_number() over()||' - '||label from acceptance_results;
rollback;
