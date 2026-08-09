\set ON_ERROR_STOP on

-- Run with psql. The migration and contract checks are enclosed in one
-- transaction that always ends with an explicit ROLLBACK.
begin;

\ir ../migrations/20260809143000_harden_lane_blocks_direct_dml.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.function_fingerprint(p_function pg_catalog.regprocedure)
returns text
language sql
stable
as $function$
  select pg_catalog.md5(pg_catalog.jsonb_build_object(
    'definition', pg_catalog.pg_get_functiondef(function_record.oid),
    'owner', owner_role.rolname,
    'language', language_record.lanname,
    'volatility', function_record.provolatile,
    'security_definer', function_record.prosecdef,
    'config', coalesce(pg_catalog.to_jsonb(function_record.proconfig), '[]'::jsonb),
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
  join pg_catalog.pg_roles as owner_role on owner_role.oid = function_record.proowner
  join pg_catalog.pg_language as language_record on language_record.oid = function_record.prolang
  where function_record.oid = p_function;
$function$;

insert into pg_temp.test_results values
  (1, 'authenticated bez INSERT',
    not pg_catalog.has_table_privilege('authenticated', 'public.lane_blocks', 'INSERT'),
    'Bezpośredni INSERT jest odebrany.'),
  (2, 'authenticated bez UPDATE',
    not pg_catalog.has_table_privilege('authenticated', 'public.lane_blocks', 'UPDATE'),
    'Bezpośredni UPDATE jest odebrany.'),
  (3, 'authenticated bez DELETE',
    not pg_catalog.has_table_privilege('authenticated', 'public.lane_blocks', 'DELETE'),
    'Bezpośredni DELETE jest odebrany.'),
  (4, 'authenticated zachowuje SELECT',
    pg_catalog.has_table_privilege('authenticated', 'public.lane_blocks', 'SELECT')
      and (select coalesce(
        pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type),
        array[]::text[]
      )
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass
        and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'authenticated'))
        = array['MAINTAIN', 'SELECT']::text[],
    'SELECT i dotychczasowy MAINTAIN pozostają bez zmian.'),
  (5, 'anon bez mutacji',
    not pg_catalog.has_table_privilege('anon', 'public.lane_blocks', 'INSERT')
      and not pg_catalog.has_table_privilege('anon', 'public.lane_blocks', 'UPDATE')
      and not pg_catalog.has_table_privilege('anon', 'public.lane_blocks', 'DELETE'),
    'anon nie ma INSERT, UPDATE ani DELETE.'),
  (6, 'PUBLIC bez mutacji',
    not exists (
      select 1
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
      ) as acl
      where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass
        and acl.grantee = 0
        and acl.privilege_type in ('INSERT', 'UPDATE', 'DELETE')
    ),
    'PUBLIC nie ma mutacyjnych praw tabelowych.'),
  (7, 'Brak polityki INSERT',
    not exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'lane_blocks'
        and cmd in ('ALL', 'INSERT')
    ),
    'Nie istnieje polityka INSERT ani ALL.'),
  (8, 'Brak polityki UPDATE',
    not exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'lane_blocks'
        and cmd in ('ALL', 'UPDATE')
    ),
    'Nie istnieje polityka UPDATE ani ALL.'),
  (9, 'Brak polityki DELETE',
    not exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'lane_blocks'
        and cmd in ('ALL', 'DELETE')
    ),
    'Nie istnieje polityka DELETE ani ALL.'),
  (10, 'Polityki SELECT są identyczne',
    (select pg_catalog.count(*) = 2
     from pg_catalog.pg_policies
     where schemaname = 'public' and tablename = 'lane_blocks')
      and exists (
        select 1 from pg_catalog.pg_policies
        where schemaname = 'public' and tablename = 'lane_blocks'
          and policyname = 'Admins and staff can view all lane blocks'
          and permissive = 'PERMISSIVE'
          and roles = array['authenticated']::name[]
          and cmd = 'SELECT'
          and qual = 'is_admin_or_staff()'
          and with_check is null
      )
      and exists (
        select 1 from pg_catalog.pg_policies
        where schemaname = 'public' and tablename = 'lane_blocks'
          and policyname = 'Anyone can view active lane blocks'
          and permissive = 'PERMISSIVE'
          and roles = array['authenticated']::name[]
          and cmd = 'SELECT'
          and qual = '(is_active = true)'
          and with_check is null
      ),
    'Zachowano oba kontrakty SELECT.'),
  (11, 'RLS pozostaje włączone',
    exists (
      select 1 from pg_catalog.pg_class
      where oid = 'public.lane_blocks'::pg_catalog.regclass
        and relrowsecurity and not relforcerowsecurity
    ),
    'RLS enabled=true, FORCE RLS=false.'),
  (12, 'Trigger lane_blocks jest identyczny',
    (select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
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
    where trigger_record.tgrelid = 'public.lane_blocks'::pg_catalog.regclass
      and not trigger_record.tgisinternal) = 'cc9db87353e4bacb3694b9be72af2655',
    'Fingerprint triggera pozostał bez zmian.'),
  (13, 'Create RPC zachowuje authenticated EXECUTE',
    pg_catalog.has_function_privilege(
      'authenticated',
      'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)',
      'EXECUTE'
    ),
    'authenticated nadal może wywołać admin_create_lane_block.'),
  (14, 'Update RPC zachowuje authenticated EXECUTE',
    pg_catalog.has_function_privilege(
      'authenticated',
      'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)',
      'EXECUTE'
    ),
    'authenticated nadal może wywołać admin_update_lane_block.'),
  (15, 'Toggle RPC zachowuje authenticated EXECUTE',
    pg_catalog.has_function_privilege(
      'authenticated',
      'public.admin_set_lane_block_active(uuid,boolean)',
      'EXECUTE'
    ),
    'authenticated nadal może wywołać admin_set_lane_block_active.'),
  (16, 'RPC pozostają SECURITY DEFINER i identyczne',
    (select bool_and(prosecdef)
     from pg_catalog.pg_proc
     where oid in (
       'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure,
       'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure,
       'public.admin_set_lane_block_active(uuid,boolean)'::pg_catalog.regprocedure
     ))
      and pg_temp.function_fingerprint(
        'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
      ) = 'd0d2ea55f2fe1b899df863c6b246e810'
      and pg_temp.function_fingerprint(
        'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
      ) = 'ea94641203847b68b9418cd3eda21cbe'
      and pg_temp.function_fingerprint(
        'public.admin_set_lane_block_active(uuid,boolean)'
      ) = 'c8010d39bbbb47a434ede423143ad1de',
    'Pełne fingerprinty trzech RPC są identyczne.'),
  (17, 'RPC pozostają własnością postgres',
    (select bool_and(owner_role.rolname = 'postgres')
     from pg_catalog.pg_proc as function_record
     join pg_catalog.pg_roles as owner_role on owner_role.oid = function_record.proowner
     where function_record.oid in (
       'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure,
       'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure,
       'public.admin_set_lane_block_active(uuid,boolean)'::pg_catalog.regprocedure
     )),
    'Owner wszystkich trzech RPC to postgres.'),
  (18, 'RPC zachowują bezpieczny search_path',
    (select bool_and(proconfig = array['search_path=pg_catalog, public, pg_temp'])
     from pg_catalog.pg_proc
     where oid in (
       'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure,
       'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure,
       'public.admin_set_lane_block_active(uuid,boolean)'::pg_catalog.regprocedure
     )),
    'search_path pozostaje pg_catalog, public, pg_temp.'),
  (19, 'Multi-family helper jest identyczny',
    pg_temp.function_fingerprint(
      'public.lock_lane_conflict_families_v1(uuid[])'
    ) = '0815401da8ad1f909c26622355c0db5f',
    'Pełny fingerprint helpera jest identyczny.'),
  (20, 'create_reservation_v2 jest identyczne',
    pg_temp.function_fingerprint(
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
    ) = '43166f4511fb63f3f00e6159a25aaefe',
    'Pełny fingerprint V2 jest identyczny.');

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
    raise exception 'lane_blocks hardening tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

do $rollback_assertion$
declare
  v_actual_hash text;
  v_function oid;
  v_signature text;
  v_expected_fingerprint text;
begin
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
  into v_actual_hash
  from pg_catalog.pg_policies as policy_record
  where policy_record.schemaname = 'public'
    and policy_record.tablename = 'lane_blocks';

  if v_actual_hash <> 'c7c749fcae1e713b6a2c2e22246fe866' then
    raise exception 'Rollback failed: public.lane_blocks policies were not restored.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'grantee', case when acl.grantee = 0 then 'PUBLIC' else grantee_role.rolname end,
      'privilege', acl.privilege_type,
      'grantable', acl.is_grantable
    ) order by case when acl.grantee = 0 then 'PUBLIC' else grantee_role.rolname end,
               acl.privilege_type
  ), '[]'::jsonb)::text)
  into v_actual_hash
  from pg_catalog.pg_class as table_record
  cross join lateral pg_catalog.aclexplode(
    coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
  ) as acl
  left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
  where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass;

  if v_actual_hash <> '5d28bc6238d5f57607e6d8c83910a04d' then
    raise exception 'Rollback failed: public.lane_blocks ACL was not restored.';
  end if;

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
  into v_actual_hash
  from pg_catalog.pg_trigger as trigger_record
  where trigger_record.tgrelid = 'public.lane_blocks'::pg_catalog.regclass
    and not trigger_record.tgisinternal;

  if v_actual_hash <> 'cc9db87353e4bacb3694b9be72af2655' then
    raise exception 'Rollback failed: public.lane_blocks trigger changed.';
  end if;

  for v_signature, v_expected_fingerprint in
    select baseline.signature, baseline.fingerprint
    from (values
      ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::text,
       'd0d2ea55f2fe1b899df863c6b246e810'::text),
      ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::text,
       'ea94641203847b68b9418cd3eda21cbe'::text),
      ('public.admin_set_lane_block_active(uuid,boolean)'::text,
       'c8010d39bbbb47a434ede423143ad1de'::text),
      ('public.lock_lane_conflict_families_v1(uuid[])'::text,
       '0815401da8ad1f909c26622355c0db5f'::text),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::text,
       '43166f4511fb63f3f00e6159a25aaefe'::text)
    ) as baseline(signature, fingerprint)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

    select pg_catalog.md5(pg_catalog.jsonb_build_object(
      'definition', pg_catalog.pg_get_functiondef(function_record.oid),
      'owner', owner_role.rolname,
      'language', language_record.lanname,
      'volatility', function_record.provolatile,
      'security_definer', function_record.prosecdef,
      'config', coalesce(pg_catalog.to_jsonb(function_record.proconfig), '[]'::jsonb),
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
    into v_actual_hash
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_roles as owner_role on owner_role.oid = function_record.proowner
    join pg_catalog.pg_language as language_record on language_record.oid = function_record.prolang
    where function_record.oid = v_function;

    if v_function is null or v_actual_hash is distinct from v_expected_fingerprint then
      raise exception 'Rollback failed: function % changed.', v_signature;
    end if;
  end loop;
end;
$rollback_assertion$;

select
  21 as test_order,
  'Migration rollback restores baseline' as test_name,
  true as passed,
  'ACL, policies, trigger, RPC, helper and V2 match the pre-migration baseline.' as result,
  true as rollback_confirmed;
