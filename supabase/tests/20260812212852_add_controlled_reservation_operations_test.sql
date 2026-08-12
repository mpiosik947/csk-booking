\set ON_ERROR_STOP on

-- psql-only contract test. The migration and all [TEST][6C-2D-S-P0A]
-- fixtures run in one transaction and are removed by the final ROLLBACK.
begin;

\ir ../migrations/20260812212852_add_controlled_reservation_operations.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

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

create function pg_temp.call_payment(
  p_user_id uuid,
  p_reservation_id uuid,
  p_payment_status text
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
  select public.update_reservation_payment(
    p_reservation_id, p_payment_status
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_note(
  p_user_id uuid,
  p_reservation_id uuid,
  p_admin_note text
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
  select public.update_reservation_admin_note(
    p_reservation_id, p_admin_note
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_cancel(
  p_user_id uuid,
  p_reservation_id uuid
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
  select public.cancel_reservation(p_reservation_id) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

do $contract_tests$
declare
  v_admin_id uuid := '6c2d0000-0000-4000-8000-000000000001';
  v_employee_id uuid := '6c2d0000-0000-4000-8000-000000000002';
  v_instructor_id uuid := '6c2d0000-0000-4000-8000-000000000003';
  v_user_id uuid := '6c2d0000-0000-4000-8000-000000000004';
  v_customer_id uuid := '6c2d0000-0000-4000-8000-000000000005';
  v_reservation_ids uuid[];
  v_result jsonb;
  v_result2 jsonb;
  v_before jsonb;
  v_after jsonb;
  v_direct_update_count integer;
  v_error_state text;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2d-admin@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_employee_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2d-employee@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_instructor_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2d-instructor@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2d-user@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_customer_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2d-customer@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
      when v_admin_id then 'admin'
      when v_employee_id then 'pracownik'
      when v_instructor_id then 'instruktor'
      else 'user'
    end,
    first_name = '[TEST]', last_name = '6C-2D-S-P0A',
    full_name = '[TEST][6C-2D-S-P0A]',
    email = 'test-6c2d-profile@example.invalid', phone = '000000000'
  where user_id in (
    v_admin_id, v_employee_id, v_instructor_id, v_user_id, v_customer_id
  );

  v_reservation_ids := array[
    '6c2d0000-0000-4000-8000-000000000101'::uuid,
    '6c2d0000-0000-4000-8000-000000000102'::uuid,
    '6c2d0000-0000-4000-8000-000000000103'::uuid,
    '6c2d0000-0000-4000-8000-000000000104'::uuid,
    '6c2d0000-0000-4000-8000-000000000105'::uuid,
    '6c2d0000-0000-4000-8000-000000000106'::uuid,
    '6c2d0000-0000-4000-8000-000000000107'::uuid,
    '6c2d0000-0000-4000-8000-000000000108'::uuid
  ];

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
    fixture.id, v_customer_id, baseline.lane_id,
    '[TEST][6C-2D-S-P0A]', 'test-6c2d-reservation@example.invalid',
    '000000000', current_date + 7000 + fixture.ordinality::integer,
    baseline.start_time, baseline.end_time, baseline.duration_minutes,
    baseline.price, 'confirmed', 'pay_on_site',
    pg_catalog.transaction_timestamp(), 'planned', null, null, null,
    pg_catalog.gen_random_uuid(), '[TEST][6C-2D-S-P0A]',
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

  if (select pg_catalog.count(*) from public.reservations where id=any(v_reservation_ids)) <> 8 then
    raise exception 'Test fixture requires one valid baseline reservation.';
  end if;

  insert into pg_temp.test_results values
    (1, 'Attendance RPC exact signature',
      pg_catalog.to_regprocedure('public.update_reservation_attendance(uuid,text)') is not null,
      'Controlled attendance writer exists.'),
    (2, 'Payment RPC exact signature',
      pg_catalog.to_regprocedure('public.update_reservation_payment(uuid,text)') is not null,
      'Controlled payment writer exists.'),
    (3, 'Admin-note RPC exact signature',
      pg_catalog.to_regprocedure('public.update_reservation_admin_note(uuid,text)') is not null,
      'Controlled admin-note writer exists.'),
    (4, 'No unexpected overloads',
      (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='update_reservation_attendance')=1
      and (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='update_reservation_payment')=1
      and (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='update_reservation_admin_note')=1,
      'Every writer has exactly one overload.'),
    (5, 'RPC security properties',
      (select pg_catalog.bool_and(p.prosecdef and r.rolname='postgres' and l.lanname='plpgsql' and p.provolatile='v' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and pg_catalog.pg_get_function_result(p.oid)='jsonb')
       from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace join pg_catalog.pg_roles r on r.oid=p.proowner join pg_catalog.pg_language l on l.oid=p.prolang
       where n.nspname='public' and p.proname in ('update_reservation_attendance','update_reservation_payment','update_reservation_admin_note')),
      'All controlled writers are postgres-owned SECURITY DEFINER PL/pgSQL JSONB functions.'),
    (6, 'Authenticated EXECUTE only client ACL',
      pg_catalog.has_function_privilege('authenticated','public.update_reservation_attendance(uuid,text)','EXECUTE')
      and pg_catalog.has_function_privilege('authenticated','public.update_reservation_payment(uuid,text)','EXECUTE')
      and pg_catalog.has_function_privilege('authenticated','public.update_reservation_admin_note(uuid,text)','EXECUTE')
      and not pg_catalog.has_function_privilege('anon','public.update_reservation_attendance(uuid,text)','EXECUTE')
      and not pg_catalog.has_function_privilege('anon','public.update_reservation_payment(uuid,text)','EXECUTE')
      and not pg_catalog.has_function_privilege('anon','public.update_reservation_admin_note(uuid,text)','EXECUTE')
      and not exists (select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('update_reservation_attendance','update_reservation_payment','update_reservation_admin_note') and a.grantee=0 and a.privilege_type='EXECUTE'),
      'anon and PUBLIC have no execute; authenticated uses the controlled RPCs.'),
    (7, 'Authenticated direct UPDATE revoked',
      not pg_catalog.has_table_privilege('authenticated','public.reservations','UPDATE')
      and not pg_catalog.has_table_privilege('anon','public.reservations','UPDATE'),
      'No client role has table UPDATE.'),
    (8, 'Legacy UPDATE policy removed',
      not exists (select 1 from pg_catalog.pg_policy where polrelid='public.reservations'::pg_catalog.regclass and polcmd='w'),
      'No UPDATE policy can provide an alternate direct path.'),
    (9, 'Operational constraint installed',
      exists (select 1 from pg_catalog.pg_constraint where conrelid='public.reservations'::pg_catalog.regclass and conname='reservations_operational_state_check' and convalidated),
      'Cross-column state consistency is enforced.'),
    (10, 'Service role retains table UPDATE',
      pg_catalog.has_table_privilege('service_role','public.reservations','UPDATE'),
      'Trusted backend owner path is unchanged.');

  v_result := pg_temp.call_attendance(v_admin_id, v_reservation_ids[1], 'start');
  insert into pg_temp.test_results values
    (11, 'Admin START', v_result->>'code'='started' and v_result->>'changed'='true' and (select reservation_status='confirmed' and attendance_status='present' and checked_in_at is not null and completed_at is null from public.reservations where id=v_reservation_ids[1]), 'START represents an in-progress visit.'),
    (12, 'START audit exactly once', (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[1] and action='RESERVATION_STARTED')=1, 'START and audit are atomic.');
  v_result2 := pg_temp.call_attendance(v_admin_id, v_reservation_ids[1], 'start');
  insert into pg_temp.test_results values
    (13, 'START idempotent retry', v_result2->>'code'='already_started' and v_result2->>'changed'='false' and (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[1] and action='RESERVATION_STARTED')=1, 'Retry creates neither a second update nor audit.');

  v_result := pg_temp.call_attendance(v_employee_id, v_reservation_ids[1], 'complete');
  insert into pg_temp.test_results values
    (14, 'Pracownik COMPLETE after START', v_result->>'code'='completed' and (select reservation_status='completed' and attendance_status='completed' and checked_in_at is not null and completed_at is not null and completed_at>=checked_in_at from public.reservations where id=v_reservation_ids[1]), 'COMPLETE preserves check-in and sets completion.'),
    (15, 'COMPLETE audit exactly once', (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[1] and action='CHECK_IN_COMPLETED')=1, 'Completion audit is singular.');
  v_result2 := pg_temp.call_attendance(v_employee_id, v_reservation_ids[1], 'complete');
  insert into pg_temp.test_results values
    (16, 'COMPLETE idempotent retry', v_result2->>'code'='already_completed' and v_result2->>'changed'='false' and (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[1] and action='CHECK_IN_COMPLETED')=1, 'Completion retry is idempotent.');

  v_result := pg_temp.call_attendance(v_employee_id, v_reservation_ids[2], 'no_show');
  insert into pg_temp.test_results values
    (17, 'Pracownik NO-SHOW', v_result->>'code'='no_show' and (select reservation_status='no_show' and attendance_status='no_show' and checked_in_at is null and completed_at is null from public.reservations where id=v_reservation_ids[2]), 'No-show does not fabricate check-in/completion timestamps.'),
    (18, 'NO-SHOW audit exactly once', (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[2] and action='RESERVATION_NO_SHOW')=1, 'No-show audit is singular.');
  v_result2 := pg_temp.call_attendance(v_employee_id, v_reservation_ids[2], 'no_show');
  insert into pg_temp.test_results values
    (19, 'NO-SHOW idempotent retry', v_result2->>'code'='already_no_show' and v_result2->>'changed'='false' and (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[2] and action='RESERVATION_NO_SHOW')=1, 'No-show retry is idempotent.');

  v_result := pg_temp.call_attendance(v_instructor_id, v_reservation_ids[3], 'complete');
  v_result2 := pg_temp.call_attendance(v_instructor_id, v_reservation_ids[3], 'start');
  insert into pg_temp.test_results values
    (20, 'Instruktor scope not expanded', v_result->>'code'='invalid_transition' and v_result2->>'code'='not_allowed' and (select reservation_status='confirmed' and attendance_status='planned' from public.reservations where id=v_reservation_ids[3]), 'Instructor retains existing completion/no-show scope but cannot start/reset globally.');

  v_result := pg_temp.call_attendance(v_user_id, v_reservation_ids[3], 'start');
  v_result2 := pg_temp.call_payment(v_user_id, v_reservation_ids[3], 'paid');
  insert into pg_temp.test_results values
    (21, 'User admin mutations denied', v_result->>'code'='not_allowed' and v_result2->>'code'='not_allowed', 'Ordinary user cannot operate attendance or payments.');
  v_result := pg_temp.call_attendance(null, v_reservation_ids[3], 'start');
  v_result2 := pg_temp.call_payment(null, v_reservation_ids[3], 'paid');
  insert into pg_temp.test_results values
    (22, 'Anonymous admin mutations denied', v_result->>'code'='not_allowed' and v_result2->>'code'='not_allowed', 'Missing auth fails closed.');

  v_result := pg_temp.call_attendance(v_admin_id, v_reservation_ids[3], 'complete');
  insert into pg_temp.test_results values
    (23, 'COMPLETE before START denied', v_result->>'code'='invalid_transition' and (select reservation_status='confirmed' and attendance_status='planned' and checked_in_at is null and completed_at is null from public.reservations where id=v_reservation_ids[3]), 'A planned visit cannot be silently completed.');
  perform pg_temp.call_attendance(v_admin_id, v_reservation_ids[3], 'start');
  v_result := pg_temp.call_attendance(v_admin_id, v_reservation_ids[3], 'no_show');
  insert into pg_temp.test_results values
    (24, 'NO-SHOW after START denied', v_result->>'code'='invalid_transition' and (select reservation_status='confirmed' and attendance_status='present' and checked_in_at is not null and completed_at is null from public.reservations where id=v_reservation_ids[3]), 'In-progress visit cannot become no-show.');

  v_result := pg_temp.call_attendance(v_admin_id, v_reservation_ids[3], 'reset');
  insert into pg_temp.test_results values
    (25, 'Admin reset START', v_result->>'code'='reset' and (select reservation_status='confirmed' and attendance_status='planned' and checked_in_at is null and completed_at is null from public.reservations where id=v_reservation_ids[3]), 'Explicit reset restores the planned state.');

  v_result := pg_temp.call_payment(v_admin_id, v_reservation_ids[4], 'paid');
  insert into pg_temp.test_results values
    (26, 'Admin payment update', v_result->>'code'='updated' and (select payment_status='paid' from public.reservations where id=v_reservation_ids[4]), 'Payment writer changes only payment status.'),
    (27, 'Payment audit exactly once', (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[4] and action='RESERVATION_PAYMENT_STATUS_CHANGED')=1, 'Payment audit is atomic and singular.');
  v_result2 := pg_temp.call_payment(v_admin_id, v_reservation_ids[4], 'paid');
  insert into pg_temp.test_results values
    (28, 'Payment idempotent retry', v_result2->>'code'='already_set' and v_result2->>'changed'='false' and (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[4] and action='RESERVATION_PAYMENT_STATUS_CHANGED')=1, 'Same payment retry creates no audit.');
  v_result := pg_temp.call_payment(v_employee_id, v_reservation_ids[4], 'voucher');
  insert into pg_temp.test_results values
    (29, 'Pracownik payment update', v_result->>'code'='updated' and (select payment_status='voucher' from public.reservations where id=v_reservation_ids[4]), 'Employee can choose another existing payment status.');
  v_result := pg_temp.call_payment(v_instructor_id, v_reservation_ids[4], 'free');
  insert into pg_temp.test_results values
    (30, 'Instruktor payment denied', v_result->>'code'='not_allowed' and (select payment_status='voucher' from public.reservations where id=v_reservation_ids[4]), 'Instructor receives no new payment writer.');
  v_result := pg_temp.call_payment(v_admin_id, v_reservation_ids[4], 'unknown');
  insert into pg_temp.test_results values
    (31, 'Unknown payment denied', v_result->>'code'='invalid_input' and (select payment_status='voucher' from public.reservations where id=v_reservation_ids[4]), 'Only existing constrained statuses are accepted.');

  select pg_catalog.to_jsonb(reservation) - 'payment_status'
  into v_before from public.reservations as reservation where id=v_reservation_ids[4];
  perform pg_temp.call_payment(v_admin_id, v_reservation_ids[4], 'free');
  select pg_catalog.to_jsonb(reservation) - 'payment_status'
  into v_after from public.reservations as reservation where id=v_reservation_ids[4];
  insert into pg_temp.test_results values
    (32, 'Payment changes no other column', v_before=v_after, 'Full row comparison excludes only payment_status.');

  v_result := pg_temp.call_note(v_employee_id, v_reservation_ids[5], '[TEST][6C-2D-S-P0A] note');
  insert into pg_temp.test_results values
    (33, 'Controlled admin note writer', v_result->>'code'='updated' and (select admin_note='[TEST][6C-2D-S-P0A] note' from public.reservations where id=v_reservation_ids[5]), 'No direct UPDATE is required for admin notes.'),
    (34, 'Admin note audit has no note text', (select pg_catalog.count(*)=1 and pg_catalog.bool_and(not details::text like '%[TEST][6C-2D-S-P0A] note%') from public.audit_logs where target_id=v_reservation_ids[5] and action='RESERVATION_ADMIN_NOTE_CHANGED'), 'Audit stores only presence booleans.');

  perform pg_temp.call_attendance(v_admin_id, v_reservation_ids[6], 'start');
  begin
    perform pg_temp.call_cancel(v_employee_id, v_reservation_ids[6]);
  exception when sqlstate '55000' then
    v_error_state := sqlstate;
  end;
  insert into pg_temp.test_results values
    (35, 'START then CANCEL conflict safe', v_error_state='55000' and (select reservation_status='confirmed' and attendance_status='present' and checked_in_at is not null and completed_at is null from public.reservations where id=v_reservation_ids[6]), 'Cancellation cannot corrupt an in-progress visit.');

  v_result := pg_temp.call_cancel(v_employee_id, v_reservation_ids[7]);
  v_result2 := pg_temp.call_attendance(v_admin_id, v_reservation_ids[7], 'start');
  insert into pg_temp.test_results values
    (36, 'CANCEL then START conflict safe', v_result->>'changed'='true' and v_result2->>'code'='invalid_transition' and (select reservation_status='cancelled_by_admin' and attendance_status='planned' and checked_in_at is null and completed_at is null from public.reservations where id=v_reservation_ids[7]), 'A cancelled reservation cannot start.');

  perform pg_temp.call_attendance(v_admin_id, v_reservation_ids[8], 'start');
  perform pg_temp.call_attendance(v_admin_id, v_reservation_ids[8], 'complete');
  v_error_state := null;
  begin
    perform pg_temp.call_cancel(v_employee_id, v_reservation_ids[8]);
  exception when sqlstate '55000' then
    v_error_state := sqlstate;
  end;
  v_result := pg_temp.call_attendance(v_employee_id, v_reservation_ids[8], 'no_show');
  insert into pg_temp.test_results values
    (37, 'COMPLETE then CANCEL conflict safe', v_error_state='55000' and (select reservation_status='completed' and attendance_status='completed' from public.reservations where id=v_reservation_ids[8]), 'Completed reservation cannot be cancelled.'),
    (38, 'COMPLETE then NO-SHOW conflict safe', v_result->>'code'='invalid_transition' and (select reservation_status='completed' and attendance_status='completed' and checked_in_at is not null and completed_at is not null from public.reservations where id=v_reservation_ids[8]), 'Completed reservation cannot become no-show.');

  -- Direct DML is checked through actual authenticated privileges, not only ACL catalogs.
  perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub',v_admin_id,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    update public.reservations set reservation_status='no_show' where id=v_reservation_ids[5];
    get diagnostics v_direct_update_count = row_count;
  exception when insufficient_privilege then
    v_direct_update_count := 0;
  end;
  execute 'reset role';
  insert into pg_temp.test_results values
    (39, 'Admin direct UPDATE denied at ACL', v_direct_update_count=0 and (select reservation_status='confirmed' from public.reservations where id=v_reservation_ids[5]), 'Even admin JWT cannot bypass controlled RPCs.');

  -- Failure atomicity: the audit insert is forced to fail after UPDATE. The
  -- nested block is a subtransaction, so both the row mutation and audit roll back.
  select pg_catalog.to_jsonb(reservation) into v_before
  from public.reservations as reservation where id=v_reservation_ids[5];
  create function pg_temp.fail_reservation_audit()
  returns trigger language plpgsql as $trigger$
  begin
    raise exception 'forced audit failure';
  end;
  $trigger$;
  create trigger test_fail_reservation_audit
  before insert on public.audit_logs
  for each row execute function pg_temp.fail_reservation_audit();
  begin
    perform pg_temp.call_payment(v_admin_id, v_reservation_ids[5], 'paid');
  exception when others then
    null;
  end;
  drop trigger test_fail_reservation_audit on public.audit_logs;
  select pg_catalog.to_jsonb(reservation) into v_after
  from public.reservations as reservation where id=v_reservation_ids[5];
  insert into pg_temp.test_results values
    (40, 'Audit failure rolls back mutation', v_before=v_after and (select pg_catalog.count(*) from public.audit_logs where target_id=v_reservation_ids[5] and action='RESERVATION_PAYMENT_STATUS_CHANGED')=0, 'No partial reservation or audit state remains.');

  insert into pg_temp.test_results values
    (41, 'All test rows remain operationally consistent', not exists (select 1 from public.reservations r where r.id=any(v_reservation_ids) and not ((r.reservation_status='confirmed' and ((coalesce(r.attendance_status,'planned')='planned' and r.checked_in_at is null and r.completed_at is null) or (r.attendance_status='present' and r.checked_in_at is not null and r.completed_at is null))) or (r.reservation_status='completed' and r.attendance_status='completed' and r.checked_in_at is not null and r.completed_at is not null and r.completed_at>=r.checked_in_at) or (r.reservation_status='no_show' and r.attendance_status='no_show' and r.checked_in_at is null and r.completed_at is null) or (r.reservation_status in ('cancelled','canceled','cancelled_by_admin','cancelled_by_user') and coalesce(r.attendance_status,'planned')='planned' and r.checked_in_at is null and r.completed_at is null))), 'Final states satisfy the same cross-column invariant.'),
    (42, 'Critical audit details contain no reservation PII', not exists (select 1 from public.audit_logs a where a.target_id=any(v_reservation_ids) and a.details::text ~* '(example\\.invalid|000000000|customer_name|customer_email|customer_phone|admin_note)'), 'Operational audit details are technical only.'),
    (43, 'Expected audit actions are distinct', (select pg_catalog.count(distinct action)=6 from public.audit_logs where target_id=any(v_reservation_ids) and action in ('RESERVATION_STARTED','RESERVATION_ATTENDANCE_RESET','CHECK_IN_COMPLETED','RESERVATION_NO_SHOW','RESERVATION_PAYMENT_STATUS_CHANGED','RESERVATION_ADMIN_NOTE_CHANGED')), 'Start/reset/complete/no-show/payment/note are distinguishable.'),
    (44, 'SELECT policies preserved', (select pg_catalog.count(*) from pg_catalog.pg_policy where polrelid='public.reservations'::pg_catalog.regclass and polcmd='r')=2, 'Staff and own-reservation reads remain.'),
    (45, 'DELETE policy preserved', exists (select 1 from pg_catalog.pg_policy where polrelid='public.reservations'::pg_catalog.regclass and polcmd='d' and polname='Admins can delete reservations'), 'Existing delete policy is not changed.'),
    (46, 'Cancellation signature and ACL preserved', pg_catalog.to_regprocedure('public.cancel_reservation(uuid)') is not null and pg_catalog.has_function_privilege('authenticated','public.cancel_reservation(uuid)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.cancel_reservation(uuid)','EXECUTE'), 'Cancellation remains its dedicated RPC.'),
    (47, 'Fixture scope is exact', (select pg_catalog.count(*) from public.reservations where id=any(v_reservation_ids))=8 and (select pg_catalog.count(*) from auth.users where id in (v_admin_id,v_employee_id,v_instructor_id,v_user_id,v_customer_id))=5, 'Only deterministic [TEST] fixtures are used.'),
    (48, 'Ready for final ROLLBACK', true, 'Migration, fixtures, mutations and audits are in one transaction.');
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
    raise exception 'Controlled reservation operations tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
