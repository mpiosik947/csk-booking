-- Route all lane-block mutations through the authenticated SECURITY DEFINER RPCs.

do $preflight$
declare
  v_table_oid oid := pg_catalog.to_regclass('public.lane_blocks');
  v_actual_hash text;
  v_function oid;
  v_signature text;
  v_expected_fingerprint text;
begin
  if v_table_oid is null
     or not exists (
       select 1
       from pg_catalog.pg_class as table_record
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = table_record.relowner
       where table_record.oid = v_table_oid
         and table_record.relkind = 'r'
         and owner_role.rolname = 'postgres'
         and table_record.relrowsecurity
         and not table_record.relforcerowsecurity
     ) then
    raise exception 'Preflight failed: public.lane_blocks table contract differs.';
  end if;

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
    raise exception 'Preflight failed: public.lane_blocks policies differ.';
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
  where table_record.oid = v_table_oid;

  if v_actual_hash <> '5d28bc6238d5f57607e6d8c83910a04d' then
    raise exception 'Preflight failed: public.lane_blocks ACL differs.';
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
  where trigger_record.tgrelid = v_table_oid
    and not trigger_record.tgisinternal;

  if v_actual_hash <> 'cc9db87353e4bacb3694b9be72af2655' then
    raise exception 'Preflight failed: public.lane_blocks trigger differs.';
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

    if v_function is null then
      raise exception 'Preflight failed: required function % is missing.', v_signature;
    end if;

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

    if v_actual_hash is distinct from v_expected_fingerprint then
      raise exception 'Preflight failed: function % differs.', v_signature;
    end if;
  end loop;
end;
$preflight$;

revoke insert, update, delete
on table public.lane_blocks
from public, anon, authenticated;

drop policy "Admins and staff can insert lane blocks"
on public.lane_blocks;

drop policy "Admins and staff can update lane blocks"
on public.lane_blocks;

drop policy "Admins and staff can delete lane blocks"
on public.lane_blocks;

do $postflight$
declare
  v_table_oid oid := pg_catalog.to_regclass('public.lane_blocks');
  v_expected_full_acl constant text[] := array[
    'DELETE', 'INSERT', 'MAINTAIN', 'REFERENCES',
    'SELECT', 'TRIGGER', 'TRUNCATE', 'UPDATE'
  ];
  v_actual_hash text;
  v_function oid;
  v_signature text;
  v_expected_fingerprint text;
begin
  if v_table_oid is null
     or not exists (
       select 1
       from pg_catalog.pg_class as table_record
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = table_record.relowner
       where table_record.oid = v_table_oid
         and owner_role.rolname = 'postgres'
         and table_record.relrowsecurity
         and not table_record.relforcerowsecurity
     ) then
    raise exception 'Postflight failed: public.lane_blocks table contract differs.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'lane_blocks') <> 2
     or exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'lane_blocks'
         and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')
     )
     or not exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'lane_blocks'
         and policyname = 'Admins and staff can view all lane blocks'
         and permissive = 'PERMISSIVE'
         and roles = array['authenticated']::name[]
         and cmd = 'SELECT'
         and qual = 'is_admin_or_staff()'
         and with_check is null
     )
     or not exists (
       select 1
       from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'lane_blocks'
         and policyname = 'Anyone can view active lane blocks'
         and permissive = 'PERMISSIVE'
         and roles = array['authenticated']::name[]
         and cmd = 'SELECT'
         and qual = '(is_active = true)'
         and with_check is null
     ) then
    raise exception 'Postflight failed: public.lane_blocks policies differ.';
  end if;

  if exists (
       select 1
       from pg_catalog.pg_class as table_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
       ) as acl
       where table_record.oid = v_table_oid and acl.grantee = 0
     )
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(
           coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
         ) as acl
         where table_record.oid = v_table_oid
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon'))
        is distinct from array['MAINTAIN', 'SELECT']::text[]
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(
           coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
         ) as acl
         where table_record.oid = v_table_oid
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'authenticated'))
        is distinct from array['MAINTAIN', 'SELECT']::text[]
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(
           coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
         ) as acl
         where table_record.oid = v_table_oid
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'service_role'))
        is distinct from v_expected_full_acl
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(
           coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
         ) as acl
         where table_record.oid = v_table_oid
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'postgres'))
        is distinct from v_expected_full_acl then
    raise exception 'Postflight failed: public.lane_blocks ACL differs.';
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
  where trigger_record.tgrelid = v_table_oid
    and not trigger_record.tgisinternal;

  if v_actual_hash <> 'cc9db87353e4bacb3694b9be72af2655' then
    raise exception 'Postflight failed: public.lane_blocks trigger changed.';
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
      raise exception 'Postflight failed: function % changed.', v_signature;
    end if;
  end loop;
end;
$postflight$;
