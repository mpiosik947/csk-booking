\set ON_ERROR_STOP on
begin;
create temporary table i1f_results(name text,passed boolean not null) on commit drop;
create function pg_temp.ok(text,boolean) returns void language sql as $$insert into i1f_results values($1,coalesce($2,false));$$;
create function pg_temp.actor(u uuid,q text,r text default 'authenticated') returns jsonb language plpgsql as $$
declare v jsonb;begin
 perform set_config('request.jwt.claim.sub',coalesce(u::text,''),true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role',r)::text,true);
 execute format('set local role %I',r);execute q into v;reset role;
 perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);return v;
exception when others then
 reset role;perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);
 return jsonb_build_object('error',sqlstate);
end;$$;
create function pg_temp.staff_set(a uuid,e uuid,ids uuid[]) returns jsonb language plpgsql as $$
declare rev text;begin
 rev:=pg_temp.actor(a,format('select public.admin_list_available_event_instructors_v1(%L)',e))->>'revision';
 return pg_temp.actor(a,format('select public.admin_set_event_instructors_v1(%L,%L::uuid[],%L)',e,ids,rev));
end;$$;
create function pg_temp.reject_instructor_delivery() returns trigger language plpgsql as $$begin
 if new.message_type like 'instructor_%' then raise exception 'Synthetic insert failure' using errcode='23514';end if;
 return new;
end;$$;
do $$declare
 t uuid:=gen_random_uuid();tb uuid:=gen_random_uuid();e uuid:=gen_random_uuid();eb uuid:=gen_random_uuid();
 a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();i uuid:=gen_random_uuid();j uuid:=gen_random_uuid();ib uuid:=gen_random_uuid();
 generation uuid;new_generation uuid;claim uuid;claims jsonb;r jsonb;identities jsonb;before_count integer;life text;role_name text;
begin
 insert into public.tenants(id,slug,name,status) values(t,'i1f-'||t,'Synthetic A','active'),(tb,'i1f-'||tb,'Synthetic B','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
 select x,id,'active' from unnest(array[t,tb])x cross join public.saas_plans where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at)select x,x||'@example.invalid',now() from unnest(array[a,b,i,j,ib])x;
 insert into public.profiles(id,user_id,email)select id,id,email from auth.users where id=any(array[a,b,i,j,ib]) on conflict(user_id)do nothing;
 delete from public.tenant_memberships where user_id=any(array[a,b,i,j,ib]);
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values
 (t,a,'admin','active'),(tb,b,'employee','active'),(t,i,'instructor','active'),(t,j,'instructor','active'),(tb,ib,'instructor','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,max_participants,is_active)
 values(e,t,'Synthetic A',current_date+30,'10:00','11:00',10,true),(eb,tb,'Synthetic B',current_date+30,'10:00','11:00',10,true);
 perform pg_temp.ok('empty set no delivery',pg_temp.staff_set(a,e,'{}')->>'changed'='false' and not exists(select 1 from public.email_deliveries where tenant_id=t));
 create trigger synthetic_i1f_failure before insert on public.email_deliveries for each row execute function pg_temp.reject_instructor_delivery();
 r:=pg_temp.staff_set(a,e,array[i,j]);
 perform pg_temp.ok('failed outbox insert rolls back assignment',r->>'error'='23514' and not exists(select 1 from public.event_instructors where event_id=e));
 r:=pg_temp.actor(a,format('select public.admin_create_event_with_instructors_v1(%L,%L,null,current_date+31,%L::time,%L::time,%L,0,10,%L::uuid[],%L::uuid[])',
  t,'Synthetic failed create','10:00','11:00','Range','{}',array[i]));
 perform pg_temp.ok('outbox failure rolls back atomic event create',r->>'error'='23514' and not exists(select 1 from public.events where tenant_id=t and title='Synthetic failed create'));
 drop trigger synthetic_i1f_failure on public.email_deliveries;
 r:=pg_temp.staff_set(a,e,array[i,j]);
 perform pg_temp.ok('two assignments two obligations',r->>'changed'='true' and (select count(*)=2 from public.email_deliveries where tenant_id=t));
 select id into generation from public.event_instructors where event_id=e and instructor_user_id=i;
 perform pg_temp.ok('resource is assignment generation',exists(select 1 from public.email_deliveries where record_id=generation and recipient_user_id=i and message_type='instructor_assignment'));
 perform pg_temp.ok('no-op no new obligation',pg_temp.staff_set(a,e,array[i,j])->>'changed'='false' and (select count(*)=2 from public.email_deliveries where tenant_id=t));
 perform pg_temp.ok('cross-tenant target rollback',pg_temp.staff_set(a,e,array[i,ib])->>'error'='42501' and (select count(*)=2 from public.email_deliveries where tenant_id=t));
 foreach role_name in array array['anon','authenticated'] loop
  perform pg_temp.ok('claim ACL '||role_name,pg_temp.actor(a,format('select public.claim_instructor_email_batch_v1(%L)',e),role_name)->>'error'='42501');
  perform pg_temp.ok('payload ACL '||role_name,pg_temp.actor(a,format('select public.read_instructor_email_attempt_v1(%L)',gen_random_uuid()),role_name)->>'error'='42501');
 end loop;
 perform pg_temp.ok('cross-tenant actor deny',pg_temp.actor(b,format('select public.authorize_instructor_email_batch_v1(%L)',e))->>'error'='42501');
 perform pg_temp.ok('instructor actor deny',pg_temp.actor(i,format('select public.authorize_instructor_email_batch_v1(%L)',e))->>'error'='42501');
 perform pg_temp.ok('admin explicit batch allowed',pg_temp.actor(a,format('select to_jsonb(public.authorize_instructor_email_batch_v1(%L))',e))='true');
 perform pg_temp.ok('caller A cannot select event B',pg_temp.actor(a,format('select public.authorize_instructor_email_batch_v1(%L)',eb))->>'error'='42501');
 perform pg_temp.ok('nonexistent event selector denied',pg_temp.actor(a,format('select public.authorize_instructor_email_batch_v1(%L)',gen_random_uuid()))->>'error'='42501');
 create trigger synthetic_i1f_failure before insert on public.email_deliveries for each row execute function pg_temp.reject_instructor_delivery();
 r:=pg_temp.staff_set(a,e,'{}');
 perform pg_temp.ok('failed outbox insert rolls back removal',r->>'error'='23514' and (select count(*)=2 from public.event_instructors where event_id=e and unassigned_at is null));
 r:=pg_temp.actor(a,format('select public.admin_update_event_with_instructors_v1(%L,%L,%L,null,current_date+30,%L::time,%L::time,null,0,10,%L::uuid[],%L::uuid[],%L::jsonb,%L)',
  t,e,'Synthetic failed edit','10:00','11:00','{}','{}',public.instructor_event_revision_v1(e),
  pg_temp.actor(a,format('select public.admin_list_available_event_instructors_v1(%L)',e))->>'revision'));
 perform pg_temp.ok('outbox failure rolls back atomic event edit',r->>'error'='23514' and exists(select 1 from public.events where id=e and title='Synthetic A'));
 drop trigger synthetic_i1f_failure on public.email_deliveries;
 update public.tenants set status='suspended' where id=t;
 perform pg_temp.ok('B suspended assignment deny',public.claim_instructor_email_batch_v1(e)='[]');
 perform pg_temp.ok('suspended operator continuity authorization allowed',pg_temp.actor(a,format('select to_jsonb(public.authorize_instructor_email_batch_v1(%L))',e))='true');
 perform pg_temp.ok('suspended ordinary tenant role remains unavailable',pg_temp.actor(a,format('select to_jsonb(public.get_my_tenant_role_v1(%L))',t)) is null);
 update public.tenants set status='active' where id=t;
 update public.tenant_memberships set status='suspended' where user_id=i and tenant_id=t;
 update public.tenant_memberships set role='user' where user_id=j and tenant_id=t;
 perform pg_temp.ok('suspended membership and changed role deny',public.claim_instructor_email_batch_v1(e)='[]');
 update public.tenant_memberships set status='active',role='instructor' where user_id=any(array[i,j]) and tenant_id=t;
 claims:=pg_temp.actor(null,format('select public.claim_instructor_email_batch_v1(%L)',e),'service_role');
 perform pg_temp.ok('A active claims allowed',jsonb_array_length(claims)=2);
 select claim_id into claim from public.email_deliveries where record_id=generation and message_type='instructor_assignment';
 r:=public.read_instructor_email_attempt_v1(claim);
 perform pg_temp.ok('canonical account recipient',r->>'recipient_email'=i||'@example.invalid' and r->>'tenant_id'=t::text);
 perform pg_temp.ok('lease prevents duplicate claim',public.claim_instructor_email_batch_v1(e)='[]');
 perform pg_temp.ok('removal transition',pg_temp.staff_set(a,e,array[j])->>'changed'='true');
 perform pg_temp.ok('admitted exact attempt survives later removal',public.read_instructor_email_attempt_v1(claim) is not null);
 perform public.complete_instructor_email_v1(claim,false,null);
 update public.tenants set status='suspended' where id=t;
 select jsonb_agg(jsonb_build_array(id,message_type,record_id,message_type||'/'||record_id::text) order by id) into identities from public.email_deliveries where tenant_id=t;
 claims:=public.claim_instructor_email_batch_v1(e);
 perform pg_temp.ok('C suspended removal retry allow',jsonb_array_length(claims)=1 and exists(select 1 from public.email_deliveries where record_id=generation and message_type='instructor_removal' and delivery_state='sending'));
 perform pg_temp.ok('operator retry preserves exact delivery and provider identities',identities=(select jsonb_agg(jsonb_build_array(id,message_type,record_id,message_type||'/'||record_id::text) order by id) from public.email_deliveries where tenant_id=t));
 perform pg_temp.ok('removed positive retry denied',exists(select 1 from public.email_deliveries where record_id=generation and message_type='instructor_assignment' and delivery_state='failed'));
 select claim_id into claim from public.email_deliveries where record_id=generation and message_type='instructor_removal';
 perform public.complete_instructor_email_v1(claim,false,null);
 -- Canonical inactive state is disabled; do not invent a new lifecycle value.
 foreach life in array array['disabled','dormant'] loop
  update public.tenants set status=life where id=t;
  perform pg_temp.ok('E removal lifecycle deny '||life,public.claim_instructor_email_batch_v1(e)='[]');
  perform pg_temp.ok('operator authorization lifecycle deny '||life,pg_temp.actor(a,format('select public.authorize_instructor_email_batch_v1(%L)',e))->>'error'='42501');
 end loop;
 update public.tenants set status='active' where id=t;
 perform pg_temp.ok('reassign new generation',pg_temp.staff_set(a,e,array[i,j])->>'changed'='true');
 select id into new_generation from public.event_instructors where event_id=e and instructor_user_id=i and unassigned_at is null;
 perform pg_temp.ok('new assignment identity',new_generation<>generation and exists(select 1 from public.email_deliveries where record_id=new_generation and message_type='instructor_assignment'));
 insert into public.event_registrations(event_id,tenant_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(e,t,i,'Synthetic','test@example.invalid','000','registered','pending');
 create trigger synthetic_i1f_failure before insert on public.email_deliveries for each row execute function pg_temp.reject_instructor_delivery();
 r:=pg_temp.actor(a,format('select public.admin_cancel_event_v1(%L)',e));
 perform pg_temp.ok('failed instructor fanout rolls back entire cancellation',r->>'error'='23514' and exists(select 1 from public.events where id=e and cancelled_at is null)
  and not exists(select 1 from public.email_deliveries where tenant_id=t and message_type='event_cancellation'));
 drop trigger synthetic_i1f_failure on public.email_deliveries;
 r:=pg_temp.actor(a,format('select public.admin_cancel_event_v1(%L)',e));
 perform pg_temp.ok('cancellation transition unchanged',r->>'code'='cancelled');
 perform pg_temp.ok('two active instructor cancellations',(select count(*)=2 from public.email_deliveries where tenant_id=t and message_type='instructor_event_cancellation'));
 perform pg_temp.ok('closed generation excluded',not exists(select 1 from public.email_deliveries where record_id=generation and message_type='instructor_event_cancellation'));
 perform pg_temp.ok('C2B participant independent',(select count(*)=1 from public.email_deliveries where tenant_id=t and message_type='event_cancellation' and recipient_user_id=i));
 select count(*) into before_count from public.email_deliveries where tenant_id=t;
 r:=pg_temp.actor(a,format('select public.admin_cancel_event_v1(%L)',e));
 perform pg_temp.ok('cancel retry no new rows',r->>'code'='already_cancelled' and (select count(*)=before_count from public.email_deliveries where tenant_id=t));
 update public.tenants set status='suspended' where id=t;
 claims:=public.claim_instructor_email_batch_v1(e);
 perform pg_temp.ok('D suspended cancellation allow',(select count(*)=2 from public.email_deliveries where tenant_id=t and message_type='instructor_event_cancellation' and delivery_state='sending'));
 perform pg_temp.ok('G no logical creation on suspended retry',(select count(*)=before_count from public.email_deliveries where tenant_id=t));
 perform pg_temp.ok('G no assignment recreation',(select count(*)=3 from public.event_instructors where event_id=e));
 perform pg_temp.ok('G event remains cancelled',exists(select 1 from public.events where id=e and cancelled_at is not null and not is_active));
 for claim in select claim_id from public.email_deliveries where tenant_id=t and message_type='instructor_event_cancellation' loop
  perform public.complete_instructor_email_v1(claim,false,null);
 end loop;
 foreach life in array array['disabled','dormant'] loop
  update public.tenants set status=life where id=t;
  perform pg_temp.ok('F cancellation lifecycle deny '||life,public.claim_instructor_email_batch_v1(e)='[]');
 end loop;
 perform pg_temp.ok('Tenant B independent assign',pg_temp.staff_set(b,eb,array[ib])->>'changed'='true');
 claims:=public.claim_instructor_email_batch_v1(eb);
 perform pg_temp.ok('I Tenant B active despite A dormant',jsonb_array_length(claims)=1);
 claim:=(claims->0->>'claim_id')::uuid;
 perform pg_temp.ok('B payload bound',(public.read_instructor_email_attempt_v1(claim)->>'tenant_id')=tb::text);
 perform pg_temp.ok('sent marker',public.complete_instructor_email_v1(claim,true,'test_provider')->>'code'='sent');
 perform pg_temp.ok('sent historical no claim',public.claim_instructor_email_batch_v1(eb)='[]');
 update public.tenants set status='active' where id=t;
 claims:=public.claim_instructor_email_batch_v1(e);
 perform pg_temp.ok('H reactivation same logical deliveries',jsonb_array_length(claims)=2 and (select count(*)=before_count from public.email_deliveries where tenant_id=t));
 for claim in select claim_id from public.email_deliveries where tenant_id=t and message_type='instructor_event_cancellation' loop
  perform pg_temp.ok('stable cancellation provider identity',public.read_instructor_email_attempt_v1(claim)->>'idempotency_key'=(select message_type||'/'||record_id::text from public.email_deliveries where claim_id=claim));
  perform public.complete_instructor_email_v1(claim,false,null);
 end loop;
 claims:=public.claim_instructor_email_batch_v1(e);
 for claim in select claim_id from public.email_deliveries where tenant_id=t and message_type='instructor_event_cancellation' loop
  perform public.complete_instructor_email_v1(claim,false,null);
 end loop;
 perform pg_temp.ok('bounded third attempt then deny',public.claim_instructor_email_batch_v1(e)='[]'
  and (select bool_and(attempt_count=3 and delivery_state='failed') from public.email_deliveries where tenant_id=t and message_type='instructor_event_cancellation'));
 perform pg_temp.ok('positive cancelled new assignment not claimed',exists(select 1 from public.email_deliveries where record_id=new_generation and message_type='instructor_assignment' and delivery_state='pending'));
 update public.email_deliveries set updated_at=clock_timestamp()-interval '91 days' where tenant_id=tb and delivery_state='sent';
 perform pg_temp.ok('completed retention 90 days',public.purge_instructor_email_deliveries_v1()=1);
 perform pg_temp.ok('purge cannot recreate on same-set save',pg_temp.staff_set(b,eb,array[ib])->>'changed'='false' and not exists(select 1 from public.email_deliveries where tenant_id=tb));
 perform pg_temp.ok('purge cannot recreate on claim',public.claim_instructor_email_batch_v1(eb)='[]');
 -- Account anonymization removes deliveries before clearing assignment references.
 r:=pg_temp.actor(ib,'select public.anonymize_my_account_v1()');
 perform pg_temp.ok('privacy anonymization',r->>'ok'='true' and not exists(select 1 from public.email_deliveries where recipient_user_id=ib));
 perform pg_temp.ok('privacy history retained',exists(select 1 from public.event_instructors where event_id=eb and instructor_user_id is null));
 update public.tenants set status='suspended' where id=t;
 r:=pg_temp.actor(j,'select public.anonymize_my_account_v1()');
 perform pg_temp.ok('suspended privacy deletes pending/failed obligations',r->>'ok'='true' and not exists(select 1 from public.email_deliveries where recipient_user_id=j));
 perform pg_temp.ok('suspended privacy preserves closed event',exists(select 1 from public.events where id=e and cancelled_at is not null));
 perform pg_temp.ok('exact definer delta',(select count(*)=135 from pg_proc where pronamespace='public'::regnamespace and prosecdef));
 perform pg_temp.ok('new definer metadata',not exists(select 1 from pg_proc where proname in ('authorize_instructor_email_batch_v1','claim_instructor_email_batch_v1','read_instructor_email_attempt_v1','complete_instructor_email_v1') and (proowner<>'postgres'::regrole or not prosecdef or proconfig<>array['search_path=pg_catalog, public, pg_temp'])));
end;$$;
select case when passed then 'ok - ' else 'not ok - ' end||name from i1f_results;
select count(*) as assertions from i1f_results;
do $$begin if exists(select 1 from i1f_results where not passed) then raise exception 'INSTRUCTOR-1F matrix failed';end if;end;$$;
rollback;
