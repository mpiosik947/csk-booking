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
 empty_t uuid:=gen_random_uuid(); removed_pa uuid:=gen_random_uuid(); item record; baseline_result jsonb;
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

 insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online) values(lane,true,2);
 insert into public.lane_booking_durations(lane_id,duration_minutes,is_active)values(lane,60,true);
 insert into public.lane_booking_family_configuration_versions(root_lane_id)values(lane) on conflict do nothing;
 insert into public.event_lanes(event_id,lane_id,tenant_id)values(e,lane,t);
 insert into public.event_instructors(tenant_id,event_id,instructor_user_id,assigned_by)values(t,e,a,pa);
 insert into public.tenant_user_admin_notes(tenant_id,user_id,admin_note)values(t,u,'PRIVATE NOTE');
 insert into public.tenant_user_verifications(tenant_id,user_id)values(t,u) on conflict do nothing;
 insert into public.tenant_public_pricing_items(tenant_id,title,price,currency,unit,display_order,is_active)values(t,'Synthetic',10,'PLN','hour',1,true);
 insert into public.lane_blocks(tenant_id,lane_id,block_date,start_time,end_time,reason)values(t,lane,current_date+8,'10:00','11:00','Synthetic');
 insert into public.tenant_domains(tenant_id,hostname,domain_type,status)values(t,t||'.example.invalid','custom_domain','pending');
 insert into public.external_settlement_records(tenant_id,reservation_id,actor_user_id,idempotency_key,kind,amount,currency,external_reference)
 values(t,booking,pa,gen_random_uuid(),'external_refund',1,'PLN','PRIVATE FINANCIAL');
 insert into public.platform_tenant_creation_requests(actor_user_id,creation_request_id,payload_hash,tenant_id)values(pa,gen_random_uuid(),repeat('a',64),t);
 insert into public.platform_plan_change_requests(actor_user_id,change_request_id,tenant_id,payload,result)values(pa,gen_random_uuid(),t,'{}','{}');
 insert into public.platform_admin_management_requests(actor_user_id,request_id,tenant_id,payload,result)values(pa,gen_random_uuid(),t,'{}','{}');
 insert into public.audit_logs(tenant_id,action,target_type,target_id,details)values(t,'synthetic','reservation',booking,'{"secret":"PRIVATE AUDIT"}');
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t));
 perform pg_temp.ok('active tenant denied',r->'value'->'blockers' @> '[{"code":"TENANT_NOT_ARCHIVED"}]');
 perform pg_temp.ok('public flag denied',r->'value'->'blockers' @> '[{"code":"TENANT_PUBLIC"}]');
 perform pg_temp.ok('active PA allows aggregate reader',r->>'state'='00000');
 perform pg_temp.ok('anon denied',pg_temp.rpc(null,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t))->>'state'='42501');
 foreach life in array array['admin','employee','instructor','user'] loop
  update public.tenant_memberships set role=life where tenant_id=t and user_id=u;
  perform pg_temp.ok(life||' cannot read eligibility',pg_temp.rpc(u,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t))->>'state'='42501');
 end loop;
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA denied',pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t))->>'state'='42501');
 delete from public.platform_admins where user_id=pa;
 perform pg_temp.ok('removed PA denied',pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t))->>'state'='42501');
 insert into public.platform_admins(user_id,status)values(pa,'active');
 perform pg_temp.ok('missing tenant rejected',pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',gen_random_uuid()))->>'state'='22023');
 perform pg_temp.ok('null tenant rejected',pg_temp.rpc(pa,'select public.platform_get_tenant_delete_eligibility_v1(null)')->>'state'='22023');
 perform pg_temp.ok('archive fixture RPC',pg_temp.life(pa,t,'archive')->>'state'='00000');
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t))->'value';
 perform pg_temp.ok('archived not automatically eligible',r->'eligibility'->>'can_hard_delete'='false');
 perform pg_temp.ok('archived prerequisite satisfied',not(r->'blockers' @> '[{"code":"TENANT_NOT_ARCHIVED"}]'));
 perform pg_temp.ok('historical event counted',(r->'dependency_summary'->>'events')::int=3);
 perform pg_temp.ok('all reservations counted',(r->'dependency_summary'->>'reservations')::int=1);
 perform pg_temp.ok('real reminder lineage',(r->'dependency_summary'->>'reminder_occurrences')::int=2);
 perform pg_temp.ok('PII absent',not(r::text ~ 'PRIVATE|private@example|customer_name|customer_email|customer_phone|actor_user_id|target_id|hostname|verification_hash'));
 perform pg_temp.ok('root DTO allowlist',(select array_agg(k order by k) from jsonb_object_keys(r)k)=array['blockers','dependency_summary','eligibility','lifecycle','tenant','warnings']);
 perform pg_temp.ok('tenant DTO allowlist',(select array_agg(k order by k) from jsonb_object_keys(r->'tenant')k)=array['name','status','tenant_id']);
 perform pg_temp.ok('lifecycle DTO allowlist',(select array_agg(k order by k) from jsonb_object_keys(r->'lifecycle')k)=array['is_archived','is_public']);
 perform pg_temp.ok('eligibility DTO allowlist',(select array_agg(k order by k) from jsonb_object_keys(r->'eligibility')k)=array['blocker_count','can_hard_delete']);
 perform pg_temp.ok('all blockers aggregate',not exists(select 1 from jsonb_array_elements(r->'blockers') z where (select array_agg(k order by k) from jsonb_object_keys(z)k)<>array['category','code','count','hard_blocker'] or z->>'hard_blocker'<>'true' or (z->>'count')::bigint<1));
 perform pg_temp.ok('blocker count consistent',(r->'eligibility'->>'blocker_count')::int=jsonb_array_length(r->'blockers'));
 for item in select * from (values ('audit_logs','AUDIT_LOGS_EXIST'),('email_deliveries','EMAIL_HISTORY_EXISTS'),('event_instructors','EVENT_INSTRUCTORS_EXIST'),('event_lanes','EVENT_LANES_EXIST'),('event_registrations','EVENT_REGISTRATIONS_EXIST'),('events','EVENTS_EXIST'),('external_settlement_records','SETTLEMENTS_EXIST'),('lane_blocks','LANE_BLOCKS_EXIST'),('platform_admin_management_requests','PLATFORM_ADMIN_MANAGEMENT_REQUESTS_EXIST'),('platform_audit_logs','PLATFORM_AUDIT_EXISTS'),('platform_plan_change_requests','PLATFORM_PLAN_CHANGE_REQUESTS_EXIST'),('platform_tenant_creation_requests','CREATION_LEDGER_EXISTS'),('platform_tenant_lifecycle_requests','PLATFORM_TENANT_LIFECYCLE_REQUESTS_EXIST'),('reservations','RESERVATIONS_EXIST'),('shooting_lanes','SHOOTING_LANES_EXIST'),('tenant_domains','CUSTOM_DOMAIN_EXISTS'),('tenant_memberships','TENANT_MEMBERSHIPS_EXIST'),('tenant_plan_assignments','PLAN_ASSIGNMENT_EXISTS'),('tenant_public_pricing_items','TENANT_PUBLIC_PRICING_ITEMS_EXIST'),('tenant_public_profiles','TENANT_PUBLIC_PROFILES_EXIST'),('tenant_user_admin_notes','TENANT_USER_ADMIN_NOTES_EXIST'),('tenant_user_verifications','TENANT_USER_VERIFICATIONS_EXIST'),('lane_booking_durations','LANE_BOOKING_DURATIONS_EXIST'),('lane_booking_family_configuration_versions','LANE_BOOKING_FAMILY_CONFIGURATION_VERSIONS_EXIST'),('lane_booking_rules','LANE_BOOKING_RULES_EXIST'),('lane_pricing_rules','LANE_PRICING_RULES_EXIST'),('reminder_schedules','REMINDER_SCHEDULES_EXIST'),('reminder_occurrences','REMINDER_HISTORY_EXISTS')) c(tab,code) loop
  perform pg_temp.ok('dependency reported '||item.tab,(r->'dependency_summary'->>item.tab)::bigint>0 and exists(select 1 from jsonb_array_elements(r->'blockers') z where z->>'code'=item.code));
 end loop;
 perform pg_temp.ok('summary allowlist',(select array_agg(k order by k) from jsonb_object_keys(r->'dependency_summary') k)=array['audit_logs','email_deliveries','event_instructors','event_lanes','event_registrations','events','external_settlement_records','lane_blocks','lane_booking_durations','lane_booking_family_configuration_versions','lane_booking_rules','lane_pricing_rules','platform_admin_management_requests','platform_audit_logs','platform_plan_change_requests','platform_tenant_creation_requests','platform_tenant_lifecycle_requests','profile_links','reminder_occurrences','reminder_schedules','reservations','shooting_lanes','tenant_domains','tenant_memberships','tenant_plan_assignments','tenant_public_pricing_items','tenant_public_profiles','tenant_user_admin_notes','tenant_user_verifications']);
 baseline_result:=r;
 perform pg_temp.ok('deterministic result',baseline_result=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t))->'value');
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',b))->'value';
 perform pg_temp.ok('B does not inherit A business',(r->'dependency_summary'->>'reservations')::int=0 and (r->'dependency_summary'->>'events')::int=0 and (r->'dependency_summary'->>'reminder_occurrences')::int=0);
 perform pg_temp.ok('shared global user counted only as own links',(r->'dependency_summary'->>'profile_links')::int=1);
 insert into public.tenants(id,name,slug,status)values(empty_t,'Empty synthetic','pam1d-empty-'||empty_t,'archived');
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',empty_t))->'value';
 perform pg_temp.ok('minimal valid archived tenant exists',(select count(*)=1 from public.tenants where id=empty_t));
 perform pg_temp.ok('minimal tenant has zero dependency counts',not exists(select 1 from jsonb_each_text(r->'dependency_summary') where value::bigint<>0));
 perform pg_temp.ok('empty tenant still blocked by explicit deferred policy',r->'eligibility'->>'can_hard_delete'='false' and r->'blockers'='[{"code":"HARD_DELETE_POLICY_DEFERRED","category":"policy","count":1,"hard_blocker":true}]'::jsonb);
 perform pg_temp.ok('all direct FK tables classified',not exists(select 1 from pg_constraint c where c.contype='f' and c.confrelid='public.tenants'::regclass and c.conrelid::regclass::text<>all(array['audit_logs','email_deliveries','event_instructors','event_lanes','event_registrations','events','external_settlement_records','lane_blocks','platform_admin_management_requests','platform_audit_logs','platform_plan_change_requests','platform_tenant_creation_requests','platform_tenant_lifecycle_requests','reservations','shooting_lanes','tenant_domains','tenant_memberships','tenant_plan_assignments','tenant_public_pricing_items','tenant_public_profiles','tenant_user_admin_notes','tenant_user_verifications','lane_booking_durations','lane_booking_family_configuration_versions','lane_booking_rules','lane_pricing_rules','reminder_schedules','reminder_occurrences'])));
 perform pg_temp.ok('all tenant_id tables classified',not exists(select 1 from information_schema.columns where table_schema='public' and column_name='tenant_id' and table_name<>all(array['audit_logs','email_deliveries','event_instructors','event_lanes','event_registrations','events','external_settlement_records','lane_blocks','platform_admin_management_requests','platform_audit_logs','platform_plan_change_requests','platform_tenant_creation_requests','platform_tenant_lifecycle_requests','reservations','shooting_lanes','tenant_domains','tenant_memberships','tenant_plan_assignments','tenant_public_pricing_items','tenant_public_profiles','tenant_user_admin_notes','tenant_user_verifications','lane_booking_durations','lane_booking_family_configuration_versions','lane_booking_rules','lane_pricing_rules','reminder_schedules','reminder_occurrences'])));
 create table public.pam1d_unknown_fk(id uuid primary key,owner uuid references public.tenants(id));
 insert into public.pam1d_unknown_fk values(gen_random_uuid(),empty_t);
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',empty_t))->'value';
 perform pg_temp.ok('unknown direct FK fail closed',r->'blockers' @> '[{"code":"UNKNOWN_DEPENDENCY"}]' and r->'dependency_summary'='{}' and r->'eligibility'->>'can_hard_delete'='false');
 drop table public.pam1d_unknown_fk;
 create table public.pam1d_unknown_logical(tenant_id uuid);
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',empty_t))->'value';
 perform pg_temp.ok('unknown logical tenant_id fail closed',r->'blockers' @> '[{"code":"UNKNOWN_DEPENDENCY"}]');
 drop table public.pam1d_unknown_logical;
 create table public.pam1d_unknown_indirect(reservation_id uuid references public.reservations(id));
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',empty_t))->'value';
 perform pg_temp.ok('unknown indirect FK fail closed',r->'blockers' @> '[{"code":"UNKNOWN_DEPENDENCY"}]');
 drop table public.pam1d_unknown_indirect;
 perform pg_temp.ok('catalog restored',not((pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',empty_t))->'value'->'blockers') @> '[{"code":"UNKNOWN_DEPENDENCY"}]'));
 perform pg_temp.ok('read did not add audit or lifecycle rows',(select count(*)=0 from public.platform_audit_logs where tenant_id=empty_t) and (select count(*)=0 from public.platform_tenant_lifecycle_requests where tenant_id=empty_t));
 perform pg_temp.ok('function stable fixed definer postgres',(select provolatile='s' and prosecdef and pg_get_userbyid(proowner)='postgres' and proconfig=array['search_path=pg_catalog, public, pg_temp'] from pg_proc where oid='public.platform_get_tenant_delete_eligibility_v1(uuid)'::regprocedure));
 perform pg_temp.ok('authenticated execute only',has_function_privilege('authenticated','public.platform_get_tenant_delete_eligibility_v1(uuid)','EXECUTE') and not has_function_privilege('anon','public.platform_get_tenant_delete_eligibility_v1(uuid)','EXECUTE') and not has_function_privilege('service_role','public.platform_get_tenant_delete_eligibility_v1(uuid)','EXECUTE') and not exists(select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a where p.oid='public.platform_get_tenant_delete_eligibility_v1(uuid)'::regprocedure and a.grantee=0));
end;$tests$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
