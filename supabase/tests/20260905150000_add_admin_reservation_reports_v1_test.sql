\set ON_ERROR_STOP on
\pset format unaligned

select '1..25';

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
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', coalesce(p_user_id::text, ''), true
  );
  execute pg_catalog.format('set local role %I', p_role);
end;
$function$;

create function pg_temp.call_report(
  p_user_id uuid,
  p_start_date date,
  p_end_date date,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb language plpgsql as $function$
declare
  v_result jsonb;
begin
  perform pg_temp.set_client('authenticated', p_user_id);
  select public.admin_get_reservation_report_v1(
    p_start_date, p_end_date, p_limit, p_offset
  ) into v_result;
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
  v_root uuid := pg_catalog.gen_random_uuid();
  v_position_1 uuid := pg_catalog.gen_random_uuid();
  v_position_2 uuid := pg_catalog.gen_random_uuid();
  v_historical_lane uuid := pg_catalog.gen_random_uuid();
  v_price_root uuid := pg_catalog.gen_random_uuid();
  v_price_1 uuid := pg_catalog.gen_random_uuid();
  v_price_2 uuid := pg_catalog.gen_random_uuid();
  v_price_historical uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');
  v_report jsonb;
  v_page_2 jsonb;
  v_empty jsonb;
begin
  insert into auth.users(
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reports6a-admin-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_employee, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reports6a-employee-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_instructor, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reports6a-instructor-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reports6a-user-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now());

  insert into public.profiles(user_id, role, first_name, last_name, full_name, email)
  select fixture.user_id, fixture.role, '[TEST]', fixture.label,
    '[TEST][REPORTS-6A] ' || fixture.label, fixture.email
  from (values
    (v_admin, 'admin', 'Admin', 'reports6a-admin-' || v_run || '@example.invalid'),
    (v_employee, 'pracownik', 'Employee', 'reports6a-employee-' || v_run || '@example.invalid'),
    (v_instructor, 'instruktor', 'Instructor', 'reports6a-instructor-' || v_run || '@example.invalid'),
    (v_user, 'user', 'User', 'reports6a-user-' || v_run || '@example.invalid')
  ) as fixture(user_id, role, label, email)
  where not exists (
    select 1 from public.profiles profile where profile.user_id = fixture.user_id
  );

  update public.profiles as profile
  set role = fixture.role,
      first_name = '[TEST]',
      last_name = fixture.label,
      full_name = '[TEST][REPORTS-6A] ' || fixture.label,
      email = fixture.email
  from (values
    (v_admin, 'admin', 'Admin', 'reports6a-admin-' || v_run || '@example.invalid'),
    (v_employee, 'pracownik', 'Employee', 'reports6a-employee-' || v_run || '@example.invalid'),
    (v_instructor, 'instruktor', 'Instructor', 'reports6a-instructor-' || v_run || '@example.invalid'),
    (v_user, 'user', 'User', 'reports6a-user-' || v_run || '@example.invalid')
  ) as fixture(user_id, role, label, email)
  where profile.user_id = fixture.user_id;

  insert into public.shooting_lanes(
    id, name, type, is_active, max_shooters, booking_step_minutes,
    display_order, resource_kind, parent_lane_id,
    whole_lane_bookable, positions_bookable
  ) values
    (v_root, '[TEST][REPORTS-6A] Root', 'shooting', true, 2, 60, 9900, 'lane', null, true, true),
    (v_position_1, '[TEST][REPORTS-6A] Position 1', 'shooting', true, 1, 60, 9901, 'position', v_root, false, false),
    (v_position_2, '[TEST][REPORTS-6A] Position 2', 'shooting', true, 1, 60, 9902, 'position', v_root, false, false),
    (v_historical_lane, '[TEST][REPORTS-6A] Current renamed lane', 'shooting', false, 1, 60, 9903, 'lane', null, true, false);

  insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
  values
    (v_root, true, 2),
    (v_position_1, true, 1),
    (v_position_2, true, 1),
    (v_historical_lane, false, 1);

  insert into public.lane_pricing_rules(
    id, lane_id, day_group, min_shooters, max_shooters, label, hourly_price
  ) values
    (v_price_root, v_root, 'mon_thu', 1, 2, '[TEST][REPORTS-6A] Root', 100),
    (v_price_1, v_position_1, 'mon_thu', 1, 1, '[TEST][REPORTS-6A] Position 1', 50),
    (v_price_2, v_position_2, 'mon_thu', 1, 1, '[TEST][REPORTS-6A] Position 2', 70),
    (v_price_historical, v_historical_lane, 'mon_thu', 1, 1, '[TEST][REPORTS-6A] Historical', 25);

  insert into public.reservations(
    id, user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes, price,
    reservation_status, payment_status, attendance_status, checked_in_at,
    completed_at, shooters_count, pricing_rule_id,
    pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
    price_per_hour_snapshot, total_price, currency_code, creation_request_id
  ) values
    (pg_catalog.gen_random_uuid(), v_user, v_root, '[TEST] Root customer', 'reports6a-root-' || v_run || '@example.invalid', '000001', date '2026-03-29', time '08:00', time '10:00', 120, 100, 'confirmed', 'paid', 'planned', null, null, 2, v_price_root, 'mon_thu', '[TEST][REPORTS-6A] Root snapshot', '[TEST] Root price', 50, 100, 'PLN', pg_catalog.gen_random_uuid()),
    (pg_catalog.gen_random_uuid(), v_user, v_position_1, '[TEST] Position customer', 'reports6a-position-' || v_run || '@example.invalid', '000002', date '2026-03-29', time '09:00', time '11:00', 120, 50, 'completed', 'pay_on_site', 'completed', pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp(), 1, v_price_1, 'mon_thu', '[TEST][REPORTS-6A] Position 1 snapshot', '[TEST] Position price', 25, 50, 'PLN', pg_catalog.gen_random_uuid()),
    (pg_catalog.gen_random_uuid(), v_user, v_position_2, '[TEST] Cancelled', 'reports6a-cancelled-' || v_run || '@example.invalid', '000003', date '2026-03-29', time '11:00', time '12:00', 60, 70, 'cancelled_by_user', 'paid', 'planned', null, null, 1, v_price_2, 'mon_thu', '[TEST][REPORTS-6A] Position 2 snapshot', '[TEST] Cancelled price', 70, 70, 'PLN', pg_catalog.gen_random_uuid()),
    (pg_catalog.gen_random_uuid(), v_user, v_position_2, '[TEST] No show', 'reports6a-noshow-' || v_run || '@example.invalid', '000004', date '2026-03-29', time '12:00', time '13:00', 60, 80, 'no_show', 'paid', 'no_show', null, null, 1, v_price_2, 'mon_thu', '[TEST][REPORTS-6A] Position 2 snapshot', '[TEST] No show price', 80, 80, 'PLN', pg_catalog.gen_random_uuid()),
    (pg_catalog.gen_random_uuid(), v_user, v_historical_lane, '[TEST] Historical', 'reports6a-history-' || v_run || '@example.invalid', '000005', date '2026-03-29', time '13:00', time '14:00', 60, 25, 'cancelled', 'free', 'planned', null, null, 1, v_price_historical, 'mon_thu', '[TEST][REPORTS-6A] Historical snapshot', '[TEST] Historical price', 25, 25, 'PLN', pg_catalog.gen_random_uuid());

  perform pg_temp.record_result(1, 'Exact RPC signature and no overloads',
    pg_catalog.to_regprocedure('public.admin_get_reservation_report_v1(date,date,integer,integer)') is not null
    and (select pg_catalog.count(*) = 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace where namespace.nspname = 'public' and procedure.proname = 'admin_get_reservation_report_v1'),
    'Dokładnie jedna właściwa sygnatura ma istnieć.');

  perform pg_temp.record_result(2, 'SECURITY DEFINER contract is exact',
    (select procedure.prosecdef and procedure.provolatile = 's' and procedure.prorettype = 'jsonb'::pg_catalog.regtype and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[] and owner_role.rolname = 'postgres' from pg_catalog.pg_proc procedure join pg_catalog.pg_roles owner_role on owner_role.oid = procedure.proowner where procedure.oid = 'public.admin_get_reservation_report_v1(date,date,integer,integer)'::pg_catalog.regprocedure),
    'RPC ma być STABLE SECURITY DEFINER, owner postgres, bezpieczny search_path.');

  perform pg_temp.record_result(3, 'Least-privilege EXECUTE ACL',
    pg_catalog.has_function_privilege('authenticated', 'public.admin_get_reservation_report_v1(date,date,integer,integer)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon', 'public.admin_get_reservation_report_v1(date,date,integer,integer)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role', 'public.admin_get_reservation_report_v1(date,date,integer,integer)', 'EXECUTE')
    and not exists (select 1 from pg_catalog.pg_proc procedure cross join lateral pg_catalog.aclexplode(coalesce(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))) acl where procedure.oid = 'public.admin_get_reservation_report_v1(date,date,integer,integer)'::pg_catalog.regprocedure and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'),
    'Tylko authenticated otrzymuje EXECUTE; autoryzacja admin pozostaje wewnętrzna.');

  perform pg_temp.record_result(4, 'No report RLS policy or table grant widening',
    not exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and tablename in ('reservations', 'profiles', 'shooting_lanes', 'lane_booking_rules') and policyname like '%REPORTS-6A%'),
    'Migracja nie może rozszerzać RLS ani ACL tabel.');

  perform pg_temp.record_result(5, 'Synthetic role profiles are exact',
    (select pg_catalog.count(*) = 4 and pg_catalog.count(distinct role) = 4 from public.profiles where user_id in (v_admin, v_employee, v_instructor, v_user)),
    'Każdy syntetyczny Auth user ma dokładnie jeden profil właściwej roli.');

  perform pg_temp.record_result(6, 'Anon has no RPC entry point',
    not pg_catalog.has_function_privilege('anon', 'public.admin_get_reservation_report_v1(date,date,integer,integer)', 'EXECUTE'),
    'Anon nie może wykonać raportu.');

  perform pg_temp.record_result(7, 'Ordinary user denied fail-closed',
    pg_temp.call_report(v_user, date '2026-03-29', date '2026-03-29')->>'code' = 'not_allowed',
    'Zwykły user otrzymuje kontrolowane not_allowed.');

  perform pg_temp.record_result(8, 'Instructor denied fail-closed',
    pg_temp.call_report(v_instructor, date '2026-03-29', date '2026-03-29')->>'code' = 'not_allowed',
    'Instruktor otrzymuje kontrolowane not_allowed.');

  perform pg_temp.record_result(9, 'Employee denied fail-closed',
    pg_temp.call_report(v_employee, date '2026-03-29', date '2026-03-29')->>'code' = 'not_allowed',
    'Pracownik otrzymuje kontrolowane not_allowed.');

  v_report := pg_temp.call_report(v_admin, date '2026-03-29', date '2026-03-29', 2, 0);
  v_page_2 := pg_temp.call_report(v_admin, date '2026-03-29', date '2026-03-29', 2, 2);
  v_empty := pg_temp.call_report(v_admin, date '2026-04-01', date '2026-04-01');

  perform pg_temp.record_result(10, 'Admin receives successful versioned contract',
    v_report->>'code' = 'ok' and (v_report->>'ok')::boolean and (v_report->>'contract_version')::integer = 1,
    'Admin ma otrzymać ok, contract_version=1.');

  perform pg_temp.record_result(11, 'Inclusive civil-date and 08:00-20:00 metadata',
    v_report->'range'->>'start_date' = '2026-03-29' and v_report->'range'->>'end_date' = '2026-03-29' and (v_report->'range'->>'end_inclusive')::boolean and (v_report->'range'->>'days')::integer = 1 and v_report->'range'->>'time_zone' = 'Europe/Warsaw' and v_report->'range'->>'opening_start' = '08:00' and v_report->'range'->>'opening_end' = '20:00' and (v_report->'range'->>'opening_minutes_per_day')::integer = 720,
    'Zakres jest inkluzywny, cywilny i ma kanoniczne 12 godzin.');

  perform pg_temp.record_result(12, 'Reservation status semantics are canonical',
    (v_report->'summary'->>'active_reservation_count')::integer = 1 and (v_report->'summary'->>'completed_reservation_count')::integer = 1 and (v_report->'summary'->>'cancelled_reservation_count')::integer = 2 and (v_report->'summary'->>'no_show_reservation_count')::integer = 1,
    'confirmed/completed/cancelled/no_show są rozdzielone bez zacierania semantyki.');

  perform pg_temp.record_result(13, 'Revenue semantics use total_price and payment status',
    (v_report->'summary'->>'planned_revenue')::numeric = 150 and (v_report->'summary'->>'paid_revenue')::numeric = 100 and (v_report->'summary'->>'outstanding_revenue')::numeric = 50,
    'Planowany, opłacony i oczekujący przychód mają właściwe definicje.');

  perform pg_temp.record_result(14, 'Root plus two positions has effective capacity two',
    (v_report->'summary'->>'effective_capacity')::integer = 2,
    'Root nie może być trzecią jednostką obok dwóch stanowisk.');

  perform pg_temp.record_result(15, 'Overlapping root and child ranges are unioned once',
    (v_report->'summary'->>'occupied_minutes')::integer = 300 and (v_report->'summary'->>'available_minutes')::integer = 1440 and (v_report->'summary'->>'occupancy_percent')::integer = 21,
    'Root 08-10 i child 09-11 dają 300, a nie 360 minut zasobu.');

  perform pg_temp.record_result(16, 'Details are bounded and total is authoritative',
    pg_catalog.jsonb_array_length(v_report->'details') = 2 and (v_report->'pagination'->>'total')::integer = 5 and (v_report->'pagination'->>'limit')::integer = 2 and (v_report->'pagination'->>'offset')::integer = 0,
    'Pierwsza strona ma 2 z 5 rekordów.');

  perform pg_temp.record_result(17, 'Pagination returns deterministic second page',
    pg_catalog.jsonb_array_length(v_page_2->'details') = 2 and (v_page_2->'pagination'->>'offset')::integer = 2,
    'Druga strona ma właściwy offset i rozmiar.');

  perform pg_temp.record_result(18, 'Position detail keeps hierarchy-aware label',
    exists (select 1 from pg_catalog.jsonb_array_elements(v_report->'details') item where item->>'resource_kind' = 'position' and item->>'parent_lane_id' = v_root::text and item->>'lane_display_name' = '[TEST][REPORTS-6A] Root — [TEST][REPORTS-6A] Position 1 snapshot'),
    'Stanowisko ma etykietę Parent — snapshot stanowiska.');

  perform pg_temp.record_result(19, 'Historical reservation snapshot remains visible',
    exists (select 1 from pg_catalog.jsonb_array_elements(pg_temp.call_report(v_admin, date '2026-03-29', date '2026-03-29')->'details') item where item->>'lane_name_snapshot' = '[TEST][REPORTS-6A] Historical snapshot') and v_report->'history'->>'name_basis' = 'reservation_snapshot' and v_report->'history'->>'position_parent_name_basis' = 'current_configuration' and v_report->'history'->>'capacity_basis' = 'current_configuration',
    'Nazwa historyczna jest snapshotem, a ograniczenie capacity jest jawne.');

  perform pg_temp.record_result(20, 'Report contract exposes no unnecessary PII or secrets',
    not (v_report::text ~* '(user_id|admin_note|check_in_token|confirmation_token|promotion_token|jwt|service_role|address)')
    and not exists (select 1 from pg_catalog.jsonb_array_elements(v_report->'details') item where (select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(item) key) <> array['customer_email','customer_name','customer_phone','duration_minutes','end_time','id','lane_display_name','lane_id','lane_name_snapshot','parent_lane_id','payment_status','reservation_date','reservation_status','resource_kind','start_time','total_price']::text[]),
    'DTO zawiera tylko wskaźniki i pola niezbędne dla istniejącej tabeli admina.');

  perform pg_temp.record_result(21, 'Invalid reversed range is controlled',
    pg_temp.call_report(v_admin, date '2026-03-30', date '2026-03-29')->>'code' = 'invalid_input',
    'Odwrócony zakres jest odrzucany.');

  perform pg_temp.record_result(22, 'Range above 366 days is controlled',
    pg_temp.call_report(v_admin, date '2026-01-01', date '2027-01-02')->>'code' = 'invalid_input',
    'Zakres ponad rok przestępny jest odrzucany.');

  perform pg_temp.record_result(23, 'Detail bounds are controlled',
    pg_temp.call_report(v_admin, date '2026-03-29', date '2026-03-29', 101, 0)->>'code' = 'invalid_input' and pg_temp.call_report(v_admin, date '2026-03-29', date '2026-03-29', 50, -1)->>'code' = 'invalid_input',
    'Limit i offset fail-closed poza kontraktem.');

  perform pg_temp.record_result(24, 'Empty range remains a complete report',
    v_empty->>'code' = 'ok' and (v_empty->'pagination'->>'total')::integer = 0 and pg_catalog.jsonb_array_length(v_empty->'details') = 0 and (v_empty->'summary'->>'occupied_minutes')::integer = 0,
    'Brak danych nie może być mylony z błędem częściowego odczytu.');

  perform pg_temp.record_result(25, 'RPC defaults are exactly limit and offset',
    (select procedure.pronargdefaults = 2 from pg_catalog.pg_proc procedure where procedure.oid = 'public.admin_get_reservation_report_v1(date,date,integer,integer)'::pg_catalog.regprocedure)
    and pg_catalog.pg_get_indexdef('public.reservations_reporting_date_time_idx'::pg_catalog.regclass) = 'CREATE INDEX reservations_reporting_date_time_idx ON public.reservations USING btree (reservation_date, start_time, id)',
    'Tylko limit=50 i offset=0 mają wartości domyślne, a zakres ma dokładny indeks.');
end;
$tests$;

select
  (case when passed then 'ok ' else 'not ok ' end)
  || test_order::text || ' - ' || test_name
  || case when passed then '' else E'\n# ' || result end
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failed text;
begin
  select pg_catalog.string_agg(test_order || '. ' || test_name || ': ' || result, E'\n' order by test_order)
  into v_failed
  from pg_temp.test_results
  where not passed;

  if (select pg_catalog.count(*) from pg_temp.test_results) <> 25 then
    raise exception 'REPORTS-6A expected 25 checks, got %', (select pg_catalog.count(*) from pg_temp.test_results);
  end if;

  if v_failed is not null then
    raise exception E'REPORTS-6A failures:\n%', v_failed;
  end if;
end;
$assertions$;

rollback;
