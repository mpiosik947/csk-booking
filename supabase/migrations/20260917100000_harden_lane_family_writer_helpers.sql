-- SAAS-9D-3C: tenant hardening for the lane-family writer and helper modes.
-- SAAS-9D-4+, application code and compatibility defaults are out of scope.

begin;

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null then
    raise exception 'SAAS-9D-3C preflight failed: tenant authorization helper is absent.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname like '%__saas9d3c_core'
  ) then
    raise exception 'SAAS-9D-3C preflight failed: planned core object already exists.';
  end if;

  if exists (
       select 1 from public.shooting_lanes child
       join public.shooting_lanes parent on parent.id=child.parent_lane_id
       where child.tenant_id is distinct from parent.tenant_id
     )
     or exists (
       select 1 from public.lane_booking_family_configuration_versions version
       left join public.shooting_lanes root
         on root.id=version.root_lane_id
        and root.resource_kind='lane'
        and root.parent_lane_id is null
       where root.id is null
     )
     or exists (
       select 1 from public.lane_booking_rules rule
       left join public.shooting_lanes lane on lane.id=rule.lane_id
       where lane.id is null
     )
     or exists (
       select 1 from public.lane_booking_durations duration
       left join public.shooting_lanes lane on lane.id=duration.lane_id
       where lane.id is null
     )
     or exists (
       select 1 from public.lane_pricing_rules pricing
       left join public.shooting_lanes lane on lane.id=pricing.lane_id
       where lane.id is null
     ) then
    raise exception 'SAAS-9D-3C preflight failed: lane family/configuration integrity differs.';
  end if;
end;
$preflight$;

create temporary table saas9d3c_expected_targets(
  signature text primary key,
  fingerprint text not null,
  volatility "char" not null,
  expected_authenticated boolean not null
) on commit drop;

insert into saas9d3c_expected_targets values
  ('public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)','c60876406d007491187869017df989b5','v',false),
  ('public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','00fc387949410273a7cb33589cd8d1c6','v',true),
  ('public.lane_booking_family_business_snapshot_v2(uuid)','bc891bbdfab6d033fed72ece1c9fc193','s',false),
  ('public.normalize_lane_booking_family_payload_v2(jsonb)','77eee4f69abb6bdf74f1529f8e21589a','i',false),
  ('public.validate_lane_booking_rule_capacity()','78a6c1beb5048645a46d20d735324e2a','v',false),
  ('public.validate_shooting_lane_capacity_change()','96e0199a327831f40bec66c57d37f5ca','v',false),
  ('public.validate_shooting_lane_hierarchy()','dd3c97078341a74edc83ca79e9b19c0f','v',false);

do $target_guard$
declare v_count integer;
begin
  select pg_catalog.count(*) into v_count
  from saas9d3c_expected_targets expected
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
    and pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')=expected.expected_authenticated
    and not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE');

  if v_count<>7 then
    raise exception 'SAAS-9D-3C preflight failed: normalized fingerprint, metadata or ACL drift (%/7).',v_count;
  end if;
end;
$target_guard$;

create temporary table saas9d3c_unchanged_definer_snapshot on commit drop as
select procedure.proname,
       pg_catalog.pg_get_function_identity_arguments(procedure.oid) identity_arguments,
       pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
         pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
       ),E'\r',E'\n')) fingerprint,
       procedure.proowner,procedure.proconfig,procedure.proacl
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public' and procedure.prosecdef
  and procedure.proname not in(
    'admin_set_lane_booking_configuration',
    'admin_set_lane_booking_family_configuration_v2',
    'lane_booking_family_business_snapshot_v2',
    'normalize_lane_booking_family_payload_v2'
  );

create temporary table saas9d3c_trigger_snapshot on commit drop as
select expected.signature,
       pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
         pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
       ),E'\r',E'\n')) fingerprint,
       procedure.prosecdef,procedure.proowner,procedure.proconfig,procedure.proacl
from saas9d3c_expected_targets expected
join pg_catalog.pg_proc procedure on procedure.oid=pg_catalog.to_regprocedure(expected.signature)
where expected.signature like 'public.validate_%';

create temporary table saas9d3c_invariants on commit drop as
select
  (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef) definer_count,
  (select pg_catalog.count(*) from public.shooting_lanes) lane_count,
  (select pg_catalog.count(*) from public.lane_booking_rules) rule_count,
  (select pg_catalog.count(*) from public.lane_booking_durations) duration_count,
  (select pg_catalog.count(*) from public.lane_pricing_rules) pricing_count,
  (select pg_catalog.count(*) from public.lane_booking_family_configuration_versions) version_count,
  (select pg_catalog.count(*) from public.reservations) reservation_count,
  (select pg_catalog.count(*) from public.lane_blocks) block_count,
  (select pg_catalog.count(*) from public.events) event_count,
  (select pg_catalog.count(*) from public.event_lanes) event_lane_count,
  (select pg_catalog.count(*) from public.audit_logs) audit_count;

alter function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
  rename to admin_set_lane_booking_family_configuration_v2__saas9d3c_core;

do $patch_core$
declare
  v_definition text;
  v_patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
  ) into v_definition;

  v_patched:=pg_catalog.regexp_replace(v_definition,
    '([[:space:]]v_actor_role text;)',E'\\1\n  v_tenant_id uuid;');

  v_patched:=pg_catalog.regexp_replace(v_patched,
    E'  if v_actor_id is null or coalesce\\(v_actor_role, \'\'\\) <> \'admin\' then',
    E'  if v_actor_id is null then',1,1);

  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(  begin[[:space:]]+v_target := public[.]normalize_lane_booking_family_payload_v2)',
    E'  select root.tenant_id into v_tenant_id\n  from public.shooting_lanes root\n  where root.id=p_root_lane_id;\n\n  if not found then\n    return pg_catalog.jsonb_build_object(\n      \'ok\',false,\'changed\',false,\'code\',\'family_not_found\',\n      \'root_lane_id\',p_root_lane_id\n    );\n  end if;\n\n  if public.get_my_tenant_role_v1(v_tenant_id) is distinct from \'admin\' then\n    return pg_catalog.jsonb_build_object(\n      \'ok\',false,\'changed\',false,\'code\',\'not_allowed\',\n      \'root_lane_id\',p_root_lane_id\n    );\n  end if;\n\n\\1',1,1);

  v_patched:=pg_catalog.regexp_replace(v_patched,
    $regex$(  if v_family_ids is null then[[:space:]]+return pg_catalog[.]jsonb_build_object[(][[:space:]]+'ok', false, 'changed', false, 'code', 'invalid_hierarchy',[[:space:]]+'root_lane_id', p_root_lane_id[[:space:]]+[)];[[:space:]]+end if;)$regex$,
    E'\\1\n\n  if (select pg_catalog.count(*) from public.shooting_lanes lane where lane.id=any(v_family_ids) and lane.tenant_id=v_tenant_id)<>pg_catalog.cardinality(v_family_ids) then\n    return pg_catalog.jsonb_build_object(\n      \'ok\',false,\'changed\',false,\'code\',\'not_allowed\',\n      \'root_lane_id\',p_root_lane_id\n    );\n  end if;\n\n  select pg_catalog.array_agg(family_id order by family_id)\n  into v_family_ids\n  from pg_catalog.unnest(v_family_ids) as family(family_id);',1,1);

  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where root[.]id = p_root_lane_id;)',E'where root.id = p_root_lane_id\n    and root.tenant_id = v_tenant_id;',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    $regex$(where lane[.]id = [(]v_resource[.]value->>'lane_id'[)]::uuid;)$regex$,E'where lane.id = (v_resource.value->>\'lane_id\')::uuid\n      and lane.tenant_id = v_tenant_id;','g');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    $regex$(where reservation[.]lane_id = [(]v_resource[.]value->>'lane_id'[)]::uuid)$regex$,E'\\1\n      and reservation.tenant_id = v_tenant_id','g');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where child[.]parent_lane_id = p_root_lane_id)',E'\\1\n              and child.tenant_id = v_tenant_id','g');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    $regex$(on current_lane[.]id = [(]item[.]value->>'lane_id'[)]::uuid)$regex$,E'\\1\n       and current_lane.tenant_id = v_tenant_id','g');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where reservation[.]lane_id = any[(]v_affected_ids[)])',E'\\1\n      and reservation.tenant_id = v_tenant_id',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where lane_block[.]lane_id = any[(]v_affected_ids[)])',E'\\1\n      and lane_block.tenant_id = v_tenant_id',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where event_lane[.]lane_id = any[(]v_affected_ids[)])',E'\\1\n      and event_lane.tenant_id = v_tenant_id\n      and event_record.tenant_id = v_tenant_id',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    $regex$(where id = [(]v_resource[.]value->>'lane_id'[)]::uuid)$regex$,E'\\1\n          and tenant_id = v_tenant_id','g');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(insert into public[.]audit_logs[(][[:space:]]*)actor_user_id,',E'\\1tenant_id, actor_user_id,',1,1);
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(details[[:space:]]*[)][[:space:]]*values [(][[:space:]]*)v_actor_id,',E'\\1v_tenant_id, v_actor_id,',1,1);

  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'v_tenant_id uuid;')=0
     or pg_catalog.strpos(v_patched,'get_my_tenant_role_v1(v_tenant_id)')=0
     or pg_catalog.strpos(v_patched,'lane.tenant_id=v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'array_agg(family_id order by family_id)')=0
     or pg_catalog.strpos(v_patched,'root.tenant_id = v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'reservation.tenant_id = v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'lane_block.tenant_id = v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_lane.tenant_id = v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_record.tenant_id = v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'tenant_id, actor_user_id,')=0
     or pg_catalog.strpos(v_patched,'v_tenant_id, v_actor_id,')=0 then
    raise exception 'SAAS-9D-3C patch failed: writer anchors differ.';
  end if;

  execute v_patched;
end;
$patch_core$;

alter function public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean) security invoker;
revoke all on function public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean) from public,anon,authenticated,service_role;

create function public.admin_set_lane_booking_family_configuration_v2(
  p_root_lane_id uuid,p_expected_version bigint,p_resources jsonb,
  p_acknowledge_future_obligations boolean
) returns jsonb
language sql volatile security definer
set search_path = pg_catalog, public, pg_temp
as $function$
  select public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(
    p_root_lane_id,p_expected_version,p_resources,p_acknowledge_future_obligations
  );
$function$;

alter function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean) owner to postgres;
revoke all on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean) from public,anon,authenticated,service_role;
grant execute on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean) to authenticated;

alter function public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb) security invoker;
alter function public.lane_booking_family_business_snapshot_v2(uuid) security invoker;
alter function public.normalize_lane_booking_family_payload_v2(jsonb) security invoker;

revoke all on function public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb) from public,anon,authenticated,service_role;
revoke all on function public.lane_booking_family_business_snapshot_v2(uuid) from public,anon,authenticated,service_role;
revoke all on function public.normalize_lane_booking_family_payload_v2(jsonb) from public,anon,authenticated,service_role;

comment on function public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
  is 'Atomically updates one tenant-bound lane family for an active tenant administrator.';

do $postflight$
declare
  v_snapshot record;
  v_current record;
  v_invariants record;
begin
  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)<>67 then
    raise exception 'SAAS-9D-3C postflight failed: SECURITY DEFINER count is not 67.';
  end if;

  for v_snapshot in select * from saas9d3c_unchanged_definer_snapshot loop
    select pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'),E'\r',E'\n')) fingerprint,
           procedure.proowner,procedure.proconfig,procedure.proacl
    into v_current
    from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public' and procedure.proname=v_snapshot.proname
      and pg_catalog.pg_get_function_identity_arguments(procedure.oid)=v_snapshot.identity_arguments
      and procedure.prosecdef;
    if not found or v_current.fingerprint is distinct from v_snapshot.fingerprint
       or v_current.proowner is distinct from v_snapshot.proowner
       or v_current.proconfig is distinct from v_snapshot.proconfig
       or v_current.proacl is distinct from v_snapshot.proacl then
      raise exception 'SAAS-9D-3C postflight failed: unrelated SECURITY DEFINER drift in %(%).',v_snapshot.proname,v_snapshot.identity_arguments;
    end if;
  end loop;

  if exists (
    select 1 from saas9d3c_trigger_snapshot expected
    join pg_catalog.pg_proc procedure on procedure.oid=pg_catalog.to_regprocedure(expected.signature)
    where pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'),E'\r',E'\n')) is distinct from expected.fingerprint
       or procedure.prosecdef is distinct from expected.prosecdef
       or procedure.proowner is distinct from expected.proowner
       or procedure.proconfig is distinct from expected.proconfig
       or procedure.proacl is distinct from expected.proacl
  ) or (select pg_catalog.count(*) from saas9d3c_trigger_snapshot)<>3 then
    raise exception 'SAAS-9D-3C postflight failed: trigger function drift.';
  end if;

  if exists (
    select 1 from (values
      ('public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'),
      ('public.lane_booking_family_business_snapshot_v2(uuid)'),
      ('public.normalize_lane_booking_family_payload_v2(jsonb)')
    ) target(signature)
    join pg_catalog.pg_proc procedure on procedure.oid=pg_catalog.to_regprocedure(target.signature)
    where procedure.prosecdef
       or procedure.proowner<>(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
       or procedure.proconfig is distinct from array['search_path=pg_catalog, public, pg_temp']::text[]
       or pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
       or pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
       or pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
       or pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')
  ) then
    raise exception 'SAAS-9D-3C postflight failed: INVOKER helper/legacy metadata differs.';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc procedure
    where procedure.oid='public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
      and procedure.prosecdef
      and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
      and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      and not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
      and pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')
  ) then
    raise exception 'SAAS-9D-3C postflight failed: public writer metadata or ACL differs.';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc procedure
    where procedure.oid='public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
      and not procedure.prosecdef
      and pg_catalog.strpos(procedure.prosrc,'get_my_tenant_role_v1(v_tenant_id)')>0
      and pg_catalog.strpos(procedure.prosrc,'profile.role')=0
      and pg_catalog.strpos(procedure.prosrc,'reservation.tenant_id = v_tenant_id')>0
      and pg_catalog.strpos(procedure.prosrc,'lane_block.tenant_id = v_tenant_id')>0
      and pg_catalog.strpos(procedure.prosrc,'event_lane.tenant_id = v_tenant_id')>0
      and pg_catalog.strpos(procedure.prosrc,'tenant_id, actor_user_id')>0
      and not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')
  ) then
    raise exception 'SAAS-9D-3C postflight failed: writer core tenant boundary differs.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-3C postflight failed: compatibility defaults changed.';
  end if;

  select * into v_invariants from saas9d3c_invariants;
  if (select pg_catalog.count(*) from public.shooting_lanes)<>v_invariants.lane_count
     or (select pg_catalog.count(*) from public.lane_booking_rules)<>v_invariants.rule_count
     or (select pg_catalog.count(*) from public.lane_booking_durations)<>v_invariants.duration_count
     or (select pg_catalog.count(*) from public.lane_pricing_rules)<>v_invariants.pricing_count
     or (select pg_catalog.count(*) from public.lane_booking_family_configuration_versions)<>v_invariants.version_count
     or (select pg_catalog.count(*) from public.reservations)<>v_invariants.reservation_count
     or (select pg_catalog.count(*) from public.lane_blocks)<>v_invariants.block_count
     or (select pg_catalog.count(*) from public.events)<>v_invariants.event_count
     or (select pg_catalog.count(*) from public.event_lanes)<>v_invariants.event_lane_count
     or (select pg_catalog.count(*) from public.audit_logs)<>v_invariants.audit_count then
    raise exception 'SAAS-9D-3C postflight failed: migration changed business data.';
  end if;
end;
$postflight$;

commit;
