-- Route duration and pricing mutations through the atomic configuration RPC.

do $preflight$
declare
  v_table_name text;
  v_policy_hash text;
  v_acl_hash text;
  v_trigger_hash text;
  v_expected_policy_hash text;
  v_expected_trigger_hash text;
  v_actual_hash text;
  v_function oid;
  v_signature text;
  v_expected_fingerprint text;
begin
  for v_table_name, v_expected_policy_hash, v_expected_trigger_hash in
    select baseline.table_name, baseline.policy_hash, baseline.trigger_hash
    from (values
      ('lane_booking_durations'::text,
       'f3c9743651bdb5db464e23c9bee3a4d8'::text,
       '73d2096d01c9621ad6c015772d60064d'::text),
      ('lane_pricing_rules'::text,
       '9218b3875b735c54d82b8fdd9956a45b'::text,
       'ab300edf5674a781ea3c5071553073a3'::text)
    ) as baseline(table_name, policy_hash, trigger_hash)
  loop
    if not exists (
      select 1
      from pg_catalog.pg_class as table_record
      join pg_catalog.pg_namespace as schema_record
        on schema_record.oid = table_record.relnamespace
      join pg_catalog.pg_roles as owner_role
        on owner_role.oid = table_record.relowner
      where schema_record.nspname = 'public'
        and table_record.relname = v_table_name
        and table_record.relkind = 'r'
        and owner_role.rolname = 'postgres'
        and table_record.relrowsecurity
        and not table_record.relforcerowsecurity
    ) then
      raise exception 'Preflight failed: public.% table contract differs.',
        v_table_name;
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
    into v_policy_hash
    from pg_catalog.pg_policies as policy_record
    where policy_record.schemaname = 'public'
      and policy_record.tablename = v_table_name;

    if v_policy_hash is distinct from v_expected_policy_hash then
      raise exception 'Preflight failed: public.% policies differ.',
        v_table_name;
    end if;

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
    into v_acl_hash
    from pg_catalog.pg_class as table_record
    join pg_catalog.pg_namespace as schema_record
      on schema_record.oid = table_record.relnamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(table_record.relacl,
               pg_catalog.acldefault('r', table_record.relowner))
    ) as acl
    left join pg_catalog.pg_roles as grantee_role
      on grantee_role.oid = acl.grantee
    where schema_record.nspname = 'public'
      and table_record.relname = v_table_name;

    if v_acl_hash <> 'cbeef4d9030cc8afee27e817d1f5b0f4' then
      raise exception 'Preflight failed: public.% ACL differs.', v_table_name;
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
    into v_trigger_hash
    from pg_catalog.pg_trigger as trigger_record
    where trigger_record.tgrelid =
          ('public.' || v_table_name)::pg_catalog.regclass
      and not trigger_record.tgisinternal;

    if v_trigger_hash is distinct from v_expected_trigger_hash then
      raise exception 'Preflight failed: public.% triggers differ.',
        v_table_name;
    end if;
  end loop;

  for v_signature, v_expected_fingerprint in
    select baseline.signature, baseline.fingerprint
    from (values
      ('public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'::text,
       '23a0730e4070b5c3625b162527fbd680'::text),
      ('public.get_public_booking_configuration_v1()'::text,
       '4ce0eef041de344b8acd85bc5782648f'::text),
      ('public.lock_lane_conflict_families_v1(uuid[])'::text,
       '0815401da8ad1f909c26622355c0db5f'::text),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::text,
       '43166f4511fb63f3f00e6159a25aaefe'::text),
      ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::text,
       'd0d2ea55f2fe1b899df863c6b246e810'::text),
      ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::text,
       'ea94641203847b68b9418cd3eda21cbe'::text),
      ('public.admin_set_lane_block_active(uuid,boolean)'::text,
       'c8010d39bbbb47a434ede423143ad1de'::text),
      ('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       '5cb34b27251e94a26c87e59e032b3a85'::text),
      ('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       'f6f6d51e6a8979cbc9a02c7af6f7d967'::text),
      ('public.admin_set_event_active_v2(uuid,boolean)'::text,
       'a51425da82a9da7b5039051751f73752'::text)
    ) as baseline(signature, fingerprint)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

    if v_function is null then
      raise exception 'Preflight failed: required function % is missing.',
        v_signature;
    end if;

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
    into v_actual_hash
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = function_record.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function;

    if v_actual_hash is distinct from v_expected_fingerprint then
      raise exception 'Preflight failed: function % differs.', v_signature;
    end if;
  end loop;
end;
$preflight$;

revoke insert, update, delete
on table public.lane_booking_durations
from authenticated;

revoke insert, update, delete
on table public.lane_pricing_rules
from authenticated;

drop policy "Admins and employees manage lane durations"
on public.lane_booking_durations;

create policy "Admins and employees can view all lane durations"
on public.lane_booking_durations
for select
to authenticated
using (public.is_admin_or_employee());

drop policy "Admins and employees manage lane pricing rules"
on public.lane_pricing_rules;

create policy "Admins and employees can view all lane pricing rules"
on public.lane_pricing_rules
for select
to authenticated
using (public.is_admin_or_employee());

do $postflight$
declare
  v_table_name text;
  v_public_policy_name text;
  v_admin_policy_name text;
  v_public_qual text;
  v_expected_trigger_hash text;
  v_actual_hash text;
  v_expected_full_acl constant text[] := array[
    'DELETE', 'INSERT', 'MAINTAIN', 'REFERENCES',
    'SELECT', 'TRIGGER', 'TRUNCATE', 'UPDATE'
  ];
  v_function oid;
  v_signature text;
  v_expected_fingerprint text;
begin
  for v_table_name, v_public_policy_name, v_admin_policy_name,
      v_public_qual, v_expected_trigger_hash in
    select baseline.*
    from (values
      ('lane_booking_durations'::text,
       'Active lane durations are readable'::text,
       'Admins and employees can view all lane durations'::text,
       '(is_active AND (EXISTS ( SELECT 1
   FROM shooting_lanes lane
  WHERE ((lane.id = lane_booking_durations.lane_id) AND lane.is_active))))'::text,
       '73d2096d01c9621ad6c015772d60064d'::text),
      ('lane_pricing_rules'::text,
       'Active lane pricing rules are readable'::text,
       'Admins and employees can view all lane pricing rules'::text,
       '(is_active AND (EXISTS ( SELECT 1
   FROM shooting_lanes lane
  WHERE ((lane.id = lane_pricing_rules.lane_id) AND lane.is_active))))'::text,
       'ab300edf5674a781ea3c5071553073a3'::text)
    ) as baseline(
      table_name, public_policy_name, admin_policy_name,
      public_qual, trigger_hash
    )
  loop
    if not exists (
      select 1
      from pg_catalog.pg_class as table_record
      where table_record.oid =
            ('public.' || v_table_name)::pg_catalog.regclass
        and table_record.relrowsecurity
        and not table_record.relforcerowsecurity
    ) then
      raise exception 'Postflight failed: public.% RLS differs.', v_table_name;
    end if;

    if (select pg_catalog.count(*)
        from pg_catalog.pg_policies
        where schemaname = 'public' and tablename = v_table_name) <> 2
       or exists (
         select 1
         from pg_catalog.pg_policies
         where schemaname = 'public' and tablename = v_table_name
           and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')
       )
       or not exists (
         select 1
         from pg_catalog.pg_policies
         where schemaname = 'public'
           and tablename = v_table_name
           and policyname = v_public_policy_name
           and permissive = 'PERMISSIVE'
           and roles = array['anon', 'authenticated']::name[]
           and cmd = 'SELECT'
           and pg_catalog.regexp_replace(
                 qual, '[[:space:]]+', '', 'g'
               ) = pg_catalog.regexp_replace(
                 v_public_qual, '[[:space:]]+', '', 'g'
               )
           and with_check is null
       )
       or not exists (
         select 1
         from pg_catalog.pg_policies
         where schemaname = 'public'
           and tablename = v_table_name
           and policyname = v_admin_policy_name
           and permissive = 'PERMISSIVE'
           and roles = array['authenticated']::name[]
           and cmd = 'SELECT'
           and pg_catalog.regexp_replace(
                 qual, '[[:space:]]+', '', 'g'
               ) in (
                 'is_admin_or_employee()',
                 'public.is_admin_or_employee()'
               )
           and with_check is null
       ) then
      raise exception 'Postflight failed: public.% policies differ.',
        v_table_name;
    end if;

    if exists (
         select 1
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(coalesce(
           table_record.relacl,
           pg_catalog.acldefault('r', table_record.relowner)
         )) as acl
         where table_record.oid =
               ('public.' || v_table_name)::pg_catalog.regclass
           and acl.grantee = 0
       )
       or (select coalesce(pg_catalog.array_agg(
              acl.privilege_type order by acl.privilege_type
            ), array[]::text[])
           from pg_catalog.pg_class as table_record
           cross join lateral pg_catalog.aclexplode(coalesce(
             table_record.relacl,
             pg_catalog.acldefault('r', table_record.relowner)
           )) as acl
           where table_record.oid =
                 ('public.' || v_table_name)::pg_catalog.regclass
             and acl.grantee = (
               select oid from pg_catalog.pg_roles where rolname = 'anon'
             )) is distinct from array['SELECT']::text[]
       or (select coalesce(pg_catalog.array_agg(
              acl.privilege_type order by acl.privilege_type
            ), array[]::text[])
           from pg_catalog.pg_class as table_record
           cross join lateral pg_catalog.aclexplode(coalesce(
             table_record.relacl,
             pg_catalog.acldefault('r', table_record.relowner)
           )) as acl
           where table_record.oid =
                 ('public.' || v_table_name)::pg_catalog.regclass
             and acl.grantee = (
               select oid from pg_catalog.pg_roles
               where rolname = 'authenticated'
             )) is distinct from array['SELECT']::text[]
       or (select coalesce(pg_catalog.array_agg(
              acl.privilege_type order by acl.privilege_type
            ), array[]::text[])
           from pg_catalog.pg_class as table_record
           cross join lateral pg_catalog.aclexplode(coalesce(
             table_record.relacl,
             pg_catalog.acldefault('r', table_record.relowner)
           )) as acl
           where table_record.oid =
                 ('public.' || v_table_name)::pg_catalog.regclass
             and acl.grantee = (
               select oid from pg_catalog.pg_roles where rolname = 'service_role'
             )) is distinct from v_expected_full_acl
       or (select coalesce(pg_catalog.array_agg(
              acl.privilege_type order by acl.privilege_type
            ), array[]::text[])
           from pg_catalog.pg_class as table_record
           cross join lateral pg_catalog.aclexplode(coalesce(
             table_record.relacl,
             pg_catalog.acldefault('r', table_record.relowner)
           )) as acl
           where table_record.oid =
                 ('public.' || v_table_name)::pg_catalog.regclass
             and acl.grantee = (
               select oid from pg_catalog.pg_roles where rolname = 'postgres'
             )) is distinct from v_expected_full_acl then
      raise exception 'Postflight failed: public.% ACL differs.', v_table_name;
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
    where trigger_record.tgrelid =
          ('public.' || v_table_name)::pg_catalog.regclass
      and not trigger_record.tgisinternal;

    if v_actual_hash is distinct from v_expected_trigger_hash then
      raise exception 'Postflight failed: public.% triggers changed.',
        v_table_name;
    end if;
  end loop;

  for v_signature, v_expected_fingerprint in
    select baseline.signature, baseline.fingerprint
    from (values
      ('public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'::text,
       '23a0730e4070b5c3625b162527fbd680'::text),
      ('public.get_public_booking_configuration_v1()'::text,
       '4ce0eef041de344b8acd85bc5782648f'::text),
      ('public.lock_lane_conflict_families_v1(uuid[])'::text,
       '0815401da8ad1f909c26622355c0db5f'::text),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::text,
       '43166f4511fb63f3f00e6159a25aaefe'::text),
      ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::text,
       'd0d2ea55f2fe1b899df863c6b246e810'::text),
      ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::text,
       'ea94641203847b68b9418cd3eda21cbe'::text),
      ('public.admin_set_lane_block_active(uuid,boolean)'::text,
       'c8010d39bbbb47a434ede423143ad1de'::text),
      ('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       '5cb34b27251e94a26c87e59e032b3a85'::text),
      ('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::text,
       'f6f6d51e6a8979cbc9a02c7af6f7d967'::text),
      ('public.admin_set_event_active_v2(uuid,boolean)'::text,
       'a51425da82a9da7b5039051751f73752'::text)
    ) as baseline(signature, fingerprint)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

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
    into v_actual_hash
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = function_record.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function;

    if v_function is null
       or v_actual_hash is distinct from v_expected_fingerprint then
      raise exception 'Postflight failed: function % changed.', v_signature;
    end if;
  end loop;

  if not pg_catalog.has_function_privilege(
       'authenticated',
       'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)',
       'EXECUTE'
     ) then
    raise exception 'Postflight failed: authenticated lost configuration RPC EXECUTE.';
  end if;
end;
$postflight$;
