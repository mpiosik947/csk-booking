\set ON_ERROR_STOP on
\pset format unaligned

select '1..22';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer, text, boolean, text)
returns void
language sql
as $function$
  insert into pg_temp.test_results
  values ($1, $2, coalesce($3, false), $4);
$function$;

create function pg_temp.set_client(p_role text, p_user_id uuid)
returns void
language plpgsql
as $function$
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

create function pg_temp.read_availability(p_role text, p_user_id uuid)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_temp.set_client(p_role, p_user_id);
  select pg_catalog.jsonb_agg(
    pg_catalog.to_jsonb(availability)
    order by availability.event_date, availability.start_time, availability.event_id
  )
  into v_result
  from public.get_public_event_availability_v1() as availability;
  execute 'reset role';
  return coalesce(v_result, '[]'::jsonb);
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $tests$
declare
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');
  v_user_1 uuid := pg_catalog.gen_random_uuid();
  v_user_2 uuid := pg_catalog.gen_random_uuid();
  v_user_3 uuid := pg_catalog.gen_random_uuid();
  v_user_4 uuid := pg_catalog.gen_random_uuid();
  v_user_5 uuid := pg_catalog.gen_random_uuid();
  v_user_6 uuid := pg_catalog.gen_random_uuid();
  v_event_available uuid := pg_catalog.gen_random_uuid();
  v_event_reserve uuid := pg_catalog.gen_random_uuid();
  v_event_full uuid := pg_catalog.gen_random_uuid();
  v_event_cancel uuid := pg_catalog.gen_random_uuid();
  v_event_promote uuid := pg_catalog.gen_random_uuid();
  v_event_writer uuid := pg_catalog.gen_random_uuid();
  v_event_inactive uuid := pg_catalog.gen_random_uuid();
  v_cancel_registration uuid := pg_catalog.gen_random_uuid();
  v_promote_registration uuid := pg_catalog.gen_random_uuid();
  v_promotion_token text := 'test-promotion-' || v_run;
  v_anon_result jsonb;
  v_user_result jsonb;
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_visible_count integer;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (v_user_1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'availability-1-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user_2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'availability-2-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user_3, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'availability-3-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user_4, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'availability-4-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user_5, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'availability-5-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now()),
    (v_user_6, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'availability-6-' || v_run || '@example.invalid', '', pg_catalog.now(), '{}', '{}', pg_catalog.now(), pg_catalog.now());

  insert into public.profiles (id, user_id, email, role, verification_status)
  select auth_user.id, auth_user.id, auth_user.email, 'user', 'pending'
  from auth.users as auth_user
  left join public.profiles as profile on profile.user_id = auth_user.id
  where auth_user.id in (v_user_1, v_user_2, v_user_3, v_user_4, v_user_5, v_user_6)
    and profile.user_id is null;

  update public.profiles
  set first_name = '[TEST]', last_name = 'Availability',
      full_name = '[TEST] Availability', phone = '000000000'
  where user_id in (v_user_1, v_user_2, v_user_3, v_user_4, v_user_5, v_user_6);

  if not found or (
    select pg_catalog.count(*)
    from public.profiles
    where user_id in (v_user_1, v_user_2, v_user_3, v_user_4, v_user_5, v_user_6)
  ) <> 6 then
    raise exception 'Availability fixture failed: profile trigger did not create six profiles.';
  end if;

  insert into public.events (
    id, title, description, event_date, start_time, end_time, location,
    price, max_participants, is_active
  ) values
    (v_event_available, '[TEST][AVAILABILITY] A', 'Opis', current_date + 100, time '09:00', time '10:00', '[TEST]', 100, 10, true),
    (v_event_reserve, '[TEST][AVAILABILITY] B', 'Opis', current_date + 101, time '09:00', time '10:00', '[TEST]', 100, 10, true),
    (v_event_full, '[TEST][AVAILABILITY] C', 'Opis', current_date + 102, time '09:00', time '10:00', '[TEST]', 100, 2, true),
    (v_event_cancel, '[TEST][AVAILABILITY] D', 'Opis', current_date + 103, time '09:00', time '10:00', '[TEST]', 100, 3, true),
    (v_event_promote, '[TEST][AVAILABILITY] E', 'Opis', current_date + 104, time '09:00', time '10:00', '[TEST]', 100, 2, true),
    (v_event_writer, '[TEST][AVAILABILITY] F', 'Opis', current_date + 105, time '09:00', time '10:00', '[TEST]', 100, 1, true),
    (v_event_inactive, '[TEST][AVAILABILITY] Z', 'Opis', current_date + 106, time '09:00', time '10:00', '[TEST]', 100, 10, false);

  insert into public.event_registrations (
    id, event_id, user_id, customer_name, customer_email, customer_phone,
    registration_status, promotion_token, promotion_token_expires_at
  ) values
    (pg_catalog.gen_random_uuid(), v_event_available, v_user_1, '[TEST] 1', 'availability-1-' || v_run || '@example.invalid', '000', 'registered', null, null),
    (pg_catalog.gen_random_uuid(), v_event_available, v_user_2, '[TEST] 2', 'availability-2-' || v_run || '@example.invalid', '000', 'approved', null, null),
    (pg_catalog.gen_random_uuid(), v_event_available, v_user_3, '[TEST] 3', 'availability-3-' || v_run || '@example.invalid', '000', ' Registered ', null, null),
    (pg_catalog.gen_random_uuid(), v_event_reserve, v_user_1, '[TEST] 1', 'availability-1-' || v_run || '@example.invalid', '000', 'registered', null, null),
    (pg_catalog.gen_random_uuid(), v_event_reserve, v_user_2, '[TEST] 2', 'availability-2-' || v_run || '@example.invalid', '000', 'reserve', null, null),
    (pg_catalog.gen_random_uuid(), v_event_reserve, v_user_3, '[TEST] 3', 'availability-3-' || v_run || '@example.invalid', '000', ' Reserve ', null, null),
    (pg_catalog.gen_random_uuid(), v_event_reserve, v_user_4, '[TEST] 4', 'availability-4-' || v_run || '@example.invalid', '000', 'cancelled', null, null),
    (pg_catalog.gen_random_uuid(), v_event_reserve, v_user_5, '[TEST] 5', 'availability-5-' || v_run || '@example.invalid', '000', 'participant', null, null),
    (pg_catalog.gen_random_uuid(), v_event_full, v_user_1, '[TEST] 1', 'availability-1-' || v_run || '@example.invalid', '000', 'registered', null, null),
    (pg_catalog.gen_random_uuid(), v_event_full, v_user_2, '[TEST] 2', 'availability-2-' || v_run || '@example.invalid', '000', 'approved', null, null),
    (pg_catalog.gen_random_uuid(), v_event_cancel, v_user_1, '[TEST] 1', 'availability-1-' || v_run || '@example.invalid', '000', 'registered', null, null),
    (v_cancel_registration, v_event_cancel, v_user_2, '[TEST] 2', 'availability-2-' || v_run || '@example.invalid', '000', 'approved', null, null),
    (pg_catalog.gen_random_uuid(), v_event_promote, v_user_1, '[TEST] 1', 'availability-1-' || v_run || '@example.invalid', '000', 'registered', null, null),
    (v_promote_registration, v_event_promote, v_user_2, '[TEST] 2', 'availability-2-' || v_run || '@example.invalid', '000', 'reserve', v_promotion_token, pg_catalog.now() + interval '1 day'),
    (pg_catalog.gen_random_uuid(), v_event_writer, v_user_1, '[TEST] 1', 'availability-1-' || v_run || '@example.invalid', '000', 'registered', null, null);

  perform pg_temp.record_result(1, 'Exact RPC signature exists without overloads',
    pg_catalog.to_regprocedure('public.get_public_event_availability_v1()') is not null
    and (select pg_catalog.count(*) = 1 from pg_catalog.pg_proc as procedure join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace where namespace.nspname = 'public' and procedure.proname = 'get_public_event_availability_v1'),
    'Exactly one zero-argument availability RPC must exist.');

  perform pg_temp.record_result(2, 'RPC is stable SECURITY DEFINER owned by postgres',
    exists (select 1 from pg_catalog.pg_proc as procedure join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure.proowner where procedure.oid = 'public.get_public_event_availability_v1()'::regprocedure and procedure.prosecdef and procedure.provolatile = 's' and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[] and owner_role.rolname = 'postgres'),
    'The reader must have stable properties and a safe search_path.');

  perform pg_temp.record_result(3, 'RPC ACL is anon and authenticated only',
    pg_catalog.has_function_privilege('anon', 'public.get_public_event_availability_v1()', 'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated', 'public.get_public_event_availability_v1()', 'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role', 'public.get_public_event_availability_v1()', 'EXECUTE')
    and not exists (select 1 from pg_catalog.pg_proc as procedure cross join lateral pg_catalog.aclexplode(coalesce(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))) as acl where procedure.oid = 'public.get_public_event_availability_v1()'::regprocedure and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'),
    'No generic PUBLIC or service role execution is needed.');

  v_anon_result := pg_temp.read_availability('anon', null);
  v_user_result := pg_temp.read_availability('authenticated', v_user_6);

  perform pg_temp.record_result(4, 'Only active events are exposed',
    v_anon_result @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id', v_event_available))
    and not v_anon_result @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id', v_event_inactive)),
    'The public reader follows the existing is_active event filter.');

  select pg_catalog.to_jsonb(availability) into v_result from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_available;
  perform pg_temp.record_result(5, 'Capacity 10 and registered count 3 gives availability 7',
    v_result @> '{"max_participants":10,"registered_count":3,"reserve_count":0,"available_spots":7,"sold_out":false}'::jsonb,
    'Registered and approved statuses consume capacity.');

  select pg_catalog.to_jsonb(availability) into v_result from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_reserve;
  perform pg_temp.record_result(6, 'Reserve list is counted separately and does not consume capacity',
    v_result @> '{"registered_count":1,"reserve_count":2,"available_spots":9,"sold_out":false}'::jsonb,
    'Reserve, cancelled and participant statuses must not increase registered_count.');

  select pg_catalog.to_jsonb(availability) into v_result from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_full;
  perform pg_temp.record_result(7, 'Sold-out event exposes zero available spots',
    v_result @> '{"registered_count":2,"available_spots":0,"sold_out":true}'::jsonb,
    'Availability is clamped at zero.');

  perform pg_temp.set_client('authenticated', v_user_6);
  select pg_catalog.count(*) into v_visible_count from public.event_registrations where event_id = v_event_available;
  execute 'reset role';
  perform pg_temp.record_result(8, 'Owner-scoped RLS hides foreign registration rows', v_visible_count = 0, 'The ordinary user must not see other registration records.');

  perform pg_temp.record_result(9, 'Owner-scoped RLS does not affect authoritative availability',
    v_user_result @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('event_id', v_event_available, 'registered_count', 3, 'available_spots', 7)),
    'The SECURITY DEFINER reader computes the complete aggregate.');

  perform pg_temp.record_result(10, 'Anon and authenticated receive identical public aggregates',
    v_anon_result = v_user_result,
    'Availability must be identity-independent.');

  perform pg_temp.record_result(11, 'Public response has an exact PII-free shape',
    not exists (select 1 from public.get_public_event_availability_v1() as availability cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(availability)) as key_name where key_name not in ('event_id','title','description','event_date','start_time','end_time','location','price','max_participants','registered_count','reserve_count','available_spots','sold_out')),
    'No registration row, identity, contact field or token may be returned.');

  perform pg_temp.record_result(12, 'Public payload contains no fixture PII or tokens',
    v_anon_result::text !~* 'example\\.invalid|promotion|customer|user_id|registration_id|token|phone|email',
    'Aggregated output must not leak fixture identities or technical secrets.');

  perform pg_temp.record_result(13, 'Ordering is deterministic',
    v_anon_result = pg_temp.read_availability('anon', null),
    'Repeated reads must preserve event_date, start_time and event_id ordering.');

  select pg_catalog.to_jsonb(availability) into v_before from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_cancel;
  perform pg_temp.set_client('authenticated', v_user_2);
  select public.cancel_event_registration(v_cancel_registration) into v_result;
  execute 'reset role';
  select pg_catalog.to_jsonb(availability) into v_after from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_cancel;
  perform pg_temp.record_result(14, 'Controlled cancellation succeeds', v_result @> '{"changed":true,"new_status":"cancelled","freed_participant_place":true}'::jsonb, 'The existing cancellation writer remains active.');
  perform pg_temp.record_result(15, 'Cancellation updates the aggregate',
    v_before @> '{"registered_count":2,"available_spots":1}'::jsonb
    and v_after @> '{"registered_count":1,"available_spots":2}'::jsonb,
    'A cancelled registered/approved row no longer occupies capacity.');

  select pg_catalog.to_jsonb(availability) into v_before from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_promote;
  perform pg_temp.set_client('authenticated', v_user_2);
  select public.confirm_event_reserve_promotion(v_promotion_token) into v_result;
  execute 'reset role';
  select pg_catalog.to_jsonb(availability) into v_after from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_promote;
  perform pg_temp.record_result(16, 'Reserve promotion succeeds through the existing writer', v_result @> '{"ok":true,"code":"confirmed"}'::jsonb, 'Promotion must remain ownership-scoped and atomic.');
  perform pg_temp.record_result(17, 'Reserve promotion updates both counters',
    v_before @> '{"registered_count":1,"reserve_count":1,"available_spots":1}'::jsonb
    and v_after @> '{"registered_count":2,"reserve_count":0,"available_spots":0,"sold_out":true}'::jsonb,
    'Promotion transfers exactly one row from reserve to occupied.');

  perform pg_temp.set_client('authenticated', v_user_6);
  select public.register_for_event(v_event_writer, false) into v_result;
  execute 'reset role';
  perform pg_temp.record_result(18, 'Atomic registration still prevents overbooking',
    v_result @> '{"ok":true,"changed":true,"code":"reserve","registration_status":"reserve"}'::jsonb,
    'A new signup for a full event must enter reserve.');

  select pg_catalog.to_jsonb(availability) into v_after from public.get_public_event_availability_v1() as availability where availability.event_id = v_event_writer;
  perform pg_temp.record_result(19, 'Overbooking regression leaves occupied count at capacity',
    v_after @> '{"registered_count":1,"reserve_count":1,"available_spots":0,"sold_out":true}'::jsonb,
    'Reserve registration must not increase occupied capacity.');

  perform pg_temp.record_result(20, 'No registration SELECT policy was expanded',
    (select pg_catalog.count(*) = 2 from pg_catalog.pg_policies where schemaname = 'public' and tablename = 'event_registrations' and cmd = 'SELECT')
    and exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and tablename = 'event_registrations' and policyname = 'Users can view own event registrations' and qual = '(user_id = auth.uid())'),
    'SEC-008 and owner isolation remain unchanged.');

  perform pg_temp.record_result(21, 'Multiple-user aggregate is deterministic and de-duplicated',
    (select pg_catalog.count(*) = 1 from public.get_public_event_availability_v1() where event_id = v_event_available)
    and (select registered_count = 3 from public.get_public_event_availability_v1() where event_id = v_event_available),
    'One event produces exactly one authoritative row.');

  perform pg_temp.record_result(22, 'All synthetic fixture remains transaction-scoped',
    (select pg_catalog.count(*) = 6 from auth.users where id in (v_user_1, v_user_2, v_user_3, v_user_4, v_user_5, v_user_6))
    and (select pg_catalog.count(*) = 7 from public.events where id in (v_event_available, v_event_reserve, v_event_full, v_event_cancel, v_event_promote, v_event_writer, v_event_inactive)),
    'The final rollback removes every test user, profile, event and registration.');
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
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  )
  into v_failures
  from pg_temp.test_results
  where not passed;

  if v_failures is not null then
    raise exception 'Public event availability tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;
