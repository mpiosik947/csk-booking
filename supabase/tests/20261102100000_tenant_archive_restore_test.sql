\set ON_ERROR_STOP on
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into results(label) values(label);
end;$$;
create function pg_temp.rpc(actor uuid,statement text) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',case when actor is null then 'anon' else 'authenticated' end)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 if actor is null then set local role anon; else set local role authenticated; end if;
 execute statement into result;
 reset role;
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state','00000','value',result);
exception when others then
 reset role;
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state',sqlstate,'error',sqlerrm);
end;$$;
create function pg_temp.change(actor uuid,t uuid,u uuid,op text,req uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare state jsonb;
begin
 select jsonb_build_object('role',role,'status',status) into state from public.tenant_memberships where tenant_id=t and user_id=u;
 return pg_temp.rpc(actor,format('select public.platform_%s_tenant_admin_v1(%L,%L,%L::jsonb,%L)',op,t,u,state,req));
end;$$;
create function pg_temp.life(actor uuid,t uuid,op text,req uuid default gen_random_uuid()) returns jsonb language plpgsql as $$declare rev bigint;begin
 select lifecycle_revision into rev from public.tenants where id=t;
 return pg_temp.rpc(actor,format('select public.%s(%L,%L,%L)',case op when 'archive' then 'platform_archive_tenant_v1' else 'platform_restore_archived_tenant_v1' end,t,rev,req));
end;$$;
do $tests$
declare pa uuid:=gen_random_uuid();a uuid:=gen_random_uuid();u uuid:=gen_random_uuid();t uuid:=gen_random_uuid();b uuid:=gen_random_uuid();e uuid:=gen_random_uuid();reg uuid:=gen_random_uuid();
 lane uuid:=gen_random_uuid(); price uuid:=gen_random_uuid(); booking uuid:=gen_random_uuid(); due_event uuid:=gen_random_uuid(); due_reg uuid:=gen_random_uuid(); past_event uuid:=gen_random_uuid(); past_reg uuid:=gen_random_uuid();
 start_local timestamp:=date_trunc('hour',(statement_timestamp()+interval '20 hours') at time zone 'Europe/Warsaw');
 r jsonb;q text;req uuid:=gen_random_uuid();life text;before_members jsonb;before_plan jsonb;before_profile jsonb;before_domains jsonb;rev bigint;claims jsonb;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) select x,x||'@example.invalid',now(),false from unnest(array[pa,a,u])x;
 insert into public.profiles(id,user_id,email) select id,id,email from auth.users where id=any(array[pa,a,u]) on conflict(user_id)do nothing;
 insert into public.platform_admins(user_id,status)values(pa,'active');
 insert into public.tenants(id,name,slug,status)values(t,'Archive test','pam1c-'||t,'active'),(b,'Other','pam1c-'||b,'dormant');
 insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public)values(t,'pam1c-public-'||t,'Archive test','Synthetic',true),(b,'pam1c-public-'||b,'Other','Synthetic',false);
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(t,a,'admin','active'),(t,u,'user','active'),(b,a,'admin','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)select x,p.id,'active' from unnest(array[t,b])x cross join public.saas_plans p where p.plan_key='current_full_v1';
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active)values(e,t,'Preserved future',current_date+7,'10:00','11:00',true);
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(reg,t,e,u,'PRIVATE NAME','private@example.invalid','PRIVATE PHONE','registered','free');

 if start_local::time>time '22:00' then start_local:=start_local-interval '2 hours'; end if;
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(lane,t,'Synthetic lane','test',true,2,60,901,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
 values(price,lane,'mon_thu',1,2,'Synthetic',10,1,true);
 insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id,created_at)
 values(booking,u,t,lane,'Synthetic','synthetic@example.invalid','000',start_local::date,start_local::time,(start_local+interval '1 hour')::time,60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid(),now()-interval '2 days');

 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active,created_at)
 values(due_event,t,'Due reminder',start_local::date,start_local::time,(start_local+interval '1 hour')::time,true,now()-interval '2 days'),
 (past_event,t,'Completed history',current_date-7,'10:00','11:00',true,now()-interval '10 days');
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,created_at)
 values(due_reg,t,due_event,u,'Synthetic','synthetic@example.invalid','000','registered','free',now()-interval '2 days'),
 (past_reg,t,past_event,u,'Synthetic','synthetic@example.invalid','000','participant','free',now()-interval '10 days');
 perform pg_temp.ok('active reminder canonical booking lineage',exists(select 1 from public.reminder_source_v1('booking_reminder_24h',booking) where tenant_id=t));
 perform pg_temp.ok('active reminder canonical event lineage',exists(select 1 from public.reminder_source_v1('event_reminder_24h',due_reg) where tenant_id=t));
 perform public.discover_reminders_v1();
 perform pg_temp.ok('reminder occurrences created without tenant_id',(select count(*)=2 from public.reminder_occurrences where reservation_id=booking or registration_id=due_reg));
 perform pg_temp.ok('initial dormant My Events denied',pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L)',b))->'value'->>'code'='not_found');
 perform pg_temp.ok('initial dormant My Reservations denied',pg_temp.rpc(u,format('select public.get_my_reservations_v3(%L)',b))->'value'->>'code'='not_found');
 update public.tenants set status='suspended' where id=t;
 perform pg_temp.ok('suspended My Events unchanged not_found',pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L)',t))->'value'->>'code'='not_found');
 perform pg_temp.ok('suspended My Reservations unchanged not_found',pg_temp.rpc(u,format('select public.get_my_reservations_v3(%L)',t))->'value'->>'code'='not_found');
 perform pg_temp.ok('suspended separate continuity unchanged',pg_temp.rpc(u,'select public.get_my_continuity_v1()')->'value'->>'total'='4');
 update public.tenants set status='active' where id=t;
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_archive_preview_v1(%L)',t));
 perform pg_temp.ok('preview allows unresolved preserved business',r->'value'->>'can_archive'='true');
 perform pg_temp.ok('preview PII boundary',not(r::text ~ 'PRIVATE|private@example|customer_name|customer_email|customer_phone'));
 foreach life in array array['admin','employee','instructor','user'] loop
  update public.tenant_memberships set role=life where tenant_id=t and user_id=u;
  perform pg_temp.ok('nonPA archive deny '||life,pg_temp.life(u,t,'archive')->>'state'='42501');
  perform pg_temp.ok('nonPA preview deny '||life,pg_temp.rpc(u,format('select public.platform_get_tenant_archive_preview_v1(%L)',t))->>'state'='42501');
 end loop;
 perform pg_temp.ok('anon denied',pg_temp.life(null,t,'archive')->>'state'='42501');
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA denied',pg_temp.life(pa,t,'archive')->>'state'='42501');
 update public.platform_admins set status='active' where user_id=pa;
 select jsonb_agg(to_jsonb(m) order by user_id) into before_members from public.tenant_memberships m where tenant_id=t;
 select to_jsonb(x) into before_plan from public.tenant_plan_assignments x where tenant_id=t;
 select to_jsonb(x)-array['is_public','updated_at'] into before_profile from public.tenant_public_profiles x where tenant_id=t;
 select lifecycle_revision into rev from public.tenants where id=t;
 q:=format('select public.platform_archive_tenant_v1(%L,%L,%L)',t,rev,req);
 r:=pg_temp.rpc(pa,q);perform pg_temp.ok('active archive '||r::text,r->>'state'='00000' and r->'value'->>'status'='archived');
 perform pg_temp.ok('same request cached',pg_temp.rpc(pa,q)=r);
 perform pg_temp.ok('cross-operation replay mismatch',pg_temp.life(pa,t,'restore',req)->>'error'='REQUEST_REPLAY_MISMATCH');
 perform pg_temp.ok('stale revision denied',pg_temp.rpc(pa,format('select public.platform_archive_tenant_v1(%L,%L,%L)',t,rev,gen_random_uuid()))->>'state'='PT409');
 perform pg_temp.ok('same archive no-op',pg_temp.life(pa,t,'archive')->>'state'='00000');
 perform pg_temp.ok('audit once',(select count(*)=1 from public.platform_audit_logs where tenant_id=t and action='tenant_archived'));
 perform pg_temp.ok('other tenant unchanged',(select status='dormant' from public.tenants where id=b));
 perform pg_temp.ok('members retained',(select jsonb_agg(to_jsonb(m) order by user_id) from public.tenant_memberships m where tenant_id=t)=before_members);
 perform pg_temp.ok('plan retained',(select to_jsonb(x) from public.tenant_plan_assignments x where tenant_id=t)=before_plan);
 perform pg_temp.ok('profile preferences retained',(select to_jsonb(x)-array['is_public','updated_at'] from public.tenant_public_profiles x where tenant_id=t)=before_profile);
 perform pg_temp.ok('public false',(select not is_public from public.tenant_public_profiles where tenant_id=t));
 perform pg_temp.ok('public feature denied',not public.get_public_tenant_feature_access_v1(t,'booking'));
 perform pg_temp.ok('future event retained',exists(select 1 from public.events where id=e and cancelled_at is null));
 perform pg_temp.ok('registration retained',exists(select 1 from public.event_registrations where id=reg and user_id=u));
 perform pg_temp.ok('customer owned events retained',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L)',t))->'value')::text like '%'||reg||'%');
 perform pg_temp.ok('continuity retains label',(pg_temp.rpc(u,'select public.get_my_continuity_v1()')->'value')::text like '%Archive test%');
 perform pg_temp.ok('new registration denied',pg_temp.rpc(u,format('select public.register_for_event(%L,false)',e))->>'state'<>'00000');
 begin insert into public.events(tenant_id,title,event_date,start_time,end_time,is_active) values(t,'No new business',current_date+8,'10:00','11:00',true);raise exception 'UNGUARDED';exception when sqlstate '55000' or insufficient_privilege then perform pg_temp.ok('DB new event denied',true);end;
 begin update public.tenant_public_profiles set is_public=true where tenant_id=t;raise exception 'UNGUARDED';exception when sqlstate '55000' then perform pg_temp.ok('DB publish denied',true);end;
 perform pg_temp.ok('activation cannot bypass archive',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'activate'))->>'state'<>'00000');

 perform pg_temp.ok('archived reservation owner history',pg_temp.rpc(u,format('select public.get_my_reservations_v3(%L)',t))->'value'::text is not null and (pg_temp.rpc(u,format('select public.get_my_reservations_v3(%L)',t))->'value')::text like '%'||booking||'%');
 perform pg_temp.ok('archived event completed history',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L,''history'')',t))->'value')::text like '%'||past_reg||'%');
 perform pg_temp.ok('archived event future continuity',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L,''all'')',t))->'value')::text like '%'||due_reg||'%');
 perform pg_temp.ok('archived other owner excludes reservation',(pg_temp.rpc(a,format('select public.get_my_reservations_v3(%L)',t))->'value')::text not like '%'||booking||'%');
 perform pg_temp.ok('archived other owner excludes registration',(pg_temp.rpc(a,format('select public.get_my_event_registrations_v2(%L,''all'')',t))->'value')::text not like '%'||past_reg||'%');
 perform pg_temp.ok('archived cross tenant excludes registration',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L,''all'')',b))->'value')::text not like '%'||past_reg||'%');
 r:=pg_temp.rpc(u,'select public.export_my_data_v3()');
 perform pg_temp.ok('archived export retains reservation and events',r->>'state'='00000' and r::text like '%'||booking||'%' and r::text like '%'||past_reg||'%');
 perform pg_temp.ok('archived reminder sources suppressed',not exists(select 1 from public.reminder_source_v1('booking_reminder_24h',booking)) and not exists(select 1 from public.reminder_source_v1('event_reminder_24h',due_reg)));
 perform pg_temp.ok('archived reminder claim suppressed',jsonb_array_length(public.claim_reminders_v1())=0);
 perform pg_temp.ok('archived reminder tombstones retained',(select count(*)=2 from public.reminder_occurrences where reservation_id=booking or registration_id=due_reg));
 perform pg_temp.ok('archived separate continuity retains all owner records',pg_temp.rpc(u,'select public.get_my_continuity_v1()')->'value'->>'total'='4');
 perform pg_temp.ok('sole admin anonymize denied',pg_temp.rpc(a,'select public.anonymize_my_account_v1()')->>'error'='LAST_ACTIVE_ADMIN');
 r:=pg_temp.rpc(a,format('select public.admin_cancel_event_v1(%L)',e));perform pg_temp.ok('future event closure '||r::text,r->>'state'='00000' and r->'value'->>'code'='cancelled');
 perform pg_temp.ok('closure notification queued',exists(select 1 from public.email_deliveries where record_id=reg and message_type='event_cancellation'));
 r:=pg_temp.rpc(a,format('select public.claim_event_cancellation_batch_v1(%L)',e));perform pg_temp.ok('closure delivery claim '||r::text,r->>'state'='00000' and jsonb_array_length(r->'value')=1);
 r:=pg_temp.life(pa,t,'restore');perform pg_temp.ok('restore dormant '||r::text,r->>'state'='00000' and r->'value'->>'status'='dormant');
 perform pg_temp.ok('restore unpublished',(select not is_public from public.tenant_public_profiles where tenant_id=t));
 perform pg_temp.ok('restore plan retained',(select to_jsonb(x) from public.tenant_plan_assignments x where tenant_id=t)=before_plan);
 perform pg_temp.ok('restore new business denied',not public.get_public_tenant_feature_access_v1(t,'events'));

 perform pg_temp.ok('restored dormant reservation owner history',pg_temp.rpc(u,format('select public.get_my_reservations_v3(%L)',t))->'value'::text is not null and (pg_temp.rpc(u,format('select public.get_my_reservations_v3(%L)',t))->'value')::text like '%'||booking||'%');
 perform pg_temp.ok('restored dormant event completed history',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L,''history'')',t))->'value')::text like '%'||past_reg||'%');
 perform pg_temp.ok('restored dormant event future continuity',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L,''all'')',t))->'value')::text like '%'||due_reg||'%');
 perform pg_temp.ok('restored dormant other owner excludes reservation',(pg_temp.rpc(a,format('select public.get_my_reservations_v3(%L)',t))->'value')::text not like '%'||booking||'%');
 perform pg_temp.ok('restored dormant other owner excludes registration',(pg_temp.rpc(a,format('select public.get_my_event_registrations_v2(%L,''all'')',t))->'value')::text not like '%'||past_reg||'%');
 perform pg_temp.ok('restored dormant cross tenant excludes registration',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L,''all'')',b))->'value')::text not like '%'||past_reg||'%');
 r:=pg_temp.rpc(u,'select public.export_my_data_v3()');
 perform pg_temp.ok('restored dormant export retains reservation and events',r->>'state'='00000' and r::text like '%'||booking||'%' and r::text like '%'||past_reg||'%');
 perform pg_temp.ok('restored dormant reminder sources suppressed',not exists(select 1 from public.reminder_source_v1('booking_reminder_24h',booking)) and not exists(select 1 from public.reminder_source_v1('event_reminder_24h',due_reg)));
 perform pg_temp.ok('restored dormant reminder claim suppressed',jsonb_array_length(public.claim_reminders_v1())=0);
 perform pg_temp.ok('restored dormant reminder tombstones retained',(select count(*)=2 from public.reminder_occurrences where reservation_id=booking or registration_id=due_reg));
 perform pg_temp.ok('restored dormant separate continuity retains all owner records',pg_temp.rpc(u,'select public.get_my_continuity_v1()')->'value'->>'total'='4');

 -- Event cancellation retains the registration status; the existing reader's
 -- history filter uses registration status/date, while all retains this future row.
 perform pg_temp.ok('restored dormant cancelled future event retained in all',(pg_temp.rpc(u,format('select public.get_my_event_registrations_v2(%L,''all'')',t))->'value')::text like '%'||reg||'%');
 r:=pg_temp.rpc(a,format('select public.admin_cancel_event_v1(%L)',due_event));
 perform pg_temp.ok('restored dormant future closure remains available '||r::text,r->>'state'='00000' and r->'value'->>'code'='cancelled');
 foreach life in array array['dormant','suspended'] loop
  update public.tenants set status=life where id=t;
  perform pg_temp.ok('archive '||life,pg_temp.life(pa,t,'archive')->>'state'='00000');
  perform pg_temp.ok('restore '||life,pg_temp.life(pa,t,'restore')->>'state'='00000');
 end loop;
 perform pg_temp.ok('restore nonarchived denied',pg_temp.life(pa,t,'restore')->>'error'='TENANT_NOT_ARCHIVED');
end;$tests$;
select 'ok '||n||' - '||label from results order by n;
rollback;
