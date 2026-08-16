\set ON_ERROR_STOP on

-- Uruchamiaj przez psql, nie przez Supabase SQL Editor. Migracja i wszystkie
-- dane [TEST][5D-4B] są objęte jedną transakcją kończącą się ROLLBACK.
begin;

create temporary table baseline_events_contract as
select
  (select md5(string_agg(policyname || '|' || cmd || '|' || roles::text || '|'
    || coalesce(qual, '<null>') || '|' || coalesce(with_check, '<null>'), E'\n' order by policyname))
   from pg_catalog.pg_policies
   where schemaname = 'public' and tablename = 'events') as policies_hash,
  (select md5(string_agg(grantee || '|' || privilege_type, E'\n' order by grantee, privilege_type))
   from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'events'
     and grantee in ('anon', 'authenticated', 'service_role')) as grants_hash;

select policies_hash, grants_hash from pg_temp.baseline_events_contract \gset baseline_

\ir ../migrations/20260807120000_harden_event_mutations.sql

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
  active_event_id uuid not null,
  inactive_event_id uuid not null
) on commit drop;

do $setup$
declare
  v_admin_user_id uuid := '5d4b0000-0000-4000-8000-000000000001';
  v_employee_user_id uuid := '5d4b0000-0000-4000-8000-000000000002';
  v_instructor_user_id uuid := '5d4b0000-0000-4000-8000-000000000003';
  v_regular_user_id uuid := '5d4b0000-0000-4000-8000-000000000004';
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin_user_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d4b-admin@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_employee_user_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d4b-employee@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_instructor_user_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d4b-instructor@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()),
    (v_regular_user_id, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', '[TEST]-5d4b-user@example.invalid', '',
     pg_catalog.transaction_timestamp(), '{}'::jsonb, '{}'::jsonb,
     pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp());

  update public.profiles as profile_record
  set role = case profile_record.user_id
        when v_admin_user_id then 'admin'
        when v_employee_user_id then 'pracownik'
        when v_instructor_user_id then 'instruktor'
        when v_regular_user_id then 'user'
      end
  where profile_record.user_id in (
    v_admin_user_id, v_employee_user_id,
    v_instructor_user_id, v_regular_user_id
  );

  if (select count(*) from public.profiles where user_id in (
    v_admin_user_id, v_employee_user_id, v_instructor_user_id, v_regular_user_id
  )) <> 4 then
    raise exception 'Nie utworzono kompletu syntetycznych profili per role.' using errcode = 'P0002';
  end if;

  insert into pg_temp.test_context(
    admin_user_id, employee_user_id, instructor_user_id, regular_user_id,
    active_event_id, inactive_event_id
  ) values (
    v_admin_user_id, v_employee_user_id, v_instructor_user_id, v_regular_user_id,
    pg_catalog.gen_random_uuid(), pg_catalog.gen_random_uuid()
  );

  insert into public.events (
    id, title, description, event_date, start_time, end_time,
    location, price, max_participants, is_active
  )
  select active_event_id, '[TEST][5D-4B][active]', null, current_date + 30,
    time '10:00', time '11:00', null, 0, 1, true
  from pg_temp.test_context
  union all
  select inactive_event_id, '[TEST][5D-4B][inactive]', null, current_date + 31,
    time '10:00', time '11:00', null, 0, 1, false
  from pg_temp.test_context;
end;
$setup$;

create function pg_temp.test_user_id(p_role text)
returns uuid
language sql
stable
as $function$
  select case p_role
    when 'admin' then admin_user_id
    when 'pracownik' then employee_user_id
    when 'instruktor' then instructor_user_id
    when 'user' then regular_user_id
    else null
  end
  from pg_temp.test_context;
$function$;

create function pg_temp.set_test_user(p_user_id uuid)
returns void
language plpgsql
as $function$
begin
  if p_user_id is null then
    perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
    perform pg_catalog.set_config('request.jwt.claims', '{}'::text, true);
  else
    perform pg_catalog.set_config('request.jwt.claim.sub', p_user_id::text, true);
    perform pg_catalog.set_config(
      'request.jwt.claims',
      pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
      true
    );
  end if;
end;
$function$;

create function pg_temp.direct_dml_is_blocked(
  p_user_id uuid,
  p_effective_role text,
  p_operation text
)
returns boolean
language plpgsql
as $function$
declare
  v_event_id uuid;
begin
  select active_event_id
  into v_event_id
  from pg_temp.test_context;

  perform pg_temp.set_test_user(p_user_id);
  execute pg_catalog.format('set local role %I', p_effective_role);
  begin
    if p_operation = 'insert' then
      insert into public.events (
        id, title, event_date, start_time, end_time, price, max_participants, is_active
      ) values (
        pg_catalog.gen_random_uuid(), '[TEST][5D-4B][direct]', current_date + 32,
        time '10:00', time '11:00', 0, 1, true
      );
    elsif p_operation = 'update' then
      update public.events
      set title = '[TEST][5D-4B][direct-update]'
      where id = v_event_id;
    elsif p_operation = 'delete' then
      delete from public.events where id = v_event_id;
    else
      raise exception 'Nieznana operacja testowa: %', p_operation using errcode = '22023';
    end if;
  exception when insufficient_privilege then
    execute 'reset role';
    return true;
  end;

  execute 'reset role';
  return false;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.event_visibility_is_expected(
  p_user_id uuid,
  p_effective_role text,
  p_can_see_inactive boolean
)
returns boolean
language plpgsql
as $function$
declare
  v_active_count integer;
  v_inactive_count integer;
begin
  perform pg_temp.set_test_user(p_user_id);
  execute pg_catalog.format('set local role %I', p_effective_role);

  select count(*) filter (where title = '[TEST][5D-4B][active]'),
         count(*) filter (where title = '[TEST][5D-4B][inactive]')
  into v_active_count, v_inactive_count
  from public.events;
  execute 'reset role';
  return v_active_count = 1 and (v_inactive_count = 1) = p_can_see_inactive;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_event_rpc(
  p_user_id uuid,
  p_operation text,
  p_event_id uuid default null
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_temp.set_test_user(p_user_id);
  execute 'set local role authenticated';

  if p_operation = 'create' then
    select public.admin_create_event(
      '[TEST][5D-4B][rpc]', null, current_date + 40,
      time '10:00', time '11:00', null, 0, 1, '{}'::uuid[]
    ) into v_result;
  elsif p_operation = 'update' then
    select public.admin_update_event(
      p_event_id, '[TEST][5D-4B][rpc-updated]', null,
      current_date + 40, time '10:00', time '11:00', null, 0, 1, '{}'::uuid[]
    ) into v_result;
  elsif p_operation = 'set_active' then
    select public.admin_set_event_active(p_event_id, false) into v_result;
  else
    raise exception 'Nieznane RPC testowe: %', p_operation using errcode = '22023';
  end if;

  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.anon_rpc_is_blocked()
returns boolean
language plpgsql
as $function$
begin
  perform pg_temp.set_test_user(null);
  execute 'set local role anon';
  begin
    perform public.admin_set_event_active(null, false);
  exception when insufficient_privilege then
    execute 'reset role';
    return true;
  end;
  execute 'reset role';
  return false;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.no_session_rpc_is_rejected()
returns boolean
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_temp.set_test_user(null);
  execute 'set local role authenticated';
  select public.admin_create_event(
    '[TEST][5D-4B][no-session]', null, current_date + 40,
    time '10:00', time '11:00', null, 0, 1, '{}'::uuid[]
  ) into v_result;
  execute 'reset role';
  return coalesce((v_result ->> 'ok')::boolean, false) is false
    and v_result ->> 'code' = 'not_allowed';
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

insert into pg_temp.test_results values
  (1, 'RLS pozostaje włączony', (select relrowsecurity from pg_catalog.pg_class where oid = 'public.events'::regclass), 'RLS public.events.'),
  (2, 'FORCE RLS pozostaje wyłączone', not (select relforcerowsecurity from pg_catalog.pg_class where oid = 'public.events'::regclass), 'Owner SECURITY DEFINER wykonuje kontrolowane RPC.'),
  (3, 'Pozostały dokładnie trzy polityki SELECT', (select count(*) = 3 from pg_catalog.pg_policy where polrelid = 'public.events'::regclass and polcmd = 'r'), 'Polityki mutacyjne usunięte.'),
  (4, 'Brak polityk INSERT UPDATE DELETE', not exists (select 1 from pg_catalog.pg_policy where polrelid = 'public.events'::regclass and polcmd in ('a','w','d')), 'Brak klientowej ścieżki RLS do mutacji.'),
  (5, 'authenticated ma wyłącznie SELECT', pg_catalog.has_table_privilege('authenticated', 'public.events', 'SELECT') and not (pg_catalog.has_table_privilege('authenticated', 'public.events', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')), 'ACL authenticated.'),
  (6, 'anon ma wyłącznie SELECT', pg_catalog.has_table_privilege('anon', 'public.events', 'SELECT') and not (pg_catalog.has_table_privilege('anon', 'public.events', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')), 'ACL anon.'),
  (7, 'PUBLIC nie ma praw do events', not exists (select 1 from pg_catalog.pg_class as class_record cross join lateral pg_catalog.aclexplode(coalesce(class_record.relacl, pg_catalog.acldefault('r', class_record.relowner))) as acl where class_record.oid = 'public.events'::regclass and acl.grantee = 0), 'ACL katalogowe PUBLIC.'),
  (8, 'service_role zachowuje pełne prawa', pg_catalog.has_table_privilege('service_role', 'public.events', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'), 'ACL service_role.'),
  (9, 'Anon widzi tylko aktywny event', pg_temp.event_visibility_is_expected(null, 'anon', false), 'Publiczny odczyt aktywnego eventu.'),
  (10, 'User widzi tylko aktywny event', pg_temp.event_visibility_is_expected(pg_temp.test_user_id('user'), 'authenticated', false), 'Odczyt usera.'),
  (11, 'Admin widzi event nieaktywny', pg_temp.event_visibility_is_expected(pg_temp.test_user_id('admin'), 'authenticated', true), 'Odczyt panelu.'),
  (12, 'Pracownik widzi event nieaktywny', pg_temp.event_visibility_is_expected(pg_temp.test_user_id('pracownik'), 'authenticated', true), 'Odczyt panelu.'),
  (13, 'Instruktor widzi event nieaktywny', pg_temp.event_visibility_is_expected(pg_temp.test_user_id('instruktor'), 'authenticated', true), 'Odczyt panelu.');

do $direct_dml$
declare
  v_role text;
  v_operation text;
  v_order integer := 14;
begin
  foreach v_role in array array['admin', 'pracownik', 'instruktor', 'user', 'anon'] loop
    foreach v_operation in array array['insert', 'update', 'delete'] loop
      insert into pg_temp.test_results values (
        v_order,
        initcap(v_role) || ' direct ' || upper(v_operation) || ' jest zablokowany',
        pg_temp.direct_dml_is_blocked(
          pg_temp.test_user_id(v_role),
          case when v_role = 'anon' then 'anon' else 'authenticated' end,
          v_operation
        ),
        'Brak grantu DML blokuje bezpośrednią mutację.'
      );
      v_order := v_order + 1;
    end loop;
  end loop;
end;
$direct_dml$;

insert into pg_temp.test_results values
  (29, 'Trzy RPC mają dokładne sygnatury bez overloadów',
    pg_catalog.to_regprocedure('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is not null
    and pg_catalog.to_regprocedure('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is not null
    and pg_catalog.to_regprocedure('public.admin_set_event_active(uuid,boolean)') is not null
    and (select count(*) from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname = 'admin_create_event') = 1
    and (select count(*) from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname = 'admin_update_event') = 1
    and (select count(*) from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname = 'admin_set_event_active') = 1,
    'Każda nazwa ma dokładnie jeden overload o oczekiwanej sygnaturze.'),
  (30, 'RPC są SECURITY DEFINER postgres ze search_path', not exists (select 1 from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure_record.proowner where namespace_record.nspname = 'public' and procedure_record.proname in ('admin_create_event','admin_update_event','admin_set_event_active') and (not procedure_record.prosecdef or owner_role.rolname <> 'postgres' or procedure_record.proconfig is distinct from array['search_path=public, pg_temp'])), 'Kontrakt SECURITY DEFINER.'),
  (31, 'authenticated ma EXECUTE RPC', not exists (select 1 from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname in ('admin_create_event','admin_update_event','admin_set_event_active') and not pg_catalog.has_function_privilege('authenticated', procedure_record.oid, 'EXECUTE')), 'RPC są jedyną ścieżką zapisu.'),
  (32, 'anon i PUBLIC nie mają EXECUTE RPC', not exists (select 1 from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname in ('admin_create_event','admin_update_event','admin_set_event_active') and (pg_catalog.has_function_privilege('anon', procedure_record.oid, 'EXECUTE') or exists (select 1 from pg_catalog.aclexplode(coalesce(procedure_record.proacl, pg_catalog.acldefault('f', procedure_record.proowner))) as acl where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'))), 'ACL RPC.'),
  (33, 'Anon nie może wywołać RPC', pg_temp.anon_rpc_is_blocked(), 'Brak EXECUTE anon.'),
  (34, 'Brak sesji jest odrzucony przez RPC', pg_temp.no_session_rpc_is_rejected(), 'auth.uid() jest wymagane.');

do $rpc$
declare
  v_role text;
  v_create jsonb;
  v_event_id uuid;
  v_result jsonb;
  v_order integer := 35;
begin
  foreach v_role in array array['admin', 'pracownik'] loop
    v_create := pg_temp.call_event_rpc(pg_temp.test_user_id(v_role), 'create');
    v_event_id := nullif(v_create ->> 'event_id', '')::uuid;
    insert into pg_temp.test_results values (v_order, initcap(v_role) || ' RPC create działa', coalesce((v_create ->> 'ok')::boolean, false) and v_create ->> 'code' = 'created' and v_event_id is not null, 'Kontrolowane utworzenie przez SECURITY DEFINER.');
    v_order := v_order + 1;
    v_result := pg_temp.call_event_rpc(pg_temp.test_user_id(v_role), 'update', v_event_id);
    insert into pg_temp.test_results values (v_order, initcap(v_role) || ' RPC update działa', coalesce((v_result ->> 'ok')::boolean, false) and v_result ->> 'code' = 'updated', 'Kontrolowana aktualizacja przez SECURITY DEFINER.');
    v_order := v_order + 1;
    v_result := pg_temp.call_event_rpc(pg_temp.test_user_id(v_role), 'set_active', v_event_id);
    insert into pg_temp.test_results values (v_order, initcap(v_role) || ' RPC set_active działa', coalesce((v_result ->> 'ok')::boolean, false) and v_result ->> 'code' = 'deactivated', 'Kontrolowana zmiana aktywności przez SECURITY DEFINER.');
    v_order := v_order + 1;
  end loop;

  foreach v_role in array array['instruktor', 'user'] loop
    foreach v_result in array array[
      pg_temp.call_event_rpc(pg_temp.test_user_id(v_role), 'create'),
      pg_temp.call_event_rpc(pg_temp.test_user_id(v_role), 'update'),
      pg_temp.call_event_rpc(pg_temp.test_user_id(v_role), 'set_active')
    ] loop
      insert into pg_temp.test_results values (v_order, initcap(v_role) || ' RPC jest odrzucone', coalesce((v_result ->> 'ok')::boolean, false) is false and v_result ->> 'code' = 'not_allowed', 'Instruktor i user nie mają uprawnień administracyjnych.');
      v_order := v_order + 1;
    end loop;
  end loop;
end;
$rpc$;

insert into pg_temp.test_results values
  (47, 'Dane testowe mają marker', not exists (select 1 from public.events where title like '[TEST][5D-4B]%' and title not like '[TEST][5D-4B][%'), 'Wyłącznie dane syntetyczne.'),
  (48, 'Bezpośrednie DML nie zmieniło testowego eventu', (select count(*) = 2 from public.events where title in ('[TEST][5D-4B][active]', '[TEST][5D-4B][inactive]')), 'Próby direct DML nie zostawiły stanu częściowego.');

table pg_temp.test_results order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select string_agg(test_order::text || ': ' || test_name, ', ' order by test_order)
  into v_failures
  from pg_temp.test_results
  where not passed;

  if v_failures is not null then
    raise exception 'Event mutation hardening tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  :'baseline_policies_hash' = (
    select md5(string_agg(policyname || '|' || cmd || '|' || roles::text || '|'
      || coalesce(qual, '<null>') || '|' || coalesce(with_check, '<null>'), E'\n' order by policyname))
    from pg_catalog.pg_policies
    where schemaname = 'public' and tablename = 'events'
  ) and :'baseline_grants_hash' = (
    select md5(string_agg(grantee || '|' || privilege_type, E'\n' order by grantee, privilege_type))
    from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'events'
      and grantee in ('anon', 'authenticated', 'service_role')
  )
  and not exists (
    select 1 from public.events where title like '[TEST][5D-4B]%'
  )
  and not exists (
    select 1
    from auth.users
    where id in (
      '5d4b0000-0000-4000-8000-000000000001'::uuid,
      '5d4b0000-0000-4000-8000-000000000002'::uuid,
      '5d4b0000-0000-4000-8000-000000000003'::uuid,
      '5d4b0000-0000-4000-8000-000000000004'::uuid
    )
  )
  and not exists (
    select 1
    from public.profiles
    where user_id in (
      '5d4b0000-0000-4000-8000-000000000001'::uuid,
      '5d4b0000-0000-4000-8000-000000000002'::uuid,
      '5d4b0000-0000-4000-8000-000000000003'::uuid,
      '5d4b0000-0000-4000-8000-000000000004'::uuid
    )
  ) as rollback_confirmed;
