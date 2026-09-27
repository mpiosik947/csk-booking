\set ON_ERROR_STOP on
begin;
create temp table email_context_results(label text) on commit drop;
create function pg_temp.email_assert(label text, ok boolean) returns void language plpgsql as $$begin
 if ok is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into email_context_results values(label);
end;$$;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
 lane uuid:=gen_random_uuid(); price uuid:=gen_random_uuid(); booking uuid:=gen_random_uuid();
 event_id uuid:=gen_random_uuid(); registration uuid:=gen_random_uuid(); r record; role_name text; failed boolean;
begin
 insert into public.tenants(id,slug,name,status) values(a,'email-a-'||a,'Email A','active'),(b,'email-b-'||b,'Email B','active');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public)
 values(a,'CSK Krutla','Test','email-public-a-'||a,false),(b,'Strzelnica Alfa','Test','email-public-b-'||b,false);
 insert into auth.users(id,email,email_confirmed_at) values(u,'email-'||u||'@example.invalid',now());
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(lane,a,'Synthetic','test',true,2,60,901,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
 values(price,lane,'mon_thu',1,2,'Synthetic',10,1,true);
 insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
 values(booking,u,a,lane,'Synthetic','test@example.invalid','000',current_date+7,'10:00','11:00',60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid());
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
 values(event_id,b,'Synthetic',current_date+7,'10:00','11:00','Test',0,10,true);
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(registration,b,event_id,u,'Synthetic','test@example.invalid','000','reserve','free');
 -- Typed identity: same UUID may denote different resources in different tables.
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
 values(booking,b,'Collision event',current_date+7,'12:00','13:00','Test',0,10,true);
 set local role service_role;
 select * into r from public.resolve_operational_email_tenant_context_v1('event',booking);
 reset role;
 perform pg_temp.email_assert('collision event X -> B',r.tenant_id=b);
 set local role service_role;
 select * into r from public.resolve_operational_email_tenant_context_v1('reservation',booking);
 reset role;
 perform pg_temp.email_assert('reservation A -> A and name',r.tenant_id=a and r.display_name='CSK Krutla');
 perform pg_temp.email_assert('collision reservation X -> A',r.tenant_id=a);
 perform pg_temp.email_assert('DTO exactly four fields',(select count(*)=4 from jsonb_object_keys(to_jsonb(r))));
 select * into r from public.resolve_operational_email_tenant_context_v1('event',event_id);
 perform pg_temp.email_assert('event B -> B',r.tenant_id=b and r.display_name='Strzelnica Alfa');
 select * into r from public.resolve_operational_email_tenant_context_v1('event_registration',registration);
 perform pg_temp.email_assert('waitlist B -> event B',r.tenant_id=b and r.public_slug='email-public-b-'||b);
 update public.tenants set status='suspended' where id=a;
 select * into r from public.resolve_operational_email_tenant_context_v1('reservation',booking);
 perform pg_temp.email_assert('suspended existing resource readable',r.tenant_id=a);
 perform set_config('app.product10d_test_enforce','on',true);
 failed:=false;
 begin
   insert into public.events(tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
   values(a,'Must fail',current_date+7,'10:00','11:00','Test',0,10,true);
 exception when insufficient_privilege then failed:=true; end;
 perform pg_temp.email_assert('suspended new business denied',failed);
 perform set_config('app.product10d_test_enforce','off',true);
 foreach role_name in array array['anon','authenticated'] loop
  failed:=false;
  begin execute format('set local role %I',role_name);
   perform * from public.resolve_operational_email_tenant_context_v1('reservation',booking);
  exception when insufficient_privilege then failed:=true; end;
  reset role;
  perform pg_temp.email_assert(role_name||' execution denied',failed);
 end loop;
 perform pg_temp.email_assert('PUBLIC execution denied',not has_function_privilege('public','public.resolve_operational_email_tenant_context_v1(text,uuid)','EXECUTE'));
 perform pg_temp.email_assert('service execution allowed',has_function_privilege('service_role','public.resolve_operational_email_tenant_context_v1(text,uuid)','EXECUTE'));
 perform pg_temp.email_assert('service direct profile SELECT still denied',not has_table_privilege('service_role','public.tenant_public_profiles','SELECT'));
 failed:=false; begin perform * from public.resolve_operational_email_tenant_context_v1('tenant',a);
 exception when invalid_parameter_value then failed:=true; end;
 perform pg_temp.email_assert('forged resource type denied',failed);
 failed:=false; begin perform * from public.resolve_operational_email_tenant_context_v1('reservation',event_id);
 exception when no_data_found then failed:=true; end;
 perform pg_temp.email_assert('wrong resource type/id no fallback',failed);
 failed:=false; begin perform * from public.resolve_operational_email_tenant_context_v1('event',gen_random_uuid());
 exception when no_data_found then failed:=true; end;
 perform pg_temp.email_assert('unknown/deleted id closed',failed);
 failed:=false; begin perform * from public.resolve_operational_email_tenant_context_v1('event',null);
 exception when invalid_parameter_value then failed:=true; end;
 perform pg_temp.email_assert('null id closed',failed);
 delete from public.tenant_public_profiles where tenant_id=b;
 failed:=false; begin perform * from public.resolve_operational_email_tenant_context_v1('event',event_id);
 exception when no_data_found then failed:=true; end;
 perform pg_temp.email_assert('missing profile closed',failed);
 delete from public.event_registrations where id=registration;
 failed:=false; begin perform * from public.resolve_operational_email_tenant_context_v1('event_registration',registration);
 exception when no_data_found then failed:=true; end;
 perform pg_temp.email_assert('deleted registration closed',failed);
end;$$;
\pset format unaligned
\pset tuples_only on
select 'ok '||row_number() over ()||' - '||label from email_context_results;
rollback;
