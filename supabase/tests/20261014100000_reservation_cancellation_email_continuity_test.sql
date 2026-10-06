\set ON_ERROR_STOP on
begin;
create temp table continuity_email_results(label text) on commit drop;
create function pg_temp.assert_email(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into continuity_email_results values(label);
end;$$;
create function pg_temp.call_email(actor uuid,statement text) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 set local role authenticated;
 execute statement into result;
 reset role;
 return jsonb_build_object('state','00000','value',result);
exception when others then reset role; return jsonb_build_object('state',sqlstate);
end;$$;

-- Separate owner fixture preserves ownership while the original actor changes role/status.
create function pg_temp.pam_keeper(t uuid) returns void language plpgsql as $keeper$
declare u uuid:=md5(t::text||':pam1b-test-keeper')::uuid;
begin
 insert into auth.users(id,email,email_confirmed_at) values(u,u||'@example.invalid',now()) on conflict(id) do nothing;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(t,u,'admin','active') on conflict(tenant_id,user_id) do nothing;
end;$keeper$;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); owner_a uuid:=gen_random_uuid();
 owner_b uuid:=gen_random_uuid(); staff_a uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 lane uuid:=gen_random_uuid(); price uuid:=gen_random_uuid(); booking uuid:=gen_random_uuid(); other_booking uuid:=gen_random_uuid();
 lane_b uuid:=gen_random_uuid(); price_b uuid:=gen_random_uuid(); booking_b uuid:=gen_random_uuid();
 actor uuid; tenant_state text; member_role text; member_status text; result jsonb; prepared jsonb; retry jsonb;
 key1 text; key2 text; failed boolean;
begin
 insert into public.tenants(id,slug,name,status) values(a,'10gb-a-'||a,'Synthetic A','active'),(b,'10gb-b-'||b,'Synthetic B','active');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public)
 values(a,'Synthetic A','Test','10gb-public-a-'||a,false),(b,'Synthetic B','Test','10gb-public-b-'||b,false);
 insert into auth.users(id,email,email_confirmed_at) select id,'10gb-'||id||'@example.invalid',now() from unnest(array[owner_a,owner_b,staff_a,outsider]) id;
 insert into public.profiles(id,user_id,email,first_name,last_name,full_name,role)
 select id,id,'10gb-'||id||'@example.invalid','Synthetic','Customer','Synthetic Customer','user'
 from unnest(array[owner_a,owner_b,staff_a,outsider]) id on conflict(user_id) do nothing;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,owner_a,'user','active'),(a,staff_a,'admin','active'),(b,owner_b,'user','active');
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(lane,a,'Synthetic lane','test',true,2,60,901,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
 values(price,lane,'mon_thu',1,2,'Synthetic',10,1,true);
 insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
 select id,owner_a,a,lane,'Synthetic Customer','customer@example.invalid','000',current_date+case when id=booking then 7 else 8 end,'10:00','11:00',60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid() from unnest(array[booking,other_booking]) id;

 result:=pg_temp.call_email(owner_a,format('select public.prepare_confirmation_email(%L,%L)','reservation_confirmation',other_booking));
 perform pg_temp.assert_email('active confirmation preserved',result->'value'->>'code'='ready');
 delete from public.email_deliveries where record_id=other_booking;
 foreach tenant_state in array array['active','suspended'] loop
  update public.tenants set status=tenant_state where id=a;
  foreach member_role in array array['owner','admin','employee'] loop
   actor:=case when member_role='owner' then owner_a else staff_a end;
   if member_role<>'owner' then perform pg_temp.pam_keeper(a);
 update public.tenant_memberships set role=member_role where tenant_id=a and user_id=staff_a; end if;
   update public.reservations set reservation_status='confirmed' where id=booking;
   result:=pg_temp.call_email(actor,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
   perform pg_temp.assert_email(tenant_state||' '||member_role||' un-cancelled read denied',result->>'state'='42501');
   result:=pg_temp.call_email(actor,format('select public.cancel_reservation(%L)',booking));
   perform pg_temp.assert_email(tenant_state||' '||member_role||' business cancellation',result->>'state'='00000' and (result->'value'->>'changed')::boolean);
   result:=pg_temp.call_email(actor,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
   perform pg_temp.assert_email(tenant_state||' '||member_role||' cancelled reader',result->>'state'='00000' and result->'value'->>'recipient_email'='customer@example.invalid');
   perform pg_temp.assert_email(tenant_state||' '||member_role||' minimal DTO',(select count(*)=7 from jsonb_object_keys(result->'value')));
   delete from public.email_deliveries where record_id=booking;
   prepared:=pg_temp.call_email(actor,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking));
   perform pg_temp.assert_email(tenant_state||' '||member_role||' claim ready',prepared->'value'->>'code'='ready');
   retry:=pg_temp.call_email(actor,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking));
   perform pg_temp.assert_email(tenant_state||' '||member_role||' live lease prevents send',retry->'value'->>'code'='in_progress');
   update public.email_deliveries set claim_expires_at=now()-interval '1 second' where record_id=booking;
   retry:=pg_temp.call_email(actor,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking));
   perform pg_temp.assert_email(tenant_state||' '||member_role||' retry key stable',retry->'value'->>'idempotency_key'=prepared->'value'->>'idempotency_key');
   set local role service_role;
   result:=public.complete_confirmation_email((retry->'value'->>'claim_id')::uuid,true,'synthetic-provider-id',null);
   reset role;
   perform pg_temp.assert_email(tenant_state||' '||member_role||' completion',result->>'code'='sent');
   result:=pg_temp.call_email(actor,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking));
   perform pg_temp.assert_email(tenant_state||' '||member_role||' sent prevents resend',result->'value'->>'code'='already_sent');
  end loop;
 end loop;

 -- Separate resource identity, not local booking attributes, supplies the key.
 update public.reservations set reservation_status='cancelled' where id=other_booking;
 delete from public.email_deliveries where record_id in(booking,other_booking);
 prepared:=pg_temp.call_email(owner_a,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking));
 result:=pg_temp.call_email(owner_a,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',other_booking));
 key1:=prepared->'value'->>'idempotency_key'; key2:=result->'value'->>'idempotency_key';
 perform pg_temp.assert_email('different reservations different provider keys',key1 is not null and key2 is not null and key1<>key2);
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(lane_b,b,'Synthetic lane','test',true,2,60,901,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
 values(price_b,lane_b,'mon_thu',1,2,'Synthetic',10,1,true);
 insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
 select booking_b,owner_b,b,lane_b,r.customer_name,'customer-b@example.invalid',r.customer_phone,r.reservation_date,r.start_time,r.end_time,r.duration_minutes,r.price,'cancelled',r.payment_status,r.attendance_status,r.shooters_count,price_b,r.pricing_day_group_snapshot,r.lane_name_snapshot,r.pricing_label_snapshot,r.price_per_hour_snapshot,r.total_price,r.currency_code,gen_random_uuid()
 from public.reservations r where r.id=booking;
 result:=pg_temp.call_email(owner_b,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking_b));
 key2:=result->'value'->>'idempotency_key';
 perform pg_temp.assert_email('tenant A versus tenant B provider keys cannot collide',result->'value'->>'code'='ready' and key1 is not null and key2 is not null and key1<>key2);
 result:=pg_temp.call_email(staff_a,format('select public.get_reservation_cancellation_email_v1(%L)',booking_b));
 perform pg_temp.assert_email('employee A cannot read cancelled reservation B',result->>'state'='42501');
 update public.tenant_memberships set role='admin' where user_id=staff_a;
 result:=pg_temp.call_email(staff_a,format('select public.get_reservation_cancellation_email_v1(%L)',booking_b));
 perform pg_temp.assert_email('admin A cannot read cancelled reservation B',result->>'state'='42501');
 update public.reservations set reservation_status='confirmed' where id=other_booking;
 foreach member_role in array array['admin','employee','user','instructor'] loop
  update public.tenant_memberships set role=member_role where tenant_id=a and user_id=staff_a;
  result:=pg_temp.call_email(owner_b,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
  perform pg_temp.assert_email('foreign user '||member_role||' reader denied',result->>'state'='42501');
  perform pg_temp.pam_keeper(b);
  delete from public.tenant_memberships where tenant_id=a and user_id=staff_a;
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(b,staff_a,member_role,'active');
  result:=pg_temp.call_email(staff_a,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
  perform pg_temp.assert_email('cross tenant '||member_role||' reader denied',result->>'state'='42501');
  result:=pg_temp.call_email(staff_a,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking));
  perform pg_temp.assert_email('cross tenant '||member_role||' claim denied',result->'value'->>'code'='not_found');
  delete from public.tenant_memberships where tenant_id=b and user_id=staff_a;
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,staff_a,member_role,'active');
 end loop;
 update public.tenant_memberships set role='admin' where user_id=staff_a;
 foreach member_status in array array['pending','suspended'] loop
  update public.tenant_memberships set status=member_status where user_id=staff_a;
  result:=pg_temp.call_email(staff_a,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
  perform pg_temp.assert_email(member_status||' staff denied',result->>'state'='42501');
 end loop;
 result:=pg_temp.call_email(outsider,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
 perform pg_temp.assert_email('no membership non-owner denied',result->>'state'='42501');
 result:=pg_temp.call_email(null,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
 perform pg_temp.assert_email('no identity denied',result->>'state'='42501');
 result:=pg_temp.call_email(owner_a,format('select public.get_reservation_cancellation_email_v1(%L)',gen_random_uuid()));
 perform pg_temp.assert_email('missing reservation denied',result->>'state'='42501');
 result:=pg_temp.call_email(owner_a,format('select public.prepare_confirmation_email(%L,%L)','reservation_confirmation',other_booking));
 perform pg_temp.assert_email('suspended confirmation denied',result->'value'->>'code'='not_found');
 perform set_config('app.product10d_test_enforce','on',true);
 failed:=false;
 begin insert into public.events(tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
 values(a,'must fail',current_date+7,'10:00','11:00','Test',0,10,true);
 exception when insufficient_privilege then failed:=true; end;
 perform pg_temp.assert_email('suspended new event denied',failed);
 failed:=false;
 begin
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  select gen_random_uuid(),r.user_id,r.tenant_id,r.lane_id,r.customer_name,r.customer_email,r.customer_phone,current_date+10,r.start_time,r.end_time,r.duration_minutes,r.price,'confirmed',r.payment_status,r.attendance_status,r.shooters_count,r.pricing_rule_id,r.pricing_day_group_snapshot,r.lane_name_snapshot,r.pricing_label_snapshot,r.price_per_hour_snapshot,r.total_price,r.currency_code,gen_random_uuid()
  from public.reservations r where r.id=other_booking;
 exception when insufficient_privilege then failed:=true; end;
 perform pg_temp.assert_email('suspended new reservation denied',failed);
 perform set_config('app.product10d_test_enforce','off',true);
 set local role service_role;
 result:=public.check_confirmation_email_rate_limit(owner_a,repeat('a',64));
 reset role;
 perform pg_temp.assert_email('suspended limiter callable',result->>'code'='allowed');
 update public.tenants set status='dormant' where id=a;
 result:=pg_temp.call_email(owner_a,format('select public.get_reservation_cancellation_email_v1(%L)',booking));
 perform pg_temp.assert_email('dormant denied',result->>'state'='42501');
 result:=pg_temp.call_email(owner_a,format('select public.prepare_confirmation_email(%L,%L)','reservation_cancellation',booking));
 perform pg_temp.assert_email('dormant claim denied',result->'value'->>'code'='not_found');
 foreach member_role in array array['public','anon','service_role'] loop
  perform pg_temp.assert_email(member_role||' reader execute denied',not has_function_privilege(member_role,'public.get_reservation_cancellation_email_v1(uuid)','EXECUTE'));
 end loop;
 foreach member_role in array array['public','anon','authenticated','service_role'] loop
  perform pg_temp.assert_email(member_role||' internal helper denied',not has_function_privilege(member_role,'public.can_authorize_reservation_cancellation_email_core_v1(uuid)','EXECUTE'));
 end loop;
 perform pg_temp.assert_email('authenticated reader execute',has_function_privilege('authenticated','public.get_reservation_cancellation_email_v1(uuid)','EXECUTE'));
 perform pg_temp.assert_email('safe reader search path',(select proconfig=array['search_path=pg_catalog, public, pg_temp'] from pg_proc where oid='public.get_reservation_cancellation_email_v1(uuid)'::regprocedure));
end;$$;
\pset format unaligned
\pset tuples_only on
select 'ok '||row_number() over ()||' - '||label from continuity_email_results;
rollback;
