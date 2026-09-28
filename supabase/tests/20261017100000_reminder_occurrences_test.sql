\set ON_ERROR_STOP on
begin;
create temp table reminder_checks(label text) on commit drop;
create function pg_temp.check_reminder(label text,ok boolean) returns void language plpgsql as $$begin
 if ok is distinct from true then raise exception 'FAIL: %',label; end if;
insert into reminder_checks values(label); end;$$;
create function pg_temp.reject_reminder_insert() returns trigger language plpgsql as $$begin
 if new.message_type in ('booking_reminder_24h','event_reminder_24h') then raise exception 'synthetic insert failure'; end if;
 return new; end;$$;
do $$
declare a uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); r uuid:=gen_random_uuid();
 lane uuid:=gen_random_uuid(); price uuid:=gen_random_uuid(); b uuid:=gen_random_uuid();
 start_local timestamp:=(statement_timestamp()+interval '20 hours') at time zone 'Europe/Warsaw';
 c jsonb; o1 uuid; o2 uuid; o3 uuid; cb jsonb; result jsonb; role_name text; fn text; state text;
begin
 -- Use a full hour and avoid the local midnight boundary for end_time.
 start_local:=date_trunc('hour',start_local);
 if start_local::time>time '22:00' then start_local:=start_local-interval '2 hours'; end if;
 insert into public.tenants(id,slug,name,status) values(a,'reminder-'||a,'Synthetic Range B','active');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public)
 values(a,'Synthetic Range B','Synthetic','public-reminder-'||a,false);
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select a,id,'active' from public.saas_plans where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at) values(u,'reminder-'||u||'@example.invalid',now());
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,u,'admin','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active,created_at)
 values(e,a,'Synthetic event',start_local::date,start_local::time,(start_local+interval '1 hour')::time,true,now()-interval '2 days');
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,created_at)
 values(r,a,e,u,'Synthetic','synthetic@example.invalid','000','registered','pending',now()-interval '2 days');
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(lane,a,'Synthetic lane','test',true,2,60,901,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
 values(price,lane,'mon_thu',1,2,'Synthetic',10,1,true);
 insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id,created_at)
 values(b,u,a,lane,'Synthetic','synthetic@example.invalid','000',start_local::date,start_local::time,(start_local+interval '1 hour')::time,60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid(),now()-interval '2 days');
 perform pg_temp.check_reminder('booking due',exists(select 1 from public.reminder_source_v1('booking_reminder_24h',b)));
 perform pg_temp.check_reminder('event due',exists(select 1 from public.reminder_source_v1('event_reminder_24h',r)));
 perform pg_temp.check_reminder('forged resource/type denied',not exists(select 1 from public.reminder_source_v1('booking_reminder_24h',r)));
 foreach role_name in array array['public','anon','authenticated'] loop
  foreach fn in array array['discover_reminders_v1()','claim_reminders_v1()','final_check_reminder_v1(uuid)','complete_reminder_v1(uuid,boolean,text)'] loop
   perform pg_temp.check_reminder(role_name||' deny '||fn,not has_function_privilege(role_name,'public.'||fn,'execute'));
  end loop;
 end loop;
 perform pg_temp.check_reminder('service execute',has_function_privilege('service_role','public.discover_reminders_v1()','execute'));
 perform pg_temp.check_reminder('no table grants',not has_table_privilege('service_role','public.reminder_occurrences','select'));
 perform pg_temp.check_reminder('legacy uniqueness preserved',exists(select 1 from pg_constraint where conrelid='public.email_deliveries'::regclass and conname='email_deliveries_message_record_key' and contype='u'));
 create trigger reminder_test_failure before insert on public.email_deliveries for each row execute function pg_temp.reject_reminder_insert();
 begin
  perform public.discover_reminders_v1();
  raise exception 'Expected insert failure did not occur';
 exception when others then
  if sqlerrm <> 'synthetic insert failure' then raise; end if;
 end;
 perform pg_temp.check_reminder('failed delivery insert rolls occurrence back',not exists(select 1 from public.reminder_occurrences where reservation_id=b or registration_id=r));
 drop trigger reminder_test_failure on public.email_deliveries;
 perform public.discover_reminders_v1();
 select id into o1 from public.reminder_occurrences where registration_id=r;
 perform pg_temp.check_reminder('two occurrence deliveries atomic',(select count(*)=2 from public.email_deliveries where record_id in(select id from public.reminder_occurrences where reservation_id=b or registration_id=r)));
 perform public.discover_reminders_v1();
 perform pg_temp.check_reminder('discovery idempotent',(select count(*)=1 from public.reminder_occurrences where registration_id=r));
 c:=public.claim_reminders_v1();
 select value into cb from jsonb_array_elements(c) where value->>'occurrence_id'=o1::text;
 result:=public.final_check_reminder_v1((cb->>'claim_id')::uuid);
 perform pg_temp.check_reminder('tenant B source binding',result->>'display_name'='Synthetic Range B' and result->>'recipient'='synthetic@example.invalid');
 perform pg_temp.check_reminder('claim one active',jsonb_array_length(public.claim_reminders_v1())=0);
 update public.events set start_time=(start_local-interval '1 hour')::time where id=e;
 perform pg_temp.check_reminder('A1 final denied',public.final_check_reminder_v1((cb->>'claim_id')::uuid) is null);
 perform public.discover_reminders_v1();
 select id into o2 from public.reminder_occurrences where registration_id=r and generation=2;
 perform pg_temp.check_reminder('B1 new identity',o2 is not null and o2<>o1);
 c:=public.claim_reminders_v1(); select value into cb from jsonb_array_elements(c) where value->>'occurrence_id'=o2::text;
 perform public.complete_reminder_v1((cb->>'claim_id')::uuid,false,null);
 c:=public.claim_reminders_v1(); select value into result from jsonb_array_elements(c) where value->>'occurrence_id'=o2::text;
 perform pg_temp.check_reminder('retry same provider key',result->>'idempotency_key'=cb->>'idempotency_key');
 perform public.complete_reminder_v1((result->>'claim_id')::uuid,true,'synthetic-provider');
 update public.email_deliveries set updated_at=now()-interval '91 days' where record_id=o2;
 perform public.purge_reminder_deliveries_v1(); perform public.discover_reminders_v1();
 perform pg_temp.check_reminder('purge tombstone retained',exists(select 1 from public.reminder_occurrences where id=o2));
 perform pg_temp.check_reminder('purged delivery cannot recreate',not exists(select 1 from public.email_deliveries where record_id=o2));
 update public.events set start_time=start_local::time where id=e; perform public.discover_reminders_v1();
 select id into o3 from public.reminder_occurrences where registration_id=r and generation=3;
 perform pg_temp.check_reminder('A B A creates A2',o3 is not null and o3<>o1 and o3<>o2);
 c:=public.claim_reminders_v1(); select value into cb from jsonb_array_elements(c) where value->>'occurrence_id'=o3::text;
 update public.event_registrations set registration_status='cancelled' where id=r;
 perform pg_temp.check_reminder('cancel before final denies',public.final_check_reminder_v1((cb->>'claim_id')::uuid) is null);
 select claim_id::text into state from public.email_deliveries where message_type='booking_reminder_24h' and recipient_user_id=u;
 update public.reservations set reservation_status='cancelled' where id=b;
 perform pg_temp.check_reminder('booking cancel before final denies',public.final_check_reminder_v1(state::uuid) is null);
 update public.reservations set reservation_status='confirmed' where id=b;
 update public.event_registrations set registration_status='registered' where id=r;
 update public.tenants set status='suspended' where id=a;
 perform pg_temp.check_reminder('suspended booking allowed',exists(select 1 from public.reminder_source_v1('booking_reminder_24h',b)));
 perform pg_temp.check_reminder('suspended event allowed',exists(select 1 from public.reminder_source_v1('event_reminder_24h',r)));
 foreach state in array array['dormant'] loop
  update public.tenants set status=state where id=a;
  perform pg_temp.check_reminder(state||' denied',not exists(select 1 from public.reminder_source_v1('event_reminder_24h',r)) and not exists(select 1 from public.reminder_source_v1('booking_reminder_24h',b)));
 end loop;
 update public.tenants set status='active' where id=a;
 update public.event_registrations set registration_status='reserve' where id=r;
 perform pg_temp.check_reminder('reserve denied',not exists(select 1 from public.reminder_source_v1('event_reminder_24h',r)));
 update public.event_registrations set registration_status='registered',created_at=now() where id=r;
 update public.reservations set created_at=now() where id=b;
 perform pg_temp.check_reminder('created inside cutoff denied',not exists(select 1 from public.reminder_source_v1('event_reminder_24h',r)) and not exists(select 1 from public.reminder_source_v1('booking_reminder_24h',b)));
 update public.event_registrations set created_at=now()-interval '2 days' where id=r;
 update public.events set event_date=current_date-1 where id=e;
 perform pg_temp.check_reminder('past denied',not exists(select 1 from public.reminder_source_v1('event_reminder_24h',r)));
 perform pg_temp.check_reminder('spring DST elapsed 23h',('2027-03-28 12:00'::timestamp at time zone 'Europe/Warsaw')-('2027-03-27 12:00'::timestamp at time zone 'Europe/Warsaw')=interval '23 hours');
 perform pg_temp.check_reminder('autumn DST elapsed 25h',('2027-10-31 12:00'::timestamp at time zone 'Europe/Warsaw')-('2027-10-30 12:00'::timestamp at time zone 'Europe/Warsaw')=interval '25 hours');
 perform pg_temp.check_reminder('registry no PII columns',not exists(select 1 from information_schema.columns where table_name in ('reminder_schedules','reminder_occurrences') and column_name in ('recipient','email','body','token','user_id')));
 -- Deadline/batch retry are tested on a fresh schedule generation.
 update public.events set event_date=start_local::date,start_time=start_local::time where id=e;
 perform public.discover_reminders_v1();
 for result in select value from jsonb_array_elements(public.claim_reminders_v1()) loop
  perform public.complete_reminder_v1((result->>'claim_id')::uuid,false,null);
 end loop;
 for result in select value from jsonb_array_elements(public.claim_reminders_v1()) loop
  perform public.complete_reminder_v1((result->>'claim_id')::uuid,false,null);
 end loop;
 c:=public.claim_reminders_v1();
 select value into cb from jsonb_array_elements(c) where value->>'occurrence_id' in (select id::text from public.reminder_occurrences where registration_id=r);
 perform pg_temp.check_reminder('third attempt available',cb is not null);
 update public.email_deliveries set claim_expires_at=now()-interval '1 second' where claim_id=(cb->>'claim_id')::uuid;
 perform pg_temp.check_reminder('fourth attempt denied',jsonb_array_length(public.claim_reminders_v1())=0);
 perform pg_temp.check_reminder('exhausted lease terminal',(select delivery_state='failed' and attempt_count=3 from public.email_deliveries where record_id=(cb->>'occurrence_id')::uuid));
 foreach state in array array['30 minutes','1 hour','25 hours'] loop
  update public.events set event_date=((statement_timestamp()+state::interval) at time zone 'Europe/Warsaw')::date,
   start_time=((statement_timestamp()+state::interval) at time zone 'Europe/Warsaw')::time,end_time='23:59:59.999999' where id=e;
  update public.reservations set reservation_date=((statement_timestamp()+state::interval) at time zone 'Europe/Warsaw')::date,
   start_time=((statement_timestamp()+state::interval) at time zone 'Europe/Warsaw')::time,end_time='23:59:59.999999',created_at=now()-interval '3 days' where id=b;
  perform pg_temp.check_reminder('window denied '||state,not exists(select 1 from public.reminder_source_v1('event_reminder_24h',r)) and not exists(select 1 from public.reminder_source_v1('booking_reminder_24h',b)));
 end loop;
 update public.event_registrations set pii_anonymized_at=now() where id=r;
 perform pg_temp.check_reminder('anonymization retains tombstone',exists(select 1 from public.reminder_occurrences where registration_id=r));
 delete from public.event_registrations where id=r;
 perform pg_temp.check_reminder('resource deletion removes tombstone',not exists(select 1 from public.reminder_occurrences where registration_id=r));
end;$$;
select 'REMINDER_SQL_PASS='||count(*) from reminder_checks;
rollback;
