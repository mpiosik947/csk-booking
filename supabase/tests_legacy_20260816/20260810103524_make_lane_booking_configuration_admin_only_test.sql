\set ON_ERROR_STOP on

select pg_catalog.md5(
  pg_catalog.pg_get_functiondef(
    pg_catalog.to_regprocedure(
      'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
    )
  )
) as baseline_config_hash
\gset

begin;

\ir ../migrations/20260810103524_make_lane_booking_configuration_admin_only.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create temporary table test_context (
  admin_user_id uuid not null,
  employee_user_id uuid not null,
  instructor_user_id uuid not null,
  regular_user_id uuid not null,
  no_profile_user_id uuid not null
) on commit drop;

create temporary table config_snapshot (
  lane_id uuid not null,
  is_active boolean not null,
  whole_lane_bookable boolean not null,
  positions_bookable boolean not null,
  max_shooters integer not null,
  online_bookable boolean not null,
  max_people_online integer not null,
  durations_minutes integer[] not null,
  pricing jsonb not null
) on commit drop;

insert into test_context values (
  '6b5c0000-0000-4000-8000-000000000001',
  '6b5c0000-0000-4000-8000-000000000002',
  '6b5c0000-0000-4000-8000-000000000003',
  '6b5c0000-0000-4000-8000-000000000004',
  '6b5c0000-0000-4000-8000-000000000005'
);

do $setup$
declare
  v_context pg_temp.test_context%rowtype;
begin
  select * into strict v_context from pg_temp.test_context;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (
      v_context.admin_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      '[TEST]-6b5c-admin@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_context.employee_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      '[TEST]-6b5c-employee@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_context.instructor_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      '[TEST]-6b5c-instructor@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_context.regular_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      '[TEST]-6b5c-user@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    );

  update public.profiles as profile_record
  set role = case profile_record.user_id
    when v_context.admin_user_id then 'admin'
    when v_context.employee_user_id then 'pracownik'
    when v_context.instructor_user_id then 'instruktor'
    when v_context.regular_user_id then 'user'
  end
  where profile_record.user_id in (
    v_context.admin_user_id,
    v_context.employee_user_id,
    v_context.instructor_user_id,
    v_context.regular_user_id
  );

  if (
    select pg_catalog.count(*)
    from public.profiles
    where user_id in (
      v_context.admin_user_id,
      v_context.employee_user_id,
      v_context.instructor_user_id,
      v_context.regular_user_id
    )
  ) <> 4 then
    raise exception 'Test setup failed: role profiles are incomplete.';
  end if;
end;
$setup$;

insert into config_snapshot
select
  lane.id,
  lane.is_active,
  lane.whole_lane_bookable,
  lane.positions_bookable,
  lane.max_shooters,
  booking_rule.online_bookable,
  booking_rule.max_people_online,
  duration_snapshot.durations_minutes,
  pricing_snapshot.pricing
from public.shooting_lanes as lane
join public.lane_booking_rules as booking_rule
  on booking_rule.lane_id = lane.id
cross join lateral (
  select pg_catalog.array_agg(
    duration.duration_minutes order by duration.duration_minutes
  ) as durations_minutes
  from public.lane_booking_durations as duration
  where duration.lane_id = lane.id
    and duration.is_active is true
) as duration_snapshot
cross join lateral (
  select pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'day_group', pricing.day_group,
      'min_shooters', pricing.min_shooters,
      'max_shooters', pricing.max_shooters,
      'label', pricing.label,
      'hourly_price', pricing.hourly_price
    ) order by pricing.day_group, pricing.min_shooters, pricing.max_shooters
  ) as pricing
  from public.lane_pricing_rules as pricing
  where pricing.lane_id = lane.id
    and pricing.is_active is true
) as pricing_snapshot
where lane.resource_kind = 'lane'
  and duration_snapshot.durations_minutes is not null
  and pricing_snapshot.pricing is not null
order by lane.display_order, lane.id
limit 1;

do $snapshot_check$
begin
  if (select pg_catalog.count(*) from pg_temp.config_snapshot) <> 1 then
    raise exception 'Test setup failed: no complete production configuration snapshot.';
  end if;
end;
$snapshot_check$;

create function pg_temp.call_config_as(p_user_id uuid)
returns jsonb
language plpgsql
as $function$
declare
  v_snapshot pg_temp.config_snapshot%rowtype;
  v_result jsonb;
begin
  select * into strict v_snapshot from pg_temp.config_snapshot;

  if p_user_id is null then
    perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
    perform pg_catalog.set_config('request.jwt.claims', '{}'::text, true);
  else
    perform pg_catalog.set_config('request.jwt.claim.sub', p_user_id::text, true);
    perform pg_catalog.set_config(
      'request.jwt.claims',
      pg_catalog.jsonb_build_object(
        'sub', p_user_id,
        'role', 'authenticated'
      )::text,
      true
    );
  end if;

  execute 'set local role authenticated';

  select public.admin_set_lane_booking_configuration(
    v_snapshot.lane_id,
    v_snapshot.is_active,
    v_snapshot.whole_lane_bookable,
    v_snapshot.positions_bookable,
    v_snapshot.max_shooters,
    v_snapshot.online_bookable,
    v_snapshot.max_people_online,
    v_snapshot.durations_minutes,
    v_snapshot.pricing
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

create function pg_temp.direct_update_is_blocked(p_table_name text)
returns boolean
language plpgsql
as $function$
declare
  v_blocked boolean := false;
begin
  execute 'set local role authenticated';

  begin
    case p_table_name
      when 'shooting_lanes' then
        update public.shooting_lanes set name = name where false;
      when 'lane_booking_rules' then
        update public.lane_booking_rules
        set online_bookable = online_bookable where false;
      when 'lane_booking_durations' then
        update public.lane_booking_durations
        set is_active = is_active where false;
      when 'lane_pricing_rules' then
        update public.lane_pricing_rules
        set is_active = is_active where false;
      else
        raise exception 'Unknown table %.', p_table_name;
    end case;
  exception
    when insufficient_privilege then
      v_blocked := true;
  end;

  execute 'reset role';
  return v_blocked;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $tests$
declare
  v_signature constant text :=
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)';
  v_function oid := pg_catalog.to_regprocedure(v_signature);
  v_definition text;
  v_normalized_definition text;
  v_context pg_temp.test_context%rowtype;
  v_admin_result jsonb;
  v_employee_result jsonb;
  v_instructor_result jsonb;
  v_user_result jsonb;
  v_no_auth_result jsonb;
  v_no_profile_result jsonb;
begin
  select * into strict v_context from pg_temp.test_context;

  select pg_catalog.pg_get_functiondef(function_record.oid)
  into v_definition
  from pg_catalog.pg_proc as function_record
  where function_record.oid = v_function;

  v_normalized_definition := pg_catalog.replace(
    pg_catalog.replace(v_definition, E'\r\n', E'\n'),
    'if v_actor_role is null or v_actor_role <> ''admin'' then',
    'if v_actor_role is null or v_actor_role not in (''admin'', ''pracownik'') then'
  );

  v_admin_result := pg_temp.call_config_as(v_context.admin_user_id);
  v_employee_result := pg_temp.call_config_as(v_context.employee_user_id);
  v_instructor_result := pg_temp.call_config_as(v_context.instructor_user_id);
  v_user_result := pg_temp.call_config_as(v_context.regular_user_id);
  v_no_auth_result := pg_temp.call_config_as(null);
  v_no_profile_result := pg_temp.call_config_as(v_context.no_profile_user_id);

  insert into test_results values
  (1, 'A. authenticated może wywołać RPC',
    pg_catalog.has_function_privilege('authenticated', v_function, 'EXECUTE'),
    'authenticated musi zachować EXECUTE; autoryzacja jest wewnątrz RPC.'),

  (2, 'B. Admin zachowuje poprawne wywołanie',
    v_admin_result->>'ok' = 'true'
      and v_admin_result->>'code' in ('updated', 'no_change'),
    'Pełny aktualny snapshot musi zwrócić updated albo no_change.'),

  (3, 'C. Pracownik jest zablokowany',
    v_employee_result @> '{"ok":false,"changed":false,"code":"not_allowed"}'::jsonb,
    'Pracownik musi otrzymać istniejący kod not_allowed.'),

  (4, 'D. Instruktor jest zablokowany',
    v_instructor_result @> '{"ok":false,"changed":false,"code":"not_allowed"}'::jsonb,
    'Instruktor musi otrzymać not_allowed.'),

  (5, 'E. User jest zablokowany',
    v_user_result @> '{"ok":false,"changed":false,"code":"not_allowed"}'::jsonb,
    'Zwykły użytkownik musi otrzymać not_allowed.'),

  (6, 'F. Brak sesji lub profilu jest fail-closed',
    v_no_auth_result @> '{"ok":false,"changed":false,"code":"not_allowed"}'::jsonb
      and v_no_profile_result
        @> '{"ok":false,"changed":false,"code":"not_allowed"}'::jsonb,
    'Brak auth.uid() i brak profilu muszą zwrócić not_allowed.'),

  (7, 'G. Sygnatura i wynik są bez zmian',
    v_function is not null
      and (
        select pg_catalog.count(*)
        from pg_catalog.pg_proc as function_record
        join pg_catalog.pg_namespace as schema_record
          on schema_record.oid = function_record.pronamespace
        where schema_record.nspname = 'public'
          and function_record.proname = 'admin_set_lane_booking_configuration'
      ) = 1
      and (
        select pg_catalog.format_type(function_record.prorettype, null) = 'jsonb'
        from pg_catalog.pg_proc as function_record
        where function_record.oid = v_function
      ),
    'Dokładnie jeden overload ma zwracać jsonb.'),

  (8, 'H. Owner pozostaje postgres',
    (
      select owner_role.rolname = 'postgres'
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_roles as owner_role
        on owner_role.oid = function_record.proowner
      where function_record.oid = v_function
    ),
    'Owner funkcji nie może się zmienić.'),

  (9, 'I. SECURITY DEFINER i PL/pgSQL pozostają',
    (
      select function_record.prosecdef
         and language_record.lanname = 'plpgsql'
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_language as language_record
        on language_record.oid = function_record.prolang
      where function_record.oid = v_function
    ),
    'SECURITY DEFINER i język muszą pozostać bez zmian.'),

  (10, 'J. Volatility pozostaje VOLATILE',
    (select function_record.provolatile = 'v'
     from pg_catalog.pg_proc as function_record
     where function_record.oid = v_function),
    'Volatility nie może się zmienić.'),

  (11, 'K. search_path pozostaje bezpieczny',
    (select function_record.proconfig is distinct from null
        and function_record.proconfig =
          array['search_path=pg_catalog, public, pg_temp']::text[]
     from pg_catalog.pg_proc as function_record
     where function_record.oid = v_function),
    'Oczekiwano pg_catalog, public, pg_temp.'),

  (12, 'L. ACL funkcji pozostaje bez zmian',
    pg_catalog.has_function_privilege('postgres', v_function, 'EXECUTE')
      and pg_catalog.has_function_privilege(
        'authenticated', v_function, 'EXECUTE'
      )
      and not pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
      and not pg_catalog.has_function_privilege(
        'service_role', v_function, 'EXECUTE'
      )
      and not exists (
        select 1
        from pg_catalog.pg_proc as function_record
        cross join lateral pg_catalog.aclexplode(coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )) as function_acl
        where function_record.oid = v_function
          and function_acl.grantee = 0
          and function_acl.privilege_type = 'EXECUTE'
      ),
    'Wyłącznie postgres i authenticated zachowują EXECUTE.'),

  (13, 'M. Family-lock i reszta definicji są identyczne',
    pg_catalog.md5(v_normalized_definition)
      = 'd1e69566a3021253e07f27f67ea635a2'
      and pg_catalog.strpos(
        v_definition,
        'from public.lock_lane_conflict_families_v1(array[p_lane_id])'
      ) > 0,
    'Po cofnięciu jednej klauzuli auth fingerprint musi wrócić do baseline.'),

  (14, 'N. Logika pricing pozostaje',
    pg_catalog.strpos(v_definition, 'jsonb_array_elements(p_pricing)') > 0
      and pg_catalog.strpos(v_definition, 'pg_catalog.lag(') > 0
      and pg_catalog.strpos(
        v_definition, 'update public.lane_pricing_rules'
      ) > 0
      and pg_catalog.strpos(
        v_definition, 'insert into public.lane_pricing_rules'
      ) > 0,
    'Walidacja i wymiana snapshotu pricing muszą pozostać.'),

  (15, 'O. Logika durations pozostaje',
    pg_catalog.strpos(
      v_definition, 'from public.lane_booking_durations as duration'
    ) > 0
      and pg_catalog.strpos(
        v_definition, 'delete from public.lane_booking_durations'
      ) > 0
      and pg_catalog.strpos(
        v_definition, 'insert into public.lane_booking_durations'
      ) > 0,
    'Walidacja, blokady i zapis durations muszą pozostać.'),

  (16, 'P. Zachowanie no_change pozostaje',
    pg_catalog.strpos(v_definition, '''code'', ''no_change''') > 0
      and v_admin_result->>'code' in ('updated', 'no_change'),
    'Idempotentny kontrakt no_change musi pozostać.'),

  (17, 'Q. Ochrona historycznych rezerwacji pozostaje',
    pg_catalog.strpos(v_definition, 'v_max_obligation') > 0
      and pg_catalog.strpos(v_definition, '''conflict_reservation''') > 0
      and pg_catalog.strpos(
        v_definition,
        'Pricing rows referenced by historical reservations cannot be deleted.'
      ) > 0,
    'Limity i historyczne pricing rows muszą pozostać chronione.'),

  (18, 'R. Direct DML durations nadal zablokowany',
    not pg_catalog.has_table_privilege(
      'authenticated', 'public.lane_booking_durations', 'INSERT'
    )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_durations', 'UPDATE'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_durations', 'DELETE'
      )
      and pg_temp.direct_update_is_blocked('lane_booking_durations'),
    'authenticated nie może bezpośrednio mutować durations.'),

  (19, 'S. Direct DML pricing nadal zablokowany',
    not pg_catalog.has_table_privilege(
      'authenticated', 'public.lane_pricing_rules', 'INSERT'
    )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_pricing_rules', 'UPDATE'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_pricing_rules', 'DELETE'
      )
      and pg_temp.direct_update_is_blocked('lane_pricing_rules'),
    'authenticated nie może bezpośrednio mutować pricing.'),

  (20, 'T. Direct DML shooting_lanes nadal zablokowany',
    not pg_catalog.has_table_privilege(
      'authenticated', 'public.shooting_lanes', 'INSERT'
    )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.shooting_lanes', 'UPDATE'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.shooting_lanes', 'DELETE'
      )
      and pg_temp.direct_update_is_blocked('shooting_lanes'),
    'authenticated nie może bezpośrednio mutować osi.'),

  (21, 'U. Direct DML lane_booking_rules nadal zablokowany',
    not pg_catalog.has_table_privilege(
      'authenticated', 'public.lane_booking_rules', 'INSERT'
    )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_rules', 'UPDATE'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_rules', 'DELETE'
      )
      and pg_temp.direct_update_is_blocked('lane_booking_rules'),
    'authenticated nie może bezpośrednio mutować reguł.'),

  (22, 'V. Publiczne readery pozostają bez zmian',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      pg_catalog.to_regprocedure(
        'public.get_public_booking_configuration_v1()'
      )
    )) = '2aee39e3d37d3d1a19f58c3626aa0365'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(
        pg_catalog.to_regprocedure(
          'public.get_lane_booking_busy_ranges_v3(uuid,date)'
        )
      )) = '05b59d331577a3d91e8079e908bfa380',
    'Public config i Availability V3 nie mogą się zmienić.'),

  (23, 'W. create_reservation_v2 pozostaje bez zmian',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      pg_catalog.to_regprocedure(
        'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
      )
    )) = '601664ae4957ed0eef29f85ded57a191',
    'Hierarchy-aware reservation writer nie może się zmienić.'),

  (24, 'X. Lane-block RPC pozostają bez zmian',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      pg_catalog.to_regprocedure(
        'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
      )
    )) = 'fba59c6dbe820ab5c81525bb4dc8659e'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(
        pg_catalog.to_regprocedure(
          'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
        )
      )) = '66f4ba1fb3fe7686b2a04f335851dc43'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(
        pg_catalog.to_regprocedure(
          'public.admin_set_lane_block_active(uuid,boolean)'
        )
      )) = '58fd6523e0b2fa55c6e6afc2a33a1b1b',
    'Trzy lane-block writery nie mogą się zmienić.'),

  (25, 'Y. Event V2 RPC pozostają bez zmian',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      pg_catalog.to_regprocedure(
        'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
      )
    )) = '6b8d29b11797a346ae9387a9bd3ec6b9'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(
        pg_catalog.to_regprocedure(
          'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
        )
      )) = 'a525123389f3a646cd3da6f26e466ed5'
      and pg_catalog.md5(pg_catalog.pg_get_functiondef(
        pg_catalog.to_regprocedure(
          'public.admin_set_event_active_v2(uuid,boolean)'
        )
      )) = 'ad56e445e74634f540425d92ff93acb1',
    'Trzy Event V2 writery nie mogą się zmienić.');
end;
$tests$;

select test_order, test_name, passed, result
from test_results
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
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Admin-only configuration tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  26 as test_order,
  'Z. ROLLBACK przywrócił baseline' as test_name,
  (
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      pg_catalog.to_regprocedure(
        'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
      )
    )) = :'baseline_config_hash'
    and not exists (
      select 1 from auth.users
      where id in (
        '6b5c0000-0000-4000-8000-000000000001',
        '6b5c0000-0000-4000-8000-000000000002',
        '6b5c0000-0000-4000-8000-000000000003',
        '6b5c0000-0000-4000-8000-000000000004'
      )
    )
    and not exists (
      select 1 from public.profiles
      where user_id in (
        '6b5c0000-0000-4000-8000-000000000001',
        '6b5c0000-0000-4000-8000-000000000002',
        '6b5c0000-0000-4000-8000-000000000003',
        '6b5c0000-0000-4000-8000-000000000004'
      )
    )
  ) as passed,
  'Definicja RPC i wszystkie syntetyczne role muszą wrócić do baseline.' as result
\gset

\if :passed
\else
  \echo 'Rollback verification failed.'
  \quit 1
\endif

select
  26 as test_order,
  'Z. ROLLBACK przywrócił baseline' as test_name,
  :passed::boolean as passed,
  'Definicja RPC i wszystkie syntetyczne role wróciły do baseline.' as result;
