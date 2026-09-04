\set ON_ERROR_STOP on
\pset format unaligned

select '1..24';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer, text, boolean, text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1, $2, coalesce($3, false), $4);
$function$;

create function pg_temp.set_client(p_role text, p_user_id uuid)
returns void language plpgsql as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', p_role)::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub', coalesce(p_user_id::text, ''), true);
  execute pg_catalog.format('set local role %I', p_role);
end;
$function$;

create function pg_temp.direct_delete_denied(p_role text, p_user_id uuid, p_reservation_id uuid)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client(p_role, p_user_id);
  delete from public.reservations where id = p_reservation_id;
  execute 'reset role';
  return false;
exception
  when insufficient_privilege then
    execute 'reset role';
    return true;
end;
$function$;

create function pg_temp.truncate_denied(p_role text, p_user_id uuid)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client(p_role, p_user_id);
  execute 'truncate table public.reservations';
  execute 'reset role';
  return false;
exception
  when insufficient_privilege then
    execute 'reset role';
    return true;
end;
$function$;

create function pg_temp.call_cancel(p_user_id uuid, p_reservation_id uuid)
returns jsonb language plpgsql as $function$
declare
  v_result jsonb;
begin
  perform pg_temp.set_client('authenticated', p_user_id);
  select public.cancel_reservation(p_reservation_id) into v_result;
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
  v_admin uuid := pg_catalog.gen_random_uuid();
  v_employee uuid := pg_catalog.gen_random_uuid();
  v_instructor uuid := pg_catalog.gen_random_uuid();
  v_user uuid := pg_catalog.gen_random_uuid();
  v_lifecycle_user uuid := pg_catalog.gen_random_uuid();
  v_lane uuid := pg_catalog.gen_random_uuid();
  v_price uuid := pg_catalog.gen_random_uuid();
  v_user_reservation uuid := pg_catalog.gen_random_uuid();
  v_admin_reservation uuid := pg_catalog.gen_random_uuid();
  v_employee_reservation uuid := pg_catalog.gen_random_uuid();
  v_lifecycle_reservation uuid := pg_catalog.gen_random_uuid();
  v_admin_checked_in_reservation uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');
  v_result jsonb;
  v_count integer;
  v_audit_count integer;
begin
  insert into auth.users(
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'clean004-admin-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_employee, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'clean004-employee-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_instructor, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'clean004-instructor-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'clean004-user-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_lifecycle_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'clean004-lifecycle-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now());

  insert into public.profiles(user_id, role, first_name, last_name, full_name, email)
  select fixture.user_id, fixture.role, '[TEST]', fixture.label,
    '[TEST][CLEAN-004] ' || fixture.label, fixture.email
  from (values
    (v_admin, 'admin', 'Admin', 'clean004-admin-' || v_run || '@example.invalid'),
    (v_employee, 'pracownik', 'Employee', 'clean004-employee-' || v_run || '@example.invalid'),
    (v_instructor, 'instruktor', 'Instructor', 'clean004-instructor-' || v_run || '@example.invalid'),
    (v_user, 'user', 'User', 'clean004-user-' || v_run || '@example.invalid'),
    (v_lifecycle_user, 'user', 'Lifecycle', 'clean004-lifecycle-' || v_run || '@example.invalid')
  ) as fixture(user_id, role, label, email)
  where not exists (
    select 1 from public.profiles as profile where profile.user_id = fixture.user_id
  );

  update public.profiles as profile
  set role = fixture.role,
      first_name = '[TEST]',
      last_name = fixture.label,
      full_name = '[TEST][CLEAN-004] ' || fixture.label,
      email = fixture.email
  from (values
    (v_admin, 'admin', 'Admin', 'clean004-admin-' || v_run || '@example.invalid'),
    (v_employee, 'pracownik', 'Employee', 'clean004-employee-' || v_run || '@example.invalid'),
    (v_instructor, 'instruktor', 'Instructor', 'clean004-instructor-' || v_run || '@example.invalid'),
    (v_user, 'user', 'User', 'clean004-user-' || v_run || '@example.invalid'),
    (v_lifecycle_user, 'user', 'Lifecycle', 'clean004-lifecycle-' || v_run || '@example.invalid')
  ) as fixture(user_id, role, label, email)
  where profile.user_id = fixture.user_id;

  perform pg_temp.record_result(1, 'Synthetic role profiles are exact',
    (select pg_catalog.count(*) = 5 from public.profiles where user_id in (
      v_admin, v_employee, v_instructor, v_user, v_lifecycle_user
    )), 'Każdy syntetyczny Auth user musi mieć dokładnie jeden profil.');

  insert into public.shooting_lanes(
    id, name, type, is_active, max_shooters, booking_step_minutes,
    resource_kind, whole_lane_bookable, positions_bookable
  ) values (
    v_lane, '[TEST][CLEAN-004] Lane', 'shooting', false, 1, 60, 'lane', true, false
  );

  insert into public.lane_pricing_rules(
    id, lane_id, day_group, min_shooters, max_shooters, label, hourly_price
  ) values (
    v_price, v_lane, 'mon_thu', 1, 1, '[TEST][CLEAN-004]', 10
  );

  insert into public.reservations(
    id, user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes, price,
    reservation_status, payment_status, attendance_status, shooters_count,
    pricing_rule_id, pricing_day_group_snapshot, lane_name_snapshot,
    pricing_label_snapshot, price_per_hour_snapshot, total_price, currency_code,
    creation_request_id
  ) values
    (v_user_reservation, v_user, v_lane, '[TEST] User', 'clean004-user-' || v_run || '@example.invalid', '000', current_date + 30, time '10:00', time '11:00', 60, 10, 'confirmed', 'pay_on_site', 'planned', 1, v_price, 'mon_thu', '[TEST][CLEAN-004] Lane', '[TEST][CLEAN-004]', 10, 10, 'PLN', pg_catalog.gen_random_uuid()),
    (v_admin_reservation, v_user, v_lane, '[TEST] User', 'clean004-user-' || v_run || '@example.invalid', '000', current_date + 31, time '10:00', time '11:00', 60, 10, 'confirmed', 'paid', 'planned', 1, v_price, 'mon_thu', '[TEST][CLEAN-004] Lane', '[TEST][CLEAN-004]', 10, 10, 'PLN', pg_catalog.gen_random_uuid()),
    (v_employee_reservation, v_user, v_lane, '[TEST] User', 'clean004-user-' || v_run || '@example.invalid', '000', current_date + 32, time '10:00', time '11:00', 60, 10, 'confirmed', 'pay_on_site', 'planned', 1, v_price, 'mon_thu', '[TEST][CLEAN-004] Lane', '[TEST][CLEAN-004]', 10, 10, 'PLN', pg_catalog.gen_random_uuid()),
    (v_lifecycle_reservation, v_lifecycle_user, v_lane, '[TEST] Lifecycle', 'clean004-lifecycle-' || v_run || '@example.invalid', '000', current_date + 33, time '10:00', time '11:00', 60, 10, 'confirmed', 'pay_on_site', 'planned', 1, v_price, 'mon_thu', '[TEST][CLEAN-004] Lane', '[TEST][CLEAN-004]', 10, 10, 'PLN', pg_catalog.gen_random_uuid()),
    (v_admin_checked_in_reservation, v_user, v_lane, '[TEST] User', 'clean004-user-' || v_run || '@example.invalid', '000', current_date + 34, time '10:00', time '11:00', 60, 10, 'confirmed', 'paid_on_site', 'planned', 1, v_price, 'mon_thu', '[TEST][CLEAN-004] Lane', '[TEST][CLEAN-004]', 10, 10, 'PLN', pg_catalog.gen_random_uuid());

  update public.reservations
  set attendance_status = 'present',
      checked_in_at = pg_catalog.transaction_timestamp()
  where id = v_admin_checked_in_reservation;

  perform pg_temp.record_result(2, 'Reservations RLS and owner contract',
    exists (
      select 1
      from pg_catalog.pg_class as relation
      join pg_catalog.pg_roles as owner_role on owner_role.oid = relation.relowner
      where relation.oid = 'public.reservations'::regclass
        and relation.relrowsecurity
        and owner_role.rolname = 'postgres'
    ), 'RLS ma być włączone, owner postgres.');

  perform pg_temp.record_result(3, 'Only exact SELECT policies remain',
    (select pg_catalog.count(*) = 2 from pg_catalog.pg_policies where schemaname = 'public' and tablename = 'reservations')
    and not exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and tablename = 'reservations' and cmd <> 'SELECT')
    and exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and tablename = 'reservations' and policyname = 'Admins and staff can view all reservations' and cmd = 'SELECT' and qual = 'is_admin_or_employee()')
    and exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and tablename = 'reservations' and policyname = 'Users can view own reservations' and cmd = 'SELECT' and qual = '(user_id = auth.uid())'),
    'Polityka DELETE ma nie istnieć, a obie polityki SELECT pozostać bez zmian.');

  perform pg_temp.record_result(4, 'authenticated reservation ACL is SELECT-only',
    pg_catalog.has_table_privilege('authenticated', 'public.reservations', 'SELECT')
    and not pg_catalog.has_table_privilege('authenticated', 'public.reservations', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
    'authenticated nie może mieć bezpośredniego DML ani praw technicznych.');

  perform pg_temp.record_result(5, 'anon and PUBLIC have no reservation ACL',
    not pg_catalog.has_table_privilege('anon', 'public.reservations', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
    and not exists (
      select 1
      from pg_catalog.pg_class as relation
      cross join lateral pg_catalog.aclexplode(coalesce(relation.relacl, pg_catalog.acldefault('r', relation.relowner))) as acl
      where relation.oid = 'public.reservations'::regclass and acl.grantee = 0
    ), 'anon i PUBLIC nie mogą mieć praw tabelowych.');

  perform pg_temp.record_result(6, 'service_role reservation ACL remains complete',
    pg_catalog.has_table_privilege('service_role', 'public.reservations', 'SELECT')
    and pg_catalog.has_table_privilege('service_role', 'public.reservations', 'INSERT')
    and pg_catalog.has_table_privilege('service_role', 'public.reservations', 'UPDATE')
    and pg_catalog.has_table_privilege('service_role', 'public.reservations', 'DELETE')
    and pg_catalog.has_table_privilege('service_role', 'public.reservations', 'TRUNCATE')
    and pg_catalog.has_table_privilege('service_role', 'public.reservations', 'REFERENCES')
    and pg_catalog.has_table_privilege('service_role', 'public.reservations', 'TRIGGER')
    and pg_catalog.has_table_privilege('service_role', 'public.reservations', 'MAINTAIN'),
    'service_role zachowuje dotychczasowy pełny ACL.');

  perform pg_temp.record_result(7, 'Controlled cancellation RPC remains hardened',
    exists (
      select 1
      from pg_catalog.pg_proc as procedure
      join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure.proowner
      where procedure.oid = 'public.cancel_reservation(uuid)'::regprocedure
        and procedure.prosecdef
        and procedure.provolatile = 'v'
        and procedure.prorettype = 'jsonb'::regtype
        and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
        and owner_role.rolname = 'postgres'
    ) and pg_catalog.has_function_privilege('authenticated', 'public.cancel_reservation(uuid)', 'EXECUTE'),
    'cancel_reservation pozostaje kontrolowanym RPC dla authenticated.');

  perform pg_temp.record_result(8, 'Account anonymization remains available without DELETE',
    pg_catalog.to_regprocedure('public.anonymize_my_account_v1()') is not null
    and pg_catalog.has_function_privilege('authenticated', 'public.anonymize_my_account_v1()', 'EXECUTE')
    and pg_catalog.pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure) !~* 'delete[[:space:]]+from[[:space:]]+public\.reservations',
    'SEC-009 ma anonimizować i zachowywać rezerwacje historyczne.');

  perform pg_temp.record_result(9, 'Anon direct DELETE denied', pg_temp.direct_delete_denied('anon', null, v_user_reservation), 'Anon DELETE ma zwracać 42501.');
  perform pg_temp.record_result(10, 'User direct DELETE denied', pg_temp.direct_delete_denied('authenticated', v_user, v_user_reservation), 'User DELETE ma zwracać 42501.');
  perform pg_temp.record_result(11, 'Instructor direct DELETE denied', pg_temp.direct_delete_denied('authenticated', v_instructor, v_user_reservation), 'Instructor DELETE ma zwracać 42501.');
  perform pg_temp.record_result(12, 'Employee direct DELETE denied', pg_temp.direct_delete_denied('authenticated', v_employee, v_user_reservation), 'Employee DELETE ma zwracać 42501.');
  perform pg_temp.record_result(13, 'Admin direct DELETE denied', pg_temp.direct_delete_denied('authenticated', v_admin, v_admin_reservation), 'Admin DELETE ma zwracać 42501.');
  perform pg_temp.record_result(14, 'Admin cannot delete checked-in paid history', pg_temp.direct_delete_denied('authenticated', v_admin, v_admin_checked_in_reservation), 'ACL blokuje DELETE niezależnie od stanu operacyjnego.');
  perform pg_temp.record_result(15, 'Application roles cannot TRUNCATE reservations',
    pg_temp.truncate_denied('anon', null)
    and pg_temp.truncate_denied('authenticated', v_user)
    and pg_temp.truncate_denied('authenticated', v_employee)
    and pg_temp.truncate_denied('authenticated', v_admin),
    'Anon i wszystkie role authenticated mają otrzymać 42501 dla TRUNCATE.');

  v_result := pg_temp.call_cancel(v_user, v_user_reservation);
  perform pg_temp.record_result(16, 'User controlled cancellation succeeds for own reservation',
    v_result @> '{"changed":true,"new_status":"cancelled_by_user","cancelled_by":"user"}'::jsonb,
    'User anuluje własną przyszłą rezerwację przez RPC.');
  perform pg_temp.record_result(17, 'User cancellation preserves history and creates one audit',
    (select reservation_status = 'cancelled_by_user' from public.reservations where id = v_user_reservation)
    and (select pg_catalog.count(*) = 1 from public.audit_logs where action = 'reservation_cancelled_by_user' and target_id = v_user_reservation),
    'Rekord pozostaje, a audit powstaje dokładnie raz.');

  v_result := pg_temp.call_cancel(v_admin, v_admin_reservation);
  perform pg_temp.record_result(18, 'Admin controlled cancellation succeeds for paid reservation',
    v_result @> '{"changed":true,"new_status":"cancelled_by_admin","cancelled_by":"staff","operator_role":"admin"}'::jsonb
    and (select payment_status = 'paid' and reservation_status = 'cancelled_by_admin' from public.reservations where id = v_admin_reservation),
    'Admin używa RPC, zachowując stan płatności i historię.');
  perform pg_temp.record_result(19, 'Admin cancellation creates trusted audit',
    (select pg_catalog.count(*) = 1 from public.audit_logs where action = 'reservation_cancelled_by_staff' and target_id = v_admin_reservation and actor_user_id = v_admin),
    'Audit aktora pochodzi z auth.uid().');

  v_result := pg_temp.call_cancel(v_employee, v_employee_reservation);
  perform pg_temp.record_result(20, 'Employee controlled cancellation succeeds',
    v_result @> '{"changed":true,"new_status":"cancelled_by_admin","cancelled_by":"staff","operator_role":"pracownik"}'::jsonb
    and (select reservation_status = 'cancelled_by_admin' from public.reservations where id = v_employee_reservation),
    'Pracownik używa tego samego kontrolowanego lifecycle.');
  perform pg_temp.record_result(21, 'Employee cancellation creates trusted audit',
    (select pg_catalog.count(*) = 1 from public.audit_logs where action = 'reservation_cancelled_by_staff' and target_id = v_employee_reservation and actor_user_id = v_employee),
    'Audit pracownika pochodzi z auth.uid().');

  select pg_catalog.count(*) into v_audit_count
  from public.audit_logs
  where action = 'reservation_cancelled_by_staff' and target_id = v_employee_reservation;
  v_result := pg_temp.call_cancel(v_employee, v_employee_reservation);
  perform pg_temp.record_result(22, 'Controlled cancellation is idempotent',
    v_result @> '{"changed":false,"new_status":"cancelled_by_admin"}'::jsonb
    and (select pg_catalog.count(*) from public.audit_logs where action = 'reservation_cancelled_by_staff' and target_id = v_employee_reservation) = v_audit_count,
    'No-change nie dodaje drugiego auditu.');

  perform pg_temp.set_client('authenticated', v_lifecycle_user);
  select public.anonymize_my_account_v1() into v_result;
  execute 'reset role';
  perform pg_temp.record_result(23, 'SEC-009 anonymization preserves reservation history',
    v_result @> '{"ok":true,"changed":true,"code":"anonymized"}'::jsonb
    and exists (
      select 1
      from public.reservations
      where id = v_lifecycle_reservation
        and user_id is null
        and pii_anonymized_at is not null
        and customer_email like 'deleted-user-%@invalid.local'
        and check_in_token is null
    ), 'Anonimizacja działa bez table DELETE i zachowuje rekord operacyjny.');

  select pg_catalog.count(*) into v_count
  from public.reservations
  where id in (
    v_user_reservation, v_admin_reservation, v_employee_reservation,
    v_lifecycle_reservation, v_admin_checked_in_reservation
  );
  perform pg_temp.record_result(24, 'All reservation history remains transactionally present',
    v_count = 5,
    'Anulowanie, check-in/payment fixture i anonimizacja nie mogą usuwać historii.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)
  || test_order::text || ' - ' || test_name
  || case when passed then '' else E'\n# ' || result end
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

  if v_failures is not null then
    raise exception 'CLEAN-004 tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
