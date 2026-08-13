\set ON_ERROR_STOP on

-- Psql-only security contract test. The migration, every schema-only malformed
-- hierarchy fixture, and all [TEST][6C-2E-A] rows are enclosed in one
-- transaction and removed by the final ROLLBACK.
begin;

create temporary table my_reservations_v2_baseline (
  policies_hash text not null,
  table_acl_hash text not null
) on commit drop;

insert into pg_temp.my_reservations_v2_baseline (
  policies_hash,
  table_acl_hash
)
select
  (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      policy.polrelid::text || ':' || policy.polname || ':' ||
      policy.polcmd::text || ':' || policy.polroles::text || ':' ||
      coalesce(pg_catalog.pg_get_expr(policy.polqual, policy.polrelid), '') || ':' ||
      coalesce(pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid), ''),
      E'\n' order by policy.polrelid, policy.polname
    ), ''))
    from pg_catalog.pg_policy as policy
    where policy.polrelid in (
      'public.reservations'::pg_catalog.regclass,
      'public.shooting_lanes'::pg_catalog.regclass
    )
  ),
  (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      relation.oid::text || ':' || acl.grantee::text || ':' ||
      acl.grantor::text || ':' || acl.privilege_type || ':' ||
      acl.is_grantable::text,
      E'\n' order by relation.oid, acl.grantee, acl.privilege_type
    ), ''))
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
    ) as acl
    where relation.oid in (
      'public.reservations'::pg_catalog.regclass,
      'public.shooting_lanes'::pg_catalog.regclass
    )
  );

\ir ../migrations/20260813120000_add_my_reservations_v2_read_rpc.sql

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

create function pg_temp.call_my_reservations(p_user_id uuid)
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
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', p_user_id::text, true
  );
  execute 'set local role authenticated';
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.to_jsonb(result_row)
      order by result_row.reservation_date desc,
               result_row.start_time desc,
               result_row.id desc
    ),
    '[]'::jsonb
  )
  into v_result
  from public.get_my_reservations_v2() as result_row;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_my_reservations_sqlstate(
  p_role name,
  p_user_id uuid
)
returns text
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    case
      when p_user_id is null then '{}'::jsonb::text
      else pg_catalog.jsonb_build_object(
        'sub', p_user_id,
        'role', p_role
      )::text
    end,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', coalesce(p_user_id::text, ''), true
  );
  execute pg_catalog.format('set local role %I', p_role);
  perform pg_catalog.count(*) from public.get_my_reservations_v2();
  execute 'reset role';
  return null;
exception when others then
  execute 'reset role';
  return sqlstate;
end;
$function$;

create function pg_temp.visible_inactive_lane_count(
  p_user_id uuid,
  p_lane_ids uuid[]
)
returns bigint
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_count bigint;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', p_user_id::text, true
  );
  execute 'set local role authenticated';
  select pg_catalog.count(*)
  into v_count
  from public.shooting_lanes as lane
  where lane.id = any(p_lane_ids)
    and not lane.is_active;
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
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', p_user_id::text, true
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

create function pg_temp.insert_test_reservation(
  p_id uuid,
  p_user_id uuid,
  p_lane_id uuid,
  p_date date,
  p_start time without time zone
)
returns void
language sql
as $function$
  insert into public.reservations (
    id, user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes, price,
    reservation_status, payment_status, attendance_status, check_in_token,
    reservation_note, shooters_count, pricing_rule_id,
    pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
    price_per_hour_snapshot, total_price, currency_code, creation_request_id
  ) values (
    p_id,
    p_user_id,
    p_lane_id,
    '[TEST][6C-2E-A]',
    'test-6c2ea-reservation@example.invalid',
    '000000000',
    p_date,
    p_start,
    p_start + interval '1 hour',
    60,
    100,
    'confirmed',
    'pay_on_site',
    'planned',
    pg_catalog.gen_random_uuid(),
    '[TEST][6C-2E-A]',
    1,
    '6c2e0000-0000-4000-8000-000000000301',
    'mon_thu',
    '[TEST][6C-2E-A]',
    '[TEST][6C-2E-A]',
    100,
    100,
    'PLN',
    pg_catalog.gen_random_uuid()
  );
$function$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) values
  ('6c2e0000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test-6c2ea-user-a@example.invalid', '', pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb, pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
  ('6c2e0000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test-6c2ea-user-b@example.invalid', '', pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb, pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
  ('6c2e0000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test-6c2ea-instructor@example.invalid', '', pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb, pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
  ('6c2e0000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test-6c2ea-admin@example.invalid', '', pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb, pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
  ('6c2e0000-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test-6c2ea-employee@example.invalid', '', pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb, pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp());

update public.profiles
set role = case
      when user_id = '6c2e0000-0000-4000-8000-000000000003'::uuid
        then 'instruktor'
      when user_id = '6c2e0000-0000-4000-8000-000000000004'::uuid
        then 'admin'
      when user_id = '6c2e0000-0000-4000-8000-000000000005'::uuid
        then 'pracownik'
      else 'user'
    end,
    first_name = '[TEST]',
    last_name = '6C-2E-A',
    full_name = '[TEST][6C-2E-A]',
    email = 'test-6c2ea-profile@example.invalid',
    phone = '000000000',
    verification_status = 'verified',
    permissions_verified = true
where user_id in (
  '6c2e0000-0000-4000-8000-000000000001'::uuid,
  '6c2e0000-0000-4000-8000-000000000002'::uuid,
  '6c2e0000-0000-4000-8000-000000000003'::uuid,
  '6c2e0000-0000-4000-8000-000000000004'::uuid,
  '6c2e0000-0000-4000-8000-000000000005'::uuid
);

insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values
  ('6c2e0000-0000-4000-8000-000000000101', '[TEST][6C-2E-A] Active Parent', '[TEST]', '[TEST][6C-2E-A]', 100, true, 5, 60, 9951, 'PLN', 'lane', null, true, false),
  ('6c2e0000-0000-4000-8000-000000000102', '[TEST][6C-2E-A] Inactive Parent', '[TEST]', '[TEST][6C-2E-A]', 100, false, 5, 60, 9952, 'PLN', 'lane', null, true, true),
  ('6c2e0000-0000-4000-8000-000000000103', '[TEST][6C-2E-A] Inactive Child', '[TEST]', '[TEST][6C-2E-A]', 100, false, 1, 60, 9953, 'PLN', 'position', '6c2e0000-0000-4000-8000-000000000102', false, false);

insert into public.lane_pricing_rules (
  id, lane_id, day_group, min_shooters, max_shooters,
  label, hourly_price, display_order, is_active
) values (
  '6c2e0000-0000-4000-8000-000000000301',
  '6c2e0000-0000-4000-8000-000000000101',
  'mon_thu', 1, 5, '[TEST][6C-2E-A]', 100, 1, true
);

select pg_temp.insert_test_reservation(
  '6c2e0000-0000-4000-8000-000000000401',
  '6c2e0000-0000-4000-8000-000000000001',
  '6c2e0000-0000-4000-8000-000000000101',
  current_date + 9001, time '10:00'
);
select pg_temp.insert_test_reservation(
  '6c2e0000-0000-4000-8000-000000000402',
  '6c2e0000-0000-4000-8000-000000000001',
  '6c2e0000-0000-4000-8000-000000000102',
  current_date + 9002, time '11:00'
);
select pg_temp.insert_test_reservation(
  '6c2e0000-0000-4000-8000-000000000403',
  '6c2e0000-0000-4000-8000-000000000001',
  '6c2e0000-0000-4000-8000-000000000103',
  current_date + 9003, time '12:00'
);
select pg_temp.insert_test_reservation(
  '6c2e0000-0000-4000-8000-000000000404',
  '6c2e0000-0000-4000-8000-000000000002',
  '6c2e0000-0000-4000-8000-000000000101',
  current_date + 9004, time '13:00'
);
select pg_temp.insert_test_reservation(
  '6c2e0000-0000-4000-8000-000000000405',
  '6c2e0000-0000-4000-8000-000000000003',
  '6c2e0000-0000-4000-8000-000000000103',
  current_date + 9005, time '14:00'
);

do $contract_tests$
declare
  v_user_a jsonb := pg_temp.call_my_reservations(
    '6c2e0000-0000-4000-8000-000000000001'
  );
  v_user_b jsonb := pg_temp.call_my_reservations(
    '6c2e0000-0000-4000-8000-000000000002'
  );
  v_instructor jsonb := pg_temp.call_my_reservations(
    '6c2e0000-0000-4000-8000-000000000003'
  );
  v_definition text := pg_catalog.pg_get_functiondef(
    'public.get_my_reservations_v2()'::pg_catalog.regprocedure
  );
  v_policies_hash text;
  v_table_acl_hash text;
begin
  perform pg_temp.record_result(1, 'Exact no-argument RPC exists',
    pg_catalog.to_regprocedure('public.get_my_reservations_v2()') is not null
    and (
      select pg_catalog.count(*) = 1
      from pg_catalog.pg_proc as procedure
      join pg_catalog.pg_namespace as namespace
        on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'public'
        and procedure.proname = 'get_my_reservations_v2'
        and procedure.pronargs = 0
    ),
    'Exactly one no-argument ownership-scoped list RPC is required.');

  perform pg_temp.record_result(2, 'Minimal output contract',
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_array(
          procedure.proargnames[argument_index],
          pg_catalog.format_type(
            procedure.proallargtypes[argument_index], null
          )
        )
        order by argument_index
      ) = $json$[
        ["id", "uuid"],
        ["reservation_date", "date"],
        ["start_time", "time without time zone"],
        ["end_time", "time without time zone"],
        ["price", "numeric"],
        ["reservation_status", "text"],
        ["payment_status", "text"],
        ["check_in_token", "uuid"],
        ["attendance_status", "text"],
        ["checked_in_at", "timestamp with time zone"],
        ["lane_display_name", "text"]
      ]$json$::jsonb
      from pg_catalog.pg_proc as procedure
      cross join lateral pg_catalog.generate_subscripts(
        procedure.proargnames, 1
      ) as argument_index
      where procedure.oid =
        'public.get_my_reservations_v2()'::pg_catalog.regprocedure
        and procedure.proargmodes[argument_index] = 't'
    ),
    'Only fields required by the current /my-reservations UI are returned.');

  perform pg_temp.record_result(3, 'User A sees exactly three own rows',
    pg_catalog.jsonb_array_length(v_user_a) = 3,
    'User A receives all own fixtures and no other reservation.');

  perform pg_temp.record_result(4, 'Active parent display name',
    exists (
      select 1
      from pg_catalog.jsonb_array_elements(v_user_a) as item
      where item->>'id' = '6c2e0000-0000-4000-8000-000000000401'
        and item->>'lane_display_name' = '[TEST][6C-2E-A] Active Parent'
    ),
    'A standalone/root lane uses its own authoritative current name.');

  perform pg_temp.record_result(5, 'Inactive parent remains readable by ownership',
    exists (
      select 1
      from pg_catalog.jsonb_array_elements(v_user_a) as item
      where item->>'id' = '6c2e0000-0000-4000-8000-000000000402'
        and item->>'lane_display_name' = '[TEST][6C-2E-A] Inactive Parent'
    ),
    'An own historical reservation keeps its inactive root label.');

  perform pg_temp.record_result(6, 'Inactive child and parent hierarchy label',
    exists (
      select 1
      from pg_catalog.jsonb_array_elements(v_user_a) as item
      where item->>'id' = '6c2e0000-0000-4000-8000-000000000403'
        and item->>'lane_display_name' =
          '[TEST][6C-2E-A] Inactive Parent — [TEST][6C-2E-A] Inactive Child'
    ),
    'Inactive parent and child are named only through the owned reservation.');

  perform pg_temp.record_result(7, 'User B isolation',
    pg_catalog.jsonb_array_length(v_user_b) = 1
    and v_user_b->0->>'id' = '6c2e0000-0000-4000-8000-000000000404'
    and not exists (
      select 1 from pg_catalog.jsonb_array_elements(v_user_b) as item
      where item->>'id' in (
        '6c2e0000-0000-4000-8000-000000000401',
        '6c2e0000-0000-4000-8000-000000000402',
        '6c2e0000-0000-4000-8000-000000000403'
      )
    ),
    'User B receives only User B ownership scope.');

  perform pg_temp.record_result(8, 'Instructor ownership without global scope',
    pg_catalog.jsonb_array_length(v_instructor) = 1
    and v_instructor->0->>'id' = '6c2e0000-0000-4000-8000-000000000405',
    'Instructor can read an own reservation but none owned by other users.');

  perform pg_temp.record_result(9, 'Ordinary user cannot enumerate inactive lanes',
    pg_temp.visible_inactive_lane_count(
      '6c2e0000-0000-4000-8000-000000000001',
      array[
        '6c2e0000-0000-4000-8000-000000000102'::uuid,
        '6c2e0000-0000-4000-8000-000000000103'::uuid
      ]
    ) = 0,
    'The SECURITY DEFINER exception does not widen shooting_lanes RLS.');

  perform pg_temp.record_result(10, 'Anon has no EXECUTE',
    pg_temp.call_my_reservations_sqlstate('anon', null) = '42501',
    'Anon is denied before any reservation or lane metadata is returned.');

  perform pg_temp.record_result(11, 'Authenticated call without auth.uid fails closed',
    pg_temp.call_my_reservations_sqlstate('authenticated', null) = '42501',
    'An executable RPC still requires an authenticated subject internally.');

  perform pg_temp.record_result(12, 'Exact EXECUTE ACL',
    pg_catalog.has_function_privilege(
      'authenticated', 'public.get_my_reservations_v2()', 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon', 'public.get_my_reservations_v2()', 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'service_role', 'public.get_my_reservations_v2()', 'EXECUTE'
    )
    and not exists (
      select 1
      from pg_catalog.pg_proc as procedure
      cross join lateral pg_catalog.aclexplode(
        coalesce(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))
      ) as acl
      where procedure.oid =
        'public.get_my_reservations_v2()'::pg_catalog.regprocedure
        and acl.grantee = 0
        and acl.privilege_type = 'EXECUTE'
    ),
    'Only authenticated receives explicit client EXECUTE.');

  perform pg_temp.record_result(13, 'SECURITY DEFINER properties',
    exists (
      select 1
      from pg_catalog.pg_proc as procedure
      join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure.proowner
      join pg_catalog.pg_language as language on language.oid = procedure.prolang
      where procedure.oid =
        'public.get_my_reservations_v2()'::pg_catalog.regprocedure
        and procedure.prosecdef
        and procedure.provolatile = 's'
        and procedure.proconfig =
          array['search_path=pg_catalog, public, pg_temp']::text[]
        and owner_role.rolname = 'postgres'
        and language.lanname = 'plpgsql'
    ),
    'Owner, stable volatility and fixed safe search_path are exact.');

  perform pg_temp.record_result(14, 'Ownership and static SQL definition',
    v_definition ~ 'auth\.uid\(\)'
    and v_definition ~ 'reservation\.user_id = v_user_id'
    and v_definition !~* '\mexecute\M'
    and v_definition !~* '\mformat\s*\('
    and v_definition !~* '\m(insert|update|delete|merge|truncate|alter|drop|grant|revoke)\M'
    and v_definition !~* 'customer_(name|email|phone)'
    and v_definition !~* '\madmin_note\M'
    and v_definition !~* '\mreservation_note\M',
    'No caller-owned identifier, dynamic SQL, PII or operational notes are used.');

  perform pg_temp.record_result(15, 'Exact result keys contain no PII',
    not exists (
      select 1
      from pg_catalog.jsonb_array_elements(v_user_a) as item
      cross join lateral pg_catalog.jsonb_object_keys(item) as key_name
      where key_name not in (
        'id', 'reservation_date', 'start_time', 'end_time', 'price',
        'reservation_status', 'payment_status', 'check_in_token',
        'attendance_status', 'checked_in_at', 'lane_display_name'
      )
    ),
    'The result cannot expose customer, staff, pricing-rule or internal lane fields.');

  perform pg_temp.record_result(16, 'Stable deterministic sorting',
    (v_user_a->0->>'id') = '6c2e0000-0000-4000-8000-000000000403'
    and (v_user_a->1->>'id') = '6c2e0000-0000-4000-8000-000000000402'
    and (v_user_a->2->>'id') = '6c2e0000-0000-4000-8000-000000000401',
    'Date, time and id descending preserve current list semantics with a tie-breaker.');

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    policy.polrelid::text || ':' || policy.polname || ':' ||
    policy.polcmd::text || ':' || policy.polroles::text || ':' ||
    coalesce(pg_catalog.pg_get_expr(policy.polqual, policy.polrelid), '') || ':' ||
    coalesce(pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid), ''),
    E'\n' order by policy.polrelid, policy.polname
  ), ''))
  into v_policies_hash
  from pg_catalog.pg_policy as policy
  where policy.polrelid in (
    'public.reservations'::pg_catalog.regclass,
    'public.shooting_lanes'::pg_catalog.regclass
  );

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    relation.oid::text || ':' || acl.grantee::text || ':' ||
    acl.grantor::text || ':' || acl.privilege_type || ':' ||
    acl.is_grantable::text,
    E'\n' order by relation.oid, acl.grantee, acl.privilege_type
  ), ''))
  into v_table_acl_hash
  from pg_catalog.pg_class as relation
  cross join lateral pg_catalog.aclexplode(
    coalesce(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
  ) as acl
  where relation.oid in (
    'public.reservations'::pg_catalog.regclass,
    'public.shooting_lanes'::pg_catalog.regclass
  );

  perform pg_temp.record_result(17, 'Existing RLS policies unchanged',
    exists (
      select 1 from pg_temp.my_reservations_v2_baseline as baseline
      where baseline.policies_hash = v_policies_hash
    ),
    'No reservations or shooting_lanes policy was added, removed or changed.');

  perform pg_temp.record_result(18, 'Existing table grants unchanged',
    exists (
      select 1 from pg_temp.my_reservations_v2_baseline as baseline
      where baseline.table_acl_hash = v_table_acl_hash
    ),
    'No direct table privilege was widened.');

  perform pg_temp.record_result(19, 'P0-B ownership policy remains exact',
    exists (
      select 1
      from pg_catalog.pg_policy as policy
      where policy.polrelid = 'public.reservations'::pg_catalog.regclass
        and policy.polname = 'Users can view own reservations'
        and policy.polcmd = 'r'
        and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
        and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) =
          '(user_id = auth.uid())'
        and policy.polwithcheck is null
    ),
    'The P0-B table-level ownership boundary is preserved.');

  perform pg_temp.record_result(20, 'Public inactive-lane policy remains exact',
    exists (
      select 1
      from pg_catalog.pg_policy as policy
      where policy.polrelid = 'public.shooting_lanes'::pg_catalog.regclass
        and policy.polname = 'Public can view active shooting lanes'
        and policy.polcmd = 'r'
        and policy.polroles = array[0::oid]
        and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) =
          '(is_active = true)'
        and policy.polwithcheck is null
    ),
    'Inactive resources remain hidden from ordinary direct SELECT.');
end;
$contract_tests$;

do $p0_regression$
declare
  v_target constant uuid := '6c2e0000-0000-4000-8000-000000000404';
  v_before jsonb;
  v_after jsonb;
  v_audits_before bigint;
  v_audits_after bigint;
  v_instructor_result jsonb;
  v_user_result jsonb;
  v_admin_result jsonb;
  v_employee_result jsonb;
begin
  select pg_catalog.to_jsonb(reservation)
  into v_before
  from public.reservations as reservation
  where reservation.id = v_target;

  select pg_catalog.count(*)
  into v_audits_before
  from public.audit_logs as audit
  where audit.target_id = v_target;

  v_instructor_result := pg_temp.call_attendance(
    '6c2e0000-0000-4000-8000-000000000003', v_target, 'start'
  );
  v_user_result := pg_temp.call_attendance(
    '6c2e0000-0000-4000-8000-000000000001', v_target, 'start'
  );

  select pg_catalog.to_jsonb(reservation)
  into v_after
  from public.reservations as reservation
  where reservation.id = v_target;

  select pg_catalog.count(*)
  into v_audits_after
  from public.audit_logs as audit
  where audit.target_id = v_target;

  perform pg_temp.record_result(21, 'P0-B instructor and user mutation denied',
    v_instructor_result->>'code' = 'not_allowed'
    and v_instructor_result->>'changed' = 'false'
    and v_user_result->>'code' = 'not_allowed'
    and v_user_result->>'changed' = 'false',
    'Ownership read does not reopen attendance mutation to instructor or user.');

  perform pg_temp.record_result(22, 'P0 denial is side-effect free',
    v_before = v_after and v_audits_before = v_audits_after,
    'Denied attendance attempts change no column, timestamp or audit count.');

  v_admin_result := pg_temp.call_attendance(
    '6c2e0000-0000-4000-8000-000000000004', v_target, 'start'
  );
  v_employee_result := pg_temp.call_attendance(
    '6c2e0000-0000-4000-8000-000000000005', v_target, 'reset'
  );

  perform pg_temp.record_result(23, 'P0-A admin and pracownik flow preserved',
    v_admin_result->>'code' = 'started'
    and v_admin_result->>'changed' = 'true'
    and v_employee_result->>'code' = 'reset'
    and v_employee_result->>'changed' = 'true'
    and exists (
      select 1
      from public.reservations as reservation
      where reservation.id = v_target
        and reservation.reservation_status = 'confirmed'
        and reservation.attendance_status = 'planned'
        and reservation.checked_in_at is null
        and reservation.completed_at is null
    ),
    'Admin START and employee RESET still use the controlled P0-A writer.');

  perform pg_temp.record_result(24, 'P0 direct reservation UPDATE remains closed',
    not pg_catalog.has_table_privilege(
      'authenticated', 'public.reservations', 'UPDATE'
    )
    and not pg_catalog.has_table_privilege(
      'anon', 'public.reservations', 'UPDATE'
    )
    and not exists (
      select 1
      from pg_catalog.pg_policy as policy
      where policy.polrelid = 'public.reservations'::pg_catalog.regclass
        and policy.polcmd in ('w', '*')
    ),
    'No direct UPDATE grant or UPDATE/ALL policy is restored.');
end;
$p0_regression$;

-- Build one malformed child only inside the rollback transaction to verify
-- that the read contract never invents a hierarchy label.
alter table public.shooting_lanes
  disable trigger validate_shooting_lane_hierarchy_trigger;
alter table public.shooting_lanes
  drop constraint shooting_lanes_resource_parent_check;

insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values (
  '6c2e0000-0000-4000-8000-000000000104',
  '[TEST][6C-2E-A] Malformed Child', '[TEST]', '[TEST][6C-2E-A]',
  100, false, 1, 60, 9954, 'PLN', 'position', null, false, false
);

select pg_temp.insert_test_reservation(
  '6c2e0000-0000-4000-8000-000000000406',
  '6c2e0000-0000-4000-8000-000000000001',
  '6c2e0000-0000-4000-8000-000000000104',
  current_date + 9006, time '15:00'
);

select pg_temp.record_result(
  25,
  'Malformed hierarchy fails closed',
  exists (
    select 1
    from pg_catalog.jsonb_array_elements(pg_temp.call_my_reservations(
      '6c2e0000-0000-4000-8000-000000000001'
    )) as item
    where item->>'id' = '6c2e0000-0000-4000-8000-000000000406'
      and item->'lane_display_name' = 'null'::jsonb
  ),
  'A position without a valid parent returns null instead of a guessed name.'
);

select pg_temp.record_result(
  26,
  'Fixture and migration are rollback-ready',
  (select pg_catalog.count(*) from public.reservations
   where id between
     '6c2e0000-0000-4000-8000-000000000401'::uuid and
     '6c2e0000-0000-4000-8000-000000000406'::uuid) = 6
  and (select pg_catalog.count(*) from auth.users
       where id in (
         '6c2e0000-0000-4000-8000-000000000001'::uuid,
         '6c2e0000-0000-4000-8000-000000000002'::uuid,
         '6c2e0000-0000-4000-8000-000000000003'::uuid,
         '6c2e0000-0000-4000-8000-000000000004'::uuid,
         '6c2e0000-0000-4000-8000-000000000005'::uuid
       )) = 5,
  'All synthetic records and the RPC remain inside this transaction.'
);

select test_order, test_name, passed, result
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

  if (select pg_catalog.count(*) from pg_temp.test_results) <> 26 then
    raise exception 'My reservations V2 test count differs from 26.';
  end if;

  if v_failures is not null then
    raise exception 'My reservations V2 tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure('public.get_my_reservations_v2()') is null
  and not exists (
    select 1 from auth.users
    where id in (
      '6c2e0000-0000-4000-8000-000000000001'::uuid,
      '6c2e0000-0000-4000-8000-000000000002'::uuid,
      '6c2e0000-0000-4000-8000-000000000003'::uuid,
      '6c2e0000-0000-4000-8000-000000000004'::uuid,
      '6c2e0000-0000-4000-8000-000000000005'::uuid
    )
  )
  and not exists (
    select 1 from public.shooting_lanes
    where id between
      '6c2e0000-0000-4000-8000-000000000101'::uuid and
      '6c2e0000-0000-4000-8000-000000000104'::uuid
  )
  and not exists (
    select 1 from public.reservations
    where id between
      '6c2e0000-0000-4000-8000-000000000401'::uuid and
      '6c2e0000-0000-4000-8000-000000000406'::uuid
  ) as rollback_confirmed;
