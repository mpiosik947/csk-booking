\set ON_ERROR_STOP on
\pset format unaligned

select '1..28';

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
    'request.jwt.claim.sub',
    coalesce(p_user_id::text, ''),
    true
  );
  execute pg_catalog.format('set local role %I', p_role);
end;
$function$;

create function pg_temp.export_as(p_user_id uuid)
returns jsonb language plpgsql as $function$
declare
  v_result jsonb;
begin
  perform pg_temp.set_client('authenticated', p_user_id);
  select public.export_my_data_v1() into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.anonymize_as(p_user_id uuid)
returns jsonb language plpgsql as $function$
declare
  v_result jsonb;
begin
  perform pg_temp.set_client('authenticated', p_user_id);
  select public.anonymize_my_account_v1() into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.anon_lifecycle_denied(p_function text)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client('anon', null);
  if p_function = 'export' then
    perform public.export_my_data_v1();
  elsif p_function = 'anonymize' then
    perform public.anonymize_my_account_v1();
  else
    raise exception 'Unknown lifecycle function';
  end if;
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

create function pg_temp.reject_account_audit()
returns trigger language plpgsql as $function$
begin
  if new.action = 'account_anonymized' then
    raise exception 'Synthetic audit failure';
  end if;
  return new;
end;
$function$;

do $tests$
declare
  v_user_a uuid := '9c009000-0000-4000-8000-000000000001';
  v_user_b uuid := '9c009000-0000-4000-8000-000000000002';
  v_user_failure uuid := '9c009000-0000-4000-8000-000000000003';
  v_event uuid := '9c009000-0000-4000-8000-000000000010';
  v_reservation_a uuid := '9c009000-0000-4000-8000-000000000020';
  v_reservation_b uuid := '9c009000-0000-4000-8000-000000000021';
  v_reservation_failure uuid := '9c009000-0000-4000-8000-000000000022';
  v_registration_a uuid := '9c009000-0000-4000-8000-000000000030';
  v_registration_b uuid := '9c009000-0000-4000-8000-000000000031';
  v_lane_id uuid := '9c009000-0000-4000-8000-000000000040';
  v_pricing_rule_id uuid := '9c009000-0000-4000-8000-000000000041';
  v_export jsonb;
  v_result jsonb;
  v_pseudonym_hash text;
  v_pseudonym_id uuid;
  v_before_reservations integer;
  v_before_registrations integer;
  v_before_audits integer;
  v_failed boolean := false;
begin
  v_pseudonym_hash := pg_catalog.md5(v_user_a::text || ':csk-sec009-v1');
  v_pseudonym_id := (
    pg_catalog.substr(v_pseudonym_hash, 1, 8) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 9, 4) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 13, 4) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 17, 4) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 21, 12)
  )::uuid;

  insert into public.shooting_lanes(
    id, name, type, description, price_per_hour, is_active, max_shooters,
    booking_step_minutes, display_order, currency_code, resource_kind,
    parent_lane_id, whole_lane_bookable, positions_bookable
  ) values (
    v_lane_id, '[TEST][SEC-009] Lane', 'test', '[TEST][SEC-009]', 10,
    false, 1, 60, 999, 'PLN', 'lane', null, false, false
  );

  insert into public.lane_pricing_rules(
    id, lane_id, day_group, min_shooters, max_shooters, label,
    hourly_price, display_order, is_active
  ) values (
    v_pricing_rule_id, v_lane_id, 'mon_thu', 1, 1,
    '[TEST][SEC-009] Price', 10, 1, true
  );

  insert into auth.users(
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (v_user_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'sec009-a@example.invalid', '', now(), '{}',
      '{"accepted_terms":true,"accepted_terms_at":"2026-01-01T00:00:00Z","accepted_privacy":true,"accepted_privacy_at":"2026-01-01T00:00:00Z"}', now(), now()),
    (v_user_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'sec009-b@example.invalid', '', now(), '{}',
      '{"accepted_terms":"legacy","accepted_privacy":"unknown"}', now(), now()),
    (v_user_failure, '00000000-0000-0000-8000-000000000000', 'authenticated', 'authenticated',
      'sec009-failure@example.invalid', '', now(), '{}', '{}', now(), now());

  insert into public.profiles(
    user_id, role, first_name, last_name, full_name, email, phone,
    city, street, house_number, admin_note, verification_note,
    permissions_verification_note, permission_sport, qualification_instructor
  ) values
    (v_user_a, 'user', '[TEST][SEC-009] Alicja', 'Alpha', '[TEST][SEC-009] Alicja Alpha',
      'sec009-a@example.invalid', '500000001', 'Testowo', 'Sekretna 1', '1',
      'SEC009 ADMIN NOTE A', 'SEC009 VERIFY NOTE A', 'SEC009 PERMISSION NOTE A', true, true),
    (v_user_b, 'user', '[TEST][SEC-009] Barbara', 'Beta', '[TEST][SEC-009] Barbara Beta',
      'sec009-b@example.invalid', '500000002', 'Kontrolne', 'Inna 2', '2',
      'SEC009 ADMIN NOTE B', null, null, false, false),
    (v_user_failure, 'user', '[TEST][SEC-009] Failure', 'Gamma', '[TEST][SEC-009] Failure Gamma',
      'sec009-failure@example.invalid', '500000003', null, null, null,
      'SEC009 FAILURE NOTE', null, null, false, false);

  insert into public.events(
    id, title, event_date, start_time, end_time, location, price,
    max_participants, is_active
  ) values (
    v_event, '[TEST][SEC-009] Event', date '2099-09-04', time '10:00',
    time '11:00', '[TEST]', 0, 10, true
  );

  insert into public.reservations(
    id, user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes, price,
    reservation_status, payment_status, attendance_status, admin_note,
    check_in_token, reservation_note, shooters_count, pricing_rule_id,
    pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
    price_per_hour_snapshot, total_price, currency_code, creation_request_id
  ) values
    (v_reservation_a, v_user_a, v_lane_id, '[TEST][SEC-009] Alicja Alpha',
      'sec009-a@example.invalid', '500000001', date '2099-09-05', time '10:00',
      time '11:00', 60, 10, 'confirmed', 'pay_on_site', 'planned',
      'SEC009 RESERVATION ADMIN NOTE A', pg_catalog.gen_random_uuid(),
      'SEC009 RESERVATION NOTE A', 1, v_pricing_rule_id, 'mon_thu',
      '[TEST] Lane snapshot', '[TEST] Price snapshot', 10, 10, 'PLN',
      pg_catalog.gen_random_uuid()),
    (v_reservation_b, v_user_b, v_lane_id, '[TEST][SEC-009] Barbara Beta',
      'sec009-b@example.invalid', '500000002', date '2099-09-06', time '10:00',
      time '11:00', 60, 20, 'confirmed', 'pay_on_site', 'planned',
      'SEC009 RESERVATION ADMIN NOTE B', pg_catalog.gen_random_uuid(),
      'SEC009 RESERVATION NOTE B', 1, v_pricing_rule_id, 'mon_thu',
      '[TEST] Lane snapshot', '[TEST] Price snapshot', 20, 20, 'PLN',
      pg_catalog.gen_random_uuid()),
    (v_reservation_failure, v_user_failure, v_lane_id, '[TEST][SEC-009] Failure Gamma',
      'sec009-failure@example.invalid', '500000003', date '2099-09-07', time '10:00',
      time '11:00', 60, 30, 'confirmed', 'pay_on_site', 'planned',
      'SEC009 FAILURE ADMIN NOTE', pg_catalog.gen_random_uuid(),
      'SEC009 FAILURE NOTE', 1, v_pricing_rule_id, 'mon_thu',
      '[TEST] Lane snapshot', '[TEST] Price snapshot', 30, 30, 'PLN',
      pg_catalog.gen_random_uuid());

  insert into public.event_registrations(
    id, event_id, user_id, customer_name, customer_email, customer_phone,
    registration_status, payment_status, promotion_token,
    promotion_token_expires_at, promotion_email_sent_at, promotion_confirmed_at
  ) values
    (v_registration_a, v_event, v_user_a, '[TEST][SEC-009] Alicja Alpha',
      'sec009-a@example.invalid', '500000001', 'approved', 'paid_on_site',
      'sec009-token-a', now() + interval '1 day', now(), now()),
    (v_registration_b, v_event, v_user_b, '[TEST][SEC-009] Barbara Beta',
      'sec009-b@example.invalid', '500000002', 'registered', 'pay_on_site',
      'sec009-token-b', now() + interval '1 day', now(), null);

  insert into public.email_deliveries(
    message_type, record_id, recipient_user_id, sent_at, provider_message_id
  ) values
    ('reservation_confirmation', v_reservation_a, v_user_a, now(), 'sec009-provider-a'),
    ('reservation_confirmation', v_reservation_b, v_user_b, now(), 'sec009-provider-b');

  insert into public.confirmation_email_rate_limits(
    scope_type, scope_key, request_timestamps
  ) values
    ('user', v_user_a::text, array[now()]),
    ('user', v_user_b::text, array[now()]);

  insert into public.audit_logs(
    actor_user_id, actor_name, actor_role, action, target_type, target_id,
    target_name, details
  ) values
    (v_user_a, '[TEST][SEC-009] Alicja Alpha', 'user', 'fixture_action',
      'reservation', v_reservation_a, '[TEST][SEC-009] Alicja Alpha',
      pg_catalog.jsonb_build_object(
        'customer_email', 'sec009-a@example.invalid',
        'phone', '500000001',
        'nested', pg_catalog.jsonb_build_object('admin_note', 'SEC009 ADMIN NOTE A'),
        'subject_id', v_user_a::text,
        'permissions_verified_by', (select profile.id::text from public.profiles as profile where profile.user_id = v_user_a),
        'safe_status', 'confirmed'
      )),
    (v_user_b, '[TEST][SEC-009] Barbara Beta', 'user', 'fixture_action',
      'reservation', v_reservation_b, '[TEST][SEC-009] Barbara Beta',
      pg_catalog.jsonb_build_object('safe_status', 'confirmed'));

  select count(*) into v_before_reservations from public.reservations
  where id in (v_reservation_a, v_reservation_b, v_reservation_failure);
  select count(*) into v_before_registrations from public.event_registrations
  where id in (v_registration_a, v_registration_b);
  select count(*) into v_before_audits from public.audit_logs
  where action = 'fixture_action' and target_id in (v_reservation_a, v_reservation_b);

  perform pg_temp.record_result(1, 'Lifecycle function signatures are exact',
    pg_catalog.to_regprocedure('public.export_my_data_v1()') is not null
    and pg_catalog.to_regprocedure('public.anonymize_my_account_v1()') is not null
    and (select count(*) = 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'export_my_data_v1')
    and (select count(*) = 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'anonymize_my_account_v1'),
    'Obie funkcje muszą być jednoznaczne i bez parametrów użytkownika.');

  perform pg_temp.record_result(2, 'Lifecycle SECURITY DEFINER properties are hardened',
    (select bool_and(p.prosecdef and p.proowner = 'postgres'::regrole and p.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[])
      from pg_catalog.pg_proc p where p.oid in ('public.export_my_data_v1()'::regprocedure, 'public.anonymize_my_account_v1()'::regprocedure)),
    'Owner, SECURITY DEFINER i search_path muszą być kontrolowane.');

  perform pg_temp.record_result(3, 'Lifecycle ACL is authenticated-only',
    pg_catalog.has_function_privilege('authenticated', 'public.export_my_data_v1()', 'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated', 'public.anonymize_my_account_v1()', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon', 'public.export_my_data_v1()', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon', 'public.anonymize_my_account_v1()', 'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role', 'public.export_my_data_v1()', 'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role', 'public.anonymize_my_account_v1()', 'EXECUTE'),
    'PUBLIC/anon/service_role nie mogą wykonywać owner lifecycle RPC.');

  perform pg_temp.record_result(4, 'Anon calls are denied',
    pg_temp.anon_lifecycle_denied('export') and pg_temp.anon_lifecycle_denied('anonymize'),
    'Brak JWT musi zakończyć oba wywołania SQLSTATE 42501.');

  v_export := pg_temp.export_as(v_user_a);

  perform pg_temp.record_result(5, 'Export has the stable versioned top-level contract',
    (select pg_catalog.array_agg(key order by key) = array['account','event_registrations','export_version','generated_at','profile','reservations']::text[] from pg_catalog.jsonb_object_keys(v_export) as key)
    and v_export->>'export_version' = '1',
    'Eksport nie może dodawać niezatwierdzonych sekcji.');

  perform pg_temp.record_result(6, 'Export is scoped to auth.uid()',
    v_export->'account'->>'id' = v_user_a::text
    and pg_catalog.jsonb_array_length(v_export->'reservations') = 1
    and v_export->'reservations'->0->>'id' = v_reservation_a::text
    and pg_catalog.jsonb_array_length(v_export->'event_registrations') = 1
    and v_export->'event_registrations'->0->>'id' = v_registration_a::text
    and v_export::text not like '%' || v_user_b::text || '%',
    'Użytkownik nie może eksportować cudzych rekordów.');

  perform pg_temp.record_result(7, 'Export includes approved user data',
    v_export->'account'->>'email' = 'sec009-a@example.invalid'
    and v_export->'profile'->>'first_name' = '[TEST][SEC-009] Alicja'
    and (v_export->'profile'->>'permission_sport')::boolean
    and (v_export->'profile'->>'qualification_instructor')::boolean
    and v_export->'reservations'->0->>'reservation_note' = 'SEC009 RESERVATION NOTE A',
    'Allowlista powinna obejmować dane konta, profilu i historię właściciela.');

  perform pg_temp.record_result(8, 'Export excludes secrets and staff-only notes',
    v_export::text !~ '"(check_in_token|promotion_token|admin_note|verification_note|permissions_verification_note|raw_app_meta_data|raw_user_meta_data|audit_logs)"[[:space:]]*:'
    and v_export::text not like '%sec009-token-a%'
    and v_export::text not like '%SEC009 ADMIN NOTE A%',
    'Tokeny, audit i notatki administracyjne nie mogą trafić do eksportu.');

  v_export := pg_temp.export_as(v_user_b);
  perform pg_temp.record_result(9, 'Malformed historical consent metadata fails safely',
    v_export is not null
      and not (v_export->'account'->>'accepted_terms')::boolean
      and not (v_export->'account'->>'accepted_privacy')::boolean,
    'Niepoprawne historyczne flagi nie mogą psuć eksportu i mają dawać bezpieczne false.');

  v_result := pg_temp.anonymize_as(v_user_a);
  perform pg_temp.record_result(10, 'First anonymization reports one atomic change',
    v_result @> '{"ok":true,"changed":true,"code":"anonymized","reservation_count":1,"event_registration_count":1}'::jsonb,
    'Pierwsze wywołanie musi podać kontrolowany rezultat i liczniki.');

  perform pg_temp.record_result(11, 'Profile PII is deleted while the other profile remains',
    not exists(select 1 from public.profiles where user_id = v_user_a)
    and exists(select 1 from public.profiles where user_id = v_user_b and email = 'sec009-b@example.invalid'),
    'Usunięcie profilu musi dotyczyć wyłącznie właściciela.');

  perform pg_temp.record_result(12, 'Reservation history is retained and anonymized',
    exists(select 1 from public.reservations where id = v_reservation_a
      and user_id is null and customer_name like 'deleted-user-%'
      and customer_email like 'deleted-user-%@invalid.local'
      and customer_phone = '[redacted]' and admin_note is null
      and reservation_note is null and check_in_token is null
      and pii_anonymized_at is not null and reservation_status = 'confirmed'
      and total_price = 10 and lane_id = v_lane_id),
    'Historia operacyjna ma pozostać bez identyfikującego PII i tokenu.');

  perform pg_temp.record_result(13, 'Event registration history is retained and anonymized',
    exists(select 1 from public.event_registrations where id = v_registration_a
      and user_id is null and customer_name like 'deleted-user-%'
      and customer_email like 'deleted-user-%@invalid.local'
      and customer_phone = '[redacted]' and promotion_token is null
      and promotion_token_expires_at is null and promotion_claim_id is null
      and promotion_claim_expires_at is null and promotion_last_error_code is null
      and pii_anonymized_at is not null and promotion_email_sent_at is not null
      and promotion_confirmed_at is not null and registration_status = 'approved'),
    'Historia eventu i timestampy operacyjne pozostają, token/PII znikają.');

  perform pg_temp.record_result(14, 'Technical delivery and user rate-limit state is removed',
    not exists(select 1 from public.email_deliveries where recipient_user_id = v_user_a)
    and not exists(select 1 from public.confirmation_email_rate_limits where scope_type = 'user' and scope_key = v_user_a::text)
    and exists(select 1 from public.email_deliveries where recipient_user_id = v_user_b)
    and exists(select 1 from public.confirmation_email_rate_limits where scope_type = 'user' and scope_key = v_user_b::text),
    'Cleanup danych technicznych musi być ownership-scoped.');

  perform pg_temp.record_result(15, 'Existing audit is pseudonymized without losing safe facts',
    exists(select 1 from public.audit_logs where action = 'fixture_action' and target_id = v_reservation_a
      and actor_user_id = v_pseudonym_id and actor_name like 'deleted-user-%'
      and details->>'safe_status' = 'confirmed'
      and details->>'permissions_verified_by' = '[redacted]'
      and details::text not like '%sec009-a@example.invalid%'
      and details::text not like '%500000001%'
      and details::text not like '%SEC009 ADMIN NOTE A%'),
    'Historia audytu pozostaje użyteczna bez bezpośredniego PII i notatek.');

  perform pg_temp.record_result(16, 'Exactly one pseudonymous deletion audit is written',
    (select count(*) = 1 from public.audit_logs where action = 'account_anonymized' and actor_user_id = v_pseudonym_id and target_id = v_pseudonym_id)
    and exists(select 1 from public.audit_logs where action = 'account_anonymized' and actor_user_id = v_pseudonym_id
      and actor_name like 'deleted-user-%' and target_name like 'deleted-user-%'
      and details::text !~* '"(email|phone|check_in_token|promotion_token|jwt|secret|admin_note)"[[:space:]]*:'),
    'Pierwsza zmiana ma utworzyć dokładnie jeden bezpieczny audit.');

  v_result := pg_temp.anonymize_as(v_user_a);
  perform pg_temp.record_result(17, 'Repeated anonymization is idempotent',
    v_result @> '{"ok":true,"changed":false,"code":"already_anonymized"}'::jsonb
    and (select count(*) = 1 from public.audit_logs where action = 'account_anonymized' and actor_user_id = v_pseudonym_id and target_id = v_pseudonym_id),
    'Retry nie może tworzyć drugiego auditu ani drugiej mutacji.');

  perform pg_temp.record_result(18, 'Other user data remains byte-for-byte identifiable',
    exists(select 1 from public.reservations where id = v_reservation_b and user_id = v_user_b
      and customer_email = 'sec009-b@example.invalid' and admin_note = 'SEC009 RESERVATION ADMIN NOTE B'
      and check_in_token is not null and pii_anonymized_at is null)
    and exists(select 1 from public.event_registrations where id = v_registration_b and user_id = v_user_b
      and customer_email = 'sec009-b@example.invalid' and promotion_token = 'sec009-token-b'
      and pii_anonymized_at is null),
    'Operacja owner-scoped nie może zmienić danych innego użytkownika.');

  perform pg_temp.record_result(19, 'Operational record counts do not change',
    (select count(*) from public.reservations where id in (v_reservation_a, v_reservation_b, v_reservation_failure)) = v_before_reservations
    and (select count(*) from public.event_registrations where id in (v_registration_a, v_registration_b)) = v_before_registrations,
    'Rezerwacje i registrations mają zostać zachowane historycznie.');

  perform pg_temp.record_result(20, 'Auth identity remains until the server-side final step',
    exists(select 1 from auth.users where id = v_user_a),
    'RPC DB nie może samodzielnie usuwać Auth usera.');

  delete from auth.users where id = v_user_a;
  perform pg_temp.record_result(21, 'Auth identity can be deleted after unlinking business history',
    not exists(select 1 from auth.users where id = v_user_a)
    and exists(select 1 from public.reservations where id = v_reservation_a and user_id is null)
    and exists(select 1 from public.event_registrations where id = v_registration_a and user_id is null),
    'Kolejność DB anonymization -> Auth deletion musi respektować FK i historię.');

  execute 'create trigger sec009_reject_account_audit before insert on public.audit_logs for each row execute function pg_temp.reject_account_audit()';
  begin
    perform pg_temp.anonymize_as(v_user_failure);
  exception when others then
    v_failed := true;
  end;
  execute 'drop trigger sec009_reject_account_audit on public.audit_logs';

  perform pg_temp.record_result(22, 'Audit failure aborts anonymization', v_failed,
    'Błąd zaufanego auditu musi przerwać całą transakcję RPC.');

  perform pg_temp.record_result(23, 'Audit failure leaves profile PII intact',
    exists(select 1 from public.profiles where user_id = v_user_failure
      and email = 'sec009-failure@example.invalid' and admin_note = 'SEC009 FAILURE NOTE'),
    'Nie może powstać częściowy stan po błędzie DB.');

  perform pg_temp.record_result(24, 'Audit failure leaves reservation and token intact',
    exists(select 1 from public.reservations where id = v_reservation_failure
      and user_id = v_user_failure and customer_email = 'sec009-failure@example.invalid'
      and reservation_note = 'SEC009 FAILURE NOTE' and check_in_token is not null
      and pii_anonymized_at is null),
    'Rollback wewnętrznej operacji ma przywrócić PII, powiązanie i token.');

  perform pg_temp.record_result(25, 'Audit failure writes no deletion audit',
    not exists(select 1 from public.audit_logs where action = 'account_anonymized' and actor_user_id = v_user_failure),
    'Failing RPC nie może zostawić fałszywego auditu sukcesu.');

  perform pg_temp.record_result(26, 'Audit history remains append-only to clients',
    not pg_catalog.has_table_privilege('authenticated', 'public.audit_logs', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
    'SEC-009 nie może osłabić SEC-007.');

  perform pg_temp.record_result(27, 'Anonymization schema supports retained history',
    exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'reservations' and column_name = 'user_id' and is_nullable = 'YES')
    and exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'reservations' and column_name = 'check_in_token' and is_nullable = 'YES')
    and exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'reservations' and column_name = 'pii_anonymized_at' and data_type = 'timestamp with time zone')
    and exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'event_registrations' and column_name = 'pii_anonymized_at' and data_type = 'timestamp with time zone'),
    'Minimalne kolumny/nullability muszą wspierać anonimizację bez kasowania historii.');

  perform pg_temp.record_result(28, 'Fixture baseline remained internally consistent',
    v_before_audits = 2
    and exists(select 1 from auth.users where id = v_user_b)
    and exists(select 1 from auth.users where id = v_user_failure),
    'Test nie może uzyskać PASS na niepełnym fixture.');
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
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  )
  into v_failures
  from pg_temp.test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'SEC-009 tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
