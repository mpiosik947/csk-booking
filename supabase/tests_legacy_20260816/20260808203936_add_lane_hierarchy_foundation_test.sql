\set ON_ERROR_STOP on

-- Run with psql. The migration and every [TEST][6A-3] fixture are enclosed in
-- one transaction that ends with an explicit ROLLBACK.
begin;

create temporary table baseline_lane_hierarchy_contract as
select
  (select pg_catalog.count(*) from public.shooting_lanes) as lane_count,
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
   from public.shooting_lanes as row_record) as lane_data_hash,
  (select pg_catalog.md5(pg_catalog.string_agg(
     policyname || '|' || permissive || '|' || cmd || '|' || roles::text || '|'
       || coalesce(qual, '<null>') || '|' || coalesce(with_check, '<null>'),
     E'\n' order by policyname))
   from pg_catalog.pg_policies
   where schemaname = 'public' and tablename = 'shooting_lanes') as lane_policies_hash,
  (select pg_catalog.md5(pg_catalog.string_agg(
     coalesce(grantee_role.rolname, 'PUBLIC') || '|' || acl.privilege_type || '|'
       || acl.is_grantable::text,
     E'\n' order by coalesce(grantee_role.rolname, 'PUBLIC'), acl.privilege_type))
   from pg_catalog.pg_class as table_record
   cross join lateral pg_catalog.aclexplode(
     coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
   ) as acl
   left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
   where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass) as lane_acl_hash,
  (select pg_catalog.md5(pg_catalog.string_agg(
     object_type || '|' || table_name || '|' || object_name || '|' || definition,
     E'\n' order by object_type, table_name, object_name))
   from (
     select 'column'::text as object_type, table_record.relname as table_name,
            attribute_record.attname as object_name,
            pg_catalog.format_type(attribute_record.atttypid, attribute_record.atttypmod)
              || '|' || attribute_record.attnotnull::text || '|'
              || coalesce(pg_catalog.pg_get_expr(default_record.adbin, default_record.adrelid), '<null>')
              as definition
     from pg_catalog.pg_class as table_record
     join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = table_record.relnamespace
     join pg_catalog.pg_attribute as attribute_record on attribute_record.attrelid = table_record.oid
     left join pg_catalog.pg_attrdef as default_record
       on default_record.adrelid = attribute_record.attrelid
      and default_record.adnum = attribute_record.attnum
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'lane_booking_durations', 'lane_pricing_rules', 'reservations',
         'lane_blocks', 'events', 'event_lanes'
       )
       and attribute_record.attnum > 0 and not attribute_record.attisdropped
     union all
     select 'constraint', table_record.relname, constraint_record.conname,
            pg_catalog.pg_get_constraintdef(constraint_record.oid, true)
     from pg_catalog.pg_constraint as constraint_record
     join pg_catalog.pg_class as table_record on table_record.oid = constraint_record.conrelid
     join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = table_record.relnamespace
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'lane_booking_durations', 'lane_pricing_rules', 'reservations',
         'lane_blocks', 'events', 'event_lanes'
       )
     union all
     select 'index', table_record.relname,
            index_record.indexrelid::pg_catalog.regclass::text,
            pg_catalog.pg_get_indexdef(index_record.indexrelid)
     from pg_catalog.pg_index as index_record
     join pg_catalog.pg_class as table_record on table_record.oid = index_record.indrelid
     join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = table_record.relnamespace
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'lane_booking_durations', 'lane_pricing_rules', 'reservations',
         'lane_blocks', 'events', 'event_lanes'
       )
     union all
     select 'trigger', table_record.relname, trigger_record.tgname,
            pg_catalog.pg_get_triggerdef(trigger_record.oid, true)
     from pg_catalog.pg_trigger as trigger_record
     join pg_catalog.pg_class as table_record on table_record.oid = trigger_record.tgrelid
     join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = table_record.relnamespace
     where namespace_record.nspname = 'public'
       and table_record.relname in (
         'lane_booking_durations', 'lane_pricing_rules', 'reservations',
         'lane_blocks', 'events', 'event_lanes'
       )
       and not trigger_record.tgisinternal
     union all
     select 'policy', policy_record.tablename, policy_record.policyname,
            policy_record.permissive || '|' || policy_record.cmd || '|'
              || policy_record.roles::text || '|' || coalesce(policy_record.qual, '<null>')
              || '|' || coalesce(policy_record.with_check, '<null>')
     from pg_catalog.pg_policies as policy_record
     where policy_record.schemaname = 'public'
       and policy_record.tablename in (
         'lane_booking_durations', 'lane_pricing_rules', 'reservations',
         'lane_blocks', 'events', 'event_lanes'
       )
   ) as schema_object) as other_schema_hash,
  (select pg_catalog.md5(
     (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(r)::text), E'\n' order by r.id), '')) from public.reservations r)
     || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(b)::text), E'\n' order by b.id), '')) from public.lane_blocks b)
     || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(d)::text), E'\n' order by d.id), '')) from public.lane_booking_durations d)
     || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(p)::text), E'\n' order by p.id), '')) from public.lane_pricing_rules p)
     || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(e)::text), E'\n' order by e.id), '')) from public.events e)
     || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(el)::text), E'\n' order by el.event_id, el.lane_id), '')) from public.event_lanes el)
   )) as other_data_hash,
  pg_catalog.md5(
    pg_catalog.pg_get_functiondef(
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
    )
    || pg_catalog.pg_get_functiondef(
      'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
    )
  ) as runtime_functions_hash;

select * from pg_temp.baseline_lane_hierarchy_contract \gset baseline_

\ir ../migrations/20260808203936_add_lane_hierarchy_foundation.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(
  p_order integer,
  p_name text,
  p_passed boolean,
  p_result text
)
returns void
language sql
as $function$
  insert into pg_temp.test_results values (p_order, p_name, p_passed, p_result);
$function$;

create function pg_temp.expect_lane_insert_error(
  p_id uuid,
  p_kind text,
  p_parent_id uuid,
  p_whole boolean,
  p_positions boolean,
  p_expected_state text
)
returns boolean
language plpgsql
as $function$
begin
  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values (
    p_id, '[TEST][6A-3][INVALID]', '[TEST]', '[TEST]', 0, true,
    1, 60, 9999, 'PLN', p_kind, p_parent_id, p_whole, p_positions
  );
  return false;
exception when others then
  return sqlstate = p_expected_state;
end;
$function$;

create function pg_temp.set_test_user(p_user_id uuid, p_role text)
returns void
language plpgsql
as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', coalesce(p_user_id::text, ''), true
  );
  perform pg_catalog.set_config(
    'request.jwt.claims',
    case when p_user_id is null
      then pg_catalog.jsonb_build_object('role', p_role)::text
      else pg_catalog.jsonb_build_object('sub', p_user_id, 'role', p_role)::text
    end,
    true
  );
end;
$function$;

create function pg_temp.visible_fixture_rules(p_user_id uuid, p_role text)
returns bigint
language plpgsql
as $function$
declare
  v_effective_role text := case when p_role = 'anon' then 'anon' else 'authenticated' end;
  v_count bigint;
begin
  perform pg_temp.set_test_user(p_user_id, v_effective_role);
  execute pg_catalog.format('set local role %I', v_effective_role);
  select pg_catalog.count(*) into v_count
  from public.lane_booking_rules
  where lane_id::text like '6a300000-0000-4000-8000-%';
  execute 'reset role';
  return v_count;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.fixture_rule_is_visible(
  p_user_id uuid,
  p_role text,
  p_lane_id uuid
)
returns boolean
language plpgsql
as $function$
declare
  v_effective_role text := case when p_role = 'anon' then 'anon' else 'authenticated' end;
  v_visible boolean;
begin
  perform pg_temp.set_test_user(p_user_id, v_effective_role);
  execute pg_catalog.format('set local role %I', v_effective_role);
  select exists (
    select 1 from public.lane_booking_rules where lane_id = p_lane_id
  ) into v_visible;
  execute 'reset role';
  return v_visible;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.direct_rule_dml_blocked(p_user_id uuid, p_role text)
returns boolean
language plpgsql
as $function$
declare
  v_effective_role text := case when p_role = 'anon' then 'anon' else 'authenticated' end;
  v_insert_blocked boolean := false;
  v_update_blocked boolean := false;
  v_delete_blocked boolean := false;
begin
  perform pg_temp.set_test_user(p_user_id, v_effective_role);
  execute pg_catalog.format('set local role %I', v_effective_role);

  begin
    insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
    values ('6a300000-0000-4000-8000-000000000104', false, 1);
  exception when insufficient_privilege then
    v_insert_blocked := true;
  end;

  begin
    update public.lane_booking_rules set online_bookable = false
    where lane_id = '6a300000-0000-4000-8000-000000000101';
  exception when insufficient_privilege then
    v_update_blocked := true;
  end;

  begin
    delete from public.lane_booking_rules
    where lane_id = '6a300000-0000-4000-8000-000000000101';
  exception when insufficient_privilege then
    v_delete_blocked := true;
  end;

  execute 'reset role';
  return v_insert_blocked and v_update_blocked and v_delete_blocked;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

do $fixtures$
declare
  v_admin constant uuid := '6a300000-0000-4000-8000-000000000001';
  v_employee constant uuid := '6a300000-0000-4000-8000-000000000002';
  v_instructor constant uuid := '6a300000-0000-4000-8000-000000000003';
  v_user constant uuid := '6a300000-0000-4000-8000-000000000004';
begin
  if exists (
    select 1 from auth.users
    where id in (v_admin, v_employee, v_instructor, v_user)
  ) or exists (
    select 1 from public.shooting_lanes
    where id::text like '6a300000-0000-4000-8000-%'
  ) then
    raise exception '[TEST][6A-3] fixture identifiers already exist.';
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     '[TEST]-6a3-admin@example.invalid', '', pg_catalog.transaction_timestamp(), '{}', '{}',
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_employee, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     '[TEST]-6a3-employee@example.invalid', '', pg_catalog.transaction_timestamp(), '{}', '{}',
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_instructor, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     '[TEST]-6a3-instructor@example.invalid', '', pg_catalog.transaction_timestamp(), '{}', '{}',
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     '[TEST]-6a3-user@example.invalid', '', pg_catalog.transaction_timestamp(), '{}', '{}',
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
    when v_admin then 'admin'
    when v_employee then 'pracownik'
    when v_instructor then 'instruktor'
    when v_user then 'user'
  end
  where user_id in (v_admin, v_employee, v_instructor, v_user);

  if (select pg_catalog.count(*) from public.profiles
      where user_id in (v_admin, v_employee, v_instructor, v_user)) <> 4 then
    raise exception 'Synthetic profiles were not created.';
  end if;

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values
    ('6a300000-0000-4000-8000-000000000101', '[TEST][6A-3][PARENT-ACTIVE]', '[TEST]', '[TEST]', 0, true, 5, 60, 9101, 'PLN', 'lane', null, true, true),
    ('6a300000-0000-4000-8000-000000000102', '[TEST][6A-3][PARENT-INACTIVE]', '[TEST]', '[TEST]', 0, false, 5, 60, 9102, 'PLN', 'lane', null, true, true),
    ('6a300000-0000-4000-8000-000000000103', '[TEST][6A-3][OFFLINE]', '[TEST]', '[TEST]', 0, true, 3, 60, 9103, 'PLN', 'lane', null, true, false),
    ('6a300000-0000-4000-8000-000000000104', '[TEST][6A-3][DELETE-PARENT]', '[TEST]', '[TEST]', 0, true, 2, 60, 9104, 'PLN', 'lane', null, false, true),
    ('6a300000-0000-4000-8000-000000000201', '[TEST][6A-3][POSITION-ACTIVE]', '[TEST]', '[TEST]', 0, true, 1, 60, 9201, 'PLN', 'position', '6a300000-0000-4000-8000-000000000101', false, false),
    ('6a300000-0000-4000-8000-000000000202', '[TEST][6A-3][POSITION-INACTIVE-PARENT]', '[TEST]', '[TEST]', 0, true, 1, 60, 9202, 'PLN', 'position', '6a300000-0000-4000-8000-000000000102', false, false),
    ('6a300000-0000-4000-8000-000000000203', '[TEST][6A-3][POSITION-OFFLINE]', '[TEST]', '[TEST]', 0, true, 1, 60, 9203, 'PLN', 'position', '6a300000-0000-4000-8000-000000000101', false, false),
    ('6a300000-0000-4000-8000-000000000204', '[TEST][6A-3][DELETE-CHILD]', '[TEST]', '[TEST]', 0, true, 1, 60, 9204, 'PLN', 'position', '6a300000-0000-4000-8000-000000000104', false, false);

  insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
  values
    ('6a300000-0000-4000-8000-000000000101', true, 5),
    ('6a300000-0000-4000-8000-000000000102', true, 5),
    ('6a300000-0000-4000-8000-000000000103', false, 3),
    ('6a300000-0000-4000-8000-000000000201', true, 1),
    ('6a300000-0000-4000-8000-000000000202', true, 1),
    ('6a300000-0000-4000-8000-000000000203', false, 1);
end;
$fixtures$;

do $tests$
declare
  v_passed boolean;
begin
  perform pg_temp.record_result(1, 'Migracja utworzyla fundament',
    pg_catalog.to_regclass('public.lane_booking_rules') is not null
      and pg_catalog.to_regprocedure('public.validate_shooting_lane_hierarchy()') is not null,
    'Tabela i helper hierarchii musza istniec.');

  perform pg_temp.record_result(2, 'Dokladnie cztery nowe kolumny shooting_lanes',
    (select pg_catalog.count(*) = 4 from information_schema.columns
     where table_schema = 'public' and table_name = 'shooting_lanes'
       and column_name in ('resource_kind', 'parent_lane_id', 'whole_lane_bookable', 'positions_bookable')),
    'Sprawdzono obecność czterech kolumn fundamentu.');

  perform pg_temp.record_result(3, 'Szesc istniejacych UUID zachowano',
    (select lane_count from pg_temp.baseline_lane_hierarchy_contract) = 6
      and (select pg_catalog.count(*) from public.shooting_lanes
           where id::text not like '6a300000-0000-4000-8000-%') = 6,
    'Nie utworzono ani nie usunieto istniejacej osi.');

  perform pg_temp.record_result(4, 'Backfill istniejacych osi',
    not exists (
      select 1 from public.shooting_lanes
      where id::text not like '6a300000-0000-4000-8000-%'
        and (resource_kind <> 'lane' or parent_lane_id is not null
             or not whole_lane_bookable or positions_bookable)
    ),
    'Istniejace rekordy sa top-level lane z whole mode.');

  perform pg_temp.record_result(5, 'Backfill lane_booking_rules 1:1',
    (select pg_catalog.count(*) from public.lane_booking_rules
     where lane_id::text not like '6a300000-0000-4000-8000-%') = 6
      and not exists (
        select 1 from public.shooting_lanes lane
        left join public.lane_booking_rules rule on rule.lane_id = lane.id
        where lane.id::text not like '6a300000-0000-4000-8000-%'
          and (rule.lane_id is null or rule.max_people_online <> lane.max_shooters
               or rule.online_bookable <> lane.is_active)
      ),
    'Jeden rekord per istniejaca os; limit i publikacja zachowane.');

  perform pg_temp.record_result(6, 'resource_kind odrzuca nieznana wartosc',
    pg_temp.expect_lane_insert_error('6a300000-0000-4000-8000-000000000301', 'other', null, false, false, '23514'),
    'Oczekiwano check_violation.');

  perform pg_temp.record_result(7, 'Lane bez parenta jest poprawne',
    exists (select 1 from public.shooting_lanes where id = '6a300000-0000-4000-8000-000000000101' and resource_kind = 'lane' and parent_lane_id is null),
    'Top-level lane zostal utworzony.');

  perform pg_temp.record_result(8, 'Lane z parentem jest blokowane',
    pg_temp.expect_lane_insert_error('6a300000-0000-4000-8000-000000000302', 'lane', '6a300000-0000-4000-8000-000000000101', false, false, '23514'),
    'Relacja lane/parent jest fail-closed.');

  perform pg_temp.record_result(9, 'Position bez parenta jest blokowane',
    pg_temp.expect_lane_insert_error('6a300000-0000-4000-8000-000000000303', 'position', null, false, false, '23514'),
    'Position wymaga parent_lane_id.');

  perform pg_temp.record_result(10, 'Self-parent jest blokowany',
    pg_temp.expect_lane_insert_error('6a300000-0000-4000-8000-000000000304', 'position', '6a300000-0000-4000-8000-000000000304', false, false, '23514'),
    'Rekord nie moze wskazywac sam na siebie.');

  perform pg_temp.record_result(11, 'Position do position jest blokowane',
    pg_temp.expect_lane_insert_error('6a300000-0000-4000-8000-000000000305', 'position', '6a300000-0000-4000-8000-000000000201', false, false, '23514'),
    'Parent musi byc top-level lane.');

  begin
    update public.shooting_lanes
    set resource_kind = 'position', parent_lane_id = '6a300000-0000-4000-8000-000000000103'
    where id = '6a300000-0000-4000-8000-000000000101';
    v_passed := false;
  exception when check_violation then
    v_passed := true;
  end;
  perform pg_temp.record_result(12, 'Depth wiekszy niz 1 jest blokowany', v_passed,
    'Lane posiadajace dzieci nie moze stac sie position.');

  perform pg_temp.record_result(13, 'Position nie moze sprzedawac whole lane',
    pg_temp.expect_lane_insert_error('6a300000-0000-4000-8000-000000000306', 'position', '6a300000-0000-4000-8000-000000000101', true, false, '23514'),
    'whole_lane_bookable musi byc false.');

  perform pg_temp.record_result(14, 'Position nie moze sprzedawac positions',
    pg_temp.expect_lane_insert_error('6a300000-0000-4000-8000-000000000307', 'position', '6a300000-0000-4000-8000-000000000101', false, true, '23514'),
    'positions_bookable musi byc false.');

  perform pg_temp.record_result(15, 'Poprawny lane i position przechodza',
    exists (select 1 from public.shooting_lanes where id = '6a300000-0000-4000-8000-000000000201' and resource_kind = 'position' and parent_lane_id = '6a300000-0000-4000-8000-000000000101'),
    'Poprawny child zostal zapisany.');

  begin
    delete from public.shooting_lanes where id = '6a300000-0000-4000-8000-000000000104';
    v_passed := false;
  exception when foreign_key_violation then
    v_passed := true;
  end;
  perform pg_temp.record_result(16, 'ON DELETE RESTRICT chroni parenta', v_passed,
    'Parent z childem nie moze zostac usuniety.');

  perform pg_temp.record_result(17, 'Minimalny kontrakt lane_booking_rules',
    (select pg_catalog.count(*) = 5 from information_schema.columns
     where table_schema = 'public' and table_name = 'lane_booking_rules')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='lane_booking_rules' and column_name='lane_id' and data_type='uuid' and is_nullable='NO')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='lane_booking_rules' and column_name='online_bookable' and data_type='boolean' and is_nullable='NO' and column_default='false')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='lane_booking_rules' and column_name='max_people_online' and data_type='integer' and is_nullable='NO'),
    'Tabela ma dokladnie piec uzgodnionych kolumn.');

  begin
    insert into public.lane_booking_rules values ('6a300000-0000-4000-8000-000000000101', false, 1, pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp());
    v_passed := false;
  exception when unique_violation then
    v_passed := true;
  end;
  perform pg_temp.record_result(18, 'lane_booking_rules jest 1:1', v_passed,
    'Duplikat lane_id zwraca unique_violation.');

  begin
    update public.lane_booking_rules set max_people_online = 0
    where lane_id = '6a300000-0000-4000-8000-000000000103';
    v_passed := false;
  exception when check_violation then
    v_passed := true;
  end;
  perform pg_temp.record_result(19, 'max_people_online musi byc dodatnie', v_passed,
    'Zero zwraca check_violation.');

  begin
    update public.lane_booking_rules set max_people_online = 4
    where lane_id = '6a300000-0000-4000-8000-000000000103';
    v_passed := false;
  exception when check_violation then
    v_passed := true;
  end;
  perform pg_temp.record_result(20, 'Limit online nie przekracza fizycznego', v_passed,
    'Trigger odrzuca max_people_online > max_shooters.');

  begin
    update public.shooting_lanes set max_shooters = 4
    where id = '6a300000-0000-4000-8000-000000000101';
    v_passed := false;
  exception when check_violation then
    v_passed := true;
  end;
  perform pg_temp.record_result(21, 'Zmniejszenie fizycznego limitu jest chronione', v_passed,
    'Nie mozna obnizyc max_shooters ponizej aktywnego limitu online.');

  perform pg_temp.record_result(22, 'RLS i dwie polityki SELECT',
    exists (select 1 from pg_catalog.pg_class where oid='public.lane_booking_rules'::pg_catalog.regclass and relrowsecurity and not relforcerowsecurity)
      and (select pg_catalog.count(*)=2 from pg_catalog.pg_policies where schemaname='public' and tablename='lane_booking_rules')
      and not exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='lane_booking_rules' and cmd <> 'SELECT'),
    'Brak polityk mutacyjnych.');

  perform pg_temp.record_result(23, 'Anon widzi active online parent i position',
    pg_temp.visible_fixture_rules(null, 'anon') = 2,
    'Widoczne sa tylko aktywne, online i topologicznie dozwolone konfiguracje.');

  perform pg_temp.record_result(24, 'Anon nie widzi offline lub inactive',
    not pg_temp.fixture_rule_is_visible(null, 'anon', '6a300000-0000-4000-8000-000000000102')
      and not pg_temp.fixture_rule_is_visible(null, 'anon', '6a300000-0000-4000-8000-000000000103')
      and not pg_temp.fixture_rule_is_visible(null, 'anon', '6a300000-0000-4000-8000-000000000202')
      and not pg_temp.fixture_rule_is_visible(null, 'anon', '6a300000-0000-4000-8000-000000000203'),
    'Offline i dzieci nieaktywnego parenta sa ukryte przez RLS.');

  perform pg_temp.record_result(25, 'Zwykly user ma publiczny zakres',
    pg_temp.visible_fixture_rules('6a300000-0000-4000-8000-000000000004', 'authenticated') = 2,
    'User nie otrzymuje polityki staff.');

  perform pg_temp.record_result(26, 'Admin widzi wszystkie konfiguracje',
    pg_temp.visible_fixture_rules('6a300000-0000-4000-8000-000000000001', 'authenticated') = 6,
    'Admin widzi online, offline i inactive.');

  perform pg_temp.record_result(27, 'Pracownik widzi wszystkie konfiguracje',
    pg_temp.visible_fixture_rules('6a300000-0000-4000-8000-000000000002', 'authenticated') = 6,
    'Pracownik jest objety is_admin_or_staff().');

  perform pg_temp.record_result(28, 'Instruktor widzi wszystkie konfiguracje',
    pg_temp.visible_fixture_rules('6a300000-0000-4000-8000-000000000003', 'authenticated') = 6,
    'Instruktor jest objety is_admin_or_staff().');

  perform pg_temp.record_result(29, 'Anon nie moze wykonywac direct DML',
    pg_temp.direct_rule_dml_blocked(null, 'anon'),
    'INSERT, UPDATE i DELETE sa blokowane ACL.');

  perform pg_temp.record_result(30, 'Authenticated nie moze wykonywac direct DML',
    pg_temp.direct_rule_dml_blocked('6a300000-0000-4000-8000-000000000001', 'authenticated'),
    'Nawet admin ma tabelowo wylacznie SELECT.');

  perform pg_temp.record_result(31, 'PUBLIC bez praw; klienci tylko SELECT',
    not exists (
      select 1
      from pg_catalog.pg_class table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) acl
      where table_record.oid = 'public.lane_booking_rules'::pg_catalog.regclass
        and acl.grantee = 0
    )
      and (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
           from pg_catalog.pg_class table_record
           cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) acl
           where table_record.oid='public.lane_booking_rules'::pg_catalog.regclass
             and acl.grantee=(select oid from pg_catalog.pg_roles where rolname='anon')) = array['SELECT']::text[]
      and (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
           from pg_catalog.pg_class table_record
           cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) acl
           where table_record.oid='public.lane_booking_rules'::pg_catalog.regclass
             and acl.grantee=(select oid from pg_catalog.pg_roles where rolname='authenticated')) = array['SELECT']::text[],
    'Sprawdzono pelny klientowy kontrakt tabelowy.');

  perform pg_temp.record_result(32, 'service_role zachowuje pelny ACL',
    (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
     from pg_catalog.pg_class table_record
     cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) acl
     where table_record.oid='public.lane_booking_rules'::pg_catalog.regclass
       and acl.grantee=(select oid from pg_catalog.pg_roles where rolname='service_role'))
      = array['DELETE','INSERT','MAINTAIN','REFERENCES','SELECT','TRIGGER','TRUNCATE','UPDATE']::text[],
    'service_role ma wymagany pelny dostep.');

  perform pg_temp.record_result(33, 'Helpery sa bezpieczne',
    not exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      join pg_catalog.pg_roles o on o.oid=p.proowner
      where n.nspname='public'
        and p.proname in (
          'validate_shooting_lane_hierarchy',
          'validate_lane_booking_rule_capacity',
          'validate_shooting_lane_capacity_change'
        )
        and (not p.prosecdef or o.rolname <> 'postgres'
             or p.proconfig <> array['search_path=pg_catalog, public, pg_temp']::text[])
    )
      and (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('validate_shooting_lane_hierarchy','validate_lane_booking_rule_capacity','validate_shooting_lane_capacity_change')) = 3,
    'SECURITY DEFINER, owner postgres i bezpieczny search_path.');

  perform pg_temp.record_result(34, 'updated_at korzysta z istniejacego helpera',
    exists (
      select 1 from pg_catalog.pg_trigger
      where tgrelid='public.lane_booking_rules'::pg_catalog.regclass
        and tgname='set_lane_booking_rules_updated_at'
        and tgfoid='public.set_booking_configuration_updated_at()'::pg_catalog.regprocedure
        and tgenabled='O'
    ),
    'Nie utworzono drugiego globalnego helpera updated_at.');

  perform pg_temp.record_result(35, 'Inne tabele i dane pozostaly identyczne',
    (select other_schema_hash from pg_temp.baseline_lane_hierarchy_contract) = (
      select pg_catalog.md5(pg_catalog.string_agg(object_type || '|' || table_name || '|' || object_name || '|' || definition, E'\n' order by object_type, table_name, object_name))
      from (
        select 'column'::text object_type, c.relname table_name, a.attname object_name,
          pg_catalog.format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull::text||'|'||coalesce(pg_catalog.pg_get_expr(d.adbin,d.adrelid),'<null>') definition
        from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_attribute a on a.attrelid=c.oid left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
        where n.nspname='public' and c.relname in ('lane_booking_durations','lane_pricing_rules','reservations','lane_blocks','events','event_lanes') and a.attnum>0 and not a.attisdropped
        union all select 'constraint',c.relname,x.conname,pg_catalog.pg_get_constraintdef(x.oid,true) from pg_catalog.pg_constraint x join pg_catalog.pg_class c on c.oid=x.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('lane_booking_durations','lane_pricing_rules','reservations','lane_blocks','events','event_lanes')
        union all select 'index',c.relname,i.indexrelid::pg_catalog.regclass::text,pg_catalog.pg_get_indexdef(i.indexrelid) from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('lane_booking_durations','lane_pricing_rules','reservations','lane_blocks','events','event_lanes')
        union all select 'trigger',c.relname,t.tgname,pg_catalog.pg_get_triggerdef(t.oid,true) from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('lane_booking_durations','lane_pricing_rules','reservations','lane_blocks','events','event_lanes') and not t.tgisinternal
        union all select 'policy',p.tablename,p.policyname,p.permissive||'|'||p.cmd||'|'||p.roles::text||'|'||coalesce(p.qual,'<null>')||'|'||coalesce(p.with_check,'<null>') from pg_catalog.pg_policies p where p.schemaname='public' and p.tablename in ('lane_booking_durations','lane_pricing_rules','reservations','lane_blocks','events','event_lanes')
      ) schema_object
    )
    and (select other_data_hash from pg_temp.baseline_lane_hierarchy_contract) = pg_catalog.md5(
      (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(r)::text), E'\n' order by r.id), '')) from public.reservations r)
      || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(b)::text), E'\n' order by b.id), '')) from public.lane_blocks b)
      || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(d)::text), E'\n' order by d.id), '')) from public.lane_booking_durations d)
      || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(p)::text), E'\n' order by p.id), '')) from public.lane_pricing_rules p)
      || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(e)::text), E'\n' order by e.id), '')) from public.events e)
      || (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.md5(pg_catalog.to_jsonb(el)::text), E'\n' order by el.event_id, el.lane_id), '')) from public.event_lanes el)
    ),
    'Nie zmieniono schematu tabel runtime.');

  perform pg_temp.record_result(36, 'Runtime RPC pozostaly identyczne',
    (select runtime_functions_hash from pg_temp.baseline_lane_hierarchy_contract) = pg_catalog.md5(
      pg_catalog.pg_get_functiondef('public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure)
      || pg_catalog.pg_get_functiondef('public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure)
    ),
    'create_reservation i availability v2 nie zostaly zmienione.');

  perform pg_temp.record_result(37, 'Fixture sa ograniczone markerem',
    (select pg_catalog.count(*) from public.shooting_lanes where id::text like '6a300000-0000-4000-8000-%') = 8
      and (select pg_catalog.count(*) from auth.users where id::text like '6a300000-0000-4000-8000-%') = 4,
    'Wszystkie dane testowe maja kontrolowany manifest.');

  perform pg_temp.record_result(38, 'Gotowosc do ROLLBACK', true,
    'Migracja, helpery, ACL, RLS i fixture sa w jednej transakcji.');
end;
$tests$;

table pg_temp.test_results order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(test_order::text || ': ' || test_name, ', ' order by test_order)
  into v_failures
  from pg_temp.test_results
  where not passed;

  if v_failures is not null then
    raise exception 'Lane hierarchy foundation tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regclass('public.lane_booking_rules') is null
  and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='shooting_lanes'
      and column_name in ('resource_kind','parent_lane_id','whole_lane_bookable','positions_bookable')
  )
  and pg_catalog.to_regprocedure('public.validate_shooting_lane_hierarchy()') is null
  and pg_catalog.to_regprocedure('public.validate_lane_booking_rule_capacity()') is null
  and pg_catalog.to_regprocedure('public.validate_shooting_lane_capacity_change()') is null
  and :'baseline_lane_count'::bigint = (select pg_catalog.count(*) from public.shooting_lanes)
  and :'baseline_lane_data_hash' = (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
    from public.shooting_lanes row_record
  )
  and :'baseline_lane_policies_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      policyname||'|'||permissive||'|'||cmd||'|'||roles::text||'|'||coalesce(qual,'<null>')||'|'||coalesce(with_check,'<null>'),
      E'\n' order by policyname))
    from pg_catalog.pg_policies where schemaname='public' and tablename='shooting_lanes'
  )
  and :'baseline_lane_acl_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      coalesce(r.rolname,'PUBLIC')||'|'||a.privilege_type||'|'||a.is_grantable::text,
      E'\n' order by coalesce(r.rolname,'PUBLIC'),a.privilege_type))
    from pg_catalog.pg_class c
    cross join lateral pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) a
    left join pg_catalog.pg_roles r on r.oid=a.grantee
    where c.oid='public.shooting_lanes'::pg_catalog.regclass
  )
  and not exists (select 1 from auth.users where id::text like '6a300000-0000-4000-8000-%')
  and not exists (select 1 from public.profiles where user_id::text like '6a300000-0000-4000-8000-%')
  and not exists (select 1 from public.shooting_lanes where id::text like '6a300000-0000-4000-8000-%')
  as rollback_confirmed;
