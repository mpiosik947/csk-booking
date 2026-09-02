\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..10';

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

create function pg_temp.call_confirm(p_user_id uuid,p_token text)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  if p_user_id is null then
    perform pg_catalog.set_config(
      'request.jwt.claims',
      pg_catalog.jsonb_build_object('role','authenticated')::text,
      true
    );
    perform pg_catalog.set_config('request.jwt.claim.sub',null,true);
  else
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
  end if;
  execute 'set local role authenticated';
  select public.confirm_event_reserve_promotion(p_token) into v_result;
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
  v_owner uuid := '6c030000-0000-4000-8000-000000000001';
  v_other uuid := '6c030000-0000-4000-8000-000000000002';
  v_event uuid := '6c030000-0000-4000-8000-000000000010';
  v_registration uuid := '6c030000-0000-4000-8000-000000000020';
  v_token text := '6c030000-0000-4000-8000-000000000030';
  v_result jsonb;
  v_denied boolean;
  v_confirmed_at timestamptz;
  v_created_at timestamptz;
begin
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_owner,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-sec003-owner@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-sec003-other@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(
    user_id,role,first_name,last_name,full_name,email,phone
  ) values
    (v_owner,'user','[TEST]','SEC-003 Owner','[TEST][SEC-003] Owner',
      'test-sec003-owner@example.invalid','000000001'),
    (v_other,'user','[TEST]','SEC-003 Other','[TEST][SEC-003] Other',
      'test-sec003-other@example.invalid','000000002');

  insert into public.events(
    id,title,event_date,start_time,end_time,location,price,max_participants,is_active
  ) values (
    v_event,'[TEST][SEC-003] POST confirmation',current_date + 30,
    time '10:00',time '11:00','[TEST]',0,2,true
  );

  insert into public.event_registrations(
    id,event_id,user_id,customer_name,customer_email,customer_phone,
    registration_status,payment_status,created_at,promotion_token,
    promotion_token_expires_at,promotion_email_sent_at,
    promotion_claim_id,promotion_claim_expires_at,promotion_attempt_count,
    promotion_last_attempt_at
  ) values (
    v_registration,v_event,v_owner,'[TEST] Owner',
    'test-sec003-owner@example.invalid','000000001','reserve','pending',
    pg_catalog.transaction_timestamp(),v_token,
    pg_catalog.transaction_timestamp() + interval '24 hours',
    pg_catalog.transaction_timestamp(),
    '6c030000-0000-4000-8000-000000000040',
    pg_catalog.transaction_timestamp() + interval '10 minutes',1,
    pg_catalog.transaction_timestamp()
  );

  select created_at into v_created_at
  from public.event_registrations where id=v_registration;

  perform pg_temp.record_result(1,'RPC security and ACL contract',
    (select procedure.prosecdef
       and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
       and procedure.proconfig=array['search_path=public, pg_temp']::text[]
     from pg_catalog.pg_proc procedure
     where procedure.oid='public.confirm_event_reserve_promotion(text)'::pg_catalog.regprocedure)
    and pg_catalog.has_function_privilege(
      'authenticated','public.confirm_event_reserve_promotion(text)','EXECUTE')
    and not pg_catalog.has_function_privilege(
      'anon','public.confirm_event_reserve_promotion(text)','EXECUTE')
    and not pg_catalog.has_function_privilege(
      'service_role','public.confirm_event_reserve_promotion(text)','EXECUTE')
    and not exists(
      select 1
      from pg_catalog.pg_proc procedure
      cross join lateral pg_catalog.aclexplode(coalesce(
        procedure.proacl,pg_catalog.acldefault('f',procedure.proowner)
      )) acl
      where procedure.oid='public.confirm_event_reserve_promotion(text)'::pg_catalog.regprocedure
        and acl.grantee=0 and acl.privilege_type='EXECUTE'
    ),
    'Only authenticated can execute; owner, SECURITY DEFINER and search_path are exact.');

  v_denied:=false;
  begin
    perform pg_temp.call_confirm(null,v_token);
  exception when insufficient_privilege then
    v_denied:=true;
  end;
  perform pg_temp.record_result(2,'Missing authentication denied',v_denied,
    'A request without auth.uid() receives SQLSTATE 42501.');

  perform pg_temp.record_result(3,'Anonymous execution denied',
    not pg_catalog.has_function_privilege(
      'anon','public.confirm_event_reserve_promotion(text)','EXECUTE'),
    'anon cannot call the mutating RPC.');

  v_denied:=false;
  begin
    perform pg_temp.call_confirm(v_other,v_token);
  exception when insufficient_privilege then
    v_denied:=true;
  end;
  perform pg_temp.record_result(4,'Other user denied',v_denied,
    'An authenticated non-owner receives SQLSTATE 42501.');

  perform pg_temp.record_result(5,'Denied call leaves registration unchanged',
    exists(
      select 1 from public.event_registrations registration
      where registration.id=v_registration
        and registration.registration_status='reserve'
        and registration.promotion_confirmed_at is null
        and registration.promotion_claim_id='6c030000-0000-4000-8000-000000000040'::uuid
    ),
    'The ownership denial performs no partial mutation.');

  v_result:=pg_temp.call_confirm(v_owner,v_token);
  perform pg_temp.record_result(6,'Owner confirms with the expected result',
    v_result->>'code'='confirmed'
    and (v_result->>'ok')::boolean
    and (v_result->>'registration_id')::uuid=v_registration
    and (v_result->>'event_id')::uuid=v_event,
    'The authenticated owner receives one controlled success result.');

  select promotion_confirmed_at into v_confirmed_at
  from public.event_registrations where id=v_registration;
  perform pg_temp.record_result(7,'Exactly the expected confirmation mutation',
    exists(
      select 1 from public.event_registrations registration
      where registration.id=v_registration
        and registration.registration_status='registered'
        and registration.promotion_confirmed_at is not null
        and registration.promotion_claim_id is null
        and registration.promotion_claim_expires_at is null
        and registration.promotion_last_error_code is null
        and registration.created_at=v_created_at
        and registration.user_id=v_owner
        and registration.event_id=v_event
        and registration.promotion_token=v_token
    ),
    'Status and confirmation fields change once; identity, owner and token remain unchanged.');

  v_result:=pg_temp.call_confirm(v_owner,v_token);
  perform pg_temp.record_result(8,'Repeated POST is safely non-mutating',
    v_result->>'code'='not_reserve'
    and not (v_result->>'ok')::boolean
    and (select promotion_confirmed_at=v_confirmed_at
      from public.event_registrations where id=v_registration),
    'The second call does not perform another confirmation mutation.');

  v_result:=pg_temp.call_confirm(
    v_owner,'6c030000-0000-4000-8000-000000000099'
  );
  perform pg_temp.record_result(9,'Unknown token is controlled',
    v_result->>'code'='not_found' and not (v_result->>'ok')::boolean,
    'An unknown token returns a safe result without data.');

  perform pg_temp.record_result(10,'Fixtures are transaction-scoped',
    (select count(*)=1 from public.events where id=v_event)
    and (select count(*)=1 from public.event_registrations where id=v_registration)
    and (select count(*)=2 from auth.users where id in (v_owner,v_other)),
    'All synthetic records are inside the transaction that ends with ROLLBACK.');
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
    raise exception 'SEC-003 tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
