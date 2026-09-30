begin;
set local app.product10d_test_enforce = 'on';
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid();
  ea uuid := gen_random_uuid(); eb uuid := gen_random_uuid();
  ra uuid := gen_random_uuid(); rb uuid := gen_random_uuid();
  la uuid := gen_random_uuid(); lb uuid := gen_random_uuid();
  ba uuid := gen_random_uuid(); bb uuid := gen_random_uuid();
  pa uuid := gen_random_uuid(); pb uuid := gen_random_uuid();
  n integer; x text; dto jsonb;
begin
  update public.tenants set status='dormant' where status='active';
  insert into public.tenants(id,slug,name,status) values
    (a,'reader-a-'||a,'Reader A','active'),(b,'reader-b-'||b,'Reader B','active'),(c,'reader-c-'||c,'Reader C','active');
  insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public)
    values(a,'public-reader-a-'||a,'Reader A','Test',true),(b,'public-reader-b-'||b,'Reader B','Test',true);
  insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
    select t,id,'active' from public.saas_plans cross join unnest(array[a,b]) t where plan_key='current_full_v1';
  insert into auth.users(id,email) values(ua,ua||'@example.invalid'),(ub,ub||'@example.invalid');
  insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active)
    values(ea,a,'Event A',current_date+30,'10:00','11:00',true),(eb,b,'Event B',current_date+30,'10:00','11:00',true);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,registration_status,customer_name,customer_email,customer_phone)
    values(ra,a,ea,ua,'registered','A',ua||'@example.invalid','000'),(rb,b,eb,ub,'reserve','B',ub||'@example.invalid','000');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,resource_kind,whole_lane_bookable,positions_bookable)
    values(la,a,'Lane A','test',true,2,60,'lane',true,false),(lb,b,'Lane B','test',true,2,60,'lane',true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
    values(pa,la,'mon_thu',1,2,'Internal A',10,1,true),(pb,lb,'mon_thu',1,2,'Internal B',10,1,true);
  insert into public.reservations(id,tenant_id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,check_in_token,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
    values(ba,a,ua,la,'A',ua||'@example.invalid','000',current_date+30,'10:00','11:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,pa,'mon_thu','Lane A','Internal A',10,10,'PLN',gen_random_uuid()),
    (bb,b,ub,lb,'B',ub||'@example.invalid','000',current_date+30,'10:00','11:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,pb,'mon_thu','Lane B','Internal B',10,10,'PLN',gen_random_uuid());
  perform set_config('request.jwt.claim.sub',ua::text,true);
  for n in reverse 3..0 loop
    if n=2 then update public.tenants set status='dormant' where id=c; end if;
    if n=1 then update public.tenants set status='dormant' where id=b; end if;
    if n=0 then update public.tenants set status='dormant' where id=a; end if;
    if (public.read_owned_event_confirmation_v1(ra) is not null) is distinct from (n>0)
      or (public.read_owned_booking_confirmation_v1(ba) is not null) is distinct from (n>0) then
      raise exception 'Active tenant count % regression',n;
    end if;
    if public.read_owned_event_confirmation_v1(rb) is not null or public.read_owned_booking_confirmation_v1(bb) is not null then raise exception 'Cross-owner leak'; end if;
  end loop;
  update public.tenants set status='active' where id in(a,b,c);
  perform set_config('request.jwt.claim.sub',ub::text,true);
  if public.read_owned_event_confirmation_v1(rb)->>'title' is distinct from 'Event B' or public.read_owned_booking_confirmation_v1(bb)->>'lane_name' is distinct from 'Lane B' then raise exception 'Tenant B reader'; end if;
  perform set_config('request.jwt.claim.sub',ua::text,true);
  foreach x in array array['suspended','dormant'] loop
    update public.tenants set status=x where id=a;
    if public.read_owned_event_confirmation_v1(ra) is not null or public.read_owned_booking_confirmation_v1(ba) is not null then raise exception 'Lifecycle fail open'; end if;
  end loop;
  update public.tenants set status='active' where id=a;
  update public.events set is_active=false where id=ea;
  if public.read_owned_event_confirmation_v1(ra) is not null then raise exception 'Hidden event'; end if;
  update public.events set is_active=true where id=ea;
  update public.tenant_public_profiles set is_public=false where tenant_id=a;
  if public.read_owned_event_confirmation_v1(ra) is not null or public.read_owned_booking_confirmation_v1(ba) is not null then raise exception 'Unpublished tenant'; end if;
  update public.tenant_public_profiles set is_public=true where tenant_id=a;
  dto:=public.read_owned_event_confirmation_v1(ra);
  if dto - array['customer_name','registration_status','title','event_date','start_time','end_time','location','price'] <> '{}'::jsonb then raise exception 'Event DTO'; end if;
  dto:=public.read_owned_booking_confirmation_v1(ba);
  if dto - array['customer_name','reservation_status','reservation_date','start_time','end_time','price','check_in_token','lane_name'] <> '{}'::jsonb then raise exception 'Booking DTO'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  if public.read_owned_event_confirmation_v1(ra) is not null or public.read_owned_booking_confirmation_v1(ba) is not null then raise exception 'Missing actor'; end if;
  foreach x in array array['read_owned_event_confirmation_v1','read_owned_booking_confirmation_v1'] loop
    if has_function_privilege('anon','public.'||x||'(uuid)','EXECUTE') or has_function_privilege('service_role','public.'||x||'(uuid)','EXECUTE')
      or not has_function_privilege('authenticated','public.'||x||'(uuid)','EXECUTE') then raise exception 'ACL'; end if;
  end loop;
  raise notice 'OWNED CONFIRMATION READERS: count 0/1/2/3, ownership, lifecycle, hidden, public visibility, DTO, ACL PASS';
end $$;
rollback;
