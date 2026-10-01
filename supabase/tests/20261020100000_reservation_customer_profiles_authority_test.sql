\set ON_ERROR_STOP on
begin;
create temporary table rcp1_results (name text, passed boolean not null) on commit drop;
create function pg_temp.rcp1_check(p_name text, p_ok boolean) returns void language sql as $$
  insert into pg_temp.rcp1_results values (p_name, coalesce(p_ok, false));
$$;
create function pg_temp.rcp1_read(p_actor uuid, p_ids uuid[]) returns text language plpgsql as $$
declare v_count integer;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_actor::text,''),true);
  set local role authenticated;
  select count(*) into v_count from public.get_reservation_customer_profiles_v1(p_ids);
  reset role;
  perform set_config('request.jwt.claims','{}',true);
  perform set_config('request.jwt.claim.sub','',true);
  return 'rows='||v_count;
exception when others then
  reset role;
  perform set_config('request.jwt.claims','{}',true);
  perform set_config('request.jwt.claim.sub','',true);
  return sqlstate;
end;
$$;

do $test$
declare
  a uuid := 'c5c00000-0000-4000-8000-000000000001';
  b uuid := '7cc10000-0000-4000-8000-000000000001';
  actors uuid[] := array[
    '7cc10000-0000-4000-8000-000000000010','7cc10000-0000-4000-8000-000000000011',
    '7cc10000-0000-4000-8000-000000000012','7cc10000-0000-4000-8000-000000000013',
    '7cc10000-0000-4000-8000-000000000014','7cc10000-0000-4000-8000-000000000015',
    '7cc10000-0000-4000-8000-000000000016','7cc10000-0000-4000-8000-000000000017']::uuid[];
  roles text[] := array['admin','employee','instructor','user','admin','admin'];
  statuses text[] := array['active','active','active','active','suspended','pending'];
  lane_a uuid := '7cc10000-0000-4000-8000-000000000030';
  lane_b uuid := '7cc10000-0000-4000-8000-000000000031';
  price_a uuid := '7cc10000-0000-4000-8000-000000000032';
  price_b uuid := '7cc10000-0000-4000-8000-000000000033';
  res_a uuid := '7cc10000-0000-4000-8000-000000000040';
  res_b uuid := '7cc10000-0000-4000-8000-000000000041';
  missing uuid := '7cc10000-0000-4000-8000-000000000099';
  actor uuid;
  i integer;
begin
  insert into public.tenants(id,name,slug,status) values(b,'[TEST RCP1] B','test-rcp1-b','dormant');
  foreach actor in array actors loop
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
      values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.invalid','',now(),'{}','{}',now(),now());
    insert into public.profiles(id,user_id,email,full_name,phone,role,verification_status)
      values(actor,actor,actor||'@example.invalid','Synthetic RCP1','000','user','pending')
      on conflict(user_id) do update set full_name=excluded.full_name;
  end loop;
  -- Remove only these synthetic users' trigger-created memberships.
  delete from public.tenant_memberships where user_id=any(actors);
  for i in 1..6 loop
    insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,actors[i],roles[i],statuses[i]);
  end loop;
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(b,actors[8],'admin','active');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values
    (lane_a,a,'[TEST RCP1] A','test',true,2,60,9980,'PLN','lane',null,true,false),
    (lane_b,b,'[TEST RCP1] B','test',true,2,60,9981,'PLN','lane',null,true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price) values
    (price_a,lane_a,'mon_thu',1,2,'Synthetic A',10),(price_b,lane_b,'mon_thu',1,2,'Synthetic B',10);
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,check_in_token,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id) values
    (res_a,actors[4],a,lane_a,'Synthetic','rcp1@example.invalid','000',date '2099-10-10',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,price_a,'mon_thu','A','A',10,10,'PLN',gen_random_uuid()),
    (res_b,actors[8],b,lane_b,'Synthetic','rcp1@example.invalid','000',date '2099-10-11',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,price_b,'mon_thu','B','B',10,10,'PLN',gen_random_uuid());

  perform pg_temp.rcp1_check('A admin own tenant ALLOW',pg_temp.rcp1_read(actors[1],array[res_a])='rows=1');
  perform pg_temp.rcp1_check('B employee own tenant ALLOW',pg_temp.rcp1_read(actors[2],array[res_a])='rows=1');
  perform pg_temp.rcp1_check('C instructor DENY',pg_temp.rcp1_read(actors[3],array[res_a])='42501');
  perform pg_temp.rcp1_check('D user including reservation owner DENY',pg_temp.rcp1_read(actors[4],array[res_a])='42501');
  perform pg_temp.rcp1_check('E no membership DENY',pg_temp.rcp1_read(actors[7],array[res_a])='42501');
  perform pg_temp.rcp1_check('H suspended membership DENY',pg_temp.rcp1_read(actors[5],array[res_a])='42501');
  perform pg_temp.rcp1_check('I pending membership DENY',pg_temp.rcp1_read(actors[6],array[res_a])='42501');
  perform pg_temp.rcp1_check('J mixed tenant array DENY',pg_temp.rcp1_read(actors[1],array[res_a,res_b])='42501');
  perform pg_temp.rcp1_check('K missing ID DENY',pg_temp.rcp1_read(actors[1],array[missing])='42501');
  perform pg_temp.rcp1_check('K valid plus missing ID DENY',pg_temp.rcp1_read(actors[1],array[res_a,missing])='42501');
  perform pg_temp.rcp1_check('duplicate IDs invalid',pg_temp.rcp1_read(actors[1],array[res_a,res_a])='22023');
  perform pg_temp.rcp1_check('empty array invalid',pg_temp.rcp1_read(actors[1],array[]::uuid[])='22023');
  perform pg_temp.rcp1_check('null array invalid',pg_temp.rcp1_read(actors[1],null)='22023');
  perform pg_temp.rcp1_check('null item invalid',pg_temp.rcp1_read(actors[1],array[res_a,null])='22023');
  perform pg_temp.rcp1_check('oversized array invalid',pg_temp.rcp1_read(actors[1],array_fill(res_a,array[201]))='22023');
  perform pg_temp.rcp1_check('null auth identity DENY',pg_temp.rcp1_read(null,array[res_a])='42501');
  update public.profiles set role='admin' where user_id=actors[7];
  perform pg_temp.rcp1_check('profiles.role admin no membership DENY',pg_temp.rcp1_read(actors[7],array[res_a])='42501');
  perform pg_temp.rcp1_check('admin B cannot read A',pg_temp.rcp1_read(actors[8],array[res_a])='42501');

  -- Both tenants are active for the cross-tenant cases: denial must be membership-bound.
  update public.tenants set status='active' where id=b;
  perform pg_temp.rcp1_check('F admin A active reservation B DENY',pg_temp.rcp1_read(actors[1],array[res_b])='42501');
  perform pg_temp.rcp1_check('G employee A active reservation B DENY',pg_temp.rcp1_read(actors[2],array[res_b])='42501');
  perform pg_temp.rcp1_check('admin B own active B ALLOW',pg_temp.rcp1_read(actors[8],array[res_b])='rows=1');
  update public.tenants set status='dormant' where id=a;
  perform pg_temp.rcp1_check('dormant tenant membership DENY',pg_temp.rcp1_read(actors[1],array[res_a])='42501');
  update public.tenants set status='suspended' where id=b;
  perform pg_temp.rcp1_check('suspended tenant DENY unchanged',pg_temp.rcp1_read(actors[8],array[res_b])='42501');

  perform pg_temp.rcp1_check('definer owner search_path unchanged',exists(select 1 from pg_proc where oid='public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure and prosecdef and proowner='postgres'::regrole and proconfig=array['search_path=pg_catalog, public, pg_temp'] and provolatile='s'));
  perform pg_temp.rcp1_check('exact EXECUTE ACL unchanged',exists(select 1 from pg_proc where oid='public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure and proacl::text='{postgres=X/postgres,authenticated=X/postgres}'));
  perform pg_temp.rcp1_check('anon and service_role cannot execute',not has_function_privilege('anon','public.get_reservation_customer_profiles_v1(uuid[])','EXECUTE') and not has_function_privilege('service_role','public.get_reservation_customer_profiles_v1(uuid[])','EXECUTE'));
  perform pg_temp.rcp1_check('definer inventory unchanged',(select count(*)=135 from pg_proc where pronamespace='public'::regnamespace and prosecdef));
end;
$test$;
select case when passed then 'ok - ' else 'not ok - ' end||name from rcp1_results;
do $$ begin
  if (select count(*) from rcp1_results) <> 27 or exists(select 1 from rcp1_results where not passed) then
    raise exception 'SECURITY-FIX-RCP1 authority matrix failed';
  end if;
end; $$;
rollback;
