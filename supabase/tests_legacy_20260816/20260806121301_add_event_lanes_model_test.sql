\set ON_ERROR_STOP on

-- Test uruchamiany przez psql. Migracja i wszystkie dane syntetyczne są
-- wykonywane w jednej transakcji zakończonej ROLLBACK.
begin;

\ir ../migrations/20260806121301_add_event_lanes_model.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

do $catalog_tests$
declare
  v_passed boolean;
begin
  insert into test_results
  values (
    1,
    'Tabela event_lanes istnieje',
    pg_catalog.to_regclass('public.event_lanes') is not null,
    'Oczekiwano public.event_lanes.'
  );

  select
    pg_catalog.count(*) = 3
    and pg_catalog.bool_and(
      case column_name
        when 'event_id' then data_type = 'uuid' and is_nullable = 'NO'
        when 'lane_id' then data_type = 'uuid' and is_nullable = 'NO'
        when 'created_at' then
          data_type = 'timestamp with time zone'
          and is_nullable = 'NO'
          and column_default = 'transaction_timestamp()'
        else false
      end
    )
  into v_passed
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'event_lanes';

  insert into test_results
  values (
    2,
    'Dokładne kolumny event_lanes',
    v_passed,
    'Oczekiwano event_id uuid, lane_id uuid i created_at timestamptz.'
  );

  select exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.event_lanes'::pg_catalog.regclass
      and constraint_record.conname = 'event_lanes_pkey'
      and constraint_record.contype = 'p'
      and constraint_record.conkey = array[
        (
          select attribute.attnum
          from pg_catalog.pg_attribute as attribute
          where attribute.attrelid = 'public.event_lanes'::pg_catalog.regclass
            and attribute.attname = 'event_id'
        ),
        (
          select attribute.attnum
          from pg_catalog.pg_attribute as attribute
          where attribute.attrelid = 'public.event_lanes'::pg_catalog.regclass
            and attribute.attname = 'lane_id'
        )
      ]::smallint[]
  ) into v_passed;

  insert into test_results
  values (
    3,
    'PRIMARY KEY event_id lane_id',
    v_passed,
    'Oczekiwano złożonego klucza głównego (event_id, lane_id).'
  );

  select exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    join pg_catalog.pg_class as referenced_table
      on referenced_table.oid = constraint_record.confrelid
    join pg_catalog.pg_namespace as referenced_schema
      on referenced_schema.oid = referenced_table.relnamespace
    where constraint_record.conrelid = 'public.event_lanes'::pg_catalog.regclass
      and constraint_record.conname = 'event_lanes_event_id_fkey'
      and constraint_record.contype = 'f'
      and referenced_schema.nspname = 'public'
      and referenced_table.relname = 'events'
      and constraint_record.confdeltype = 'c'
      and constraint_record.conkey = array[
        (
          select attribute.attnum
          from pg_catalog.pg_attribute as attribute
          where attribute.attrelid = 'public.event_lanes'::pg_catalog.regclass
            and attribute.attname = 'event_id'
        )
      ]::smallint[]
      and constraint_record.confkey = array[
        (
          select attribute.attnum
          from pg_catalog.pg_attribute as attribute
          where attribute.attrelid = 'public.events'::pg_catalog.regclass
            and attribute.attname = 'id'
        )
      ]::smallint[]
  ) into v_passed;

  insert into test_results
  values (
    4,
    'FK event_id z ON DELETE CASCADE',
    v_passed,
    'event_id powinien wskazywać public.events(id) z ON DELETE CASCADE.'
  );

  select exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    join pg_catalog.pg_class as referenced_table
      on referenced_table.oid = constraint_record.confrelid
    join pg_catalog.pg_namespace as referenced_schema
      on referenced_schema.oid = referenced_table.relnamespace
    where constraint_record.conrelid = 'public.event_lanes'::pg_catalog.regclass
      and constraint_record.conname = 'event_lanes_lane_id_fkey'
      and constraint_record.contype = 'f'
      and referenced_schema.nspname = 'public'
      and referenced_table.relname = 'shooting_lanes'
      and constraint_record.confdeltype = 'r'
      and constraint_record.conkey = array[
        (
          select attribute.attnum
          from pg_catalog.pg_attribute as attribute
          where attribute.attrelid = 'public.event_lanes'::pg_catalog.regclass
            and attribute.attname = 'lane_id'
        )
      ]::smallint[]
      and constraint_record.confkey = array[
        (
          select attribute.attnum
          from pg_catalog.pg_attribute as attribute
          where attribute.attrelid = 'public.shooting_lanes'::pg_catalog.regclass
            and attribute.attname = 'id'
        )
      ]::smallint[]
  ) into v_passed;

  insert into test_results
  values (
    5,
    'FK lane_id z ON DELETE RESTRICT',
    v_passed,
    'lane_id powinien wskazywać public.shooting_lanes(id) z ON DELETE RESTRICT.'
  );

  select exists (
    select 1
    from pg_catalog.pg_indexes
    where schemaname = 'public'
      and tablename = 'event_lanes'
      and indexname = 'event_lanes_lane_event_idx'
      and indexdef ~ '\(lane_id, event_id\)'
  ) into v_passed;

  insert into test_results
  values (
    6,
    'Indeks lane_id event_id istnieje',
    v_passed,
    'Oczekiwano event_lanes_lane_event_idx(lane_id,event_id).'
  );

  select exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.events'::pg_catalog.regclass
      and conname = 'events_time_range_check'
      and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid)
        ~ 'CHECK \(\(end_time > start_time\)\)'
  ) into v_passed;

  insert into test_results
  values (
    7,
    'Constraint czasu eventu istnieje',
    v_passed,
    'Oczekiwano events_time_range_check: end_time > start_time.'
  );

  select relrowsecurity
  into v_passed
  from pg_catalog.pg_class
  where oid = 'public.event_lanes'::pg_catalog.regclass;

  insert into test_results
  values (
    8,
    'RLS event_lanes jest włączone',
    v_passed,
    'Oczekiwano relrowsecurity=true.'
  );

  select
    pg_catalog.count(*) = 1
    and pg_catalog.bool_and(
      policyname = 'Admins and staff can view event lanes'
      and permissive = 'PERMISSIVE'
      and roles = array['authenticated']::name[]
      and cmd = 'SELECT'
      and lower(btrim(qual)) in (
        'is_admin_or_staff()',
        'public.is_admin_or_staff()'
      )
      and with_check is null
    )
  into v_passed
  from pg_catalog.pg_policies
  where schemaname = 'public'
    and tablename = 'event_lanes';

  insert into test_results
  values (
    9,
    'Tylko polityka SELECT',
    v_passed,
    'Nie mogą istnieć polityki INSERT, UPDATE ani DELETE.'
  );

  select
    pg_catalog.count(*) filter (
      where grantee = 'authenticated'
        and privilege_type = 'SELECT'
    ) = 1
    and pg_catalog.count(*) filter (
      where grantee = 'authenticated'
        and privilege_type <> 'SELECT'
    ) = 0
    and pg_catalog.count(distinct privilege_type) filter (
      where grantee = 'service_role'
    ) = 7
  into v_passed
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name = 'event_lanes'
    and grantee in ('authenticated', 'service_role');

  insert into test_results
  values (
    10,
    'ACL authenticated tylko SELECT',
    v_passed,
    'authenticated ma wyłącznie SELECT, a service_role zachowuje pełny dostęp.'
  );

  select not exists (
    select 1
    from information_schema.table_privileges
    where table_schema = 'public'
      and table_name = 'event_lanes'
      and grantee in ('anon', 'PUBLIC')
  )
  into v_passed;

  insert into test_results
  values (
    11,
    'anon i PUBLIC bez dostępu',
    v_passed,
    'anon i PUBLIC nie mogą posiadać praw do event_lanes.'
  );
end;
$catalog_tests$;

do $functional_tests$
declare
  v_event_id uuid := pg_catalog.gen_random_uuid();
  v_lane_id uuid := pg_catalog.gen_random_uuid();
  v_admin_user_id uuid := pg_catalog.gen_random_uuid();
  v_employee_user_id uuid := pg_catalog.gen_random_uuid();
  v_instructor_user_id uuid := pg_catalog.gen_random_uuid();
  v_user_id uuid := pg_catalog.gen_random_uuid();
  v_visible_count bigint;
  v_rejected boolean;
begin
  insert into public.events (
    id, title, description, event_date, start_time, end_time,
    location, price, max_participants, is_active
  ) values (
    v_event_id, '[TEST][5D-1]', '[TEST]', current_date + 30,
    time '10:00', time '12:00', '[TEST]', 0, 1, true
  );

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code
  ) values (
    v_lane_id, '[TEST][5D-1]', '[TEST]', '[TEST]', 0, true,
    1, 60, 999, 'PLN'
  );

  insert into public.event_lanes (event_id, lane_id)
  values (v_event_id, v_lane_id);

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (
      v_admin_user_id, '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated', '[TEST]-5d1-admin@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_employee_user_id, '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated', '[TEST]-5d1-employee@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_instructor_user_id, '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated', '[TEST]-5d1-instructor@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_user_id, '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated', '[TEST]-5d1-user@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    );

  update public.profiles
  set role = case user_id
    when v_admin_user_id then 'admin'
    when v_employee_user_id then 'pracownik'
    when v_instructor_user_id then 'instruktor'
    else 'user'
  end
  where user_id in (
    v_admin_user_id,
    v_employee_user_id,
    v_instructor_user_id,
    v_user_id
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_admin_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select pg_catalog.count(*) into v_visible_count from public.event_lanes;
  execute 'reset role';
  insert into test_results values (
    12, 'Admin może SELECT', v_visible_count = 1,
    'Admin powinien widzieć przypisanie eventu do osi.'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_employee_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select pg_catalog.count(*) into v_visible_count from public.event_lanes;
  execute 'reset role';
  insert into test_results values (
    13, 'Pracownik może SELECT', v_visible_count = 1,
    'Pracownik powinien widzieć przypisanie eventu do osi.'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_instructor_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select pg_catalog.count(*) into v_visible_count from public.event_lanes;
  execute 'reset role';
  insert into test_results values (
    14, 'Instruktor może SELECT', v_visible_count = 1,
    'Instruktor powinien widzieć przypisanie eventu do osi.'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select pg_catalog.count(*) into v_visible_count from public.event_lanes;
  execute 'reset role';
  insert into test_results values (
    15, 'User nie może SELECT', v_visible_count = 0,
    'Zwykły user nie powinien widzieć event_lanes.'
  );

  v_rejected := false;
  begin
    insert into public.event_lanes (event_id, lane_id)
    values (v_event_id, v_lane_id);
  exception
    when unique_violation then
      v_rejected := true;
  end;
  insert into test_results values (
    16, 'Duplikat relacji jest odrzucony', v_rejected,
    'Oczekiwano naruszenia PRIMARY KEY(event_id,lane_id).'
  );

  v_rejected := false;
  begin
    insert into public.event_lanes (event_id, lane_id)
    values (pg_catalog.gen_random_uuid(), v_lane_id);
  exception
    when foreign_key_violation then
      v_rejected := true;
  end;
  insert into test_results values (
    17, 'Nieistniejący event jest odrzucony', v_rejected,
    'Oczekiwano naruszenia FK event_id.'
  );

  v_rejected := false;
  begin
    insert into public.event_lanes (event_id, lane_id)
    values (v_event_id, pg_catalog.gen_random_uuid());
  exception
    when foreign_key_violation then
      v_rejected := true;
  end;
  insert into test_results values (
    18, 'Nieistniejąca oś jest odrzucona', v_rejected,
    'Oczekiwano naruszenia FK lane_id.'
  );

  v_rejected := false;
  begin
    insert into public.events (
      title, event_date, start_time, end_time, price,
      max_participants, is_active
    ) values (
      '[TEST][5D-1][INVALID]', current_date + 30,
      time '12:00', time '12:00', 0, 1, true
    );
  exception
    when check_violation then
      v_rejected := true;
  end;
  insert into test_results values (
    19, 'Nieprawidłowy czas eventu jest odrzucony', v_rejected,
    'Oczekiwano events_time_range_check.'
  );

  insert into test_results values (
    20,
    'Dane testowe są objęte ROLLBACK',
    (
      select pg_catalog.count(*) = 1
      from public.events
      where id = v_event_id
        and title = '[TEST][5D-1]'
    ) and (
      select pg_catalog.count(*) = 1
      from public.event_lanes
      where event_id = v_event_id
        and lane_id = v_lane_id
    ),
    'Migracja i dane syntetyczne znajdują się w otwartej transakcji.'
  );
end;
$functional_tests$;

select
  test_order,
  test_name,
  passed,
  result
from test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', '
    order by test_order
  )
  into v_failures
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Event lanes model tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regclass('public.event_lanes') is null
  and not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.events'::pg_catalog.regclass
      and conname = 'events_time_range_check'
  )
  and not exists (
    select 1
    from public.events
    where title in ('[TEST][5D-1]', '[TEST][5D-1][INVALID]')
  )
  and not exists (
    select 1
    from public.shooting_lanes
    where name = '[TEST][5D-1]'
  )
  and not exists (
    select 1
    from auth.users
    where email like '[TEST]-5d1-%@example.invalid'
  ) as rollback_confirmed;
