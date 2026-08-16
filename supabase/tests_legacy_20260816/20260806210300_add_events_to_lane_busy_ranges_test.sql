\set ON_ERROR_STOP on

-- Test przeznaczony wyłącznie do uruchomienia przez psql.
-- Migracja i syntetyczne dane [TEST][5D-4A-6C] są wycofywane przez ROLLBACK.
begin;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure
  )) as baseline_function_md5
\gset

do $clean_preflight$
begin
  if exists (
       select 1 from public.events
       where title like '[TEST][5D-4A-6C]%'
     )
     or exists (
       select 1 from public.shooting_lanes
       where name like '[TEST][5D-4A-6C]%'
     )
     or exists (
       select 1 from public.lane_blocks
       where reason like '[TEST][5D-4A-6C]%'
     )
     or exists (
       select 1 from public.reservations
       where reservation_note = '[TEST][5D-4A-6C]'
     )
     or exists (
       select 1 from auth.users
       where email like '[TEST]-5d4a6c-%@example.invalid'
     ) then
    raise exception 'Istnieją wcześniejsze dane [TEST][5D-4A-6C].';
  end if;
end;
$clean_preflight$;

\ir ../migrations/20260806210300_add_events_to_lane_busy_ranges.sql

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
  insert into pg_temp.test_results (test_order, test_name, passed, result)
  values (p_test_order, p_test_name, coalesce(p_passed, false), p_result);
$function$;

create function pg_temp.call_create_reservation(
  p_user_id uuid,
  p_lane_id uuid,
  p_test_date date,
  p_start_time time without time zone,
  p_duration_minutes integer
)
returns jsonb
language plpgsql
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
  execute 'set local role authenticated';
  select public.create_reservation(
    p_lane_id,
    p_test_date,
    p_start_time,
    p_duration_minutes,
    1,
    pg_catalog.gen_random_uuid(),
    '[TEST][5D-4A-6C]'
  )
  into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $contract_tests$
declare
  v_function_oid oid :=
    'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure;
  v_base_date date := current_date + 5000;
  v_user_id uuid := pg_catalog.gen_random_uuid();
  v_lane_1 uuid := pg_catalog.gen_random_uuid();
  v_lane_2 uuid := pg_catalog.gen_random_uuid();
  v_active_reservation_id uuid;
  v_cancelled_reservation_id uuid;
  v_event_single uuid := pg_catalog.gen_random_uuid();
  v_event_global uuid := pg_catalog.gen_random_uuid();
  v_event_inactive uuid := pg_catalog.gen_random_uuid();
  v_event_other_lane uuid := pg_catalog.gen_random_uuid();
  v_event_other_day uuid := pg_catalog.gen_random_uuid();
  v_event_multi uuid := pg_catalog.gen_random_uuid();
  v_event_matrix uuid := pg_catalog.gen_random_uuid();
  v_result jsonb;
  v_result_2 jsonb;
  v_result_3 jsonb;
  v_count bigint;
  v_passed boolean;
begin
  perform pg_temp.record_result(
    1,
    'Zachowana sygnatura RPC',
    (
      select pg_catalog.count(*) = 1
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = function_record.pronamespace
      where namespace_record.nspname = 'public'
        and function_record.proname = 'get_lane_booking_busy_ranges'
        and function_record.proargtypes = '2950 1082'::pg_catalog.oidvector
    ),
    'Oczekiwano dokładnie public.get_lane_booking_busy_ranges(uuid,date).'
  );

  perform pg_temp.record_result(
    2,
    'Zachowany kontrakt TABLE(start_time,end_time)',
    (
      select function_record.prorettype =
               'pg_catalog.record'::pg_catalog.regtype
        and function_record.proallargtypes = array[
          'pg_catalog.uuid'::pg_catalog.regtype,
          'pg_catalog.date'::pg_catalog.regtype,
          'time without time zone'::pg_catalog.regtype,
          'time without time zone'::pg_catalog.regtype
        ]::oid[]
        and function_record.proargmodes = array['i','i','t','t']::"char"[]
        and function_record.proargnames = array[
          'p_lane_id','p_reservation_date','start_time','end_time'
        ]::text[]
      from pg_catalog.pg_proc as function_record
      where function_record.oid = v_function_oid
    ),
    'Wynik powinien zawierać wyłącznie start_time i end_time.'
  );

  perform pg_temp.record_result(
    3,
    'Owner postgres',
    (
      select pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
      from pg_catalog.pg_proc as function_record
      where function_record.oid = v_function_oid
    ),
    'Oczekiwano właściciela postgres.'
  );

  perform pg_temp.record_result(
    4,
    'SECURITY DEFINER',
    (
      select function_record.prosecdef
      from pg_catalog.pg_proc as function_record
      where function_record.oid = v_function_oid
    ),
    'Funkcja powinna pozostać SECURITY DEFINER.'
  );

  perform pg_temp.record_result(
    5,
    'STABLE',
    (
      select function_record.provolatile = 's'
      from pg_catalog.pg_proc as function_record
      where function_record.oid = v_function_oid
    ),
    'Funkcja powinna pozostać STABLE.'
  );

  perform pg_temp.record_result(
    6,
    'Bezpieczny search_path',
    (
      select function_record.proconfig = array[
        'search_path=pg_catalog, public, pg_temp'
      ]::text[]
      from pg_catalog.pg_proc as function_record
      where function_record.oid = v_function_oid
    ),
    'Oczekiwano search_path pg_catalog, public, pg_temp.'
  );

  perform pg_temp.record_result(
    7,
    'authenticated z EXECUTE',
    pg_catalog.has_function_privilege(
      'authenticated', v_function_oid, 'EXECUTE'
    ),
    'authenticated powinien mieć EXECUTE.'
  );

  perform pg_temp.record_result(
    8,
    'service_role z EXECUTE',
    pg_catalog.has_function_privilege(
      'service_role', v_function_oid, 'EXECUTE'
    ),
    'service_role powinien zachować EXECUTE.'
  );

  perform pg_temp.record_result(
    9,
    'anon bez EXECUTE',
    not pg_catalog.has_function_privilege(
      'anon', v_function_oid, 'EXECUTE'
    ),
    'anon nie powinien mieć EXECUTE.'
  );

  perform pg_temp.record_result(
    10,
    'PUBLIC bez EXECUTE',
    not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )
      ) as privilege_record
      where function_record.oid = v_function_oid
        and privilege_record.grantee = 0
        and privilege_record.privilege_type = 'EXECUTE'
    ),
    'PUBLIC nie powinien mieć EXECUTE.'
  );

  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  ) values (
    v_user_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    '[TEST]-5d4a6c-user@example.invalid',
    '',
    pg_catalog.transaction_timestamp(),
    '{}'::jsonb,
    '{}'::jsonb,
    pg_catalog.transaction_timestamp(),
    pg_catalog.transaction_timestamp()
  );

  update public.profiles
  set role = 'user',
      first_name = '[TEST]',
      last_name = '5D-4A-6C',
      full_name = '[TEST][5D-4A-6C]',
      email = '[TEST]-5d4a6c-user@example.invalid',
      phone = '000000000',
      verification_status = 'verified'
  where user_id = v_user_id;

  insert into public.shooting_lanes (
    id,
    name,
    type,
    description,
    price_per_hour,
    is_active,
    max_shooters,
    booking_step_minutes,
    display_order,
    currency_code
  ) values
    (
      v_lane_1,
      '[TEST][5D-4A-6C][LANE-1]',
      '[TEST]',
      '[TEST]',
      10,
      true,
      5,
      60,
      991,
      'PLN'
    ),
    (
      v_lane_2,
      '[TEST][5D-4A-6C][LANE-2]',
      '[TEST]',
      '[TEST]',
      10,
      true,
      5,
      60,
      992,
      'PLN'
    );

  insert into public.lane_booking_durations (
    lane_id,
    duration_minutes,
    display_order,
    is_active
  ) values
    (v_lane_1, 60, 1, true),
    (v_lane_1, 120, 2, true),
    (v_lane_1, 180, 3, true),
    (v_lane_1, 240, 4, true),
    (v_lane_2, 60, 1, true);

  insert into public.lane_pricing_rules (
    lane_id,
    day_group,
    min_shooters,
    max_shooters,
    label,
    hourly_price,
    display_order,
    is_active
  ) values
    (v_lane_1, 'mon_thu', 1, 5, '[TEST][5D-4A-6C]', 10, 1, true),
    (v_lane_1, 'fri_sun', 1, 5, '[TEST][5D-4A-6C]', 10, 1, true),
    (v_lane_2, 'mon_thu', 1, 5, '[TEST][5D-4A-6C]', 10, 1, true),
    (v_lane_2, 'fri_sun', 1, 5, '[TEST][5D-4A-6C]', 10, 1, true);

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_1, v_base_date, time '09:00', 60
  );
  v_active_reservation_id := (v_result->>'reservation_id')::uuid;

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_1, v_base_date, time '10:00', 60
  );
  v_cancelled_reservation_id := (v_result->>'reservation_id')::uuid;
  update public.reservations
  set reservation_status = 'cancelled'
  where id = v_cancelled_reservation_id;

  perform pg_temp.record_result(
    11,
    'Aktywna reservation nadal jest zwracana',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges(v_lane_1, v_base_date) as busy
      where busy.start_time = time '09:00'
        and busy.end_time = time '10:00'
    ),
    'Oczekiwano przedziału aktywnej rezerwacji.'
  );

  perform pg_temp.record_result(
    12,
    'Anulowana reservation nie jest zwracana',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(v_lane_1, v_base_date) as busy
      where busy.start_time = time '10:00'
        and busy.end_time = time '11:00'
    ),
    'Anulowana rezerwacja nie może zajmować osi.'
  );

  insert into public.lane_blocks (
    lane_id,
    block_date,
    start_time,
    end_time,
    reason,
    is_active
  ) values
    (
      v_lane_1,
      v_base_date + 1,
      time '09:00',
      time '10:00',
      '[TEST][5D-4A-6C][ACTIVE-BLOCK]',
      true
    ),
    (
      v_lane_1,
      v_base_date + 1,
      time '10:00',
      time '11:00',
      '[TEST][5D-4A-6C][INACTIVE-BLOCK]',
      false
    );

  perform pg_temp.record_result(
    13,
    'Aktywny lane_block nadal jest zwracany',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 1
      ) as busy
      where busy.start_time = time '09:00'
        and busy.end_time = time '10:00'
    ),
    'Oczekiwano przedziału aktywnej blokady.'
  );

  perform pg_temp.record_result(
    14,
    'Nieaktywny lane_block nie jest zwracany',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 1
      ) as busy
      where busy.start_time = time '10:00'
        and busy.end_time = time '11:00'
    ),
    'Nieaktywna blokada nie może zajmować osi.'
  );

  insert into public.events (
    id,
    title,
    event_date,
    start_time,
    end_time,
    price,
    max_participants,
    is_active
  ) values
    (
      v_event_single,
      '[TEST][5D-4A-6C][ACTIVE-SINGLE]',
      v_base_date + 2,
      time '11:00',
      time '14:00',
      0,
      5,
      true
    ),
    (
      v_event_global,
      '[TEST][5D-4A-6C][GLOBAL]',
      v_base_date + 2,
      time '15:00',
      time '16:00',
      0,
      5,
      true
    ),
    (
      v_event_inactive,
      '[TEST][5D-4A-6C][INACTIVE]',
      v_base_date + 2,
      time '16:00',
      time '17:00',
      0,
      5,
      false
    ),
    (
      v_event_other_lane,
      '[TEST][5D-4A-6C][OTHER-LANE]',
      v_base_date + 2,
      time '17:00',
      time '18:00',
      0,
      5,
      true
    ),
    (
      v_event_other_day,
      '[TEST][5D-4A-6C][OTHER-DAY]',
      v_base_date + 3,
      time '18:00',
      time '19:00',
      0,
      5,
      true
    ),
    (
      v_event_multi,
      '[TEST][5D-4A-6C][MULTI]',
      v_base_date + 4,
      time '12:00',
      time '13:00',
      0,
      5,
      true
    ),
    (
      v_event_matrix,
      '[TEST][5D-4A-6C][MATRIX]',
      v_base_date + 5,
      time '11:00',
      time '14:00',
      0,
      5,
      true
    );

  insert into public.event_lanes (event_id, lane_id) values
    (v_event_single, v_lane_1),
    (v_event_inactive, v_lane_1),
    (v_event_other_lane, v_lane_2),
    (v_event_other_day, v_lane_1),
    (v_event_multi, v_lane_1),
    (v_event_multi, v_lane_2),
    (v_event_matrix, v_lane_1);

  perform pg_temp.record_result(
    15,
    'Aktywny event na osi jest zwracany',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 2
      ) as busy
      where busy.start_time = time '11:00'
        and busy.end_time = time '14:00'
    ),
    'Aktywny przypisany event powinien zajmować oś.'
  );

  perform pg_temp.record_result(
    16,
    'Event globalny nie jest zwracany',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 2
      ) as busy
      where busy.start_time = time '15:00'
        and busy.end_time = time '16:00'
    ),
    'Brak event_lanes oznacza event globalny.'
  );

  perform pg_temp.record_result(
    17,
    'Event nieaktywny nie jest zwracany',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 2
      ) as busy
      where busy.start_time = time '16:00'
        and busy.end_time = time '17:00'
    ),
    'Nieaktywny event nie może zajmować osi.'
  );

  perform pg_temp.record_result(
    18,
    'Event na innej osi nie jest zwracany',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 2
      ) as busy
      where busy.start_time = time '17:00'
        and busy.end_time = time '18:00'
    ),
    'Przypisanie do innej osi nie może blokować wybranej osi.'
  );

  perform pg_temp.record_result(
    19,
    'Event innego dnia nie jest zwracany',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 2
      ) as busy
      where busy.start_time = time '18:00'
        and busy.end_time = time '19:00'
    ),
    'Event innego dnia nie może blokować wybranej daty.'
  );

  perform pg_temp.record_result(
    20,
    'Event jednoosiowy blokuje tylko przypisaną oś',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 2
      ) as busy
      where busy.start_time = time '11:00'
        and busy.end_time = time '14:00'
    )
    and not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_2, v_base_date + 2
      ) as busy
      where busy.start_time = time '11:00'
        and busy.end_time = time '14:00'
    ),
    'Event jednoosiowy nie może pojawić się na drugiej osi.'
  );

  perform pg_temp.record_result(
    21,
    'Event wieloosiowy jest zwracany dla obu osi',
    exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 4
      ) as busy
      where busy.start_time = time '12:00'
        and busy.end_time = time '13:00'
    )
    and exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_2, v_base_date + 4
      ) as busy
      where busy.start_time = time '12:00'
        and busy.end_time = time '13:00'
    ),
    'Każda przypisana oś powinna otrzymać busy range.'
  );

  select pg_catalog.count(*)
  into v_count
  from public.get_lane_booking_busy_ranges(
    v_lane_1, v_base_date + 2
  ) as busy
  where busy.start_time = time '11:00'
    and busy.end_time = time '14:00';

  perform pg_temp.record_result(
    22,
    'Dokładny zakres eventu 11:00-14:00',
    v_count = 1,
    'Oczekiwano dokładnie jednego niezmienionego przedziału.'
  );

  perform pg_temp.record_result(
    23,
    'Wynik nie zawiera danych eventu ani PII',
    (
      select pg_catalog.array_agg(key order by key) =
        array['end_time','start_time']::text[]
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 2
      ) as busy
      cross join lateral pg_catalog.jsonb_object_keys(
        pg_catalog.to_jsonb(busy)
      ) as key
    )
    and pg_catalog.lower(
      pg_catalog.pg_get_functiondef(v_function_oid)
    ) !~ 'customer_|participant|email|phone|full_name',
    'Publiczny kontrakt powinien zawierać wyłącznie czasy.'
  );

  perform pg_temp.record_result(
    24,
    'Styk przed eventem nie koliduje',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 5
      ) as busy
      where busy.start_time < time '11:00'
        and busy.end_time > time '10:00'
    ),
    'Przedziały [10:00,11:00) i [11:00,14:00) nie kolidują.'
  );

  perform pg_temp.record_result(
    25,
    'Styk po evencie nie koliduje',
    not exists (
      select 1
      from public.get_lane_booking_busy_ranges(
        v_lane_1, v_base_date + 5
      ) as busy
      where busy.start_time < time '15:00'
        and busy.end_time > time '14:00'
    ),
    'Przedziały [11:00,14:00) i [14:00,15:00) nie kolidują.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_1, v_base_date + 5, time '10:00', 120
  );
  v_result_2 := pg_temp.call_create_reservation(
    v_user_id, v_lane_1, v_base_date + 5, time '11:00', 60
  );
  v_result_3 := pg_temp.call_create_reservation(
    v_user_id, v_lane_1, v_base_date + 5, time '13:00', 60
  );

  perform pg_temp.record_result(
    26,
    'Busy RPC i create_reservation zgodne dla konfliktów',
    v_result = '{"ok":false,"changed":false,"code":"slot_unavailable"}'::jsonb
    and v_result_2 = '{"ok":false,"changed":false,"code":"slot_unavailable"}'::jsonb
    and v_result_3 = '{"ok":false,"changed":false,"code":"slot_unavailable"}'::jsonb,
    'Przecięcia 10:00-12:00, 11:00-12:00 i 13:00-14:00 muszą być zablokowane.'
  );

  v_result := pg_temp.call_create_reservation(
    v_user_id, v_lane_1, v_base_date + 5, time '10:00', 60
  );
  v_result_2 := pg_temp.call_create_reservation(
    v_user_id, v_lane_1, v_base_date + 5, time '14:00', 60
  );

  perform pg_temp.record_result(
    27,
    'Busy RPC i create_reservation zgodne dla styków',
    v_result->>'code' = 'created'
    and v_result_2->>'code' = 'created',
    'Rezerwacje 10:00-11:00 i 14:00-15:00 powinny być dozwolone.'
  );
end;
$contract_tests$;

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

  if v_failures is not null then
    raise exception '5D-4A-6C busy range tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges(uuid,date)'::pg_catalog.regprocedure
  )) = :'baseline_function_md5' as rollback_function_restored,
  not exists (
    select 1 from public.events
    where title like '[TEST][5D-4A-6C]%'
  )
  and not exists (
    select 1 from public.shooting_lanes
    where name like '[TEST][5D-4A-6C]%'
  )
  and not exists (
    select 1 from public.lane_blocks
    where reason like '[TEST][5D-4A-6C]%'
  )
  and not exists (
    select 1 from public.reservations
    where reservation_note = '[TEST][5D-4A-6C]'
  ) as rollback_business_data_removed,
  not exists (
    select 1 from auth.users
    where email like '[TEST]-5d4a6c-%@example.invalid'
  ) as rollback_auth_data_removed
\gset

select *
from (
  values
    (
      28,
      'ROLLBACK przywrócił definicję RPC',
      :'rollback_function_restored'::boolean,
      'Definicja funkcji powinna mieć pierwotny MD5.'
    ),
    (
      29,
      'Brak danych [TEST][5D-4A-6C] po ROLLBACK',
      :'rollback_business_data_removed'::boolean,
      'Syntetyczne eventy, osie, blokady i rezerwacje nie mogą pozostać.'
    ),
    (
      30,
      'Brak example.invalid po ROLLBACK',
      :'rollback_auth_data_removed'::boolean,
      'Syntetyczny użytkownik nie może pozostać.'
    )
) as rollback_results(test_order, test_name, passed, result)
order by test_order;

select 1 / (
  :'rollback_function_restored'::boolean
  and :'rollback_business_data_removed'::boolean
  and :'rollback_auth_data_removed'::boolean
)::integer as rollback_assertion;

select true as rollback_confirmed;
