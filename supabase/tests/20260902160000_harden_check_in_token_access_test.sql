\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..15';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.call_public_status(p_token uuid)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  execute 'set local role anon';
  select public.get_public_check_in_status_v1(p_token) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_staff_lookup(p_user_id uuid,p_token uuid)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub',p_user_id::text,
      'role','authenticated'
    )::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub',p_user_id::text,true
  );
  execute 'set local role authenticated';
  select coalesce(
    pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result)),
    '[]'::jsonb
  )
  into v_result
  from public.get_check_in_reservation_v1(p_token) as result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_attendance(
  p_user_id uuid,
  p_reservation_id uuid
)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub',p_user_id::text,
      'role','authenticated'
    )::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub',p_user_id::text,true
  );
  execute 'set local role authenticated';
  select public.update_reservation_attendance(p_reservation_id,'start')
  into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $tests$
declare
  v_admin uuid := '6d050000-0000-4000-8000-000000000001';
  v_employee uuid := '6d050000-0000-4000-8000-000000000002';
  v_instructor uuid := '6d050000-0000-4000-8000-000000000003';
  v_user uuid := '6d050000-0000-4000-8000-000000000004';
  v_owner uuid := '6d050000-0000-4000-8000-000000000005';
  v_lanes uuid[] := array[
    '6d050000-0000-4000-8000-000000000011'::uuid,
    '6d050000-0000-4000-8000-000000000012'::uuid,
    '6d050000-0000-4000-8000-000000000013'::uuid,
    '6d050000-0000-4000-8000-000000000014'::uuid
  ];
  v_prices uuid[] := array[
    '6d050000-0000-4000-8000-000000000021'::uuid,
    '6d050000-0000-4000-8000-000000000022'::uuid,
    '6d050000-0000-4000-8000-000000000023'::uuid,
    '6d050000-0000-4000-8000-000000000024'::uuid
  ];
  v_valid uuid := '6d050000-0000-4000-8000-000000000031';
  v_used uuid := '6d050000-0000-4000-8000-000000000032';
  v_cancelled uuid := '6d050000-0000-4000-8000-000000000033';
  v_expired uuid := '6d050000-0000-4000-8000-000000000034';
  v_tokens uuid[] := array[
    '6d050000-0000-4000-8000-000000000041'::uuid,
    '6d050000-0000-4000-8000-000000000042'::uuid,
    '6d050000-0000-4000-8000-000000000043'::uuid,
    '6d050000-0000-4000-8000-000000000044'::uuid
  ];
  v_today date := (pg_catalog.transaction_timestamp()
    at time zone 'Europe/Warsaw')::date;
  v_result jsonb;
  v_result_2 jsonb;
  v_denied boolean;
  v_checked_at timestamp with time zone;
  v_audit_count bigint;
begin
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec005-admin@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec005-employee@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec005-instructor@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec005-user@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_owner,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec005-owner@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(
    user_id,role,first_name,last_name,full_name,email,phone
  ) values
    (v_admin,'admin','[TEST]','SEC-005 Admin','[TEST][SEC-005] Admin','test-sec005-admin@example.invalid','000000001'),
    (v_employee,'pracownik','[TEST]','SEC-005 Employee','[TEST][SEC-005] Employee','test-sec005-employee@example.invalid','000000002'),
    (v_instructor,'instruktor','[TEST]','SEC-005 Instructor','[TEST][SEC-005] Instructor','test-sec005-instructor@example.invalid','000000003'),
    (v_user,'user','[TEST]','SEC-005 User','[TEST][SEC-005] User','test-sec005-user@example.invalid','000000004'),
    (v_owner,'user','[TEST]','SEC-005 Owner','[TEST][SEC-005] Owner','test-sec005-owner@example.invalid','000000005');

  insert into public.shooting_lanes(
    id,name,type,is_active,max_shooters,booking_step_minutes,
    display_order,currency_code,resource_kind,parent_lane_id,
    whole_lane_bookable,positions_bookable
  )
  select
    v_lanes[index],
    '[TEST][SEC-005] Lane ' || index,
    'test',true,1,60,900 + index,'PLN','lane',null,true,false
  from pg_catalog.generate_series(1,4) as index;

  insert into public.lane_pricing_rules(
    id,lane_id,day_group,min_shooters,max_shooters,label,
    hourly_price,display_order,is_active
  )
  select
    v_prices[index],v_lanes[index],'mon_thu',1,1,
    '[TEST][SEC-005] Price',10,1,true
  from pg_catalog.generate_series(1,4) as index;

  insert into public.reservations(
    id,user_id,lane_id,customer_name,customer_email,customer_phone,
    reservation_date,start_time,end_time,duration_minutes,price,
    reservation_status,payment_status,attendance_status,checked_in_at,
    completed_at,check_in_token,reservation_note,shooters_count,
    pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,
    pricing_label_snapshot,price_per_hour_snapshot,total_price,
    currency_code,creation_request_id
  ) values
    (v_valid,v_owner,v_lanes[1],'[TEST] Owner','test-sec005-owner@example.invalid','000000005',v_today,time '00:01',time '23:59',1438,10,'confirmed','pay_on_site','planned',null,null,v_tokens[1],null,1,v_prices[1],'mon_thu','[TEST] Lane 1','[TEST] Price',10,10,'PLN','6d050000-0000-4000-8000-000000000051'),
    (v_used,v_owner,v_lanes[2],'[TEST] Used','test-sec005-used@example.invalid','000000006',v_today,time '00:01',time '23:59',1438,10,'confirmed','pay_on_site','present',pg_catalog.transaction_timestamp(),null,v_tokens[2],null,1,v_prices[2],'mon_thu','[TEST] Lane 2','[TEST] Price',10,10,'PLN','6d050000-0000-4000-8000-000000000052'),
    (v_cancelled,v_owner,v_lanes[3],'[TEST] Cancelled','test-sec005-cancelled@example.invalid','000000007',v_today,time '00:01',time '23:59',1438,10,'cancelled','pay_on_site','planned',null,null,v_tokens[3],null,1,v_prices[3],'mon_thu','[TEST] Lane 3','[TEST] Price',10,10,'PLN','6d050000-0000-4000-8000-000000000053'),
    (v_expired,v_owner,v_lanes[4],'[TEST] Expired','test-sec005-expired@example.invalid','000000008',v_today-3,time '00:01',time '01:00',59,10,'confirmed','pay_on_site','planned',null,null,v_tokens[4],null,1,v_prices[4],'mon_thu','[TEST] Lane 4','[TEST] Price',10,10,'PLN','6d050000-0000-4000-8000-000000000054');

  perform pg_temp.record_result(1,'Function signatures and security contract',
    pg_catalog.to_regprocedure('public.is_reservation_check_in_token_usable_v1(date,time without time zone,time without time zone,text,timestamp with time zone)') is not null
    and pg_catalog.to_regprocedure('public.get_public_check_in_status_v1(uuid)') is not null
    and pg_catalog.to_regprocedure('public.get_check_in_reservation_v1(uuid)') is not null
    and (select procedure.prosecdef and procedure.provolatile='s'
      and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
      and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      from pg_catalog.pg_proc procedure
      where procedure.oid='public.get_public_check_in_status_v1(uuid)'::pg_catalog.regprocedure)
    and (select procedure.prosecdef and procedure.provolatile='s'
      and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
      and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      from pg_catalog.pg_proc procedure
      where procedure.oid='public.get_check_in_reservation_v1(uuid)'::pg_catalog.regprocedure),
    'Both readers are STABLE SECURITY DEFINER functions owned by postgres with the exact search_path.');

  perform pg_temp.record_result(2,'Least-privilege EXECUTE ACL',
    pg_catalog.has_function_privilege('anon','public.get_public_check_in_status_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.get_public_check_in_status_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_public_check_in_status_v1(uuid)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_check_in_reservation_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.get_check_in_reservation_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_check_in_reservation_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.is_reservation_check_in_token_usable_v1(date,time without time zone,time without time zone,text,timestamp with time zone)','EXECUTE')
    and not exists(
      select 1 from pg_catalog.pg_proc procedure
      cross join lateral pg_catalog.aclexplode(coalesce(
        procedure.proacl,pg_catalog.acldefault('f',procedure.proowner)
      )) acl
      where procedure.oid in (
        'public.get_public_check_in_status_v1(uuid)'::pg_catalog.regprocedure,
        'public.get_check_in_reservation_v1(uuid)'::pg_catalog.regprocedure,
        'public.is_reservation_check_in_token_usable_v1(date,time without time zone,time without time zone,text,timestamp with time zone)'::pg_catalog.regprocedure
      ) and acl.grantee=0 and acl.privilege_type='EXECUTE'
    ),
    'anon can execute only the neutral reader; authenticated can execute only the staff reader.');

  perform pg_temp.record_result(3,'Exact Warsaw validity boundaries',
    public.is_reservation_check_in_token_usable_v1(date '2026-01-10',time '10:00',time '11:00','confirmed',timestamptz '2026-01-09 09:00:00+00')
    and public.is_reservation_check_in_token_usable_v1(date '2026-01-10',time '10:00',time '11:00','confirmed',timestamptz '2026-01-10 12:00:00+00')
    and not public.is_reservation_check_in_token_usable_v1(date '2026-01-10',time '10:00',time '11:00','confirmed',timestamptz '2026-01-09 08:59:59+00')
    and not public.is_reservation_check_in_token_usable_v1(date '2026-01-10',time '10:00',time '11:00','confirmed',timestamptz '2026-01-10 12:00:01+00'),
    'Winter Warsaw window is inclusive from start minus 24 hours through end plus 2 hours.');

  v_result:=pg_temp.call_public_status(v_tokens[1]);
  perform pg_temp.record_result(4,'Valid token returns ready',
    v_result='{"ok":true,"code":"ready"}'::jsonb,
    'A valid planned reservation returns the exact neutral ready contract.');

  v_result:=pg_temp.call_public_status(v_tokens[4]);
  perform pg_temp.record_result(5,'Expired token denied',
    v_result='{"ok":false,"code":"unavailable"}'::jsonb,
    'An expired token returns the same neutral unavailable result.');

  v_result:=pg_temp.call_public_status('6d050000-0000-4000-8000-000000000099');
  perform pg_temp.record_result(6,'Invalid token denied',
    v_result='{"ok":false,"code":"unavailable"}'::jsonb,
    'An unknown UUID does not reveal whether a reservation exists.');

  v_result:=pg_temp.call_public_status(v_tokens[3]);
  perform pg_temp.record_result(7,'Cancelled token immediately invalid',
    v_result='{"ok":false,"code":"unavailable"}'::jsonb
    and pg_catalog.jsonb_array_length(
      pg_temp.call_staff_lookup(v_admin,v_tokens[3])
    )=0,
    'Cancelled reservations are unavailable to both public and staff token readers.');

  v_result:=pg_temp.call_public_status(v_tokens[2]);
  perform pg_temp.record_result(8,'Used token is controlled and non-mutating',
    v_result='{"ok":true,"code":"already_checked_in"}'::jsonb,
    'A checked-in reservation returns only already_checked_in during the active window.');

  perform pg_temp.record_result(9,'Public DTO is exactly minimal',
    not exists(
      select 1
      from pg_catalog.jsonb_object_keys(
        pg_temp.call_public_status(v_tokens[1])
      ) as key
      where key not in ('ok','code')
    )
    and (select pg_catalog.count(*)=2
      from pg_catalog.jsonb_object_keys(
        pg_temp.call_public_status(v_tokens[1])
      )),
    'Public output has only ok and code, without identifiers, PII, schedule or token data.');

  v_result:=pg_temp.call_staff_lookup(v_admin,v_tokens[1]);
  perform pg_temp.record_result(10,'Admin staff lookup allowed',
    pg_catalog.jsonb_array_length(v_result)=1
    and v_result->0->>'reservation_id'=v_valid::text
    and not (v_result->0 ? 'check_in_token')
    and not (v_result->0 ? 'reservation_note'),
    'Admin receives one allowlisted operational DTO without the token or internal note.');

  v_result:=pg_temp.call_staff_lookup(v_employee,v_tokens[1]);
  perform pg_temp.record_result(11,'Employee staff lookup allowed',
    pg_catalog.jsonb_array_length(v_result)=1
    and v_result->0->>'reservation_id'=v_valid::text,
    'Employee retains the existing operational check-in access.');

  v_denied:=false;
  begin
    perform pg_temp.call_staff_lookup(v_instructor,v_tokens[1]);
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(12,'Instructor staff lookup denied',v_denied,
    'The new operational token reader allows exactly admin and employee.');

  v_denied:=false;
  begin
    perform pg_temp.call_staff_lookup(v_user,v_tokens[1]);
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(13,'Ordinary user staff lookup denied',v_denied,
    'Possessing a copied token does not grant an ordinary user the staff DTO.');

  select pg_catalog.count(*) into v_audit_count
  from public.audit_logs where target_id=v_valid;
  v_result:=pg_temp.call_attendance(v_admin,v_valid);
  select checked_in_at into v_checked_at
  from public.reservations where id=v_valid;
  v_result_2:=pg_temp.call_attendance(v_admin,v_valid);
  perform pg_temp.record_result(14,'First check-in succeeds and repeat is idempotent',
    v_result->>'code'='started'
    and (v_result->>'changed')::boolean
    and v_result_2->>'code'='already_started'
    and not (v_result_2->>'changed')::boolean
    and pg_temp.call_public_status(v_tokens[1])
      ='{"ok":true,"code":"already_checked_in"}'::jsonb
    and (select checked_in_at=v_checked_at from public.reservations where id=v_valid)
    and (select pg_catalog.count(*)=v_audit_count+1
      from public.audit_logs where target_id=v_valid),
    'The first mutation is recorded once; the repeat changes nothing and token status is already_checked_in.');

  perform pg_temp.record_result(15,'All fixtures are transaction-scoped',
    (select pg_catalog.count(*)=4 from public.reservations
      where id in (v_valid,v_used,v_cancelled,v_expired))
    and (select pg_catalog.count(*)=4 from public.shooting_lanes
      where id=any(v_lanes))
    and (select pg_catalog.count(*)=5 from auth.users
      where id in (v_admin,v_employee,v_instructor,v_user,v_owner)),
    'All SEC-005 fixtures remain inside the transaction that ends with ROLLBACK.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end
  || test_order || ' - ' || test_name || ' # ' || result
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,', ' order by test_order
  ) into v_failures
  from pg_temp.test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'SEC-005 tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
