\set ON_ERROR_STOP on
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table results(n serial,label text,passed boolean) on commit drop;
create temporary table cleanup_ids(tenant uuid,other_tenant uuid,actor uuid,event uuid,registration uuid,lane uuid,price uuid,booking uuid) on commit drop;
create function pg_temp.check_result(label text,actual text,expected text)
returns void language plpgsql as $f$
begin
 insert into results(label,passed) values(label,actual=expected);
 if actual is distinct from expected then raise exception '%: expected %, got %',label,expected,actual; end if;
end;$f$;
create function pg_temp.call_cancel(actor uuid,call_sql text)
returns text language plpgsql as $f$
declare v jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',case when actor is null then 'anon' else 'authenticated' end)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 if actor is null then set local role anon; else set local role authenticated; end if;
 execute call_sql into v;
 reset role;
 perform set_config('request.jwt.claims','{}',true);
 perform set_config('request.jwt.claim.sub','',true);
 return case when v->>'changed'='true' then 'ALLOW'
   when v->>'ok'='false' and v->>'code' in ('not_allowed','unauthorized') then 'DENY'
   when v->>'ok'='false' then 'ERROR:'||coalesce(v->>'code','unknown') else 'UNCHANGED' end;
exception when others then
 reset role;
 perform set_config('request.jwt.claims','{}',true);
 perform set_config('request.jwt.claim.sub','',true);
 return sqlstate;
end;$f$;
do $test$
declare
 t uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
 e uuid:=gen_random_uuid(); r uuid:=gen_random_uuid(); lane uuid:=gen_random_uuid(); price uuid:=gen_random_uuid(); booking uuid:=gen_random_uuid();
 starts timestamp:=(transaction_timestamp() at time zone 'Europe/Warsaw')::date + time '10:00';
 kind text; call_sql text; member_status text; function_name text; definition text;
begin
 insert into cleanup_ids values(t,b,u,e,r,lane,price,booking);
 insert into auth.users(id,email) values(u,'p10e-cancel-'||u||'@example.invalid');
 insert into public.tenants(id,name,slug,status) values(t,'Synthetic cancellation','p10e-'||t,'active'),(b,'Synthetic other','p10e-'||b,'active');
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(t,u,'user','active'),(b,u,'admin','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select t,id,'active' from public.saas_plans where plan_key='current_full_v1';
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
 values(e,t,'Synthetic cancellation',starts::date,time '10:00',time '11:00','Synthetic',0,10,true);
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(r,t,e,u,'Synthetic','synthetic@example.invalid','000','registered','free');
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(lane,t,'Synthetic cancellation','test',true,2,60,900,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
 values(price,lane,'mon_thu',1,2,'Synthetic',10,1,true);
 insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
 values(booking,u,t,lane,'Synthetic','synthetic@example.invalid','000',starts::date,time '00:01',time '00:31',30,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid());
 foreach kind in array array['event','reservation'] loop
   call_sql:=case kind when 'event' then format('select public.cancel_event_registration_v2(%L,%L)',t,r) else format('select public.cancel_reservation(%L)',booking) end;
   update public.tenant_memberships set role='user',status='active' where tenant_id=t and user_id=u;
   update public.profiles set role='user' where user_id=u;
   perform pg_temp.check_result(kind||' user/global user cutoff',pg_temp.call_cancel(u,call_sql),'55000');
   update public.profiles set role='admin' where user_id=u;
   perform pg_temp.check_result(kind||' user/global admin cutoff',pg_temp.call_cancel(u,call_sql),'55000');
   update public.tenant_memberships set role='admin',status='active' where tenant_id=t and user_id=u;
   update public.profiles set role='user' where user_id=u;
   perform pg_temp.check_result(kind||' tenant admin/global user override',pg_temp.call_cancel(u,call_sql),'ALLOW');
   update public.event_registrations set registration_status='registered' where id=r;
   update public.reservations set reservation_status='confirmed' where id=booking;
   update public.tenant_memberships set role='employee' where tenant_id=t and user_id=u;
   perform pg_temp.check_result(kind||' employee/global user override',pg_temp.call_cancel(u,call_sql),'ALLOW');
   update public.event_registrations set registration_status='registered' where id=r;
   update public.reservations set reservation_status='confirmed' where id=booking;
   update public.profiles set role='admin' where user_id=u;
   foreach member_status in array array['pending','suspended'] loop
     update public.tenant_memberships set role='admin',status=member_status where tenant_id=t and user_id=u;
     perform pg_temp.check_result(kind||' membership '||member_status,pg_temp.call_cancel(u,call_sql),'42501');
   end loop;
   delete from public.tenant_memberships where tenant_id=t and user_id=u;
   perform pg_temp.check_result(kind||' admin only in other tenant',pg_temp.call_cancel(u,call_sql),'42501');
   perform pg_temp.check_result(kind||' anon',pg_temp.call_cancel(null,call_sql),'42501');
   insert into public.tenant_memberships(tenant_id,user_id,role,status) values(t,u,'user','active');
   update public.events set event_date=event_date+7 where id=e;
   update public.reservations set reservation_date=reservation_date+7 where id=booking;
   perform pg_temp.check_result(kind||' eligible owner/global admin',pg_temp.call_cancel(u,call_sql),'ALLOW');
   update public.event_registrations set registration_status='registered',user_id=null where id=r;
   update public.reservations set reservation_status='confirmed',user_id=null where id=booking;
   perform pg_temp.check_result(kind||' non-owner global admin',pg_temp.call_cancel(u,call_sql),'42501');
   update public.event_registrations set user_id=u where id=r;
   update public.reservations set user_id=u where id=booking;
   update public.reservations set reservation_date=starts::date where id=booking;
   update public.tenants set status='suspended' where id=t;
   perform pg_temp.check_result(kind||' suspension does not grant global-role override',pg_temp.call_cancel(u,call_sql),case kind when 'reservation' then '55000' else '42501' end);
   update public.tenants set status='active' where id=t;
   update public.events set event_date=starts::date where id=e;
   update public.reservations set reservation_date=starts::date where id=booking;
 end loop;
 update public.tenant_memberships set role='admin',status='active' where tenant_id=t and user_id=u;
 update public.profiles set role='user' where user_id=u;
 perform pg_temp.check_result('tenant admin/global user reservation payment',pg_temp.call_cancel(u,format('select public.update_reservation_payment(%L,''paid'')',booking)),'ALLOW');
 perform pg_temp.check_result('tenant admin/global user reservation note',pg_temp.call_cancel(u,format('select public.update_reservation_admin_note(%L,''Synthetic'')',booking)),'ALLOW');
 perform pg_temp.check_result('tenant admin/global user reservation attendance',pg_temp.call_cancel(u,format('select public.update_reservation_attendance(%L,''no_show'')',booking)),'ALLOW');
 perform pg_temp.check_result('tenant admin/global user event payment',pg_temp.call_cancel(u,format('select public.mark_event_registration_paid_v2(%L,%L)',t,r)),'ALLOW');
 perform pg_temp.check_result('tenant admin/global user event approval',pg_temp.call_cancel(u,format('select public.approve_event_registration_v2(%L,%L)',t,r)),'ALLOW');
 perform pg_temp.check_result('tenant admin/global user event deactivation',pg_temp.call_cancel(u,format('select public.admin_set_event_active_v3(%L,%L,false)',t,e)),'ALLOW');
 update public.tenant_memberships set role='user' where tenant_id=t and user_id=u;
 update public.profiles set role='admin' where user_id=u;
 perform pg_temp.check_result('tenant user/global admin cannot change payment',pg_temp.call_cancel(u,format('select public.update_reservation_payment(%L,''unpaid'')',booking)),'DENY');
 perform pg_temp.check_result('tenant user/global admin cannot change event state',pg_temp.call_cancel(u,format('select public.admin_set_event_active_v3(%L,%L,true)',t,e)),'DENY');
 foreach function_name in array array[
 'admin_create_lane_block__saas9d3a_core','admin_set_lane_block_active__saas9d3a_core','admin_update_lane_block__saas9d3a_core',
 'admin_set_event_active_v2__saas9d2b1_core','admin_update_event_v2__saas9d2b1_core',
 'approve_event_registration__saas9d2a_core','mark_event_registration_paid__saas9d2a_core',
 'update_reservation_admin_note__saas9d1_core','update_reservation_payment__saas9d1_core','update_reservation_attendance__saas9d1_core',
 'create_reservation_v2__saas9d1_core','get_check_in_reservation_v1__saas9d1_core','admin_list_event_registrations_v1__saas9d2a_core'
 ] loop
   select pg_get_functiondef(p.oid) into strict definition from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=function_name;
   perform pg_temp.check_result(function_name||' resource authority',case when position('public.get_my_tenant_role_v1(resource.tenant_id)' in definition)>0 and definition !~ '(profile|v_profile|v_actor_profile)[.]role' and exists(
     select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=function_name and not p.prosecdef
     and p.proconfig @> array['search_path=pg_catalog, public, pg_temp']
     and not has_function_privilege('authenticated',p.oid,'EXECUTE') and not has_function_privilege('anon',p.oid,'EXECUTE') and not has_function_privilege('service_role',p.oid,'EXECUTE')
   ) then 'PASS' else 'FAIL' end,'PASS');
 end loop;
 perform pg_temp.check_result('closed helper ACL',case when not exists(
   select 1 from unnest(array['anon','authenticated','service_role']) role_name
   cross join unnest(array['public.cancel_reservation__saas9d1_core(uuid)','public.cancel_event_registration__saas9d2a_core(uuid)']) signature
   where has_function_privilege(role_name,signature,'EXECUTE')) then 'PASS' else 'FAIL' end,'PASS');
 perform pg_temp.check_result('SECURITY DEFINER unchanged',case when (select count(*) from pg_proc where pronamespace='public'::regnamespace and prosecdef)=100 then 'PASS' else 'FAIL' end,'PASS');
end;$test$;
select '1..'||(count(*)+1) from results;
select 'ok '||n||' - '||label from results order by n;
select * from cleanup_ids
\gset fixture_
rollback;
with cleanup as (select
 (select count(*) from auth.users where id=:'fixture_actor'::uuid)+
 (select count(*) from public.profiles where user_id=:'fixture_actor'::uuid)+
 (select count(*) from public.tenants where id in(:'fixture_tenant'::uuid,:'fixture_other_tenant'::uuid))+
 (select count(*) from public.tenant_memberships where user_id=:'fixture_actor'::uuid)+
 (select count(*) from public.tenant_plan_assignments where tenant_id in(:'fixture_tenant'::uuid,:'fixture_other_tenant'::uuid))+
 (select count(*) from public.events where id=:'fixture_event'::uuid)+
 (select count(*) from public.event_registrations where id=:'fixture_registration'::uuid)+
 (select count(*) from public.shooting_lanes where id=:'fixture_lane'::uuid)+
 (select count(*) from public.lane_pricing_rules where id=:'fixture_price'::uuid)+
 (select count(*) from public.reservations where id=:'fixture_booking'::uuid)+
 (select count(*) from public.audit_logs where tenant_id=:'fixture_tenant'::uuid or actor_user_id=:'fixture_actor'::uuid)
 as remaining)
select case when remaining=0 then 'ok 46 - rollback cleanup across all fixture tables = 0' else 'not ok 46 - remaining fixtures='||remaining end from cleanup;
