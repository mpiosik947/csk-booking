-- SAAS-9D-3A: tenant hardening for lane-block administration RPCs.
-- Lane configuration and every later SAAS-9D phase are intentionally out of scope.

begin;

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null then
    raise exception 'SAAS-9D-3A preflight failed: tenant authorization helper is absent.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname like '%__saas9d3a_core'
  ) then
    raise exception 'SAAS-9D-3A preflight failed: planned core objects already exist.';
  end if;

  if exists (
    select 1
    from public.lane_blocks block
    left join public.shooting_lanes lane
      on lane.id=block.lane_id and lane.tenant_id=block.tenant_id
    where lane.id is null
  ) then
    raise exception 'SAAS-9D-3A preflight failed: lane/block tenant inconsistency exists.';
  end if;
end;
$preflight$;

create temporary table saas9d3a_expected_targets (
  signature text primary key,
  fingerprint text not null
) on commit drop;

insert into saas9d3a_expected_targets(signature,fingerprint) values
  ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)','fba59c6dbe820ab5c81525bb4dc8659e'),
  ('public.admin_set_lane_block_active(uuid,boolean)','58fd6523e0b2fa55c6e6afc2a33a1b1b'),
  ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)','66f4ba1fb3fe7686b2a04f335851dc43');

do $target_guard$
declare
  v_count integer;
begin
  select pg_catalog.count(*) into v_count
  from saas9d3a_expected_targets expected
  join pg_catalog.pg_proc procedure
    on procedure.oid=pg_catalog.to_regprocedure(expected.signature)
  where pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
          pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
        ),E'\r',E'\n'))=expected.fingerprint
    and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
    and procedure.prosecdef
    and procedure.provolatile='v'
    and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
    and not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE');

  if v_count<>3 then
    raise exception 'SAAS-9D-3A preflight failed: normalized target fingerprint, metadata or ACL drift (%/3).',v_count;
  end if;
end;
$target_guard$;

create temporary table saas9d3a_unchanged_definer_snapshot on commit drop as
select
  procedure.proname,
  pg_catalog.pg_get_function_identity_arguments(procedure.oid) as identity_arguments,
  pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
    pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
  ),E'\r',E'\n')) as fingerprint,
  procedure.proowner,
  procedure.proconfig,
  procedure.proacl
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.prosecdef
  and procedure.proname not in (
    'admin_create_lane_block','admin_set_lane_block_active','admin_update_lane_block'
  );

create temporary table saas9d3a_invariants on commit drop as
select
  (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef) as definer_count,
  (select pg_catalog.count(*) from public.lane_blocks) as block_count,
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.concat_ws('|',block.id,block.tenant_id,block.lane_id,block.block_date,block.start_time,block.end_time,block.reason,block.is_active),E'\n' order by block.id),'')) from public.lane_blocks block) as block_fingerprint;

alter function public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)
  rename to admin_create_lane_block__saas9d3a_core;
alter function public.admin_set_lane_block_active(uuid,boolean)
  rename to admin_set_lane_block_active__saas9d3a_core;
alter function public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)
  rename to admin_update_lane_block__saas9d3a_core;

-- Patch only explicit tenant ownership and conflict-domain predicates inside the
-- frozen business implementations. The public wrappers below are the sole authority.
do $patch_cores$
declare
  v_definition text;
  v_patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched:=pg_catalog.regexp_replace(v_definition,
    '(where reservation[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and reservation.tenant_id = v_lane.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where event_lane[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and event_lane.tenant_id = v_lane.tenant_id\n      and event_record.tenant_id = v_lane.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(insert into public[.]lane_blocks [(][[:space:]]*)lane_id,',E'\\1tenant_id,\n      lane_id,');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '([)][[:space:]]*values [(][[:space:]]*)p_lane_id,',E'\\1v_lane.tenant_id,\n      p_lane_id,');
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'reservation.tenant_id = v_lane.tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_lane.tenant_id = v_lane.tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_record.tenant_id = v_lane.tenant_id')=0
     or pg_catalog.strpos(v_patched,'tenant_id,')=0
     or pg_catalog.strpos(v_patched,'v_lane.tenant_id,')=0 then
    raise exception 'SAAS-9D-3A patch failed: create core anchors differ.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.admin_set_lane_block_active__saas9d3a_core(uuid,boolean)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched:=pg_catalog.regexp_replace(v_definition,
    '(where lane[.]id = v_current[.]lane_id)',E'\\1\n    and lane.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where reservation[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and reservation.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where event_lane[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and event_lane.tenant_id = v_current.tenant_id\n      and event_record.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where id = p_block_id;)',E'where id = p_block_id\n      and tenant_id = v_current.tenant_id;',1,0);
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'lane.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'reservation.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_lane.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_record.tenant_id = v_current.tenant_id')=0 then
    raise exception 'SAAS-9D-3A patch failed: activation core anchors differ.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched:=pg_catalog.regexp_replace(v_definition,
    '(where lane[.]id = p_lane_id)',E'\\1\n    and lane.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where reservation[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and reservation.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where event_lane[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and event_lane.tenant_id = v_current.tenant_id\n      and event_record.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where id = p_block_id;)',E'where id = p_block_id\n      and tenant_id = v_current.tenant_id;',1,0);
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'lane.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'reservation.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_lane.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_record.tenant_id = v_current.tenant_id')=0 then
    raise exception 'SAAS-9D-3A patch failed: update core anchors differ.';
  end if;
  execute v_patched;
end;
$patch_cores$;

alter function public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text) security invoker;
alter function public.admin_set_lane_block_active__saas9d3a_core(uuid,boolean) security invoker;
alter function public.admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time without time zone,time without time zone,text,boolean) security invoker;

revoke all on function public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text) from public,anon,authenticated,service_role;
revoke all on function public.admin_set_lane_block_active__saas9d3a_core(uuid,boolean) from public,anon,authenticated,service_role;
revoke all on function public.admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time without time zone,time without time zone,text,boolean) from public,anon,authenticated,service_role;

create function public.admin_create_lane_block(
  p_lane_id uuid,
  p_block_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_reason text default null::text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_tenant_id uuid;
  v_role text;
begin
  if auth.uid() is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','lane_block_id',null);
  end if;

  if p_lane_id is null then
    return public.admin_create_lane_block__saas9d3a_core(p_lane_id,p_block_date,p_start_time,p_end_time,p_reason);
  end if;

  select lane.tenant_id into v_tenant_id
  from public.shooting_lanes lane
  where lane.id=p_lane_id
  for key share;

  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_lane','lane_block_id',null);
  end if;

  v_role:=public.get_my_tenant_role_v1(v_tenant_id);
  if v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','lane_block_id',null);
  end if;

  return public.admin_create_lane_block__saas9d3a_core(p_lane_id,p_block_date,p_start_time,p_end_time,p_reason);
end;
$function$;

create function public.admin_set_lane_block_active(p_block_id uuid,p_is_active boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_tenant_id uuid;
  v_role text;
begin
  if auth.uid() is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','lane_block_id',p_block_id);
  end if;

  if p_block_id is null then
    return public.admin_set_lane_block_active__saas9d3a_core(p_block_id,p_is_active);
  end if;

  select block.tenant_id into v_tenant_id
  from public.lane_blocks block
  join public.shooting_lanes lane
    on lane.id=block.lane_id and lane.tenant_id=block.tenant_id
  where block.id=p_block_id
  for update of block;

  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','block_not_found','lane_block_id',p_block_id);
  end if;

  v_role:=public.get_my_tenant_role_v1(v_tenant_id);
  if v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','lane_block_id',p_block_id);
  end if;

  return public.admin_set_lane_block_active__saas9d3a_core(p_block_id,p_is_active);
end;
$function$;

create function public.admin_update_lane_block(
  p_block_id uuid,
  p_lane_id uuid,
  p_block_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_reason text,
  p_is_active boolean
) returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_block_tenant_id uuid;
  v_lane_tenant_id uuid;
  v_role text;
begin
  if auth.uid() is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','lane_block_id',p_block_id);
  end if;

  if p_block_id is null then
    return public.admin_update_lane_block__saas9d3a_core(p_block_id,p_lane_id,p_block_date,p_start_time,p_end_time,p_reason,p_is_active);
  end if;

  select block.tenant_id into v_block_tenant_id
  from public.lane_blocks block
  join public.shooting_lanes lane
    on lane.id=block.lane_id and lane.tenant_id=block.tenant_id
  where block.id=p_block_id
  for update of block;

  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','block_not_found','lane_block_id',p_block_id);
  end if;

  v_role:=public.get_my_tenant_role_v1(v_block_tenant_id);
  if v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','lane_block_id',p_block_id);
  end if;

  if p_lane_id is null then
    return public.admin_update_lane_block__saas9d3a_core(p_block_id,p_lane_id,p_block_date,p_start_time,p_end_time,p_reason,p_is_active);
  end if;

  select lane.tenant_id into v_lane_tenant_id
  from public.shooting_lanes lane
  where lane.id=p_lane_id
  for key share;

  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_lane','lane_block_id',p_block_id);
  end if;

  if v_lane_tenant_id is distinct from v_block_tenant_id then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','lane_block_id',p_block_id);
  end if;

  return public.admin_update_lane_block__saas9d3a_core(p_block_id,p_lane_id,p_block_date,p_start_time,p_end_time,p_reason,p_is_active);
end;
$function$;

alter function public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text) owner to postgres;
alter function public.admin_set_lane_block_active(uuid,boolean) owner to postgres;
alter function public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean) owner to postgres;

revoke all on function public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text) from public,anon,authenticated,service_role;
revoke all on function public.admin_set_lane_block_active(uuid,boolean) from public,anon,authenticated,service_role;
revoke all on function public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean) from public,anon,authenticated,service_role;
grant execute on function public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text) to authenticated;
grant execute on function public.admin_set_lane_block_active(uuid,boolean) to authenticated;
grant execute on function public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean) to authenticated;

comment on function public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)
  is 'Creates one tenant-bound lane block for an active tenant admin or employee.';
comment on function public.admin_set_lane_block_active(uuid,boolean)
  is 'Toggles one tenant-bound lane block for an active tenant admin or employee.';
comment on function public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)
  is 'Updates one lane block without allowing a cross-tenant lane move.';

do $postflight$
declare
  v_snapshot record;
  v_invariants record;
  v_current record;
begin
  for v_snapshot in select * from saas9d3a_unchanged_definer_snapshot loop
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
      raise exception 'SAAS-9D-3A postflight failed: unrelated SECURITY DEFINER drift in %(%).',v_snapshot.proname,v_snapshot.identity_arguments;
    end if;
  end loop;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)
     <> (select definer_count from saas9d3a_invariants) then
    raise exception 'SAAS-9D-3A postflight failed: SECURITY DEFINER count changed.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-3A postflight failed: compatibility defaults changed.';
  end if;

  if exists (
    select 1
    from (values
      ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'),
      ('public.admin_set_lane_block_active(uuid,boolean)'),
      ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)')
    ) target(signature)
    join pg_catalog.pg_proc procedure on procedure.oid=pg_catalog.to_regprocedure(target.signature)
    where not procedure.prosecdef
       or procedure.proowner<>(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
       or procedure.proconfig is distinct from array['search_path=pg_catalog, public, pg_temp']::text[]
       or pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
       or pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
       or not pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
       or pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')
       or pg_catalog.strpos(pg_catalog.pg_get_functiondef(procedure.oid),'get_my_tenant_role_v1')=0
       or pg_catalog.strpos(pg_catalog.pg_get_functiondef(procedure.oid),'profile.role')>0
  ) then
    raise exception 'SAAS-9D-3A postflight failed: public wrapper metadata, ACL or authorization differs.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname in (
        'admin_create_lane_block__saas9d3a_core',
        'admin_set_lane_block_active__saas9d3a_core',
        'admin_update_lane_block__saas9d3a_core'
      )
      and (procedure.prosecdef
        or pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
        or pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
        or pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
        or pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE'))
  ) or (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname like '%__saas9d3a_core')<>3 then
    raise exception 'SAAS-9D-3A postflight failed: internal core exposure differs.';
  end if;

  if pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure),'reservation.tenant_id = v_lane.tenant_id')=0
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure),'event_lane.tenant_id = v_lane.tenant_id')=0
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure),'v_lane.tenant_id,')=0
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_set_lane_block_active__saas9d3a_core(uuid,boolean)'::pg_catalog.regprocedure),'reservation.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure),'lane.tenant_id = v_current.tenant_id')=0 then
    raise exception 'SAAS-9D-3A postflight failed: tenant-bound core predicates are absent.';
  end if;

  select * into v_invariants from saas9d3a_invariants;
  if (select pg_catalog.count(*) from public.lane_blocks)<>v_invariants.block_count
     or (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.concat_ws('|',block.id,block.tenant_id,block.lane_id,block.block_date,block.start_time,block.end_time,block.reason,block.is_active),E'\n' order by block.id),'')) from public.lane_blocks block) is distinct from v_invariants.block_fingerprint then
    raise exception 'SAAS-9D-3A postflight failed: migration changed lane-block business data.';
  end if;
end;
$postflight$;

commit;
