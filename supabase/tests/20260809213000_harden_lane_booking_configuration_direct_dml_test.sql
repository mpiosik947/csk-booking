\set ON_ERROR_STOP on

-- psql-only contract test. The migration, reversible configuration update and
-- synthetic admin fixture are enclosed in one transaction ending in ROLLBACK.
begin;

create temporary table baseline_state (
  key text primary key,
  value text not null
) on commit drop;

create function pg_temp.function_fingerprint(
  p_function pg_catalog.regprocedure
)
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(pg_catalog.jsonb_build_object(
    'definition', pg_catalog.pg_get_functiondef(function_record.oid),
    'owner', owner_role.rolname,
    'language', language_record.lanname,
    'volatility', function_record.provolatile,
    'security_definer', function_record.prosecdef,
    'config', coalesce(pg_catalog.to_jsonb(function_record.proconfig),
                       '[]'::jsonb),
    'acl', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'grantor', pg_catalog.pg_get_userbyid(function_acl.grantor),
        'grantee', case when function_acl.grantee = 0 then 'PUBLIC'
                        else pg_catalog.pg_get_userbyid(function_acl.grantee) end,
        'privilege', function_acl.privilege_type,
        'grantable', function_acl.is_grantable
      ) order by function_acl.grantee, function_acl.privilege_type)
      from pg_catalog.aclexplode(coalesce(
        function_record.proacl,
        pg_catalog.acldefault('f', function_record.proowner)
      )) as function_acl
    ), '[]'::jsonb)
  )::text)
  from pg_catalog.pg_proc as function_record
  join pg_catalog.pg_roles as owner_role
    on owner_role.oid = function_record.proowner
  join pg_catalog.pg_language as language_record
    on language_record.oid = function_record.prolang
  where function_record.oid = p_function;
$function$;

create function pg_temp.policy_hash(p_table text)
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'name', policy_record.policyname,
      'permissive', policy_record.permissive,
      'roles', policy_record.roles,
      'command', policy_record.cmd,
      'using', policy_record.qual,
      'with_check', policy_record.with_check
    ) order by policy_record.policyname
  ), '[]'::jsonb)::text)
  from pg_catalog.pg_policies as policy_record
  where policy_record.schemaname = 'public'
    and policy_record.tablename = p_table;
$function$;

create function pg_temp.acl_hash(p_table pg_catalog.regclass)
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'grantee', case when acl.grantee = 0 then 'PUBLIC'
                      else grantee_role.rolname end,
      'privilege', acl.privilege_type,
      'grantable', acl.is_grantable
    ) order by case when acl.grantee = 0 then 'PUBLIC'
                    else grantee_role.rolname end,
               acl.privilege_type
  ), '[]'::jsonb)::text)
  from pg_catalog.pg_class as table_record
  cross join lateral pg_catalog.aclexplode(coalesce(
    table_record.relacl,
    pg_catalog.acldefault('r', table_record.relowner)
  )) as acl
  left join pg_catalog.pg_roles as grantee_role
    on grantee_role.oid = acl.grantee
  where table_record.oid = p_table;
$function$;

create function pg_temp.trigger_hash(p_table pg_catalog.regclass)
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'name', trigger_record.tgname,
      'enabled', trigger_record.tgenabled,
      'definition', pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
      'function', trigger_record.tgfoid::pg_catalog.regprocedure::text,
      'fingerprint', pg_catalog.md5(
        trigger_record.tgname || '|' || trigger_record.tgenabled::text || '|'
        || pg_catalog.pg_get_triggerdef(trigger_record.oid, true) || '|'
        || trigger_record.tgfoid::pg_catalog.regprocedure::text
      )
    ) order by trigger_record.tgname
  ), '[]'::jsonb)::text)
  from pg_catalog.pg_trigger as trigger_record
  where trigger_record.tgrelid = p_table
    and not trigger_record.tgisinternal;
$function$;

create function pg_temp.configuration_snapshot()
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(pg_catalog.jsonb_build_object(
    'lanes', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record)
                                          order by id)
              from public.shooting_lanes as row_record),
    'rules', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record)
                                          order by lane_id)
              from public.lane_booking_rules as row_record),
    'durations', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record)
                                              order by id)
                  from public.lane_booking_durations as row_record),
    'pricing', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record)
                                            order by id)
                from public.lane_pricing_rules as row_record)
  )::text);
$function$;

create function pg_temp.reader_snapshot()
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.to_jsonb(config_record) order by lane_id
  ), '[]'::jsonb)::text)
  from public.get_public_booking_configuration_v1() as config_record;
$function$;

create function pg_temp.logical_lane_configuration(p_lane_id uuid)
returns jsonb
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.jsonb_build_object(
    'is_active', lane.is_active,
    'whole_lane_bookable', lane.whole_lane_bookable,
    'positions_bookable', lane.positions_bookable,
    'max_shooters', lane.max_shooters,
    'online_bookable', rule.online_bookable,
    'max_people_online', rule.max_people_online,
    'durations', coalesce((
      select pg_catalog.jsonb_agg(duration.duration_minutes
                                  order by duration.duration_minutes)
      from public.lane_booking_durations as duration
      where duration.lane_id = lane.id and duration.is_active
    ), '[]'::jsonb),
    'pricing', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'day_group', pricing.day_group,
        'min_shooters', pricing.min_shooters,
        'max_shooters', pricing.max_shooters,
        'label', pricing.label,
        'hourly_price', pricing.hourly_price
      ) order by pricing.day_group, pricing.min_shooters,
                 pricing.max_shooters)
      from public.lane_pricing_rules as pricing
      where pricing.lane_id = lane.id and pricing.is_active
    ), '[]'::jsonb)
  )
  from public.shooting_lanes as lane
  join public.lane_booking_rules as rule on rule.lane_id = lane.id
  where lane.id = p_lane_id;
$function$;

insert into pg_temp.baseline_state(key, value) values
  ('configuration', pg_temp.configuration_snapshot()),
  ('reader', pg_temp.reader_snapshot()),
  ('durations_policy', pg_temp.policy_hash('lane_booking_durations')),
  ('pricing_policy', pg_temp.policy_hash('lane_pricing_rules')),
  ('durations_acl', pg_temp.acl_hash('public.lane_booking_durations')),
  ('pricing_acl', pg_temp.acl_hash('public.lane_pricing_rules')),
  ('durations_trigger', pg_temp.trigger_hash('public.lane_booking_durations')),
  ('pricing_trigger', pg_temp.trigger_hash('public.lane_pricing_rules'));

\ir ../migrations/20260809213000_harden_lane_booking_configuration_direct_dml.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.call_config(
  p_user_id uuid,
  p_lane_id uuid,
  p_is_active boolean,
  p_whole_lane_bookable boolean,
  p_positions_bookable boolean,
  p_max_shooters integer,
  p_online_bookable boolean,
  p_max_people_online integer,
  p_durations integer[],
  p_pricing jsonb
)
returns jsonb
language plpgsql
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id, 'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_set_lane_booking_configuration(
    p_lane_id, p_is_active, p_whole_lane_bookable,
    p_positions_bookable, p_max_shooters, p_online_bookable,
    p_max_people_online, p_durations, p_pricing
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.direct_dml_denied(
  p_table pg_catalog.regclass,
  p_action text,
  p_row_id uuid
)
returns boolean
language plpgsql
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_denied boolean := false;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', '6b4d3000-0000-4000-8000-000000000001'::uuid,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';

  begin
    if p_action = 'INSERT' then
      execute pg_catalog.format('insert into %s default values', p_table);
    elsif p_action = 'UPDATE' then
      execute pg_catalog.format('update %s set id = id where id = $1', p_table)
        using p_row_id;
    elsif p_action = 'DELETE' then
      execute pg_catalog.format('delete from %s where id = $1', p_table)
        using p_row_id;
    else
      raise exception 'Unsupported test action.';
    end if;
  exception
    when insufficient_privilege then
      v_denied := true;
    when others then
      v_denied := false;
  end;

  execute 'reset role';
  return v_denied;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $tests$
declare
  v_admin_id constant uuid := '6b4d3000-0000-4000-8000-000000000001';
  v_lane_id uuid;
  v_duration_id uuid;
  v_pricing_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_durations integer[];
  v_pricing jsonb;
  v_online boolean;
  v_total_durations bigint;
  v_total_pricing bigint;
  v_visible_durations bigint;
  v_visible_pricing bigint;
begin
  insert into auth.users(
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values (
    v_admin_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'test-6b4d3-admin@example.invalid', '',
    pg_catalog.transaction_timestamp(), '{}', '{}',
    pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
  );

  update public.profiles
  set role = 'admin',
      first_name = '[TEST]',
      last_name = '6B-4D3',
      full_name = '[TEST][6B-4D3]',
      email = 'test-6b4d3-admin@example.invalid',
      phone = '000000000',
      verification_status = 'verified'
  where user_id = v_admin_id;

  select config.lane_id
  into v_lane_id
  from public.get_public_booking_configuration_v1() as config
  where config.resource_kind = 'lane'
  order by config.display_order, config.lane_id
  limit 1;

  if v_lane_id is null then
    raise exception 'No safe standalone lane is available for the rollback test.';
  end if;

  select id into v_duration_id
  from public.lane_booking_durations
  where lane_id = v_lane_id
  order by id limit 1;

  select id into v_pricing_id
  from public.lane_pricing_rules
  where lane_id = v_lane_id
  order by id limit 1;

  insert into pg_temp.test_results values
    (1, 'Durations authenticated INSERT=false',
      not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_durations', 'INSERT'
      ), 'Direct INSERT grant is absent.'),
    (2, 'Durations authenticated UPDATE=false',
      not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_durations', 'UPDATE'
      ), 'Direct UPDATE grant is absent.'),
    (3, 'Durations authenticated DELETE=false',
      not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_durations', 'DELETE'
      ), 'Direct DELETE grant is absent.'),
    (4, 'Pricing authenticated INSERT=false',
      not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_pricing_rules', 'INSERT'
      ), 'Direct INSERT grant is absent.'),
    (5, 'Pricing authenticated UPDATE=false',
      not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_pricing_rules', 'UPDATE'
      ), 'Direct UPDATE grant is absent.'),
    (6, 'Pricing authenticated DELETE=false',
      not pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_pricing_rules', 'DELETE'
      ), 'Direct DELETE grant is absent.'),
    (7, 'Durations authenticated SELECT preserved',
      pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_booking_durations', 'SELECT'
      ), 'Authenticated retains SELECT.'),
    (8, 'Pricing authenticated SELECT preserved',
      pg_catalog.has_table_privilege(
        'authenticated', 'public.lane_pricing_rules', 'SELECT'
      ), 'Authenticated retains SELECT.'),
    (9, 'Anon and PUBLIC privileges preserved',
      pg_catalog.has_table_privilege(
        'anon', 'public.lane_booking_durations', 'SELECT'
      )
      and pg_catalog.has_table_privilege(
        'anon', 'public.lane_pricing_rules', 'SELECT'
      )
      and not exists (
        select 1
        from pg_catalog.pg_class as table_record
        cross join lateral pg_catalog.aclexplode(coalesce(
          table_record.relacl,
          pg_catalog.acldefault('r', table_record.relowner)
        )) as acl
        where table_record.oid in (
          'public.lane_booking_durations'::pg_catalog.regclass,
          'public.lane_pricing_rules'::pg_catalog.regclass
        ) and acl.grantee = 0
      ), 'Anon has SELECT only and PUBLIC has no table privileges.'),
    (10, 'Durations RLS unchanged',
      exists (select 1 from pg_catalog.pg_class
              where oid = 'public.lane_booking_durations'::pg_catalog.regclass
                and relrowsecurity and not relforcerowsecurity),
      'RLS enabled=true and FORCE RLS=false.'),
    (11, 'Pricing RLS unchanged',
      exists (select 1 from pg_catalog.pg_class
              where oid = 'public.lane_pricing_rules'::pg_catalog.regclass
                and relrowsecurity and not relforcerowsecurity),
      'RLS enabled=true and FORCE RLS=false.'),
    (12, 'Durations mutation policies absent',
      not exists (select 1 from pg_catalog.pg_policies
                  where schemaname='public'
                    and tablename='lane_booking_durations'
                    and cmd in ('ALL','INSERT','UPDATE','DELETE')),
      'Only SELECT policies remain.'),
    (13, 'Pricing mutation policies absent',
      not exists (select 1 from pg_catalog.pg_policies
                  where schemaname='public'
                    and tablename='lane_pricing_rules'
                    and cmd in ('ALL','INSERT','UPDATE','DELETE')),
      'Only SELECT policies remain.'),
    (14, 'Durations triggers unchanged',
      pg_temp.trigger_hash('public.lane_booking_durations') =
        (select value from pg_temp.baseline_state
         where key='durations_trigger'),
      'All non-internal trigger definitions are identical.'),
    (15, 'Pricing triggers unchanged',
      pg_temp.trigger_hash('public.lane_pricing_rules') =
        (select value from pg_temp.baseline_state
         where key='pricing_trigger'),
      'All non-internal trigger definitions are identical.'),
    (16, 'Config RPC authenticated EXECUTE preserved',
      pg_catalog.has_function_privilege(
        'authenticated',
        'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)',
        'EXECUTE'
      ), 'Authenticated retains RPC EXECUTE.'),
    (17, 'Config RPC definition and ACL unchanged',
      pg_temp.function_fingerprint(
        'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
      ) = '23a0730e4070b5c3625b162527fbd680',
      'Full RPC fingerprint is identical.');

  select count(*) into v_total_durations
  from public.lane_booking_durations;
  select count(*) into v_total_pricing
  from public.lane_pricing_rules;

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_admin_id, 'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select count(*) into v_visible_durations
  from public.lane_booking_durations;
  select count(*) into v_visible_pricing
  from public.lane_pricing_rules;
  execute 'reset role';

  insert into pg_temp.test_results values
    (18, 'Administrative SELECT semantics preserved',
      v_visible_durations = v_total_durations
      and v_visible_pricing = v_total_pricing,
      'Admin still sees active and inactive configuration rows.'),
    (19, 'Actual direct DML denied on durations',
      pg_temp.direct_dml_denied(
        'public.lane_booking_durations', 'INSERT', v_duration_id
      ) and pg_temp.direct_dml_denied(
        'public.lane_booking_durations', 'UPDATE', v_duration_id
      ) and pg_temp.direct_dml_denied(
        'public.lane_booking_durations', 'DELETE', v_duration_id
      ), 'INSERT, UPDATE and DELETE raise insufficient_privilege.'),
    (20, 'Actual direct DML denied on pricing',
      pg_temp.direct_dml_denied(
        'public.lane_pricing_rules', 'INSERT', v_pricing_id
      ) and pg_temp.direct_dml_denied(
        'public.lane_pricing_rules', 'UPDATE', v_pricing_id
      ) and pg_temp.direct_dml_denied(
        'public.lane_pricing_rules', 'DELETE', v_pricing_id
      ), 'INSERT, UPDATE and DELETE raise insufficient_privilege.'),
    (21, 'Public reader unchanged before RPC write',
      pg_temp.reader_snapshot() = (
        select value from pg_temp.baseline_state where key='reader'
      ), 'ACL/RLS migration does not alter public configuration output.'),
    (22, 'Migration changed no configuration data',
      pg_temp.configuration_snapshot() = (
        select value from pg_temp.baseline_state where key='configuration'
      ), 'Configuration snapshot is byte-for-byte identical.');

  v_before := pg_temp.logical_lane_configuration(v_lane_id);
  v_online := (v_before->>'online_bookable')::boolean;

  select pg_catalog.array_agg(duration_minutes order by duration_minutes)
  into v_durations
  from public.lane_booking_durations
  where lane_id=v_lane_id and is_active;

  select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'day_group',day_group,
    'min_shooters',min_shooters,
    'max_shooters',max_shooters,
    'label',label,
    'hourly_price',hourly_price
  ) order by day_group,min_shooters,max_shooters)
  into v_pricing
  from public.lane_pricing_rules
  where lane_id=v_lane_id and is_active;

  v_result := pg_temp.call_config(
    v_admin_id,
    v_lane_id,
    (v_before->>'is_active')::boolean,
    (v_before->>'whole_lane_bookable')::boolean,
    (v_before->>'positions_bookable')::boolean,
    (v_before->>'max_shooters')::integer,
    not v_online,
    (v_before->>'max_people_online')::integer,
    v_durations,
    v_pricing
  );
  v_after := pg_temp.logical_lane_configuration(v_lane_id);

  insert into pg_temp.test_results values
    (23, 'Real RPC UPDATE succeeds after revoke',
      v_result->>'code'='updated'
      and v_result->>'changed'='true',
      'SECURITY DEFINER performs actual owner DML.'),
    (24, 'RPC update is atomic and complete',
      v_after = v_before || pg_catalog.jsonb_build_object(
        'online_bookable', not v_online
      ), 'Only the requested scalar changed; durations and pricing are complete.'),
    (25, 'Service role and owner direct DML unchanged',
      pg_catalog.has_table_privilege(
        'service_role','public.lane_booking_durations','INSERT'
      ) and pg_catalog.has_table_privilege(
        'service_role','public.lane_booking_durations','UPDATE'
      ) and pg_catalog.has_table_privilege(
        'service_role','public.lane_booking_durations','DELETE'
      ) and pg_catalog.has_table_privilege(
        'service_role','public.lane_pricing_rules','INSERT'
      ) and pg_catalog.has_table_privilege(
        'service_role','public.lane_pricing_rules','UPDATE'
      ) and pg_catalog.has_table_privilege(
        'service_role','public.lane_pricing_rules','DELETE'
      ) and pg_catalog.has_table_privilege(
        'postgres','public.lane_booking_durations','INSERT'
      ) and pg_catalog.has_table_privilege(
        'postgres','public.lane_booking_durations','UPDATE'
      ) and pg_catalog.has_table_privilege(
        'postgres','public.lane_booking_durations','DELETE'
      ) and pg_catalog.has_table_privilege(
        'postgres','public.lane_pricing_rules','INSERT'
      ) and pg_catalog.has_table_privilege(
        'postgres','public.lane_pricing_rules','UPDATE'
      ) and pg_catalog.has_table_privilege(
        'postgres','public.lane_pricing_rules','DELETE'
      ), 'Service role and postgres remain outside this hardening scope.'),
    (26, 'Family helper unchanged',
      pg_temp.function_fingerprint(
        'public.lock_lane_conflict_families_v1(uuid[])'
      )='0815401da8ad1f909c26622355c0db5f',
      'Full helper fingerprint is identical.'),
    (27, 'Reservation V2 unchanged',
      pg_temp.function_fingerprint(
        'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
      )='43166f4511fb63f3f00e6159a25aaefe',
      'Full reservation writer fingerprint is identical.'),
    (28, 'Lane-block RPCs unchanged',
      pg_temp.function_fingerprint(
        'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
      )='d0d2ea55f2fe1b899df863c6b246e810'
      and pg_temp.function_fingerprint(
        'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
      )='ea94641203847b68b9418cd3eda21cbe'
      and pg_temp.function_fingerprint(
        'public.admin_set_lane_block_active(uuid,boolean)'
      )='c8010d39bbbb47a434ede423143ad1de',
      'All three lane-block writers are identical.'),
    (29, 'Event V2 RPCs unchanged',
      pg_temp.function_fingerprint(
        'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
      )='5cb34b27251e94a26c87e59e032b3a85'
      and pg_temp.function_fingerprint(
        'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
      )='f6f6d51e6a8979cbc9a02c7af6f7d967'
      and pg_temp.function_fingerprint(
        'public.admin_set_event_active_v2(uuid,boolean)'
      )='a51425da82a9da7b5039051751f73752',
      'All three Event V2 writers are identical.'),
    (30, 'Public config reader definition unchanged',
      pg_temp.function_fingerprint(
        'public.get_public_booking_configuration_v1()'
      )='4ce0eef041de344b8acd85bc5782648f',
      'Full public reader fingerprint is identical.'),
    (31, 'Current hierarchy has no positions',
      not exists (
        select 1 from public.shooting_lanes where resource_kind='position'
      ), 'position_count remains zero.');
end;
$tests$;

select test_order, test_name, passed, result
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  if (select count(*) from pg_temp.test_results) <> 31 then
    raise exception 'Expected exactly 31 lane configuration hardening controls.';
  end if;

  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  )
  into v_failures
  from pg_temp.test_results
  where not passed;

  if v_failures is not null then
    raise exception 'Lane configuration hardening tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  (select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'name', policy_record.policyname,
      'permissive', policy_record.permissive,
      'roles', policy_record.roles,
      'command', policy_record.cmd,
      'using', policy_record.qual,
      'with_check', policy_record.with_check
    ) order by policy_record.policyname
  ), '[]'::jsonb)::text)
   from pg_catalog.pg_policies as policy_record
   where policy_record.schemaname='public'
     and policy_record.tablename='lane_booking_durations')
    = 'f3c9743651bdb5db464e23c9bee3a4d8'
  and (select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'name', policy_record.policyname,
      'permissive', policy_record.permissive,
      'roles', policy_record.roles,
      'command', policy_record.cmd,
      'using', policy_record.qual,
      'with_check', policy_record.with_check
    ) order by policy_record.policyname
  ), '[]'::jsonb)::text)
   from pg_catalog.pg_policies as policy_record
   where policy_record.schemaname='public'
     and policy_record.tablename='lane_pricing_rules')
    = '9218b3875b735c54d82b8fdd9956a45b'
  and (select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'grantee', case when acl.grantee=0 then 'PUBLIC'
                      else role_record.rolname end,
      'privilege', acl.privilege_type,
      'grantable', acl.is_grantable
    ) order by case when acl.grantee=0 then 'PUBLIC'
                    else role_record.rolname end,
               acl.privilege_type
  ), '[]'::jsonb)::text)
   from pg_catalog.pg_class as table_record
   cross join lateral pg_catalog.aclexplode(coalesce(
     table_record.relacl,
     pg_catalog.acldefault('r',table_record.relowner)
   )) as acl
   left join pg_catalog.pg_roles as role_record on role_record.oid=acl.grantee
   where table_record.oid='public.lane_booking_durations'::pg_catalog.regclass)
    = 'cbeef4d9030cc8afee27e817d1f5b0f4'
  and (select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'grantee', case when acl.grantee=0 then 'PUBLIC'
                      else role_record.rolname end,
      'privilege', acl.privilege_type,
      'grantable', acl.is_grantable
    ) order by case when acl.grantee=0 then 'PUBLIC'
                    else role_record.rolname end,
               acl.privilege_type
  ), '[]'::jsonb)::text)
   from pg_catalog.pg_class as table_record
   cross join lateral pg_catalog.aclexplode(coalesce(
     table_record.relacl,
     pg_catalog.acldefault('r',table_record.relowner)
   )) as acl
   left join pg_catalog.pg_roles as role_record on role_record.oid=acl.grantee
   where table_record.oid='public.lane_pricing_rules'::pg_catalog.regclass)
    = 'cbeef4d9030cc8afee27e817d1f5b0f4'
  and (select pg_catalog.md5(pg_catalog.jsonb_build_object(
    'lanes',(select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by id)
             from public.shooting_lanes x),
    'rules',(select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by lane_id)
             from public.lane_booking_rules x),
    'durations',(select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by id)
                 from public.lane_booking_durations x),
    'pricing',(select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by id)
               from public.lane_pricing_rules x)
  )::text)) = '5e110f1cdd639b4d0b11fdb68897e125'
  and (select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.to_jsonb(config_record) order by lane_id
  ),'[]'::jsonb)::text)
       from public.get_public_booking_configuration_v1() config_record)
    = '82e30105451b3ed2cfaab5aad596f528'
  and not exists (
    select 1 from auth.users
    where email='test-6b4d3-admin@example.invalid'
  )
  and not exists (
    select 1 from public.profiles
    where full_name='[TEST][6B-4D3]'
  )
  and (select count(*) from public.shooting_lanes)=6
  and (select count(*) from public.shooting_lanes
       where resource_kind='position')=0
  and (select count(*) from public.lane_booking_rules)=6
  and (select count(*) from public.lane_booking_durations)=20
  and (select count(*) from public.lane_pricing_rules)=40
  and (select count(*) from public.reservations)=4
  and (select count(*) from public.lane_blocks)=3
  and (select count(*) from public.events)=10
  and (select count(*) from public.event_lanes)=8
  as rollback_confirmed;
