\set ON_ERROR_STOP on

-- Psql-only security contract test. The migration and every [TEST][6C-3B1]
-- identity are enclosed in this transaction and removed by the final rollback.
begin;

create temporary table lane_configuration_read_baseline (
  configuration_hash text not null,
  policies_hash text not null,
  table_acl_hash text not null
) on commit drop;

insert into pg_temp.lane_configuration_read_baseline (
  configuration_hash,
  policies_hash,
  table_acl_hash
)
select
  pg_catalog.md5(pg_catalog.jsonb_build_object(
    'lanes', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.id)
      from public.shooting_lanes as row_record
    ), '[]'::jsonb),
    'rules', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.lane_id)
      from public.lane_booking_rules as row_record
    ), '[]'::jsonb),
    'durations', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.id)
      from public.lane_booking_durations as row_record
    ), '[]'::jsonb),
    'pricing', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.id)
      from public.lane_pricing_rules as row_record
    ), '[]'::jsonb)
  )::text),
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
      'public.shooting_lanes'::pg_catalog.regclass,
      'public.lane_booking_rules'::pg_catalog.regclass,
      'public.lane_booking_durations'::pg_catalog.regclass,
      'public.lane_pricing_rules'::pg_catalog.regclass
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
    cross join lateral pg_catalog.aclexplode(coalesce(
      relation.relacl,
      pg_catalog.acldefault('r', relation.relowner)
    )) as acl
    where relation.oid in (
      'public.shooting_lanes'::pg_catalog.regclass,
      'public.lane_booking_rules'::pg_catalog.regclass,
      'public.lane_booking_durations'::pg_catalog.regclass,
      'public.lane_pricing_rules'::pg_catalog.regclass
    )
  );

\ir ../migrations/20260814074648_add_admin_lane_booking_configuration_read_v1.sql

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

create temporary table test_context (
  admin_user_id uuid not null,
  employee_user_id uuid not null,
  instructor_user_id uuid not null,
  regular_user_id uuid not null,
  parent_100m_id uuid not null
) on commit drop;

insert into pg_temp.test_context values (
  '6c3b1000-0000-4000-8000-000000000001',
  '6c3b1000-0000-4000-8000-000000000002',
  '6c3b1000-0000-4000-8000-000000000003',
  '6c3b1000-0000-4000-8000-000000000004',
  '254ca7f6-ce80-4267-8966-4558cc8f8fd2'
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
      '[TEST]-6c3b1-admin@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_context.employee_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      '[TEST]-6c3b1-employee@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_context.instructor_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      '[TEST]-6c3b1-instructor@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    ),
    (
      v_context.regular_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      '[TEST]-6c3b1-user@example.invalid', '',
      pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
      pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
    );

  update public.profiles as profile
  set role = case profile.user_id
    when v_context.admin_user_id then 'admin'
    when v_context.employee_user_id then 'pracownik'
    when v_context.instructor_user_id then 'instruktor'
    when v_context.regular_user_id then 'user'
  end
  where profile.user_id in (
    v_context.admin_user_id,
    v_context.employee_user_id,
    v_context.instructor_user_id,
    v_context.regular_user_id
  );

  if (
    select pg_catalog.count(*)
    from public.profiles as profile
    where profile.user_id in (
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

create function pg_temp.call_snapshot(
  p_role name,
  p_user_id uuid
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
    case when p_user_id is null then '{}'::jsonb::text
         else pg_catalog.jsonb_build_object(
           'sub', p_user_id,
           'role', p_role
         )::text end,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', coalesce(p_user_id::text, ''), true
  );
  execute pg_catalog.format('set local role %I', p_role);
  select public.admin_get_lane_booking_configuration_v1()
  into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_snapshot_sqlstate(
  p_role name,
  p_user_id uuid
)
returns text
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
begin
  perform pg_temp.call_snapshot(p_role, p_user_id);
  return null;
exception when others then
  return sqlstate;
end;
$function$;

create temporary table admin_snapshot (
  snapshot jsonb not null
) on commit drop;

insert into pg_temp.admin_snapshot(snapshot)
select pg_temp.call_snapshot(
  'authenticated',
  (select admin_user_id from pg_temp.test_context)
);

select pg_temp.record_result(
  1,
  'RPC istnieje z pojedynczą sygnaturą',
  pg_catalog.to_regprocedure(
    'public.admin_get_lane_booking_configuration_v1()'
  ) is not null
  and (
    select pg_catalog.count(*)
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname = 'admin_get_lane_booking_configuration_v1'
  ) = 1,
  'Oczekiwano dokładnie public.admin_get_lane_booking_configuration_v1().'
);

select pg_temp.record_result(
  2,
  'Metadane SECURITY DEFINER',
  (
    select procedure.prosecdef
       and procedure.provolatile = 's'
       and owner_role.rolname = 'postgres'
       and language_record.lanname = 'plpgsql'
       and procedure.prorettype = 'pg_catalog.jsonb'::pg_catalog.regtype
       and procedure.proconfig is not distinct from
            array['search_path=pg_catalog, public, pg_temp']::text[]
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = procedure.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = procedure.prolang
    where procedure.oid =
      'public.admin_get_lane_booking_configuration_v1()'::pg_catalog.regprocedure
  ),
  'Oczekiwano STABLE, SECURITY DEFINER, owner postgres i bezpiecznego search_path.'
);

select pg_temp.record_result(
  3,
  'ACL funkcji jest minimalne',
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.admin_get_lane_booking_configuration_v1()'::pg_catalog.regprocedure,
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.admin_get_lane_booking_configuration_v1()'::pg_catalog.regprocedure,
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'service_role',
    'public.admin_get_lane_booking_configuration_v1()'::pg_catalog.regprocedure,
    'EXECUTE'
  )
  and not exists (
    select 1
    from pg_catalog.pg_proc as procedure
    cross join lateral pg_catalog.aclexplode(coalesce(
      procedure.proacl,
      pg_catalog.acldefault('f', procedure.proowner)
    )) as function_acl
    where procedure.oid =
      'public.admin_get_lane_booking_configuration_v1()'::pg_catalog.regprocedure
      and function_acl.grantee = 0
      and function_acl.privilege_type = 'EXECUTE'
  ),
  'authenticated ma EXECUTE; anon, service_role i PUBLIC nie mają EXECUTE.'
);

select pg_temp.record_result(
  4,
  'Admin odczytuje snapshot',
  (select snapshot ? 'contract_version' and snapshot ? 'resources'
   from pg_temp.admin_snapshot),
  'Admin powinien otrzymać kontrakt JSONB.'
);

select pg_temp.record_result(
  5,
  'Pracownik jest blokowany',
  pg_temp.call_snapshot_sqlstate(
    'authenticated',
    (select employee_user_id from pg_temp.test_context)
  ) = '42501',
  'Oczekiwano SQLSTATE 42501.'
);

select pg_temp.record_result(
  6,
  'Instruktor jest blokowany',
  pg_temp.call_snapshot_sqlstate(
    'authenticated',
    (select instructor_user_id from pg_temp.test_context)
  ) = '42501',
  'Oczekiwano SQLSTATE 42501.'
);

select pg_temp.record_result(
  7,
  'User jest blokowany',
  pg_temp.call_snapshot_sqlstate(
    'authenticated',
    (select regular_user_id from pg_temp.test_context)
  ) = '42501',
  'Oczekiwano SQLSTATE 42501.'
);

select pg_temp.record_result(
  8,
  'Brak sesji jest blokowany',
  pg_temp.call_snapshot_sqlstate('authenticated', null) = '42501',
  'Oczekiwano SQLSTATE 42501.'
);

select pg_temp.record_result(
  9,
  'Anon jest blokowany',
  pg_temp.call_snapshot_sqlstate('anon', null) = '42501',
  'Oczekiwano odmowy na poziomie ACL.'
);

select pg_temp.record_result(
  10,
  'Kontrakt główny ma dokładny shape',
  (
    select pg_catalog.array_agg(key_name order by key_name)
      = array['contract_version', 'resources']::text[]
      and snapshot->'contract_version' = '1'::jsonb
      and pg_catalog.jsonb_typeof(snapshot->'resources') = 'array'
    from pg_temp.admin_snapshot
    cross join lateral pg_catalog.jsonb_object_keys(snapshot) as key_record(key_name)
    group by snapshot
  ),
  'Oczekiwano contract_version=1 i tablicy resources.'
);

select pg_temp.record_result(
  11,
  'Resource ma dokładny bezpieczny shape',
  not exists (
    select 1
    from pg_temp.admin_snapshot as stored
    cross join lateral pg_catalog.jsonb_array_elements(
      stored.snapshot->'resources'
    ) as resource(value)
    where (
      select pg_catalog.array_agg(key_name order by key_name)
      from pg_catalog.jsonb_object_keys(resource.value) as key_record(key_name)
    ) is distinct from array[
      'booking_step_minutes', 'currency_code', 'display_order', 'durations',
      'is_active', 'lane_id', 'max_people_online', 'max_shooters', 'name',
      'online_bookable', 'parent_lane_id', 'positions_bookable', 'pricing',
      'resource_kind', 'whole_lane_bookable'
    ]::text[]
  ),
  'Nie wolno zwracać technicznych identyfikatorów konfiguracji ani timestampów.'
);

select pg_temp.record_result(
  12,
  'Snapshot zawiera wszystkie zasoby',
  (
    select pg_catalog.jsonb_array_length(snapshot->'resources')
    from pg_temp.admin_snapshot
  ) = (select pg_catalog.count(*) from public.shooting_lanes),
  'Panel administracyjny ma widzieć aktywne, nieaktywne i dormant resources.'
);

select pg_temp.record_result(
  13,
  'Kolejność zasobów jest deterministyczna',
  (
    select pg_catalog.array_agg((resource.value->>'lane_id')::uuid order by resource.ordinality)
    from pg_temp.admin_snapshot as stored
    cross join lateral pg_catalog.jsonb_array_elements(
      stored.snapshot->'resources'
    ) with ordinality as resource(value, ordinality)
  ) is not distinct from (
    select pg_catalog.array_agg(
      lane.id order by root.display_order, root.id,
      case when lane.resource_kind = 'lane' then 0 else 1 end,
      lane.display_order, lane.id
    )
    from public.shooting_lanes as lane
    join public.shooting_lanes as root
      on root.id = case when lane.resource_kind = 'lane'
                        then lane.id else lane.parent_lane_id end
  ),
  'Oczekiwano root display_order/id, parent przed children i child display_order/id.'
);

select pg_temp.record_result(
  14,
  'Durations należą do własnego resource i są stabilnie sortowane',
  not exists (
    select 1
    from pg_temp.admin_snapshot as stored
    cross join lateral pg_catalog.jsonb_array_elements(
      stored.snapshot->'resources'
    ) as resource(value)
    where resource.value->'durations' is distinct from coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'duration_minutes', duration.duration_minutes,
          'display_order', duration.display_order,
          'is_active', duration.is_active
        ) order by duration.display_order, duration.duration_minutes, duration.id
      )
      from public.lane_booking_durations as duration
      where duration.lane_id = (resource.value->>'lane_id')::uuid
    ), '[]'::jsonb)
  ),
  'Brak inheritance lub fallbacku durations.'
);

select pg_temp.record_result(
  15,
  'Pricing należy do własnego resource i jest stabilnie sortowany',
  not exists (
    select 1
    from pg_temp.admin_snapshot as stored
    cross join lateral pg_catalog.jsonb_array_elements(
      stored.snapshot->'resources'
    ) as resource(value)
    where resource.value->'pricing' is distinct from coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'day_group', pricing.day_group,
          'min_shooters', pricing.min_shooters,
          'max_shooters', pricing.max_shooters,
          'label', pricing.label,
          'hourly_price', pricing.hourly_price,
          'display_order', pricing.display_order,
          'is_active', pricing.is_active
        ) order by
          case pricing.day_group when 'mon_thu' then 0
                                 when 'fri_sun' then 1 else 2 end,
          pricing.is_active desc, pricing.display_order,
          pricing.min_shooters, pricing.max_shooters, pricing.id
      )
      from public.lane_pricing_rules as pricing
      where pricing.lane_id = (resource.value->>'lane_id')::uuid
    ), '[]'::jsonb)
  ),
  'Brak inheritance lub fallbacku pricing.'
);

select pg_temp.record_result(
  16,
  'Jeden booking rule na każdy resource',
  (select pg_catalog.count(*) from public.lane_booking_rules)
    = (select pg_catalog.count(*) from public.shooting_lanes)
  and not exists (
    select 1
    from public.shooting_lanes as lane
    left join public.lane_booking_rules as rule on rule.lane_id = lane.id
    where rule.lane_id is null
  ),
  'Snapshot nie może maskować brakującej lub wielokrotnej reguły.'
);

select pg_temp.record_result(
  17,
  'Brak duplicate durations i active pricing overlap',
  not exists (
    select 1
    from public.lane_booking_durations as duration
    group by duration.lane_id, duration.duration_minutes
    having pg_catalog.count(*) > 1
  )
  and not exists (
    select 1
    from public.lane_pricing_rules as first_rule
    join public.lane_pricing_rules as second_rule
      on second_rule.lane_id = first_rule.lane_id
     and second_rule.day_group = first_rule.day_group
     and second_rule.is_active
     and second_rule.id > first_rule.id
     and second_rule.min_shooters <= first_rule.max_shooters
     and second_rule.max_shooters >= first_rule.min_shooters
    where first_rule.is_active
  ),
  'Oczekiwano jednoznacznych collections.'
);

select pg_temp.record_result(
  18,
  'Parent Oś 100 m zachowuje bieżący baseline',
  (
    select pg_catalog.count(*) = 1
       and pg_catalog.bool_and(
         resource.value->>'name' = 'Oś 100 m'
         and resource.value->>'resource_kind' = 'lane'
         and resource.value->'parent_lane_id' = 'null'::jsonb
         and (resource.value->>'max_shooters')::integer = 6
         and (resource.value->>'max_people_online')::integer = 6
         and (resource.value->>'booking_step_minutes')::integer = 60
         and (resource.value->>'currency_code') = 'PLN'
         and (resource.value->>'is_active')::boolean
         and (resource.value->>'online_bookable')::boolean
         and (resource.value->>'whole_lane_bookable')::boolean
         and not (resource.value->>'positions_bookable')::boolean
       )
    from pg_temp.admin_snapshot as stored
    cross join lateral pg_catalog.jsonb_array_elements(
      stored.snapshot->'resources'
    ) as resource(value)
    where (resource.value->>'lane_id')::uuid =
      (select parent_100m_id from pg_temp.test_context)
  ),
  'Odczyt nie może zmieniać produkcyjnego parent baseline.'
);

select pg_temp.record_result(
  19,
  'Oś 100 m ma dokładnie pięć dormant positions',
  (
    select pg_catalog.count(*) = 5
       and pg_catalog.count(distinct resource.value->>'name') = 5
       and pg_catalog.bool_and(
         resource.value->>'name' in (
           'Stanowisko 1', 'Stanowisko 2', 'Stanowisko 3',
           'Stanowisko 4', 'Stanowisko 5'
         )
         and resource.value->>'resource_kind' = 'position'
         and (resource.value->>'parent_lane_id')::uuid =
           (select parent_100m_id from pg_temp.test_context)
         and not (resource.value->>'is_active')::boolean
         and not (resource.value->>'online_bookable')::boolean
         and not (resource.value->>'whole_lane_bookable')::boolean
         and not (resource.value->>'positions_bookable')::boolean
         and (resource.value->>'max_shooters')::integer = 1
         and (resource.value->>'max_people_online')::integer = 1
         and resource.value->'durations' = '[]'::jsonb
         and resource.value->'pricing' = '[]'::jsonb
       )
    from pg_temp.admin_snapshot as stored
    cross join lateral pg_catalog.jsonb_array_elements(
      stored.snapshot->'resources'
    ) as resource(value)
    where (resource.value->>'parent_lane_id')::uuid =
      (select parent_100m_id from pg_temp.test_context)
  ),
  'Dormant children muszą pozostać widoczne, nieaktywne i bez fallbacku.'
);

select pg_temp.record_result(
  20,
  'Powtórny odczyt jest deterministyczny',
  (select snapshot from pg_temp.admin_snapshot) = pg_temp.call_snapshot(
    'authenticated',
    (select admin_user_id from pg_temp.test_context)
  ),
  'Dwa odczyty niezmienionej konfiguracji muszą zwrócić identyczny JSONB.'
);

select pg_temp.record_result(
  21,
  'RPC nie zawiera writerów ani dynamic SQL',
  (
    select definition !~* '\m(insert|update|delete|merge|truncate|execute)\M'
    from (
      select pg_catalog.pg_get_functiondef(
        'public.admin_get_lane_booking_configuration_v1()'::pg_catalog.regprocedure
      ) as definition
    ) as function_record
  ),
  'Kontrakt ma być statycznym read-only RPC.'
);

select pg_temp.record_result(
  22,
  'Dane konfiguracyjne pozostały bez zmian',
  (select configuration_hash from pg_temp.lane_configuration_read_baseline)
  = pg_catalog.md5(pg_catalog.jsonb_build_object(
    'lanes', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.id)
      from public.shooting_lanes as row_record
    ), '[]'::jsonb),
    'rules', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.lane_id)
      from public.lane_booking_rules as row_record
    ), '[]'::jsonb),
    'durations', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.id)
      from public.lane_booking_durations as row_record
    ), '[]'::jsonb),
    'pricing', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.id)
      from public.lane_pricing_rules as row_record
    ), '[]'::jsonb)
  )::text),
  'Migracja i odczyty nie mogą mutować danych biznesowych.'
);

select pg_temp.record_result(
  23,
  'Polityki tabel pozostały bez zmian',
  (select policies_hash from pg_temp.lane_configuration_read_baseline) = (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      policy.polrelid::text || ':' || policy.polname || ':' ||
      policy.polcmd::text || ':' || policy.polroles::text || ':' ||
      coalesce(pg_catalog.pg_get_expr(policy.polqual, policy.polrelid), '') || ':' ||
      coalesce(pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid), ''),
      E'\n' order by policy.polrelid, policy.polname
    ), ''))
    from pg_catalog.pg_policy as policy
    where policy.polrelid in (
      'public.shooting_lanes'::pg_catalog.regclass,
      'public.lane_booking_rules'::pg_catalog.regclass,
      'public.lane_booking_durations'::pg_catalog.regclass,
      'public.lane_pricing_rules'::pg_catalog.regclass
    )
  ),
  'Migracja nie może zmieniać RLS.'
);

select pg_temp.record_result(
  24,
  'ACL tabel pozostało bez zmian',
  (select table_acl_hash from pg_temp.lane_configuration_read_baseline) = (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      relation.oid::text || ':' || acl.grantee::text || ':' ||
      acl.grantor::text || ':' || acl.privilege_type || ':' ||
      acl.is_grantable::text,
      E'\n' order by relation.oid, acl.grantee, acl.privilege_type
    ), ''))
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(coalesce(
      relation.relacl,
      pg_catalog.acldefault('r', relation.relowner)
    )) as acl
    where relation.oid in (
      'public.shooting_lanes'::pg_catalog.regclass,
      'public.lane_booking_rules'::pg_catalog.regclass,
      'public.lane_booking_durations'::pg_catalog.regclass,
      'public.lane_pricing_rules'::pg_catalog.regclass
    )
  ),
  'Migracja nie może przyznawać nowych uprawnień tabelowych.'
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

  if v_failures is not null then
    raise exception 'Admin lane configuration read tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure(
    'public.admin_get_lane_booking_configuration_v1()'
  ) is null
  and not exists (
    select 1 from auth.users
    where id in (
      '6c3b1000-0000-4000-8000-000000000001',
      '6c3b1000-0000-4000-8000-000000000002',
      '6c3b1000-0000-4000-8000-000000000003',
      '6c3b1000-0000-4000-8000-000000000004'
    )
  )
  and not exists (
    select 1 from public.profiles
    where user_id in (
      '6c3b1000-0000-4000-8000-000000000001',
      '6c3b1000-0000-4000-8000-000000000002',
      '6c3b1000-0000-4000-8000-000000000003',
      '6c3b1000-0000-4000-8000-000000000004'
    )
  ) as rollback_confirmed;
