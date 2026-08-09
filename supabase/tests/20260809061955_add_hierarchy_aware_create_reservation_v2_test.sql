\set ON_ERROR_STOP on

-- Run only with psql against the linked project. The migration and every
-- synthetic [TEST][6B-3B] fixture are enclosed in this transaction and are
-- removed by the final ROLLBACK.
begin;

create temporary table csk_6b3b_baseline (
  v1_definition_md5 text not null,
  v1_acl_md5 text not null
) on commit drop;

insert into pg_temp.csk_6b3b_baseline
select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  )),
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid =
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  ), ''));

do $clean_preflight$
begin
  if pg_catalog.to_regprocedure('public.lock_lane_conflict_family_v1(uuid)') is not null
     or pg_catalog.to_regprocedure(
       'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
     ) is not null
     or exists (select 1 from public.shooting_lanes where name like '[TEST][6B-3B]%')
     or exists (select 1 from public.events where title like '[TEST][6B-3B]%')
     or exists (select 1 from public.lane_blocks where reason like '[TEST][6B-3B]%')
     or exists (select 1 from public.reservations where reservation_note = '[TEST][6B-3B]')
     or exists (select 1 from auth.users where email like 'test-6b3b-%@example.invalid') then
    raise exception 'Unexpected prior 6B-3B objects or fixtures.';
  end if;
end;
$clean_preflight$;

\ir ../migrations/20260809061955_add_hierarchy_aware_create_reservation_v2.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(
  p_test_order integer,
  p_test_name text,
  p_passed boolean,
  p_result text
)
returns void
language sql
as $function$
  insert into pg_temp.test_results(test_order, test_name, passed, result)
  values (p_test_order, p_test_name, coalesce(p_passed, false), p_result);
$function$;

create function pg_temp.call_v2(
  p_user_id uuid,
  p_lane_id uuid,
  p_date date,
  p_start time without time zone,
  p_duration integer,
  p_shooters integer,
  p_request_id uuid
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.create_reservation_v2(
    p_lane_id, p_date, p_start, p_duration, p_shooters,
    p_request_id, '[TEST][6B-3B]'
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_v1(
  p_user_id uuid,
  p_lane_id uuid,
  p_date date,
  p_start time without time zone,
  p_duration integer,
  p_shooters integer,
  p_request_id uuid
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.create_reservation(
    p_lane_id, p_date, p_start, p_duration, p_shooters,
    p_request_id, '[TEST][6B-3B]'
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.authenticated_helper_blocked(p_lane_id uuid)
returns boolean
language plpgsql
as $function$
declare
  v_blocked boolean := false;
begin
  execute 'set local role authenticated';
  begin
    perform 1 from public.lock_lane_conflict_family_v1(p_lane_id);
  exception when insufficient_privilege then
    v_blocked := true;
  end;
  execute 'reset role';
  return v_blocked;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.helper_sqlstate(p_lane_id uuid)
returns text
language plpgsql
as $function$
begin
  perform 1 from public.lock_lane_conflict_family_v1(p_lane_id);
  return null;
exception when others then
  return sqlstate;
end;
$function$;

do $fixtures$
declare
  v_lane uuid;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    ('6b3b0000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b3b-1@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    ('6b3b0000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b3b-2@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    ('6b3b0000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b3b-3@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

  update public.profiles
  set role = 'user', first_name = '[TEST]', last_name = '6B-3B',
      full_name = '[TEST][6B-3B]', email = 'test-6b3b-profile@example.invalid',
      phone = '000000000', verification_status = 'verified'
  where user_id in (
    '6b3b0000-0000-4000-8000-000000000001',
    '6b3b0000-0000-4000-8000-000000000002',
    '6b3b0000-0000-4000-8000-000000000003'
  );

  if not found or (
    select pg_catalog.count(*) from public.profiles
    where user_id in (
      '6b3b0000-0000-4000-8000-000000000001',
      '6b3b0000-0000-4000-8000-000000000002',
      '6b3b0000-0000-4000-8000-000000000003'
    )
  ) <> 3 then
    raise exception 'Synthetic profiles were not created.';
  end if;

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values
    ('6b3b0000-0000-4000-8000-000000000101','[TEST][6B-3B][STANDALONE]','[TEST]','[TEST]',10,true,5,60,9901,'PLN','lane',null,true,false),
    ('6b3b0000-0000-4000-8000-000000000102','[TEST][6B-3B][PARENT]','[TEST]','[TEST]',10,true,5,60,9902,'PLN','lane',null,true,true),
    ('6b3b0000-0000-4000-8000-000000000103','[TEST][6B-3B][CHILD-1]','[TEST]','[TEST]',10,true,5,60,9911,'PLN','position','6b3b0000-0000-4000-8000-000000000102',false,false),
    ('6b3b0000-0000-4000-8000-000000000104','[TEST][6B-3B][CHILD-2]','[TEST]','[TEST]',10,true,5,60,9912,'PLN','position','6b3b0000-0000-4000-8000-000000000102',false,false),
    ('6b3b0000-0000-4000-8000-000000000105','[TEST][6B-3B][INACTIVE-PARENT]','[TEST]','[TEST]',10,false,5,60,9903,'PLN','lane',null,true,true),
    ('6b3b0000-0000-4000-8000-000000000106','[TEST][6B-3B][ACTIVE-CHILD-INACTIVE-PARENT]','[TEST]','[TEST]',10,true,5,60,9913,'PLN','position','6b3b0000-0000-4000-8000-000000000105',false,false),
    ('6b3b0000-0000-4000-8000-000000000107','[TEST][6B-3B][INACTIVE-CHILD]','[TEST]','[TEST]',10,false,5,60,9914,'PLN','position','6b3b0000-0000-4000-8000-000000000102',false,false),
    ('6b3b0000-0000-4000-8000-000000000108','[TEST][6B-3B][WHOLE-OFF]','[TEST]','[TEST]',10,true,5,60,9904,'PLN','lane',null,false,false),
    ('6b3b0000-0000-4000-8000-000000000109','[TEST][6B-3B][POSITIONS-OFF-PARENT]','[TEST]','[TEST]',10,true,5,60,9905,'PLN','lane',null,true,false),
    ('6b3b0000-0000-4000-8000-000000000110','[TEST][6B-3B][POSITIONS-OFF-CHILD]','[TEST]','[TEST]',10,true,5,60,9915,'PLN','position','6b3b0000-0000-4000-8000-000000000109',false,false),
    ('6b3b0000-0000-4000-8000-000000000111','[TEST][6B-3B][ONLINE-OFF]','[TEST]','[TEST]',10,true,5,60,9906,'PLN','lane',null,true,false),
    ('6b3b0000-0000-4000-8000-000000000112','[TEST][6B-3B][NO-RULE]','[TEST]','[TEST]',10,true,5,60,9907,'PLN','lane',null,true,false),
    ('6b3b0000-0000-4000-8000-000000000113','[TEST][6B-3B][NO-DURATION]','[TEST]','[TEST]',10,true,5,60,9908,'PLN','lane',null,true,false),
    ('6b3b0000-0000-4000-8000-000000000114','[TEST][6B-3B][NO-PRICING]','[TEST]','[TEST]',10,true,5,60,9909,'PLN','lane',null,true,false),
    ('6b3b0000-0000-4000-8000-000000000115','[TEST][6B-3B][CAPACITY]','[TEST]','[TEST]',10,true,5,60,9910,'PLN','lane',null,true,false);

  insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
  select lane.id, lane.id <> '6b3b0000-0000-4000-8000-000000000111'::uuid,
         case when lane.id = '6b3b0000-0000-4000-8000-000000000115'::uuid then 2 else lane.max_shooters end
  from public.shooting_lanes as lane
  where lane.name like '[TEST][6B-3B]%'
    and lane.id <> '6b3b0000-0000-4000-8000-000000000112'::uuid;

  insert into public.lane_booking_durations(lane_id, duration_minutes, display_order, is_active)
  select lane.id, 60, 1, true
  from public.shooting_lanes as lane
  where lane.name like '[TEST][6B-3B]%'
    and lane.id <> '6b3b0000-0000-4000-8000-000000000113'::uuid;

  for v_lane in
    select lane.id
    from public.shooting_lanes as lane
    where lane.name like '[TEST][6B-3B]%'
      and lane.id <> '6b3b0000-0000-4000-8000-000000000114'::uuid
  loop
    insert into public.lane_pricing_rules(
      lane_id, day_group, min_shooters, max_shooters,
      label, hourly_price, display_order, is_active
    ) values
      (v_lane,'mon_thu',1,5,'[TEST][6B-3B]',10,1,true),
      (v_lane,'fri_sun',1,5,'[TEST][6B-3B]',10,1,true);
  end loop;
end;
$fixtures$;

do $contract_tests$
declare
  v_date date := current_date + 6000;
  v_u1 constant uuid := '6b3b0000-0000-4000-8000-000000000001';
  v_u2 constant uuid := '6b3b0000-0000-4000-8000-000000000002';
  v_u3 constant uuid := '6b3b0000-0000-4000-8000-000000000003';
  v_parent constant uuid := '6b3b0000-0000-4000-8000-000000000102';
  v_child1 constant uuid := '6b3b0000-0000-4000-8000-000000000103';
  v_child2 constant uuid := '6b3b0000-0000-4000-8000-000000000104';
  v_result jsonb;
  v_result2 jsonb;
  v_created_id uuid;
  v_event_id uuid;
  v_v1_definition text;
  v_v2_definition text;
  v_helper_definition text;
begin
  v_result := pg_temp.call_v1(v_u1,'6b3b0000-0000-4000-8000-000000000101',v_date,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001001');
  v_result2 := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000101',v_date+1,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001002');
  perform pg_temp.record_result(1,'A. Standalone V1/V2 semantics equal',
    v_result->>'code'='created' and v_result2->>'code'='created'
    and (v_result-'reservation_id') = (v_result2-'reservation_id'),
    'Standalone V2 zachowuje publiczny kontrakt V1.');

  v_result := pg_temp.call_v2(v_u1,v_parent,v_date+10,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001010');
  v_result2 := pg_temp.call_v2(v_u2,v_child1,v_date+10,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001011');
  perform pg_temp.record_result(2,'B. Parent blocks child',v_result->>'code'='created' and v_result2->>'code'='slot_unavailable','Parent + child są jednym conflict scope.');

  v_result := pg_temp.call_v2(v_u1,v_child1,v_date+11,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001012');
  v_result2 := pg_temp.call_v2(v_u2,v_parent,v_date+11,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001013');
  perform pg_temp.record_result(3,'C. Child blocks parent',v_result->>'code'='created' and v_result2->>'code'='slot_unavailable','Child + parent są jednym conflict scope.');

  v_result := pg_temp.call_v2(v_u1,v_child1,v_date+12,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001014');
  v_result2 := pg_temp.call_v2(v_u2,v_child2,v_date+12,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001015');
  perform pg_temp.record_result(4,'D. Sibling children both allowed',v_result->>'code'='created' and v_result2->>'code'='created','Sibling nie należy do child conflict scope.');

  v_result := pg_temp.call_v2(v_u1,v_child1,v_date+13,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001016');
  v_result2 := pg_temp.call_v2(v_u2,v_child1,v_date+13,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001017');
  perform pg_temp.record_result(5,'E. Same child overlap rejected',v_result->>'code'='created' and v_result2->>'code'='slot_unavailable','Overlap exact lane jest odrzucony.');

  v_result := pg_temp.call_v2(v_u1,v_child1,v_date+14,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001018');
  v_result2 := pg_temp.call_v2(v_u2,v_child1,v_date+14,time '11:00',60,1,'6b3b0000-0000-4000-8000-000000001019');
  perform pg_temp.record_result(6,'F. Touching boundary allowed',v_result->>'code'='created' and v_result2->>'code'='created','[10,11) i [11,12) nie kolidują.');

  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_parent,v_date+20,time '10:00',time '11:00','[TEST][6B-3B][PARENT-BLOCK]',true);
  v_result := pg_temp.call_v2(v_u1,v_child1,v_date+20,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001020');
  perform pg_temp.record_result(7,'G. Parent block blocks child',v_result->>'code'='lane_blocked','Hierarchy-aware lane block konflikt.');

  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_child1,v_date+21,time '10:00',time '11:00','[TEST][6B-3B][CHILD-BLOCK]',true);
  v_result := pg_temp.call_v2(v_u1,v_parent,v_date+21,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001021');
  perform pg_temp.record_result(8,'H. Child block blocks parent',v_result->>'code'='lane_blocked','Parent scope obejmuje children.');

  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_child1,v_date+22,time '10:00',time '11:00','[TEST][6B-3B][SIBLING-BLOCK]',true);
  v_result := pg_temp.call_v2(v_u1,v_child2,v_date+22,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001022');
  perform pg_temp.record_result(9,'I. Sibling block does not block child',v_result->>'code'='created','Sibling block jest poza child scope.');

  insert into public.events(title,event_date,start_time,end_time,price,max_participants,is_active)
  values ('[TEST][6B-3B][PARENT-EVENT]',v_date+23,time '10:00',time '11:00',0,5,true) returning id into v_event_id;
  insert into public.event_lanes(event_id,lane_id) values(v_event_id,v_parent);
  v_result := pg_temp.call_v2(v_u1,v_child1,v_date+23,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001023');
  perform pg_temp.record_result(10,'J. Parent event blocks child',v_result->>'code'='slot_unavailable','Hierarchy-aware event konflikt.');

  insert into public.events(title,event_date,start_time,end_time,price,max_participants,is_active)
  values ('[TEST][6B-3B][CHILD-EVENT]',v_date+24,time '10:00',time '11:00',0,5,true) returning id into v_event_id;
  insert into public.event_lanes(event_id,lane_id) values(v_event_id,v_child1);
  v_result := pg_temp.call_v2(v_u1,v_parent,v_date+24,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001024');
  perform pg_temp.record_result(11,'K. Child event blocks parent',v_result->>'code'='slot_unavailable','Parent scope obejmuje child event.');

  insert into public.events(title,event_date,start_time,end_time,price,max_participants,is_active)
  values ('[TEST][6B-3B][SIBLING-EVENT]',v_date+25,time '10:00',time '11:00',0,5,true) returning id into v_event_id;
  insert into public.event_lanes(event_id,lane_id) values(v_event_id,v_child1);
  v_result := pg_temp.call_v2(v_u1,v_child2,v_date+25,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001025');
  perform pg_temp.record_result(12,'L. Sibling event does not block child',v_result->>'code'='created','Sibling event jest poza child scope.');

  insert into public.events(title,event_date,start_time,end_time,price,max_participants,is_active)
  values ('[TEST][6B-3B][GLOBAL-EVENT]',v_date+26,time '10:00',time '11:00',0,5,true);
  v_result := pg_temp.call_v2(v_u1,v_child1,v_date+26,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001026');
  perform pg_temp.record_result(13,'M. Global event ignored',v_result->>'code'='created','Event bez event_lanes nie blokuje.');

  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000105',v_date+30,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001030');
  perform pg_temp.record_result(14,'N. Inactive parent lane',v_result->>'code'='lane_inactive','Inactive requested parent jest odrzucony.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000107',v_date+31,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001031');
  perform pg_temp.record_result(15,'O. Inactive child',v_result->>'code'='lane_inactive','Inactive requested child jest odrzucony.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000106',v_date+32,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001032');
  perform pg_temp.record_result(16,'P. Child with inactive parent',v_result->>'code'='lane_inactive','Inactive parent childa jest odrzucony.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000108',v_date+33,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001033');
  perform pg_temp.record_result(17,'Q. Whole lane mode disabled',v_result->>'code'='lane_not_bookable','whole_lane_bookable=false jest kontrolowane.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000110',v_date+34,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001034');
  perform pg_temp.record_result(18,'R. Positions mode disabled',v_result->>'code'='lane_not_bookable','positions_bookable=false jest kontrolowane.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000111',v_date+35,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001035');
  perform pg_temp.record_result(19,'S. Online booking disabled',v_result->>'code'='lane_not_bookable','online_bookable=false jest kontrolowane.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000112',v_date+36,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001036');
  perform pg_temp.record_result(20,'T. Missing booking rule',v_result->>'code'='lane_not_bookable','Brak booking rule jest fail-closed.');

  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000115',v_date+37,time '10:00',60,2,'6b3b0000-0000-4000-8000-000000001037');
  perform pg_temp.record_result(21,'U. Shooters within online limit',v_result->>'code'='created','2/2 online jest dozwolone.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000115',v_date+38,time '10:00',60,3,'6b3b0000-0000-4000-8000-000000001038');
  perform pg_temp.record_result(22,'V. Above online limit requires contact',v_result->>'code'='contact_required','3 online przy limicie 2 wymaga kontaktu.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000115',v_date+39,time '10:00',60,6,'6b3b0000-0000-4000-8000-000000001039');
  perform pg_temp.record_result(23,'W. Above physical capacity',v_result->>'code'='capacity_exceeded','6 przy max 5 jest odrzucone.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000113',v_date+40,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001040');
  perform pg_temp.record_result(24,'X. Missing duration',v_result->>'code'='invalid_duration','Duration nie jest dziedziczone.');
  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000114',v_date+41,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001041');
  perform pg_temp.record_result(25,'Y. Missing pricing',v_result->>'code'='pricing_not_configured','Pricing nie jest dziedziczone.');

  v_result := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000101',v_date+42,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001042');
  v_created_id := (v_result->>'reservation_id')::uuid;
  v_result2 := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000101',v_date+42,time '10:00',60,1,'6b3b0000-0000-4000-8000-000000001042');
  perform pg_temp.record_result(26,'Z. Idempotent retry',v_result->>'code'='created' and v_result2->>'code'='already_created' and (v_result2->>'reservation_id')::uuid=v_created_id,'Retry zwraca ten sam rekord.');
  v_result2 := pg_temp.call_v2(v_u1,'6b3b0000-0000-4000-8000-000000000101',v_date+42,time '11:00',60,1,'6b3b0000-0000-4000-8000-000000001042');
  perform pg_temp.record_result(27,'AA. Idempotency conflict',v_result2->>'code'='idempotency_conflict','Ten sam request z innymi danymi jest odrzucony.');
  perform pg_temp.record_result(28,'AB. Audit exactly once',
    (select pg_catalog.count(*) from public.audit_logs where target_id=v_created_id and action='reservation_created')=1,
    'changed=true tworzy dokładnie jeden audit; retry nie tworzy drugiego.');
  perform pg_temp.record_result(29,'AC. Snapshots and pricing preserved',
    exists(select 1 from public.reservations where id=v_created_id and lane_name_snapshot='[TEST][6B-3B][STANDALONE]' and pricing_label_snapshot='[TEST][6B-3B]' and price_per_hour_snapshot=10 and total_price=10 and currency_code='PLN'),
    'Snapshoty requested resource są zachowane.');

  select pg_catalog.pg_get_functiondef('public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure) into v_v1_definition;
  perform pg_temp.record_result(30,'AD. Existing create_reservation unchanged',
    pg_catalog.md5(v_v1_definition)=(select v1_definition_md5 from pg_temp.csk_6b3b_baseline)
    and (select pg_catalog.md5(coalesce(pg_catalog.string_agg(privilege_record.grantee::text||':'||privilege_record.privilege_type,',' order by privilege_record.grantee,privilege_record.privilege_type),'')) from pg_catalog.pg_proc function_record cross join lateral pg_catalog.aclexplode(coalesce(function_record.proacl,pg_catalog.acldefault('f',function_record.proowner))) privilege_record where function_record.oid='public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure)=(select v1_acl_md5 from pg_temp.csk_6b3b_baseline),
    'V1 definition i ACL są identyczne.');

  perform pg_temp.record_result(31,'AE. V2 ACL',
    pg_catalog.has_function_privilege('authenticated','public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE')
    and pg_catalog.has_function_privilege('service_role','public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE')
    and not exists(select 1 from pg_catalog.pg_proc f cross join lateral pg_catalog.aclexplode(coalesce(f.proacl,pg_catalog.acldefault('f',f.proowner))) a where f.oid='public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'),
    'V2 EXECUTE wyłącznie authenticated/service_role spośród ról klienckich.');
  perform pg_temp.record_result(32,'AF. Helper ACL',
    pg_temp.authenticated_helper_blocked(v_parent)
    and not pg_catalog.has_function_privilege('anon','public.lock_lane_conflict_family_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.lock_lane_conflict_family_v1(uuid)','EXECUTE')
    and not exists(select 1 from pg_catalog.pg_proc f cross join lateral pg_catalog.aclexplode(coalesce(f.proacl,pg_catalog.acldefault('f',f.proowner))) a where f.oid='public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'),
    'Helper nie jest klientowym API.');

  select pg_catalog.lower(pg_catalog.pg_get_functiondef('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure)) into v_v2_definition;
  select pg_catalog.lower(pg_catalog.pg_get_functiondef('public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure)) into v_helper_definition;
  perform pg_temp.record_result(33,'AG. Security and root-first lock ordering',
    (select f.prosecdef and f.provolatile='v' and pg_catalog.pg_get_userbyid(f.proowner)='postgres' and f.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] from pg_catalog.pg_proc f where f.oid='public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure)
    and (select not f.prosecdef and f.provolatile='v' and pg_catalog.pg_get_userbyid(f.proowner)='postgres' and f.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] from pg_catalog.pg_proc f where f.oid='public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure)
    and pg_catalog.strpos(v_helper_definition,'where lane.id = p_lane_id') < pg_catalog.strpos(v_helper_definition,'where child.parent_lane_id = v_root_id')
    and v_helper_definition ~ 'where parent[.]id = v_root_id[[:space:]]+for share'
    and v_helper_definition ~ 'where lane[.]id = p_lane_id[[:space:]]+for update',
    'V2 jest SECURITY DEFINER, helper INVOKER, a locki są root-first.');
end;
$contract_tests$;

alter table public.shooting_lanes disable trigger validate_shooting_lane_hierarchy_trigger;
alter table public.shooting_lanes
  drop constraint shooting_lanes_resource_kind_check,
  drop constraint shooting_lanes_resource_parent_check,
  drop constraint shooting_lanes_parent_not_self_check;

do $malformed_hierarchy_test$
declare
  v_passed boolean := true;
begin
  v_passed := v_passed and pg_temp.helper_sqlstate(null)='22023';
  v_passed := v_passed and pg_temp.helper_sqlstate('6b3b0000-0000-4000-8000-000000009999')='P0002';

  update public.shooting_lanes set resource_kind='unknown'
  where id='6b3b0000-0000-4000-8000-000000000103';
  v_passed := v_passed and pg_temp.helper_sqlstate('6b3b0000-0000-4000-8000-000000000103')='55000';
  update public.shooting_lanes set resource_kind='position'
  where id='6b3b0000-0000-4000-8000-000000000103';

  update public.shooting_lanes set parent_lane_id=null
  where id='6b3b0000-0000-4000-8000-000000000103';
  v_passed := v_passed and pg_temp.helper_sqlstate('6b3b0000-0000-4000-8000-000000000103')='55000';
  update public.shooting_lanes set parent_lane_id='6b3b0000-0000-4000-8000-000000000102'
  where id='6b3b0000-0000-4000-8000-000000000103';

  update public.shooting_lanes set parent_lane_id=id
  where id='6b3b0000-0000-4000-8000-000000000103';
  v_passed := v_passed and pg_temp.helper_sqlstate('6b3b0000-0000-4000-8000-000000000103')='55000';
  update public.shooting_lanes set parent_lane_id='6b3b0000-0000-4000-8000-000000000102'
  where id='6b3b0000-0000-4000-8000-000000000103';

  update public.shooting_lanes
  set resource_kind='position',
      parent_lane_id='6b3b0000-0000-4000-8000-000000000101',
      whole_lane_bookable=false,
      positions_bookable=false
  where id='6b3b0000-0000-4000-8000-000000000102';
  v_passed := v_passed and pg_temp.helper_sqlstate('6b3b0000-0000-4000-8000-000000000103')='55000';

  perform pg_temp.record_result(34,'AH. Malformed hierarchy fails closed',v_passed,'NULL, missing, unknown kind, missing parent, self-parent and parent-position are rejected.');
end;
$malformed_hierarchy_test$;

select test_order, test_name, passed, result
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(test_order::text || ': ' || test_name, ', ' order by test_order)
  into v_failures
  from pg_temp.test_results
  where passed is false;

  if (select pg_catalog.count(*) from pg_temp.test_results) <> 34 then
    raise exception 'Expected exactly 34 contract controls.';
  end if;

  if v_failures is not null then
    raise exception '6B-3B contract tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure('public.lock_lane_conflict_family_v1(uuid)') is null
  and pg_catalog.to_regprocedure('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)') is null
  and pg_catalog.md5(pg_catalog.pg_get_functiondef('public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure))='3212b32f37ebc8e665a9a94e94260976'
  and not exists(select 1 from public.shooting_lanes where name like '[TEST][6B-3B]%')
  and not exists(select 1 from public.events where title like '[TEST][6B-3B]%')
  and not exists(select 1 from public.lane_blocks where reason like '[TEST][6B-3B]%')
  and not exists(select 1 from public.reservations where reservation_note='[TEST][6B-3B]')
  and not exists(select 1 from auth.users where email like 'test-6b3b-%@example.invalid')
  as rollback_confirmed;
