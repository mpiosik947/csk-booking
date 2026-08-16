\set ON_ERROR_STOP on

-- Uruchamiaj przez psql. Migracja i wszystkie dane [TEST][6A-1C] są objęte
-- jedną transakcją kończącą się jawnym ROLLBACK.
begin;

create temporary table baseline_shooting_lanes_contract as
select
  (
    select pg_catalog.md5(pg_catalog.string_agg(
      policyname || '|' || permissive || '|' || cmd || '|' || roles::text || '|'
        || coalesce(qual, '<null>') || '|'
        || coalesce(with_check, '<null>'),
      E'\n' order by policyname
    ))
    from pg_catalog.pg_policies
    where schemaname = 'public' and tablename = 'shooting_lanes'
  ) as policies_hash,
  (
    select pg_catalog.md5(pg_catalog.string_agg(
      coalesce(grantee_role.rolname, 'PUBLIC') || '|'
        || acl.privilege_type || '|' || acl.is_grantable::text,
      E'\n' order by coalesce(grantee_role.rolname, 'PUBLIC'), acl.privilege_type
    ))
    from pg_catalog.pg_class as table_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
    ) as acl
    left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
    where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
  ) as acl_hash,
  (
    select pg_catalog.md5(pg_catalog.string_agg(
      column_name || '|' || data_type || '|' || udt_schema || '.' || udt_name || '|'
        || is_nullable || '|' || coalesce(column_default, '<null>'),
      E'\n' order by ordinal_position
    ))
    from information_schema.columns
    where table_schema = 'public' and table_name = 'shooting_lanes'
  ) as columns_hash,
  (
    select pg_catalog.md5(pg_catalog.string_agg(
      constraint_record.conname || '|'
        || pg_catalog.pg_get_constraintdef(constraint_record.oid, true),
      E'\n' order by constraint_record.conname
    ))
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
  ) as constraints_hash,
  (
    select pg_catalog.md5(pg_catalog.string_agg(
      index_record.indexrelid::pg_catalog.regclass::text || '|'
        || pg_catalog.pg_get_indexdef(index_record.indexrelid),
      E'\n' order by index_record.indexrelid::pg_catalog.regclass::text
    ))
    from pg_catalog.pg_index as index_record
    where index_record.indrelid = 'public.shooting_lanes'::pg_catalog.regclass
  ) as indexes_hash,
  (
    select pg_catalog.md5(pg_catalog.string_agg(
      trigger_record.tgname || '|'
        || pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
      E'\n' order by trigger_record.tgname
    ))
    from pg_catalog.pg_trigger as trigger_record
    where trigger_record.tgrelid = 'public.shooting_lanes'::pg_catalog.regclass
      and not trigger_record.tgisinternal
  ) as triggers_hash,
  (select pg_catalog.count(*) from public.shooting_lanes) as data_count,
  (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      pg_catalog.md5(pg_catalog.to_jsonb(lane_record)::text),
      E'\n' order by lane_record.id
    ), ''))
    from public.shooting_lanes as lane_record
  ) as data_hash,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.is_admin_or_staff()'::pg_catalog.regprocedure
  )) as staff_helper_hash,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.is_admin_or_employee()'::pg_catalog.regprocedure
  )) as employee_helper_hash,
  (
    select pg_catalog.md5(
      permissive || '|' || cmd || '|' || roles::text || '|'
        || coalesce(qual, '<null>') || '|'
        || coalesce(with_check, '<null>')
    )
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'shooting_lanes'
      and policyname = 'Public can view active shooting lanes'
  ) as public_policy_hash,
  (
    select coalesce(
      pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
      array[]::text[]
    )
    from pg_catalog.pg_class as table_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
    ) as acl
    where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
      and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'service_role')
  ) as service_role_acl,
  (
    not exists (
      select 1
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
        and acl.grantee = 0
    )
    and not exists (
      select 1
      from pg_catalog.pg_roles as tested_role
      cross join lateral (
        select coalesce(
          pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
          array[]::text[]
        ) as privileges
        from pg_catalog.pg_class as table_record
        cross join lateral pg_catalog.aclexplode(
          coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
        ) as acl
        where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
          and acl.grantee = tested_role.oid
      ) as role_acl
      where tested_role.rolname in ('anon', 'authenticated', 'service_role', 'postgres')
        and role_acl.privileges is distinct from array[
          'DELETE', 'INSERT', 'MAINTAIN', 'REFERENCES',
          'SELECT', 'TRIGGER', 'TRUNCATE', 'UPDATE'
        ]::text[]
    )
  ) as baseline_acl_matches;

select
  policies_hash,
  acl_hash,
  columns_hash,
  constraints_hash,
  indexes_hash,
  triggers_hash,
  data_count,
  data_hash,
  staff_helper_hash,
  employee_helper_hash,
  public_policy_hash
from pg_temp.baseline_shooting_lanes_contract
\gset baseline_

do $setup$
declare
  v_admin_id constant uuid := '6a1c0000-0000-4000-8000-000000000001';
  v_employee_id constant uuid := '6a1c0000-0000-4000-8000-000000000002';
  v_instructor_id constant uuid := '6a1c0000-0000-4000-8000-000000000003';
  v_user_id constant uuid := '6a1c0000-0000-4000-8000-000000000004';
begin
  if exists (
    select 1 from auth.users
    where id in (v_admin_id, v_employee_id, v_instructor_id, v_user_id)
  ) or exists (
    select 1 from public.shooting_lanes
    where id in (
      '6a1c0000-0000-4000-8000-000000000101'::uuid,
      '6a1c0000-0000-4000-8000-000000000102'::uuid
    )
  ) then
    raise exception 'Setup failed: [TEST][6A-1C] identifiers already exist.';
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-6a1c-admin@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_employee_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-6a1c-employee@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_instructor_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-6a1c-instructor@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_user_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-6a1c-user@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp());

  update public.profiles as profile_record
  set role = case profile_record.user_id
        when v_admin_id then 'admin'
        when v_employee_id then 'pracownik'
        when v_instructor_id then 'instruktor'
        when v_user_id then 'user'
      end
  where profile_record.user_id in (
    v_admin_id, v_employee_id, v_instructor_id, v_user_id
  );

  if (select pg_catalog.count(*) from public.profiles
      where user_id in (v_admin_id, v_employee_id, v_instructor_id, v_user_id)) <> 4 then
    raise exception 'Setup failed: synthetic profiles were not created.';
  end if;

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code
  ) values
    ('6a1c0000-0000-4000-8000-000000000101',
     '[TEST][6A-1C][ACTIVE]', '[TEST]', '[TEST]', 0, true,
     1, 60, 9901, 'PLN'),
    ('6a1c0000-0000-4000-8000-000000000102',
     '[TEST][6A-1C][INACTIVE]', '[TEST]', '[TEST]', 0, false,
     1, 60, 9902, 'PLN');
end;
$setup$;

\ir ../migrations/20260808194442_harden_shooting_lanes_access.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.test_user_id(p_role text)
returns uuid
language sql
stable
as $function$
  select case p_role
    when 'admin' then '6a1c0000-0000-4000-8000-000000000001'::uuid
    when 'pracownik' then '6a1c0000-0000-4000-8000-000000000002'::uuid
    when 'instruktor' then '6a1c0000-0000-4000-8000-000000000003'::uuid
    when 'user' then '6a1c0000-0000-4000-8000-000000000004'::uuid
    else null
  end;
$function$;

create function pg_temp.set_test_user(p_user_id uuid, p_effective_role text)
returns void
language plpgsql
as $function$
begin
  if p_user_id is null then
    perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
    perform pg_catalog.set_config(
      'request.jwt.claims',
      pg_catalog.jsonb_build_object('role', p_effective_role)::text,
      true
    );
  else
    perform pg_catalog.set_config('request.jwt.claim.sub', p_user_id::text, true);
    perform pg_catalog.set_config(
      'request.jwt.claims',
      pg_catalog.jsonb_build_object('sub', p_user_id, 'role', p_effective_role)::text,
      true
    );
  end if;
end;
$function$;

create function pg_temp.visible_test_lanes(p_role text, p_active boolean)
returns bigint
language plpgsql
as $function$
declare
  v_count bigint;
  v_effective_role text := case when p_role = 'anon' then 'anon' else 'authenticated' end;
begin
  perform pg_temp.set_test_user(pg_temp.test_user_id(p_role), v_effective_role);
  execute pg_catalog.format('set local role %I', v_effective_role);
  select pg_catalog.count(*)
  into v_count
  from public.shooting_lanes
  where id in (
    '6a1c0000-0000-4000-8000-000000000101'::uuid,
    '6a1c0000-0000-4000-8000-000000000102'::uuid
  )
    and is_active = p_active;
  execute 'reset role';
  return v_count;
end;
$function$;

create function pg_temp.direct_dml_is_blocked(p_role text, p_operation text)
returns boolean
language plpgsql
as $function$
declare
  v_effective_role text := case when p_role = 'anon' then 'anon' else 'authenticated' end;
begin
  perform pg_temp.set_test_user(pg_temp.test_user_id(p_role), v_effective_role);
  execute pg_catalog.format('set local role %I', v_effective_role);

  begin
    if p_operation = 'insert' then
      insert into public.shooting_lanes (
        id, name, type, description, price_per_hour, is_active,
        max_shooters, booking_step_minutes, display_order, currency_code
      ) values (
        pg_catalog.gen_random_uuid(), '[TEST][6A-1C][DIRECT]', '[TEST]', '[TEST]', 0, true,
        1, 60, 9999, 'PLN'
      );
    elsif p_operation = 'update' then
      update public.shooting_lanes
      set description = '[TEST][6A-1C][DIRECT-UPDATE]'
      where id = '6a1c0000-0000-4000-8000-000000000101'::uuid;
    elsif p_operation = 'delete' then
      delete from public.shooting_lanes
      where id = '6a1c0000-0000-4000-8000-000000000101'::uuid;
    else
      raise exception 'Unknown test operation: %', p_operation using errcode = '22023';
    end if;
  exception when insufficient_privilege then
    execute 'reset role';
    return true;
  end;

  execute 'reset role';
  return false;
end;
$function$;

create function pg_temp.all_direct_dml_is_blocked(p_role text)
returns boolean
language sql
as $function$
  select pg_temp.direct_dml_is_blocked(p_role, 'insert')
     and pg_temp.direct_dml_is_blocked(p_role, 'update')
     and pg_temp.direct_dml_is_blocked(p_role, 'delete');
$function$;

insert into pg_temp.test_results values
  (1, 'ACL przed migracją odpowiada baseline',
    (select baseline_acl_matches from pg_temp.baseline_shooting_lanes_contract),
    'PUBLIC bez praw; anon, authenticated, service_role i postgres miały pełny ACL.'),
  (2, 'Tabela zachowuje ownera i flagi RLS',
    exists (
      select 1
      from pg_catalog.pg_class as table_record
      join pg_catalog.pg_roles as owner_role on owner_role.oid = table_record.relowner
      where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
        and owner_role.rolname = 'postgres'
        and table_record.relrowsecurity
        and not table_record.relforcerowsecurity
    ),
    'Owner postgres, RLS enabled, FORCE RLS false.'),
  (3, 'Publiczna polityka SELECT jest identyczna',
    (select public_policy_hash from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.md5(
        permissive || '|' || cmd || '|' || roles::text || '|'
          || coalesce(qual, '<null>') || '|'
          || coalesce(with_check, '<null>')
      )
      from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'shooting_lanes'
        and policyname = 'Public can view active shooting lanes'
    ),
    'Nie zmieniono publicznego odczytu aktywnych osi.'),
  (4, 'Istnieją dokładnie dwie polityki SELECT',
    (select pg_catalog.count(*) = 2 from pg_catalog.pg_policies
     where schemaname = 'public' and tablename = 'shooting_lanes' and cmd = 'SELECT')
    and (select pg_catalog.count(*) = 2 from pg_catalog.pg_policies
         where schemaname = 'public' and tablename = 'shooting_lanes'),
    'Public active i authenticated staff all.'),
  (5, 'Brak mutacyjnych polityk RLS',
    not exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'shooting_lanes'
        and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')
    ),
    'Nie istnieją polityki ALL/INSERT/UPDATE/DELETE.'),
  (6, 'Polityka staff ma bezpieczny kontrakt',
    exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'shooting_lanes'
        and policyname = 'Staff can view all shooting lanes'
        and permissive = 'PERMISSIVE'
        and roles = array['authenticated']::name[]
        and cmd = 'SELECT'
        and qual = 'is_admin_or_staff()'
        and with_check is null
    ),
    'Wyłącznie SELECT przez is_admin_or_staff().'),
  (7, 'PUBLIC nie ma praw tabelowych',
    not exists (
      select 1
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
        and acl.grantee = 0
    ),
    'Brak jawnego ACL PUBLIC.'),
  (8, 'anon ma wyłącznie SELECT',
    (select pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type)
     from pg_catalog.pg_class as table_record
     cross join lateral pg_catalog.aclexplode(
       coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
     ) as acl
     where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
       and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon'))
      = array['SELECT']::text[],
    'Brak DML, TRUNCATE, REFERENCES, TRIGGER i MAINTAIN.'),
  (9, 'authenticated ma wyłącznie SELECT',
    (select pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type)
     from pg_catalog.pg_class as table_record
     cross join lateral pg_catalog.aclexplode(
       coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
     ) as acl
     where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
       and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'authenticated'))
      = array['SELECT']::text[],
    'Brak DML, TRUNCATE, REFERENCES, TRIGGER i MAINTAIN.'),
  (10, 'service_role ACL pozostał bez zmian',
    (select service_role_acl from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type)
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'service_role')
    ),
    'Migracja nie zmieniła service_role.'),
  (11, 'Helpery ról pozostały identyczne',
    (select staff_helper_hash from pg_temp.baseline_shooting_lanes_contract)
      = pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin_or_staff()'::pg_catalog.regprocedure))
    and (select employee_helper_hash from pg_temp.baseline_shooting_lanes_contract)
      = pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin_or_employee()'::pg_catalog.regprocedure)),
    'Porównano pełne definicje obu funkcji.'),
  (12, 'Schemat kolumn pozostał identyczny',
    (select columns_hash from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.md5(pg_catalog.string_agg(
        column_name || '|' || data_type || '|' || udt_schema || '.' || udt_name || '|'
          || is_nullable || '|' || coalesce(column_default, '<null>'),
        E'\n' order by ordinal_position
      ))
      from information_schema.columns
      where table_schema = 'public' and table_name = 'shooting_lanes'
    ),
    'Migracja nie zmieniła kolumn.'),
  (13, 'Constrainty pozostały identyczne',
    (select constraints_hash from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.md5(pg_catalog.string_agg(
        constraint_record.conname || '|'
          || pg_catalog.pg_get_constraintdef(constraint_record.oid, true),
        E'\n' order by constraint_record.conname
      ))
      from pg_catalog.pg_constraint as constraint_record
      where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
    ),
    'Migracja nie zmieniła constraintów.'),
  (14, 'Indeksy pozostały identyczne',
    (select indexes_hash from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.md5(pg_catalog.string_agg(
        index_record.indexrelid::pg_catalog.regclass::text || '|'
          || pg_catalog.pg_get_indexdef(index_record.indexrelid),
        E'\n' order by index_record.indexrelid::pg_catalog.regclass::text
      ))
      from pg_catalog.pg_index as index_record
      where index_record.indrelid = 'public.shooting_lanes'::pg_catalog.regclass
    ),
    'Migracja nie zmieniła indeksów.'),
  (15, 'Triggery pozostały identyczne',
    (select triggers_hash from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.md5(pg_catalog.string_agg(
        trigger_record.tgname || '|'
          || pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
        E'\n' order by trigger_record.tgname
      ))
      from pg_catalog.pg_trigger as trigger_record
      where trigger_record.tgrelid = 'public.shooting_lanes'::pg_catalog.regclass
        and not trigger_record.tgisinternal
    ),
    'Migracja nie zmieniła triggerów.'),
  (16, 'Dane istniejących osi pozostały identyczne',
    (select data_count from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.count(*) from public.shooting_lanes
      where id not in (
        '6a1c0000-0000-4000-8000-000000000101'::uuid,
        '6a1c0000-0000-4000-8000-000000000102'::uuid
      )
    )
    and (select data_hash from pg_temp.baseline_shooting_lanes_contract) = (
      select pg_catalog.md5(coalesce(pg_catalog.string_agg(
        pg_catalog.md5(pg_catalog.to_jsonb(lane_record)::text),
        E'\n' order by lane_record.id
      ), ''))
      from public.shooting_lanes as lane_record
      where lane_record.id not in (
        '6a1c0000-0000-4000-8000-000000000101'::uuid,
        '6a1c0000-0000-4000-8000-000000000102'::uuid
      )
    ),
    'Liczba i hash istniejących danych są niezmienione.'),
  (17, 'anon widzi aktywną oś',
    pg_temp.visible_test_lanes('anon', true) = 1,
    'Publiczna polityka SELECT działa.'),
  (18, 'anon nie widzi nieaktywnej osi',
    pg_temp.visible_test_lanes('anon', false) = 0,
    'Nieaktywna oś pozostaje ukryta.'),
  (19, 'anon nie może wykonywać direct DML',
    pg_temp.all_direct_dml_is_blocked('anon'),
    'INSERT, UPDATE i DELETE są blokowane grantami.'),
  (20, 'user widzi aktywną oś',
    pg_temp.visible_test_lanes('user', true) = 1,
    'Publiczna polityka SELECT obejmuje authenticated user.'),
  (21, 'user nie widzi nieaktywnej osi',
    pg_temp.visible_test_lanes('user', false) = 0,
    'User nie spełnia polityki staff.'),
  (22, 'user nie może wykonywać direct DML',
    pg_temp.all_direct_dml_is_blocked('user'),
    'INSERT, UPDATE i DELETE są blokowane grantami.'),
  (23, 'instruktor widzi aktywne i nieaktywne osie',
    pg_temp.visible_test_lanes('instruktor', true) = 1
      and pg_temp.visible_test_lanes('instruktor', false) = 1,
    'is_admin_or_staff() obejmuje instruktora.'),
  (24, 'instruktor nie może wykonywać direct DML',
    pg_temp.all_direct_dml_is_blocked('instruktor'),
    'Instruktor ma wyłącznie odczyt.'),
  (25, 'pracownik widzi aktywne i nieaktywne osie',
    pg_temp.visible_test_lanes('pracownik', true) = 1
      and pg_temp.visible_test_lanes('pracownik', false) = 1,
    'Polityka staff obejmuje pracownika.'),
  (26, 'pracownik nie może wykonywać direct DML',
    pg_temp.all_direct_dml_is_blocked('pracownik'),
    'Pracownik ma wyłącznie odczyt tabelowy.'),
  (27, 'admin widzi aktywne i nieaktywne osie',
    pg_temp.visible_test_lanes('admin', true) = 1
      and pg_temp.visible_test_lanes('admin', false) = 1,
    'Polityka staff obejmuje admina.'),
  (28, 'admin nie może wykonywać direct DML',
    pg_temp.all_direct_dml_is_blocked('admin'),
    'Admin ma wyłącznie odczyt tabelowy.'),
  (29, 'Brak grantów TRUNCATE dla klientów',
    not pg_catalog.has_table_privilege('anon', 'public.shooting_lanes', 'TRUNCATE')
      and not pg_catalog.has_table_privilege('authenticated', 'public.shooting_lanes', 'TRUNCATE'),
    'TRUNCATE sprawdzono wyłącznie katalogowo; nie wykonano operacji.'),
  (30, 'Dane testowe są kompletne i niezmienione',
    (select pg_catalog.count(*) = 2 from public.shooting_lanes
     where id in (
       '6a1c0000-0000-4000-8000-000000000101'::uuid,
       '6a1c0000-0000-4000-8000-000000000102'::uuid
     ))
    and exists (
      select 1 from public.shooting_lanes
      where id = '6a1c0000-0000-4000-8000-000000000101'::uuid
        and name = '[TEST][6A-1C][ACTIVE]' and is_active
    )
    and exists (
      select 1 from public.shooting_lanes
      where id = '6a1c0000-0000-4000-8000-000000000102'::uuid
        and name = '[TEST][6A-1C][INACTIVE]' and not is_active
    ),
    'Próby direct DML nie pozostawiły stanu częściowego.'),
  (31, 'Gotowość do końcowego ROLLBACK', true,
    'Migracja, ACL, polityki, helpery i dane testowe są w jednej transakcji.');

table pg_temp.test_results order by test_order;

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
    raise exception 'Shooting lanes hardening tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  :'baseline_policies_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      policyname || '|' || permissive || '|' || cmd || '|' || roles::text || '|'
        || coalesce(qual, '<null>') || '|'
        || coalesce(with_check, '<null>'),
      E'\n' order by policyname
    ))
    from pg_catalog.pg_policies
    where schemaname = 'public' and tablename = 'shooting_lanes'
  )
  and :'baseline_acl_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      coalesce(grantee_role.rolname, 'PUBLIC') || '|'
        || acl.privilege_type || '|' || acl.is_grantable::text,
      E'\n' order by coalesce(grantee_role.rolname, 'PUBLIC'), acl.privilege_type
    ))
    from pg_catalog.pg_class as table_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
    ) as acl
    left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
    where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
  )
  and :'baseline_columns_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      column_name || '|' || data_type || '|' || udt_schema || '.' || udt_name || '|'
        || is_nullable || '|' || coalesce(column_default, '<null>'),
      E'\n' order by ordinal_position
    ))
    from information_schema.columns
    where table_schema = 'public' and table_name = 'shooting_lanes'
  )
  and :'baseline_constraints_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      constraint_record.conname || '|'
        || pg_catalog.pg_get_constraintdef(constraint_record.oid, true),
      E'\n' order by constraint_record.conname
    ))
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
  )
  and :'baseline_indexes_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      index_record.indexrelid::pg_catalog.regclass::text || '|'
        || pg_catalog.pg_get_indexdef(index_record.indexrelid),
      E'\n' order by index_record.indexrelid::pg_catalog.regclass::text
    ))
    from pg_catalog.pg_index as index_record
    where index_record.indrelid = 'public.shooting_lanes'::pg_catalog.regclass
  )
  and :'baseline_triggers_hash' = (
    select pg_catalog.md5(pg_catalog.string_agg(
      trigger_record.tgname || '|'
        || pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
      E'\n' order by trigger_record.tgname
    ))
    from pg_catalog.pg_trigger as trigger_record
    where trigger_record.tgrelid = 'public.shooting_lanes'::pg_catalog.regclass
      and not trigger_record.tgisinternal
  )
  and :'baseline_data_count'::bigint = (select pg_catalog.count(*) from public.shooting_lanes)
  and :'baseline_data_hash' = (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      pg_catalog.md5(pg_catalog.to_jsonb(lane_record)::text),
      E'\n' order by lane_record.id
    ), ''))
    from public.shooting_lanes as lane_record
  )
  and :'baseline_staff_helper_hash' = pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.is_admin_or_staff()'::pg_catalog.regprocedure
  ))
  and :'baseline_employee_helper_hash' = pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.is_admin_or_employee()'::pg_catalog.regprocedure
  ))
  and not exists (
    select 1 from auth.users
    where id in (
      '6a1c0000-0000-4000-8000-000000000001'::uuid,
      '6a1c0000-0000-4000-8000-000000000002'::uuid,
      '6a1c0000-0000-4000-8000-000000000003'::uuid,
      '6a1c0000-0000-4000-8000-000000000004'::uuid
    )
  )
  and not exists (
    select 1 from public.profiles
    where user_id in (
      '6a1c0000-0000-4000-8000-000000000001'::uuid,
      '6a1c0000-0000-4000-8000-000000000002'::uuid,
      '6a1c0000-0000-4000-8000-000000000003'::uuid,
      '6a1c0000-0000-4000-8000-000000000004'::uuid
    )
  ) as rollback_confirmed;
