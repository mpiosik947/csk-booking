\set ON_ERROR_STOP on
\pset format unaligned

select '1..20';
begin;
create temporary table saas9ec1_results(n integer primary key,label text,passed boolean) on commit drop;
create function pg_temp.ok(integer,text,boolean) returns void language sql as $$
  insert into pg_temp.saas9ec1_results values($1,$2,coalesce($3,false));
$$;
create function pg_temp.as_owner(p_actor uuid,p_sql text) returns jsonb language plpgsql as $$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_actor,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_actor::text,true);
  execute 'set local role authenticated';
  execute p_sql into v_result;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_result;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  raise;
end$$;

do $tests$
declare
  a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  b uuid:=pg_catalog.gen_random_uuid();
  owner_id uuid:=pg_catalog.gen_random_uuid();
  foreign_id uuid:=pg_catalog.gen_random_uuid();
  lane_a uuid:=pg_catalog.gen_random_uuid();
  lane_b uuid:=pg_catalog.gen_random_uuid();
  price_a uuid:=pg_catalog.gen_random_uuid();
  price_b uuid:=pg_catalog.gen_random_uuid();
  marker text:='[TEST][9E-C1]['||pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','')||']';
  reservations_a jsonb; reservations_b jsonb; events_a jsonb; events_b jsonb;
begin
  perform pg_temp.ok(1,'six versioned functions exist',
    (select count(*)=6 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in
      ('get_public_booking_configuration_v2','get_public_event_list_v3','get_public_event_availability_v2',
       'get_my_tenant_verification_v2','get_my_reservations_v3','get_my_event_registrations_v2')));
  perform pg_temp.ok(2,'six wrappers are stable postgres-owned definers with fixed search path',
    (select count(*)=6 and pg_catalog.bool_and(p.prosecdef and p.provolatile='s'
       and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where n.nspname='public' and p.proname in
      ('get_public_booking_configuration_v2','get_public_event_list_v3','get_public_event_availability_v2',
       'get_my_tenant_verification_v2','get_my_reservations_v3','get_my_event_registrations_v2')));
  perform pg_temp.ok(3,'owner lists are authenticated-only and not service-role callable',
    not pg_catalog.has_function_privilege('public','public.get_my_reservations_v3(uuid,integer,integer)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.get_my_reservations_v3(uuid,integer,integer)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_my_reservations_v3(uuid,integer,integer)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_my_reservations_v3(uuid,integer,integer)','EXECUTE')
    and not pg_catalog.has_function_privilege('public','public.get_my_event_registrations_v2(uuid,text,text,integer,integer)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.get_my_event_registrations_v2(uuid,text,text,integer,integer)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_my_event_registrations_v2(uuid,text,text,integer,integer)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_my_event_registrations_v2(uuid,text,text,integer,integer)','EXECUTE'));
  perform pg_temp.ok(4,'legacy owner-list signatures retained',
    pg_catalog.to_regprocedure('public.get_my_reservations_v2()') is not null
    and pg_catalog.to_regprocedure('public.get_my_event_registrations_v1(text,text,integer,integer)') is not null);
  perform pg_temp.ok(5,'definer inventory is 75 and retired bridge definitions are absent',
    (select count(*)=77 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)
    and (select count(*)=0 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosrc like '%active_single_tenant_id_v1%'));

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    label||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()
  from (values(owner_id,'9ec1-owner-'||pg_catalog.replace(owner_id::text,'-','')),
              (foreign_id,'9ec1-foreign-'||pg_catalog.replace(foreign_id::text,'-',''))) actor(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u
  left join public.profiles p on p.user_id=u.id
  where u.id in(owner_id,foreign_id) and p.user_id is null;
  insert into public.tenants(id,name,slug,status)
    values(b,marker||' B','test-9ec1-'||pg_catalog.left(pg_catalog.replace(b::text,'-',''),16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
    values(b,owner_id,'user','active');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,
    currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(lane_a,a,marker||' Lane A','test',true,2,60,9910,'PLN','lane',null,true,false),
    (lane_b,b,marker||' Lane B','test',true,2,60,9911,'PLN','lane',null,true,false);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)
    values(lane_a,true,2),(lane_b,true,2);
  insert into public.lane_booking_durations(lane_id,duration_minutes,display_order,is_active)
    values(lane_a,60,1,true),(lane_b,60,1,true);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
    values(price_a,lane_a,'mon_thu',1,2,'A',10,1,true),(price_b,lane_b,'mon_thu',1,2,'B',10,1,true);

  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,
    reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,
    attendance_status,check_in_token,shooters_count,pricing_rule_id,pricing_day_group_snapshot,
    lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  select pg_catalog.gen_random_uuid(),owner_id,tenant,lane,marker,'owner@example.invalid','000',
    date '2099-10-01'+n,time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',
    pg_catalog.gen_random_uuid(),1,price,'mon_thu','Lane','Test',10,10,'PLN',pg_catalog.gen_random_uuid()
  from (values(a,lane_a,price_a),(b,lane_b,price_b)) scope(tenant,lane,price)
  cross join pg_catalog.generate_series(1,8) n;

  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,
    price,max_participants,is_active)
  select pg_catalog.gen_random_uuid(),tenant,marker||' Event '||n,'Test',date '2099-11-01'+n,
    time '10:00',time '11:00','Test',0,10,true
  from (values(a),(b)) scope(tenant) cross join pg_catalog.generate_series(1,8) n;
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,
    customer_phone,registration_status,payment_status)
  select pg_catalog.gen_random_uuid(),e.tenant_id,e.id,owner_id,marker,'owner@example.invalid','000',
    'registered','pay_on_site'
  from public.events e where e.title like marker||' Event %';

  reservations_a:=pg_temp.as_owner(owner_id,pg_catalog.format(
    'select public.get_my_reservations_v3(%L::uuid,1,5)',a));
  events_a:=pg_temp.as_owner(owner_id,pg_catalog.format(
    'select public.get_my_event_registrations_v2(%L::uuid,''all'',null,1,5)',a));
  perform pg_temp.ok(6,'Tenant A reservation page contains five owner rows',
    reservations_a->>'ok'='true' and pg_catalog.jsonb_array_length(reservations_a->'items')=5);
  perform pg_temp.ok(7,'Tenant A reservation total excludes eight B rows',
    reservations_a#>>'{pagination,total}'='8');
  perform pg_temp.ok(8,'Tenant A reservation IDs belong only to A',
    not exists(select 1 from pg_catalog.jsonb_array_elements(reservations_a->'items') row
      join public.reservations r on r.id=(row->>'id')::uuid where r.tenant_id<>a));
  perform pg_temp.ok(9,'Tenant A event page contains five owner rows',
    events_a->>'ok'='true' and pg_catalog.jsonb_array_length(events_a->'items')=5);
  perform pg_temp.ok(10,'Tenant A event total excludes eight B rows',events_a#>>'{pagination,total}'='8');
  perform pg_temp.ok(11,'Tenant A event IDs belong only to A',
    not exists(select 1 from pg_catalog.jsonb_array_elements(events_a->'items') row
      join public.event_registrations r on r.id=(row->>'id')::uuid where r.tenant_id<>a));
  perform pg_temp.ok(12,'dormant B owner readers fail closed',
    pg_temp.as_owner(owner_id,pg_catalog.format('select public.get_my_reservations_v3(%L::uuid,1,5)',b))->>'code'='not_found'
    and pg_temp.as_owner(owner_id,pg_catalog.format(
      'select public.get_my_event_registrations_v2(%L::uuid,''all'',null,1,5)',b))->>'code'='not_found');
  perform pg_temp.ok(13,'foreign owner cannot see A reservation or event rows',
    pg_temp.as_owner(foreign_id,pg_catalog.format('select public.get_my_reservations_v3(%L::uuid,1,5)',a))#>>'{pagination,total}'='0'
    and pg_temp.as_owner(foreign_id,pg_catalog.format(
      'select public.get_my_event_registrations_v2(%L::uuid,''all'',null,1,5)',a))#>>'{pagination,total}'='0');
  perform pg_temp.ok(14,'reservation second page remains bounded',
    pg_temp.as_owner(owner_id,pg_catalog.format('select public.get_my_reservations_v3(%L::uuid,2,5)',a))#>>'{pagination,total}'='8'
    and pg_catalog.jsonb_array_length(pg_temp.as_owner(owner_id,pg_catalog.format(
      'select public.get_my_reservations_v3(%L::uuid,2,5)',a))->'items')=3);
  perform pg_temp.ok(15,'event second page remains bounded',
    pg_temp.as_owner(owner_id,pg_catalog.format(
      'select public.get_my_event_registrations_v2(%L::uuid,''all'',null,2,5)',a))#>>'{pagination,total}'='8'
    and pg_catalog.jsonb_array_length(pg_temp.as_owner(owner_id,pg_catalog.format(
      'select public.get_my_event_registrations_v2(%L::uuid,''all'',null,2,5)',a))->'items')=3);

  update public.tenants set status='dormant' where id=a;
  update public.tenants set status='active' where id=b;
  reservations_b:=pg_temp.as_owner(owner_id,pg_catalog.format(
    'select public.get_my_reservations_v3(%L::uuid,1,5)',b));
  events_b:=pg_temp.as_owner(owner_id,pg_catalog.format(
    'select public.get_my_event_registrations_v2(%L::uuid,''all'',null,1,5)',b));
  perform pg_temp.ok(16,'Tenant B reservation page and total exclude A',
    reservations_b#>>'{pagination,total}'='8' and pg_catalog.jsonb_array_length(reservations_b->'items')=5);
  perform pg_temp.ok(17,'Tenant B event page and total exclude A',
    events_b#>>'{pagination,total}'='8' and pg_catalog.jsonb_array_length(events_b->'items')=5);
  perform pg_temp.ok(18,'Tenant B rows carry only B IDs',
    not exists(select 1 from pg_catalog.jsonb_array_elements(reservations_b->'items') row
      join public.reservations r on r.id=(row->>'id')::uuid where r.tenant_id<>b)
    and not exists(select 1 from pg_catalog.jsonb_array_elements(events_b->'items') row
      join public.event_registrations r on r.id=(row->>'id')::uuid where r.tenant_id<>b));
  perform pg_temp.ok(19,'A becomes unavailable while B is active',
    pg_temp.as_owner(owner_id,pg_catalog.format('select public.get_my_reservations_v3(%L::uuid,1,5)',a))->>'code'='not_found');
  update public.tenants set status='dormant' where id=b;
  update public.tenants set status='active' where id=a;
  perform pg_temp.ok(20,'CSK active invariant restored before rollback',
    (select count(*)=1 from public.tenants where status='active' and id=a));
end $tests$;

select (case when passed then 'ok ' else 'not ok ' end)||n||' - '||label
from pg_temp.saas9ec1_results order by n;
do $$begin
  if (select count(*) from pg_temp.saas9ec1_results)<>20
     or exists(select 1 from pg_temp.saas9ec1_results where not passed) then
    raise exception 'SAAS-9E-C1 focused test failed';
  end if;
end$$;
rollback;
