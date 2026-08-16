\set ON_ERROR_STOP on

-- Psql-only contract test. The migration and every [TEST][6C-2D-S-P0B]
-- fixture run in one transaction and are removed by the final ROLLBACK.
select pg_catalog.md5(pg_catalog.pg_get_functiondef(
  'public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure
)) as attendance_before \gset

begin;

create temporary table safe_policy_baseline (
  policies_hash text not null
) on commit drop;

insert into pg_temp.safe_policy_baseline (policies_hash)
select pg_catalog.md5(pg_catalog.string_agg(
  policy.polrelid::text || ':' || policy.polname || ':' || policy.polcmd::text || ':' ||
  policy.polroles::text || ':' || coalesce(pg_catalog.pg_get_expr(policy.polqual, policy.polrelid), '') || ':' ||
  coalesce(pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid), ''),
  E'\n' order by policy.polrelid, policy.polname
))
from pg_catalog.pg_policy as policy
where policy.polrelid in (
  'public.events'::pg_catalog.regclass,
  'public.event_lanes'::pg_catalog.regclass,
  'public.lane_blocks'::pg_catalog.regclass,
  'public.shooting_lanes'::pg_catalog.regclass
);

\ir ../migrations/20260813075757_harden_instructor_reservation_scope.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.visible_reservation_count(
  p_role name,
  p_user_id uuid,
  p_ids uuid[]
)
returns bigint
language plpgsql
as $function$
declare
  v_count bigint;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    case when p_user_id is null then '{}'
         else pg_catalog.jsonb_build_object(
           'sub', p_user_id, 'role', p_role
         )::text end,
    true
  );
  execute pg_catalog.format('set local role %I', p_role);
  select pg_catalog.count(*) into v_count
  from public.reservations as reservation
  where reservation.id = any(p_ids);
  execute 'reset role';
  return v_count;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.visible_profile_count(
  p_role name,
  p_user_id uuid,
  p_ids uuid[]
)
returns bigint
language plpgsql
as $function$
declare
  v_count bigint;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    case when p_user_id is null then '{}'
         else pg_catalog.jsonb_build_object(
           'sub', p_user_id, 'role', p_role
         )::text end,
    true
  );
  execute pg_catalog.format('set local role %I', p_role);
  select pg_catalog.count(*) into v_count
  from public.profiles as profile
  where profile.user_id = any(p_ids);
  execute 'reset role';
  return v_count;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_attendance(
  p_user_id uuid,
  p_reservation_id uuid,
  p_action text
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    case when p_user_id is null then '{}'
         else pg_catalog.jsonb_build_object(
           'sub', p_user_id, 'role', 'authenticated'
         )::text end,
    true
  );
  execute 'set local role authenticated';
  select public.update_reservation_attendance(
    p_reservation_id, p_action
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

do $contract_tests$
declare
  v_admin_id uuid := pg_catalog.gen_random_uuid();
  v_employee_id uuid := pg_catalog.gen_random_uuid();
  v_instructor_id uuid := pg_catalog.gen_random_uuid();
  v_user_id uuid := pg_catalog.gen_random_uuid();
  v_customer_id uuid := pg_catalog.gen_random_uuid();
  v_profile_ids uuid[];
  v_reservation_ids uuid[];
  v_result jsonb;
  v_result2 jsonb;
  v_result3 jsonb;
  v_result4 jsonb;
  v_before jsonb;
  v_after jsonb;
  v_audits_before bigint;
  v_audits_after bigint;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-p0b-admin@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_employee_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-p0b-employee@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_instructor_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-p0b-instructor@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-p0b-user@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_customer_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-p0b-customer@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
      when v_admin_id then 'admin'
      when v_employee_id then 'pracownik'
      when v_instructor_id then 'instruktor'
      else 'user'
    end,
    first_name = '[TEST]', last_name = '6C-2D-S-P0B',
    full_name = '[TEST][6C-2D-S-P0B]',
    email = 'test-p0b-profile@example.invalid', phone = '000000000'
  where user_id in (
    v_admin_id, v_employee_id, v_instructor_id, v_user_id, v_customer_id
  );

  v_profile_ids := array[
    v_admin_id, v_employee_id, v_instructor_id, v_user_id, v_customer_id
  ];
  v_reservation_ids := array(
    select pg_catalog.gen_random_uuid() from pg_catalog.generate_series(1, 10)
  );

  insert into public.reservations (
    id, user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes, price,
    reservation_status, payment_status, created_at, attendance_status,
    admin_note, checked_in_at, completed_at, check_in_token,
    reservation_note, shooters_count, pricing_rule_id,
    pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
    price_per_hour_snapshot, total_price, currency_code, creation_request_id
  )
  select
    fixture.id,
    case fixture.ordinality
      when 1 then v_instructor_id
      when 2 then v_user_id
      else v_customer_id
    end,
    baseline.lane_id, '[TEST][6C-2D-S-P0B]',
    'test-p0b-reservation@example.invalid', '000000000',
    current_date + 8000 + fixture.ordinality::integer,
    baseline.start_time, baseline.end_time, baseline.duration_minutes,
    baseline.price, 'confirmed', 'pay_on_site',
    pg_catalog.transaction_timestamp(), 'planned', null, null, null,
    pg_catalog.gen_random_uuid(), '[TEST][6C-2D-S-P0B]',
    baseline.shooters_count, baseline.pricing_rule_id,
    baseline.pricing_day_group_snapshot, baseline.lane_name_snapshot,
    baseline.pricing_label_snapshot, baseline.price_per_hour_snapshot,
    baseline.total_price, baseline.currency_code, pg_catalog.gen_random_uuid()
  from pg_catalog.unnest(v_reservation_ids) with ordinality as fixture(id, ordinality)
  cross join lateral (
    select reservation.*
    from public.reservations as reservation
    order by reservation.id
    limit 1
  ) as baseline;

  if (select pg_catalog.count(*) from public.reservations where id=any(v_reservation_ids)) <> 10
     or (select pg_catalog.count(*) from public.profiles where user_id=any(v_profile_ids)) <> 5 then
    raise exception 'P0-B fixture setup failed.';
  end if;

  insert into pg_temp.test_results values
    (1, 'is_admin_or_employee exact role set',
      (select pg_catalog.pg_get_functiondef('public.is_admin_or_employee()'::pg_catalog.regprocedure) ~* $$lower\(btrim\(role::text\)\)\s+in\s+\('admin'\s*,\s*'pracownik'\)$$)
      and (select pg_catalog.pg_get_functiondef('public.is_admin_or_employee()'::pg_catalog.regprocedure) !~* 'instruktor'),
      'The narrow helper remains admin + pracownik only.'),
    (2, 'Global reservation policy narrowed',
      exists (select 1 from pg_catalog.pg_policy p where p.polrelid='public.reservations'::pg_catalog.regclass and p.polname='Admins and staff can view all reservations' and p.polcmd='r' and pg_catalog.pg_get_expr(p.polqual,p.polrelid)='is_admin_or_employee()'),
      'Global SELECT no longer uses is_admin_or_staff().'),
    (3, 'Own reservation policy preserved',
      exists (select 1 from pg_catalog.pg_policy p where p.polrelid='public.reservations'::pg_catalog.regclass and p.polname='Users can view own reservations' and p.polcmd='r' and pg_catalog.pg_get_expr(p.polqual,p.polrelid)='(user_id = auth.uid())'),
      'Ownership remains independent from profile role.'),
    (4, 'Global profile policy narrowed',
      exists (select 1 from pg_catalog.pg_policy p where p.polrelid='public.profiles'::pg_catalog.regclass and p.polname='Admins and staff can view all profiles' and p.polcmd='r' and pg_catalog.pg_get_expr(p.polqual,p.polrelid)='is_admin_or_employee()'),
      'Global profile SELECT no longer uses is_admin_or_staff().'),
    (5, 'Own profile policy preserved',
      exists (select 1 from pg_catalog.pg_policy p where p.polrelid='public.profiles'::pg_catalog.regclass and p.polname='Users can view own profile' and p.polcmd='r' and pg_catalog.pg_get_expr(p.polqual,p.polrelid)='(user_id = auth.uid())'),
      'Own profile access remains intact.'),
    (6, 'Admin sees all fixture reservations', pg_temp.visible_reservation_count('authenticated',v_admin_id,v_reservation_ids)=10, 'Admin global SELECT works.'),
    (7, 'Pracownik sees all fixture reservations', pg_temp.visible_reservation_count('authenticated',v_employee_id,v_reservation_ids)=10, 'Employee global SELECT works.'),
    (8, 'Instruktor sees only own reservation', pg_temp.visible_reservation_count('authenticated',v_instructor_id,v_reservation_ids)=1, 'Instructor global rows are hidden; ownership remains.'),
    (9, 'User sees only own reservation', pg_temp.visible_reservation_count('authenticated',v_user_id,v_reservation_ids)=1, 'User global rows are hidden; ownership remains.'),
    (10, 'Anon sees no reservations', pg_temp.visible_reservation_count('anon',null,v_reservation_ids)=0, 'Anonymous SELECT returns zero fixture rows.'),
    (11, 'Admin sees all fixture profiles', pg_temp.visible_profile_count('authenticated',v_admin_id,v_profile_ids)=5, 'Admin global profile SELECT works.'),
    (12, 'Pracownik sees all fixture profiles', pg_temp.visible_profile_count('authenticated',v_employee_id,v_profile_ids)=5, 'Employee global profile SELECT works.'),
    (13, 'Instruktor sees only own profile', pg_temp.visible_profile_count('authenticated',v_instructor_id,v_profile_ids)=1, 'Instructor global PII is hidden; own profile remains.'),
    (14, 'User sees only own profile', pg_temp.visible_profile_count('authenticated',v_user_id,v_profile_ids)=1, 'User global PII is hidden; own profile remains.'),
    (15, 'Anon sees no profiles', pg_temp.visible_profile_count('anon',null,v_profile_ids)=0, 'Anonymous SELECT returns zero fixture profiles.');

  select pg_catalog.to_jsonb(reservation) into v_before
  from public.reservations as reservation where reservation.id=v_reservation_ids[10];
  select pg_catalog.count(*) into v_audits_before
  from public.audit_logs as audit where audit.target_id=v_reservation_ids[10];
  v_result := pg_temp.call_attendance(v_instructor_id,v_reservation_ids[10],'start');
  v_result2 := pg_temp.call_attendance(v_instructor_id,v_reservation_ids[10],'reset');
  v_result3 := pg_temp.call_attendance(v_instructor_id,v_reservation_ids[10],'complete');
  v_result4 := pg_temp.call_attendance(v_instructor_id,v_reservation_ids[10],'no_show');
  select pg_catalog.to_jsonb(reservation) into v_after
  from public.reservations as reservation where reservation.id=v_reservation_ids[10];
  select pg_catalog.count(*) into v_audits_after
  from public.audit_logs as audit where audit.target_id=v_reservation_ids[10];
  insert into pg_temp.test_results values
    (16, 'Instructor START denied', v_result->>'code'='not_allowed' and v_result->>'changed'='false', 'Known foreign UUID does not bypass authorization.'),
    (17, 'Instructor RESET denied', v_result2->>'code'='not_allowed' and v_result2->>'changed'='false', 'Known foreign UUID does not bypass authorization.'),
    (18, 'Instructor COMPLETE denied', v_result3->>'code'='not_allowed' and v_result3->>'changed'='false', 'Known foreign UUID does not bypass authorization.'),
    (19, 'Instructor NO-SHOW denied', v_result4->>'code'='not_allowed' and v_result4->>'changed'='false', 'Known foreign UUID does not bypass authorization.'),
    (20, 'Denied instructor mutations change no row', v_before=v_after, 'All reservation columns and timestamps are unchanged.'),
    (21, 'Denied instructor mutations create no audit', v_audits_before=v_audits_after, 'Authorization failure is side-effect free.');

  v_result := pg_temp.call_attendance(v_user_id,v_reservation_ids[10],'start');
  v_result2 := pg_temp.call_attendance(null,v_reservation_ids[10],'start');
  insert into pg_temp.test_results values
    (22, 'User attendance denied', v_result->>'code'='not_allowed' and v_result->>'changed'='false', 'Ordinary user remains denied.'),
    (23, 'Missing session attendance denied', v_result2->>'code'='not_allowed' and v_result2->>'changed'='false', 'Missing auth fails closed.');

  v_result := pg_temp.call_attendance(v_admin_id,v_reservation_ids[4],'start');
  v_result2 := pg_temp.call_attendance(v_admin_id,v_reservation_ids[4],'reset');
  v_result3 := pg_temp.call_attendance(v_admin_id,v_reservation_ids[5],'start');
  v_result4 := pg_temp.call_attendance(v_admin_id,v_reservation_ids[5],'complete');
  insert into pg_temp.test_results values
    (24, 'Admin START and RESET preserved', v_result->>'code'='started' and v_result2->>'code'='reset', 'P0-A start/reset matrix is unchanged.'),
    (25, 'Admin COMPLETE preserved', v_result3->>'code'='started' and v_result4->>'code'='completed', 'P0-A complete transition is unchanged.');
  v_result := pg_temp.call_attendance(v_admin_id,v_reservation_ids[6],'no_show');
  insert into pg_temp.test_results values
    (26, 'Admin NO-SHOW preserved', v_result->>'code'='no_show', 'P0-A no-show transition is unchanged.');

  v_result := pg_temp.call_attendance(v_employee_id,v_reservation_ids[7],'start');
  v_result2 := pg_temp.call_attendance(v_employee_id,v_reservation_ids[7],'reset');
  v_result3 := pg_temp.call_attendance(v_employee_id,v_reservation_ids[8],'start');
  v_result4 := pg_temp.call_attendance(v_employee_id,v_reservation_ids[8],'complete');
  insert into pg_temp.test_results values
    (27, 'Pracownik START and RESET preserved', v_result->>'code'='started' and v_result2->>'code'='reset', 'P0-A start/reset matrix is unchanged.'),
    (28, 'Pracownik COMPLETE preserved', v_result3->>'code'='started' and v_result4->>'code'='completed', 'P0-A complete transition is unchanged.');
  v_result := pg_temp.call_attendance(v_employee_id,v_reservation_ids[9],'no_show');
  insert into pg_temp.test_results values
    (29, 'Pracownik NO-SHOW preserved', v_result->>'code'='no_show', 'P0-A no-show transition is unchanged.'),
    (30, 'Attendance RPC security unchanged',
      exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner join pg_catalog.pg_language l on l.oid=p.prolang where p.oid='public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure and p.prosecdef and p.provolatile='v' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and r.rolname='postgres' and l.lanname='plpgsql' and pg_catalog.pg_get_function_result(p.oid)='jsonb'),
      'Owner, language, volatility, return and fixed search_path are unchanged.'),
    (31, 'Attendance RPC ACL unchanged',
      pg_catalog.has_function_privilege('authenticated','public.update_reservation_attendance(uuid,text)','EXECUTE')
      and pg_catalog.has_function_privilege('service_role','public.update_reservation_attendance(uuid,text)','EXECUTE')
      and not pg_catalog.has_function_privilege('anon','public.update_reservation_attendance(uuid,text)','EXECUTE')
      and not exists (select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a where p.oid='public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'),
      'No execute privilege is expanded.'),
    (32, 'Authenticated direct reservation UPDATE remains revoked',
      not pg_catalog.has_table_privilege('authenticated','public.reservations','UPDATE')
      and not pg_catalog.has_table_privilege('anon','public.reservations','UPDATE'),
      'P0-A direct-write hardening remains.'),
    (33, 'No reservation UPDATE policy exists',
      not exists (select 1 from pg_catalog.pg_policy p where p.polrelid='public.reservations'::pg_catalog.regclass and p.polcmd='w'),
      'No alternate direct UPDATE path is introduced.'),
    (34, 'Calendar-related policies unchanged',
      (select pg_catalog.md5(pg_catalog.string_agg(
        p.polrelid::text || ':' || p.polname || ':' || p.polcmd::text || ':' ||
        p.polroles::text || ':' || coalesce(pg_catalog.pg_get_expr(p.polqual,p.polrelid),'') || ':' ||
        coalesce(pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid),''),
        E'\n' order by p.polrelid,p.polname
      )) from pg_catalog.pg_policy p where p.polrelid in ('public.events'::pg_catalog.regclass,'public.event_lanes'::pg_catalog.regclass,'public.lane_blocks'::pg_catalog.regclass,'public.shooting_lanes'::pg_catalog.regclass)) = (select policies_hash from pg_temp.safe_policy_baseline),
      'Events, event lanes, lane blocks and shooting lanes retain their policies.'),
    (35, 'Fixture scope remains isolated',
      (select pg_catalog.count(*) from public.reservations where id=any(v_reservation_ids))=10
      and (select pg_catalog.count(*) from auth.users where id=any(v_profile_ids))=5,
      'Only generated [TEST][6C-2D-S-P0B] fixtures are used.'),
    (36, 'Ready for final ROLLBACK', true, 'Migration, fixtures and audits are in one transaction.');
end;
$contract_tests$;

table pg_temp.test_results order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  ) into v_failures
  from pg_temp.test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Instructor scope hardening tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure
  )) = :'attendance_before' as attendance_restored,
  not exists (
    select 1 from auth.users where email like 'test-p0b-%@example.invalid'
  ) as auth_fixtures_absent,
  not exists (
    select 1 from public.profiles where full_name='[TEST][6C-2D-S-P0B]'
  ) as profile_fixtures_absent,
  not exists (
    select 1 from public.reservations where customer_name='[TEST][6C-2D-S-P0B]'
  ) as reservation_fixtures_absent;
