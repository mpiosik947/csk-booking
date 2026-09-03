\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..17';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$function$;

create temporary table expected_function_acl(
  signature text primary key,
  category text not null check (category in ('A','B','C','D','E')),
  anon_execute boolean not null,
  authenticated_execute boolean not null,
  service_role_execute boolean not null
) on commit drop;

insert into expected_function_acl values
  ('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','C',false,true,false),
  ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','D',false,false,true),
  ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)','C',false,true,false),
  ('public.admin_create_lane_booking_family_v1(jsonb)','C',false,true,false),
  ('public.admin_get_lane_booking_configuration_v1()','C',false,true,false),
  ('public.admin_get_lane_booking_configuration_v2()','C',false,true,false),
  ('public.admin_list_users_v1(integer,integer,text,text,text,text)','C',false,true,false),
  ('public.admin_set_event_active_v2(uuid,boolean)','C',false,true,false),
  ('public.admin_set_event_active(uuid,boolean)','D',false,false,true),
  ('public.admin_set_lane_block_active(uuid,boolean)','C',false,true,false),
  ('public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)','A',false,false,false),
  ('public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','C',false,true,false),
  ('public.admin_set_user_note_v1(uuid,text)','C',false,true,false),
  ('public.admin_set_user_role_v1(uuid,text)','C',false,true,false),
  ('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','C',false,true,false),
  ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','D',false,false,true),
  ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)','C',false,true,false),
  ('public.approve_event_registration(uuid)','C',false,true,false),
  ('public.cancel_event_registration(uuid)','B',false,true,true),
  ('public.cancel_reservation(uuid)','B',false,true,true),
  ('public.check_confirmation_email_rate_limit(uuid,text)','D',false,false,true),
  ('public.complete_confirmation_email(uuid,boolean,text,text)','D',false,false,true),
  ('public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','D',false,false,true),
  ('public.confirm_event_reserve_promotion(text)','B',false,true,false),
  ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)','B',false,true,true),
  ('public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','D',false,false,true),
  ('public.get_lane_booking_busy_ranges_v2(uuid,date)','B',false,true,true),
  ('public.get_lane_booking_busy_ranges_v3(uuid,date)','B',false,true,true),
  ('public.get_lane_booking_busy_ranges(uuid,date)','B',false,true,true),
  ('public.get_my_reservations_v2()','B',false,true,false),
  ('public.get_my_role()','B',false,true,false),
  ('public.get_check_in_reservation_v1(uuid)','C',false,true,false),
  ('public.get_public_booking_configuration_v1()','B',true,true,true),
  ('public.get_public_check_in_status_v1(uuid)','B',true,false,false),
  ('public.get_reservation_customer_profiles_v1(uuid[])','C',false,true,false),
  ('public.handle_new_user()','E',false,false,false),
  ('public.is_admin_or_employee()','C',false,true,false),
  ('public.is_admin_or_staff()','C',false,true,false),
  ('public.is_admin()','C',false,true,false),
  ('public.is_reservation_check_in_token_usable_v1(date,time without time zone,time without time zone,text,timestamp with time zone)','A',false,false,false),
  ('public.lane_booking_family_business_snapshot_v2(uuid)','A',false,false,false),
  ('public.lock_lane_booking_configuration()','E',false,false,false),
  ('public.lock_lane_conflict_families_v1(uuid[])','A',false,false,false),
  ('public.lock_lane_conflict_family_v1(uuid)','A',false,false,false),
  ('public.normalize_lane_booking_family_payload_v2(jsonb)','A',false,false,false),
  ('public.prepare_confirmation_email(text,uuid)','B',false,true,false),
  ('public.prepare_event_reserve_promotions(uuid)','D',false,false,true),
  ('public.prevent_non_admin_profile_privilege_changes()','E',false,false,false),
  ('public.register_for_event(uuid,boolean)','B',false,true,false),
  ('public.resolve_lane_conflict_scope_v1(uuid)','A',false,false,false),
  ('public.set_booking_configuration_updated_at()','E',false,false,false),
  ('public.set_updated_at()','E',false,false,false),
  ('public.update_profile_contact_details(uuid,text,text,text,text,text,text)','C',false,true,true),
  ('public.update_profile_identity(uuid,text,text)','C',false,true,true),
  ('public.update_profile_verification(uuid,text,text)','C',false,true,true),
  ('public.update_reservation_admin_note(uuid,text)','C',false,true,false),
  ('public.update_reservation_attendance(uuid,text)','C',false,true,true),
  ('public.update_reservation_payment(uuid,text)','C',false,true,false),
  ('public.validate_lane_booking_rule_capacity()','E',false,false,false),
  ('public.validate_shooting_lane_capacity_change()','E',false,false,false),
  ('public.validate_shooting_lane_hierarchy()','E',false,false,false);

create function pg_temp.call_admin_configuration(p_user_id uuid)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role','authenticated')::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user_id::text,true);
  execute 'set local role authenticated';
  select public.admin_get_lane_booking_configuration_v2() into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.call_lane_block_toggle(p_user_id uuid)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role','authenticated')::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user_id::text,true);
  execute 'set local role authenticated';
  select public.admin_set_lane_block_active(null,true) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function public.csk_sec002_default_acl_probe()
returns text
language sql
as $function$
  select 'owner-only'::text;
$function$;

do $tests$
declare
  v_admin uuid := '6c020000-0000-4000-8000-000000000001';
  v_employee uuid := '6c020000-0000-4000-8000-000000000002';
  v_user uuid := '6c020000-0000-4000-8000-000000000003';
  v_denied boolean;
  v_all_denied boolean := true;
  v_result jsonb;
  v_role text;
  v_actual_count integer;
begin
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-sec002-admin@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-sec002-employee@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-sec002-user@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
  values
    (v_admin,'admin','[TEST]','SEC-002 Admin','[TEST][SEC-002] Admin','test-sec002-admin@example.invalid'),
    (v_employee,'pracownik','[TEST]','SEC-002 Employee','[TEST][SEC-002] Employee','test-sec002-employee@example.invalid'),
    (v_user,'user','[TEST]','SEC-002 User','[TEST][SEC-002] User','test-sec002-user@example.invalid');

  select pg_catalog.count(*) into v_actual_count
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname='public' and procedure.prokind='f'
    and procedure.proname<>'csk_sec002_default_acl_probe';

  perform pg_temp.record_result(1,'Complete public function inventory',
    (select pg_catalog.count(*)=61 from pg_temp.expected_function_acl)
    and v_actual_count=61
    and not exists(
      select 1 from pg_temp.expected_function_acl expected
      where pg_catalog.to_regprocedure(expected.signature) is null
    )
    and not exists(
      select 1
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prokind='f'
        and procedure.proname<>'csk_sec002_default_acl_probe'
        and not exists(
          select 1 from pg_temp.expected_function_acl expected
          where pg_catalog.to_regprocedure(expected.signature)=procedure.oid
        )
    ),
    'The exact 61-function inventory has no missing or unexpected signature.');

  perform pg_temp.record_result(2,'PUBLIC executes no public function',
    not exists(
      select 1
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      cross join lateral pg_catalog.aclexplode(coalesce(
        procedure.proacl,pg_catalog.acldefault('f',procedure.proowner)
      )) acl
      where namespace.nspname='public' and procedure.prokind='f'
        and acl.grantee=0 and acl.privilege_type='EXECUTE'
    ),
    'PUBLIC EXECUTE is absent from every current and probe function.');

  perform pg_temp.record_result(3,'Exact anon ACL matrix',
    not exists(
      select 1 from pg_temp.expected_function_acl expected
      where pg_catalog.has_function_privilege('anon',expected.signature,'EXECUTE')
        is distinct from expected.anon_execute
    )
    and (select pg_catalog.count(*)=2 from pg_temp.expected_function_acl where anon_execute),
    'anon can execute only the two intended non-PII public readers.');

  perform pg_temp.record_result(4,'Exact authenticated ACL matrix',
    not exists(
      select 1 from pg_temp.expected_function_acl expected
      where pg_catalog.has_function_privilege('authenticated',expected.signature,'EXECUTE')
        is distinct from expected.authenticated_execute
    )
    and (select pg_catalog.count(*)=37 from pg_temp.expected_function_acl where authenticated_execute),
    'authenticated has exactly the 37 user, policy-helper and internally authorized RPC grants.');

  perform pg_temp.record_result(5,'Exact service_role ACL matrix',
    not exists(
      select 1 from pg_temp.expected_function_acl expected
      where pg_catalog.has_function_privilege('service_role',expected.signature,'EXECUTE')
        is distinct from expected.service_role_execute
    )
    and (select pg_catalog.count(*)=19 from pg_temp.expected_function_acl where service_role_execute),
    'service_role retains only the 19 explicitly intended server, rollback and safe-reader grants.');

  perform pg_temp.record_result(6,'Trigger functions and dormant helper are isolated',
    (select pg_catalog.count(*)=8 from pg_temp.expected_function_acl where category='E')
    and not exists(
      select 1 from pg_temp.expected_function_acl expected
      where expected.category='E' and (
        expected.anon_execute or expected.authenticated_execute or expected.service_role_execute
      )
    )
    and (select pg_catalog.count(distinct trigger_record.tgfoid)=7
      from pg_catalog.pg_trigger trigger_record
      where not trigger_record.tgisinternal
        and exists(
          select 1 from pg_temp.expected_function_acl expected
          where expected.category='E'
            and pg_catalog.to_regprocedure(expected.signature)=trigger_record.tgfoid
        ))
    and not exists(
      select 1 from pg_catalog.pg_trigger trigger_record
      where not trigger_record.tgisinternal
        and trigger_record.tgfoid='public.handle_new_user()'::pg_catalog.regprocedure
    )
    and not exists(
      select 1 from pg_temp.expected_function_acl expected
      where expected.category='E' and expected.signature<>'public.handle_new_user()'
        and not exists(
          select 1 from pg_catalog.pg_trigger trigger_record
          where trigger_record.tgfoid=pg_catalog.to_regprocedure(expected.signature)
            and not trigger_record.tgisinternal
        )
    ),
    'Seven functions remain trigger-bound; dormant handle_new_user and all trigger functions have no client EXECUTE.');

  perform pg_temp.record_result(7,'postgres function defaults are fail closed',
    not exists(
      select 1
      from pg_catalog.pg_default_acl default_acl
      join pg_catalog.pg_roles owner_role on owner_role.oid=default_acl.defaclrole
      left join pg_catalog.pg_namespace namespace on namespace.oid=default_acl.defaclnamespace
      cross join lateral pg_catalog.aclexplode(default_acl.defaclacl) acl
      left join pg_catalog.pg_roles grantee_role on grantee_role.oid=acl.grantee
      where owner_role.rolname='postgres' and default_acl.defaclobjtype='f'
        and acl.privilege_type='EXECUTE'
        and (
          acl.grantee=0
          or (namespace.nspname='public'
            and grantee_role.rolname in ('anon','authenticated','service_role'))
        )
    ),
    'Future functions created by postgres receive no client or PUBLIC EXECUTE.');

  perform pg_temp.record_result(8,'Application function creator scope is exact',
    (select pg_catalog.count(*)=61
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
      where namespace.nspname='public' and procedure.prokind='f'
        and procedure.proname<>'csk_sec002_default_acl_probe'
        and owner_role.rolname='postgres'),
    'All 61 application functions are owned by postgres, whose public-schema defaults are hardened.');

  perform pg_temp.record_result(9,'New function inherits owner-only execution',
    not pg_catalog.has_function_privilege('anon','public.csk_sec002_default_acl_probe()','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.csk_sec002_default_acl_probe()','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.csk_sec002_default_acl_probe()','EXECUTE')
    and not exists(
      select 1 from pg_catalog.pg_proc procedure
      cross join lateral pg_catalog.aclexplode(coalesce(
        procedure.proacl,pg_catalog.acldefault('f',procedure.proowner)
      )) acl
      where procedure.oid='public.csk_sec002_default_acl_probe()'::pg_catalog.regprocedure
        and acl.grantee=0 and acl.privilege_type='EXECUTE'
    ),
    'A function created after the migration is not automatically exposed.');

  foreach v_role in array array['anon','authenticated','service_role']::text[] loop
    v_denied:=false;
    begin
      execute pg_catalog.format('set local role %I',v_role);
      perform public.csk_sec002_default_acl_probe();
      execute 'reset role';
    exception when insufficient_privilege then
      execute 'reset role';
      v_denied:=true;
    end;
    v_all_denied:=v_all_denied and v_denied;
  end loop;
  perform pg_temp.record_result(10,'Default ACL denial is enforced at runtime',
    v_all_denied,
    'anon, authenticated and service_role all receive insufficient_privilege on the probe.');

  perform pg_temp.record_result(11,'SECURITY DEFINER ownership and search_path',
    not exists(
      select 1 from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
      where namespace.nspname='public' and procedure.prokind='f' and procedure.prosecdef
        and (owner_role.rolname<>'postgres' or not exists(
          select 1 from pg_catalog.unnest(procedure.proconfig) setting
          where setting like 'search_path=%'
        ))
    ),
    'All SECURITY DEFINER functions remain postgres-owned with an explicit search_path.');

  perform pg_temp.record_result(12,'RLS helper ACL is authenticated-only',
    not exists(
      select 1 from (values
        ('public.get_my_role()'),('public.is_admin()'),
        ('public.is_admin_or_employee()'),('public.is_admin_or_staff()')
      ) helper(signature)
      where not pg_catalog.has_function_privilege('authenticated',helper.signature,'EXECUTE')
        or pg_catalog.has_function_privilege('anon',helper.signature,'EXECUTE')
        or pg_catalog.has_function_privilege('service_role',helper.signature,'EXECUTE')
    ),
    'Policy helpers remain available to authenticated policies without anonymous/service RPC exposure.');

  v_denied:=false;
  begin
    execute 'set local role anon';
    perform 1 from public.get_public_booking_configuration_v1() limit 1;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    v_denied:=true;
  end;
  perform pg_temp.record_result(13,'Anonymous public reader remains callable',
    not v_denied,
    'anon can execute the intended non-PII booking configuration reader.');

  v_denied:=false;
  begin
    execute 'set local role anon';
    perform public.admin_get_lane_booking_configuration_v2();
    execute 'reset role';
  exception when insufficient_privilege then
    execute 'reset role';
    v_denied:=true;
  end;
  perform pg_temp.record_result(14,'Anonymous privileged RPC is denied at runtime',
    v_denied,
    'anon receives insufficient_privilege before the admin configuration reader executes.');

  v_denied:=false;
  begin
    perform pg_temp.call_admin_configuration(v_user);
  exception when insufficient_privilege then
    v_denied:=true;
  end;
  perform pg_temp.record_result(15,'Ordinary authenticated user is denied internally',
    v_denied,
    'ACL permits the authenticated RPC surface, while the admin-only role check returns 42501.');

  v_result:=pg_temp.call_admin_configuration(v_admin);
  perform pg_temp.record_result(16,'Authorized admin and employee behavior is preserved',
    v_result->>'contract_version'='2'
    and pg_temp.call_lane_block_toggle(v_admin)->>'code'='invalid_input'
    and pg_temp.call_lane_block_toggle(v_employee)->>'code'='invalid_input'
    and pg_temp.call_lane_block_toggle(v_user)->>'code'='not_allowed',
    'Admin-only reader allows admin; staff writer allows admin/employee and denies user.');

  v_denied:=false;
  begin
    execute 'set local role service_role';
    perform public.prepare_event_reserve_promotions(
      '6c020000-0000-4000-8000-000000000099'::uuid
    );
    execute 'reset role';
  exception
    when no_data_found then
      execute 'reset role';
    when insufficient_privilege then
      execute 'reset role';
      v_denied:=true;
  end;
  perform pg_temp.record_result(17,'Authorized service RPC reaches business validation',
    not v_denied,
    'service_role passes ACL and reaches the expected missing-event validation.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end
  ||test_order||' - '||test_name||' # '||result
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text||': '||test_name,', ' order by test_order
  ) into v_failures
  from pg_temp.test_results where passed is false;

  if v_failures is not null then
    raise exception 'SEC-002 ACL tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
