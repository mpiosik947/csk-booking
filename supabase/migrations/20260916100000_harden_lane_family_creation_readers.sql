-- SAAS-9D-3B: tenant hardening for lane-family creation and admin readers.
-- Family updates and every later SAAS-9D phase are intentionally out of scope.

begin;

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null then
    raise exception 'SAAS-9D-3B preflight failed: tenant authorization helpers are absent.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public'
        and procedure.proname in (
          'admin_create_lane_booking_family_v1',
          'admin_get_lane_booking_configuration_v1',
          'admin_get_lane_booking_configuration_v2'
        ))<>3 then
    raise exception 'SAAS-9D-3B preflight failed: target function inventory differs.';
  end if;

  if exists (
    select 1
    from public.shooting_lanes child
    join public.shooting_lanes parent on parent.id=child.parent_lane_id
    where child.tenant_id is distinct from parent.tenant_id
  ) or exists (
    select 1
    from public.lane_booking_family_configuration_versions version
    left join public.shooting_lanes root
      on root.id=version.root_lane_id
     and root.resource_kind='lane'
     and root.parent_lane_id is null
    where root.id is null
  ) then
    raise exception 'SAAS-9D-3B preflight failed: lane family hierarchy is inconsistent.';
  end if;
end;
$preflight$;

create temporary table saas9d3b_expected_targets (
  signature text primary key,
  fingerprint text not null,
  volatility "char" not null
) on commit drop;

insert into saas9d3b_expected_targets(signature,fingerprint,volatility) values
  ('public.admin_create_lane_booking_family_v1(jsonb)','69ec76ae348f83387045a5c343dd906f','v'),
  ('public.admin_get_lane_booking_configuration_v1()','2684f7ea8a3b9eba6dae4d4f7aad653c','s'),
  ('public.admin_get_lane_booking_configuration_v2()','5c729f01536d476a5c8b3cf0d9b40c62','s');

do $target_guard$
declare v_count integer;
begin
  select pg_catalog.count(*) into v_count
  from saas9d3b_expected_targets expected
  join pg_catalog.pg_proc procedure
    on procedure.oid=pg_catalog.to_regprocedure(expected.signature)
  where pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
          pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
        ),E'\r',E'\n'))=expected.fingerprint
    and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
    and procedure.prosecdef
    and procedure.provolatile=expected.volatility
    and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
    and not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE');

  if v_count<>3 then
    raise exception 'SAAS-9D-3B preflight failed: normalized target fingerprint, metadata or ACL drift (%/3).',v_count;
  end if;
end;
$target_guard$;

create temporary table saas9d3b_unchanged_definer_snapshot on commit drop as
select
  procedure.proname,
  pg_catalog.pg_get_function_identity_arguments(procedure.oid) as identity_arguments,
  pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
    pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
  ),E'\r',E'\n')) as fingerprint,
  procedure.proowner,procedure.proconfig,procedure.proacl
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.prosecdef
  and procedure.proname not in (
    'admin_create_lane_booking_family_v1',
    'admin_get_lane_booking_configuration_v1',
    'admin_get_lane_booking_configuration_v2'
  );

create temporary table saas9d3b_invariants on commit drop as
select
  (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef) as definer_count,
  (select pg_catalog.count(*) from public.shooting_lanes) as lane_count,
  (select pg_catalog.count(*) from public.lane_booking_rules) as rule_count,
  (select pg_catalog.count(*) from public.lane_booking_durations) as duration_count,
  (select pg_catalog.count(*) from public.lane_pricing_rules) as pricing_count,
  (select pg_catalog.count(*) from public.lane_booking_family_configuration_versions) as version_count,
  (select pg_catalog.count(*) from public.audit_logs) as audit_count;

-- Patch only tenant authority/ownership inside the frozen creator. Its large,
-- already-tested validation and response contract remain byte-derived from the
-- guarded baseline.
do $patch_creator$
declare
  v_definition text;
  v_patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.admin_create_lane_booking_family_v1(jsonb)'::pg_catalog.regprocedure
  ) into v_definition;

  v_patched:=pg_catalog.regexp_replace(v_definition,
    '([[:space:]]v_actor_role text;)',E'\\1\n  v_tenant_id uuid;');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(begin[[:space:]]+)(select profile[.][*])',
    E'\\1perform tenant.id from public.tenants tenant order by tenant.id for share;\n  v_tenant_id:=public.active_single_tenant_id_v1();\n  if v_actor_id is null or v_tenant_id is null\n     or public.get_my_tenant_role_v1(v_tenant_id) is distinct from \'admin\' then\n    return pg_catalog.jsonb_build_object(\n      \'ok\',false,\'changed\',false,\'code\',\'not_allowed\',\n      \'root_lane_id\',null,\'configuration_version\',null,\n      \'created_resource_count\',0\n    );\n  end if;\n\n  \\2',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(from public[.]shooting_lanes as lane;)',
    E'from public.shooting_lanes as lane\n  where lane.tenant_id=v_tenant_id;',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(insert into public[.]shooting_lanes[(][[:space:]]*)id,',
    E'\\1tenant_id, id,','g');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '([)][[:space:]]*values [(][[:space:]]*)v_root_id,',
    E'\\1v_tenant_id, v_root_id,',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '([)][[:space:]]*values [(][[:space:]]*)v_position_id,',
    E'\\1v_tenant_id, v_position_id,',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(insert into public[.]audit_logs[(][[:space:]]*)actor_user_id,',
    E'\\1tenant_id, actor_user_id,',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(details[[:space:]]*[)][[:space:]]*values [(][[:space:]]*)v_actor_id,',
    E'\\1v_tenant_id, v_actor_id,',1,1);

  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'v_tenant_id:=public.active_single_tenant_id_v1()')=0
     or pg_catalog.strpos(v_patched,'get_my_tenant_role_v1(v_tenant_id)')=0
     or pg_catalog.strpos(v_patched,'where lane.tenant_id=v_tenant_id')=0
     or (pg_catalog.length(v_patched)-pg_catalog.length(pg_catalog.replace(v_patched,'tenant_id, id,','')))/pg_catalog.length('tenant_id, id,')<>2
     or pg_catalog.strpos(v_patched,'v_tenant_id, v_root_id,')=0
     or pg_catalog.strpos(v_patched,'v_tenant_id, v_position_id,')=0
     or pg_catalog.strpos(v_patched,'tenant_id, actor_user_id,')=0
     or pg_catalog.strpos(v_patched,'v_tenant_id, v_actor_id,')=0 then
    raise exception 'SAAS-9D-3B patch failed: creator anchors differ.';
  end if;

  execute v_patched;
end;
$patch_creator$;

create or replace function public.admin_get_lane_booking_configuration_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_resources jsonb;
begin
  if v_actor_id is null or v_tenant_id is null
     or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles profile
  where profile.user_id=v_actor_id;

  if coalesce(v_actor_role,'')<>'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;

  if exists (
       select 1
       from public.shooting_lanes resource
       left join public.shooting_lanes parent
         on parent.id=resource.parent_lane_id
        and parent.tenant_id=resource.tenant_id
       where resource.tenant_id=v_tenant_id
         and (
           resource.resource_kind not in ('lane','position')
           or resource.parent_lane_id=resource.id
           or (resource.resource_kind='lane' and resource.parent_lane_id is not null)
           or (
             resource.resource_kind='position'
             and (
               resource.parent_lane_id is null
               or resource.whole_lane_bookable
               or resource.positions_bookable
               or parent.id is null
               or parent.resource_kind<>'lane'
               or parent.parent_lane_id is not null
             )
           )
         )
     )
     or exists (
       select 1
       from public.shooting_lanes resource
       left join public.lane_booking_rules booking_rule
         on booking_rule.lane_id=resource.id
       where resource.tenant_id=v_tenant_id
         and booking_rule.lane_id is null
     )
     or exists (
       select 1
       from public.lane_booking_durations duration
       join public.shooting_lanes lane
         on lane.id=duration.lane_id and lane.tenant_id=v_tenant_id
       group by duration.lane_id,duration.duration_minutes
       having pg_catalog.count(*)>1
     )
     or exists (
       select 1
       from public.lane_pricing_rules first_rule
       join public.shooting_lanes lane
         on lane.id=first_rule.lane_id and lane.tenant_id=v_tenant_id
       join public.lane_pricing_rules second_rule
         on second_rule.lane_id=first_rule.lane_id
        and second_rule.day_group=first_rule.day_group
        and second_rule.is_active
        and second_rule.id>first_rule.id
        and second_rule.min_shooters<=first_rule.max_shooters
        and second_rule.max_shooters>=first_rule.min_shooters
       where first_rule.is_active
     ) then
    raise exception 'Lane configuration snapshot is structurally ambiguous.'
      using errcode='55000';
  end if;

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'lane_id',resource.lane_id,
      'name',resource.name,
      'resource_kind',resource.resource_kind,
      'parent_lane_id',resource.parent_lane_id,
      'display_order',resource.display_order,
      'is_active',resource.is_active,
      'max_shooters',resource.max_shooters,
      'whole_lane_bookable',resource.whole_lane_bookable,
      'positions_bookable',resource.positions_bookable,
      'booking_step_minutes',resource.booking_step_minutes,
      'currency_code',resource.currency_code,
      'online_bookable',resource.online_bookable,
      'max_people_online',resource.max_people_online,
      'durations',resource.durations,
      'pricing',resource.pricing
    ) order by resource.root_display_order,resource.root_id,
      resource.resource_depth,resource.display_order,resource.lane_id
  ),'[]'::jsonb)
  into v_resources
  from (
    select
      lane.id as lane_id,lane.name,lane.resource_kind,lane.parent_lane_id,
      lane.display_order,lane.is_active,lane.max_shooters,
      lane.whole_lane_bookable,lane.positions_bookable,
      lane.booking_step_minutes,lane.currency_code::text as currency_code,
      booking_rule.online_bookable,booking_rule.max_people_online,
      case when lane.resource_kind='lane' then lane.id else lane.parent_lane_id end as root_id,
      case when lane.resource_kind='lane' then lane.display_order else parent.display_order end as root_display_order,
      case when lane.resource_kind='lane' then 0 else 1 end as resource_depth,
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'duration_minutes',duration.duration_minutes,
          'display_order',duration.display_order,
          'is_active',duration.is_active
        ) order by duration.display_order,duration.duration_minutes,duration.id)
        from public.lane_booking_durations duration
        where duration.lane_id=lane.id
      ),'[]'::jsonb) as durations,
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'day_group',pricing.day_group,
          'min_shooters',pricing.min_shooters,
          'max_shooters',pricing.max_shooters,
          'label',pricing.label,
          'hourly_price',pricing.hourly_price,
          'display_order',pricing.display_order,
          'is_active',pricing.is_active
        ) order by
          case pricing.day_group when 'mon_thu' then 0 when 'fri_sun' then 1 else 2 end,
          pricing.is_active desc,pricing.display_order,pricing.min_shooters,
          pricing.max_shooters,pricing.id)
        from public.lane_pricing_rules pricing
        where pricing.lane_id=lane.id
      ),'[]'::jsonb) as pricing
    from public.shooting_lanes lane
    join public.lane_booking_rules booking_rule on booking_rule.lane_id=lane.id
    left join public.shooting_lanes parent
      on parent.id=lane.parent_lane_id and parent.tenant_id=lane.tenant_id
    where lane.tenant_id=v_tenant_id
  ) resource;

  return pg_catalog.jsonb_build_object('contract_version',1,'resources',v_resources);
end;
$function$;

create or replace function public.admin_get_lane_booking_configuration_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_v1 jsonb;
  v_families jsonb;
begin
  if v_actor_id is null or v_tenant_id is null
     or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles profile
  where profile.user_id=v_actor_id;

  if coalesce(v_actor_role,'')<>'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;

  if (select pg_catalog.count(*)
      from public.shooting_lanes root
      where root.tenant_id=v_tenant_id
        and root.resource_kind='lane' and root.parent_lane_id is null)
     <>
     (select pg_catalog.count(*)
      from public.lane_booking_family_configuration_versions version
      join public.shooting_lanes root
        on root.id=version.root_lane_id and root.tenant_id=v_tenant_id
      where root.resource_kind='lane' and root.parent_lane_id is null) then
    raise exception 'Lane family version snapshot is incomplete.' using errcode='55000';
  end if;

  v_v1:=public.admin_get_lane_booking_configuration_v1();

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'root_lane_id',root.id,
      'configuration_version',version.configuration_version,
      'resources',coalesce((
        select pg_catalog.jsonb_agg(resource.value order by resource.ordinality)
        from pg_catalog.jsonb_array_elements(v_v1->'resources') with ordinality
          resource(value,ordinality)
        where resource.value->>'lane_id'=root.id::text
           or resource.value->>'parent_lane_id'=root.id::text
      ),'[]'::jsonb)
    ) order by root.display_order,root.id
  ),'[]'::jsonb)
  into v_families
  from public.shooting_lanes root
  join public.lane_booking_family_configuration_versions version
    on version.root_lane_id=root.id
  where root.tenant_id=v_tenant_id
    and root.resource_kind='lane' and root.parent_lane_id is null;

  return pg_catalog.jsonb_build_object('contract_version',2,'families',v_families);
end;
$function$;

alter function public.admin_create_lane_booking_family_v1(jsonb) owner to postgres;
alter function public.admin_get_lane_booking_configuration_v1() owner to postgres;
alter function public.admin_get_lane_booking_configuration_v2() owner to postgres;

revoke all on function public.admin_create_lane_booking_family_v1(jsonb) from public,anon,authenticated,service_role;
revoke all on function public.admin_get_lane_booking_configuration_v1() from public,anon,authenticated,service_role;
revoke all on function public.admin_get_lane_booking_configuration_v2() from public,anon,authenticated,service_role;
grant execute on function public.admin_create_lane_booking_family_v1(jsonb) to authenticated;
grant execute on function public.admin_get_lane_booking_configuration_v2() to authenticated;

comment on function public.admin_create_lane_booking_family_v1(jsonb)
  is 'Atomically creates one complete family in the exact active tenant for an active tenant admin.';
comment on function public.admin_get_lane_booking_configuration_v1()
  is 'Internal tenant-scoped V1 lane configuration snapshot used by the authorized V2 reader.';
comment on function public.admin_get_lane_booking_configuration_v2()
  is 'Returns the tenant-scoped admin V2 lane family configuration for an active tenant admin.';

do $postflight$
declare
  v_snapshot record;
  v_current record;
  v_invariants record;
begin
  for v_snapshot in select * from saas9d3b_unchanged_definer_snapshot loop
    select
      pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
        pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
      ),E'\r',E'\n')) as fingerprint,
      procedure.proowner,procedure.proconfig,procedure.proacl
    into v_current
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname=v_snapshot.proname
      and pg_catalog.pg_get_function_identity_arguments(procedure.oid)=v_snapshot.identity_arguments
      and procedure.prosecdef;

    if not found or v_current.fingerprint is distinct from v_snapshot.fingerprint
       or v_current.proowner is distinct from v_snapshot.proowner
       or v_current.proconfig is distinct from v_snapshot.proconfig
       or v_current.proacl is distinct from v_snapshot.proacl then
      raise exception 'SAAS-9D-3B postflight failed: unrelated SECURITY DEFINER drift in %(%).',v_snapshot.proname,v_snapshot.identity_arguments;
    end if;
  end loop;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)
     <> (select definer_count from saas9d3b_invariants)
     or (select definer_count from saas9d3b_invariants)<>70 then
    raise exception 'SAAS-9D-3B postflight failed: SECURITY DEFINER count differs from 70.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-3B postflight failed: compatibility defaults changed.';
  end if;

  if exists (
    select 1
    from (values
      ('public.admin_create_lane_booking_family_v1(jsonb)','v',true),
      ('public.admin_get_lane_booking_configuration_v1()','s',false),
      ('public.admin_get_lane_booking_configuration_v2()','s',true)
    ) target(signature,volatility,authenticated_execute)
    join pg_catalog.pg_proc procedure on procedure.oid=pg_catalog.to_regprocedure(target.signature)
    where not procedure.prosecdef
       or procedure.provolatile<>target.volatility::"char"
       or procedure.proowner<>(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
       or procedure.proconfig is distinct from array['search_path=pg_catalog, public, pg_temp']::text[]
       or pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
       or pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
       or pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')<>target.authenticated_execute
       or pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')
       or pg_catalog.strpos(pg_catalog.pg_get_functiondef(procedure.oid),'active_single_tenant_id_v1')=0
       or pg_catalog.strpos(pg_catalog.pg_get_functiondef(procedure.oid),'get_my_tenant_role_v1')=0
  ) then
    raise exception 'SAAS-9D-3B postflight failed: target metadata, ACL or membership authority differs.';
  end if;

  if pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_create_lane_booking_family_v1(jsonb)'::pg_catalog.regprocedure),'tenant_id, id,')=0
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_create_lane_booking_family_v1(jsonb)'::pg_catalog.regprocedure),'tenant_id, actor_user_id,')=0
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_get_lane_booking_configuration_v1()'::pg_catalog.regprocedure),'where lane.tenant_id=v_tenant_id')=0
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_get_lane_booking_configuration_v2()'::pg_catalog.regprocedure),'root.tenant_id=v_tenant_id')=0 then
    raise exception 'SAAS-9D-3B postflight failed: explicit tenant predicates are absent.';
  end if;

  select * into v_invariants from saas9d3b_invariants;
  if (select pg_catalog.count(*) from public.shooting_lanes)<>v_invariants.lane_count
     or (select pg_catalog.count(*) from public.lane_booking_rules)<>v_invariants.rule_count
     or (select pg_catalog.count(*) from public.lane_booking_durations)<>v_invariants.duration_count
     or (select pg_catalog.count(*) from public.lane_pricing_rules)<>v_invariants.pricing_count
     or (select pg_catalog.count(*) from public.lane_booking_family_configuration_versions)<>v_invariants.version_count
     or (select pg_catalog.count(*) from public.audit_logs)<>v_invariants.audit_count then
    raise exception 'SAAS-9D-3B postflight failed: migration changed business data.';
  end if;
end;
$postflight$;

commit;
