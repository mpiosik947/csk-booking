\set ON_ERROR_STOP on
begin;
create function pg_temp.check_c2b(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 raise notice 'PASS: %',label; end;$$;
create function pg_temp.invoke_c2b(actor uuid,statement text, dbrole text default 'authenticated') returns jsonb language plpgsql as $$
declare result jsonb; begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute format('set local role %I',dbrole); execute statement into result; reset role;
 return jsonb_build_object('state','00000','value',result);
exception when others then reset role; return jsonb_build_object('state',sqlstate,'error',sqlerrm); end;$$;
create function pg_temp.reject_c2b() returns trigger language plpgsql as $$begin
 if new.message_type='event_cancellation' then raise exception 'Synthetic failure'; end if; return new; end;$$;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); staff uuid:=gen_random_uuid();
 u uuid:=gen_random_uuid(); ea uuid:=gen_random_uuid(); eb uuid:=gen_random_uuid(); r jsonb; n integer; state text; rec record;
 claims jsonb; claim jsonb; history jsonb; historical_id uuid;
begin
 insert into public.tenants(id,slug,name,status) values(a,'c2b-a-'||a,'Synthetic A','active'),(b,'c2b-b-'||b,'Synthetic B','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
 select t,id,'active' from public.saas_plans cross join unnest(array[a,b]) t where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at) select id,'c2b-'||id||'@example.invalid',now() from unnest(array[u,staff]) id;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,u,'user','active'),(a,staff,'admin','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,max_participants,is_active)
 values(ea,a,'Synthetic A',current_date+30,'10:00','11:00',10,true),(eb,b,'Synthetic B',current_date+30,'10:00','11:00',10,true);
 -- Unique synthetic owners preserve the existing one-active-registration invariant.
 for state in select unnest(array['registered','approved','reserve','cancelled','participant']) loop
  u:=gen_random_uuid();
  insert into auth.users(id,email,email_confirmed_at) values(u,'c2b-'||u||'@example.invalid',now());
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,u,'user','active');
  insert into public.event_registrations(tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values(a,ea,u,'Synthetic','c2b@example.invalid','000',state,'pending');
 end loop;
 perform set_config('app.product10d_test_enforce','on',true);
 r:=pg_temp.invoke_c2b(staff,format('select public.admin_cancel_event_v1(%L)',eb));
 perform pg_temp.check_c2b('cross tenant denied',r->>'state'='42501');
 foreach state in array array['user','instructor'] loop
  update public.tenant_memberships set role=state where tenant_id=a and user_id=staff;
  r:=pg_temp.invoke_c2b(staff,format('select public.admin_cancel_event_v1(%L)',ea));
  perform pg_temp.check_c2b(state||' denied',r->>'state'='42501');
 end loop;
 update public.tenant_memberships set role='employee' where tenant_id=a and user_id=staff;
 select id,user_id into rec from public.event_registrations where event_id=ea and registration_status='registered';
 insert into public.email_deliveries(message_type,record_id,tenant_id,recipient_user_id,sent_at)
 values('event_registration_confirmation',rec.id,a,rec.user_id,clock_timestamp()) returning id into historical_id;
 select to_jsonb(d) into history from public.email_deliveries d where id=historical_id;
 create trigger synthetic_c2b_failure before insert on public.email_deliveries for each row execute function pg_temp.reject_c2b();
 r:=pg_temp.invoke_c2b(staff,format('select public.admin_cancel_event_v1(%L)',ea));
 perform pg_temp.check_c2b('insertion failure returned',r->>'state'='P0001');
 perform pg_temp.check_c2b('marker rolled back',(select cancelled_at is null and is_active from public.events where id=ea));
 perform pg_temp.check_c2b('deliveries rolled back',not exists(select 1 from public.email_deliveries where tenant_id=a and message_type='event_cancellation'));
 drop trigger synthetic_c2b_failure on public.email_deliveries;
 r:=pg_temp.invoke_c2b(staff,format('select public.admin_cancel_event_v1(%L)',ea));
 if r->>'state'<>'00000' then raise exception 'Cancellation error %',r; end if;
 perform pg_temp.check_c2b('employee cancel',r->'value'->>'code'='cancelled');
 select count(*) into n from public.email_deliveries where tenant_id=a and message_type='event_cancellation';
 perform pg_temp.check_c2b('three eligible obligations',n=3);
 perform pg_temp.check_c2b('statuses unchanged',(select count(distinct registration_status)=5 from public.event_registrations where event_id=ea));
 perform pg_temp.check_c2b('sent positive history unchanged',(select to_jsonb(d)=history from public.email_deliveries d where id=historical_id));
 r:=pg_temp.invoke_c2b(staff,format('select public.admin_cancel_event_v1(%L)',ea));
 perform pg_temp.check_c2b('repeat no-op',r->'value'->>'code'='already_cancelled');
 perform pg_temp.check_c2b('no duplicates',(select count(*)=3 from public.email_deliveries where tenant_id=a and message_type='event_cancellation'));
 for rec in select id,user_id from public.event_registrations where event_id=ea and registration_status in ('registered','reserve') loop
  r:=pg_temp.invoke_c2b(rec.user_id,format('select public.prepare_confirmation_email(''event_registration_confirmation'',%L)',rec.id));
  perform pg_temp.check_c2b('cancel before positive claim',r->'value'->>'code'='invalid_status');
  r:=pg_temp.invoke_c2b(rec.user_id,format('select public.claim_event_reserve_acceptance_email_v1(%L)',rec.id),'service_role');
  perform pg_temp.check_c2b('cancel before acceptance receipt claim',r->'value'->>'code'='unavailable');
 end loop;
 r:=pg_temp.invoke_c2b(staff,format('select public.admin_set_event_active_v3(%L,%L,true)',a,ea));
 perform pg_temp.check_c2b('reactivation denied',r->>'state'='42501');
 r:=pg_temp.invoke_c2b(staff,format('select public.claim_event_cancellation_batch_v1(%L)',ea));
 if r->>'state'<>'00000' then raise exception 'Claim error %',r; end if;
 perform pg_temp.check_c2b('cancelled event receipts claimable',jsonb_array_length(r->'value')=3);
 claims:=r->'value';
 r:=pg_temp.invoke_c2b(staff,format('select public.claim_event_cancellation_batch_v1(%L)',ea));
 perform pg_temp.check_c2b('active leases no duplicate claim',jsonb_array_length(r->'value')=0);
 for claim in select value from jsonb_array_elements(claims) loop
  r:=pg_temp.invoke_c2b(staff,format('select public.complete_event_cancellation_email_v1(%L,false,null)',claim->>'claim_id'),'service_role');
  perform pg_temp.check_c2b('cancellation failure recorded',r->'value'->>'code'='failed');
 end loop;
 r:=pg_temp.invoke_c2b(staff,format('select public.claim_event_cancellation_batch_v1(%L)',ea));
 perform pg_temp.check_c2b('cancellation retry after cancelled_at',jsonb_array_length(r->'value')=3);
 perform pg_temp.check_c2b('retry retains logical deliveries',(select count(*)=3 from public.email_deliveries where tenant_id=a and message_type='event_cancellation'));
 r:=pg_temp.invoke_c2b(staff,format('select public.claim_event_cancellation_batch_v1(%L)',eb));
 perform pg_temp.check_c2b('cross tenant batch denied',r->>'state'='42501');
 update public.email_deliveries set attempt_count=3,claim_expires_at=clock_timestamp()-interval '1 minute'
 where tenant_id=a and message_type='event_cancellation';
 r:=pg_temp.invoke_c2b(staff,format('select public.claim_event_cancellation_batch_v1(%L)',ea));
 perform pg_temp.check_c2b('exhausted crashed attempt never reclaimed',jsonb_array_length(r->'value')=0);
 perform pg_temp.check_c2b('exhausted attempts terminal and reclaimable by retention',
  (select count(*)=3 from public.email_deliveries where tenant_id=a and message_type='event_cancellation'
   and delivery_state='failed' and claim_id is null and last_error_code='retry_exhausted'));
 begin
  update public.email_deliveries set message_type='event_registration_confirmation' where tenant_id=a and message_type='event_cancellation';
  raise exception 'Identity mutation unexpectedly permitted';
 exception when check_violation then null; end;
 foreach state in array array['anon','authenticated'] loop
  perform pg_temp.check_c2b(state||' cannot validate server lease',not has_function_privilege(state,'public.check_event_email_dispatch_lease_v1(uuid,text)','EXECUTE'));
 end loop;
 perform pg_temp.check_c2b('public execute denied',not has_function_privilege('public','public.admin_cancel_event_v1(uuid)','EXECUTE'));
 perform pg_temp.check_c2b('service role cannot cancel',not has_function_privilege('service_role','public.admin_cancel_event_v1(uuid)','EXECUTE'));
 update public.email_deliveries set updated_at=clock_timestamp()-interval '91 days'
 where tenant_id=a and message_type='event_cancellation';
 perform pg_temp.check_c2b('90 day retention removes completed failed deliveries',public.purge_event_cancellation_deliveries_v1()=3);
 r:=pg_temp.invoke_c2b(staff,format('select public.admin_cancel_event_v1(%L)',ea));
 perform pg_temp.check_c2b('permanent event marker prevents recreation after purge',
  r->'value'->>'code'='already_cancelled' and not exists(select 1 from public.email_deliveries where tenant_id=a and message_type='event_cancellation'));
 perform pg_temp.check_c2b('purge preserves sent positive history',(select to_jsonb(d)=history from public.email_deliveries d where id=historical_id));
end;$$;
rollback;
