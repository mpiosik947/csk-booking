-- SAAS-9D-2B-1: tenant hardening for staff event-management RPCs.
-- Public event readers are intentionally deferred to SAAS-9D-2B-2.

begin;

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null then
    raise exception 'SAAS-9D-2B-1 preflight failed: tenant authorization helpers are absent.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname like '%__saas9d2b1_core'
  ) then
    raise exception 'SAAS-9D-2B-1 preflight failed: planned core objects already exist.';
  end if;
end;
$preflight$;

create temporary table saas9d2b1_preflight_guards (
  guard_name text primary key,
  matched_count integer not null check (matched_count=7)
);

insert into saas9d2b1_preflight_guards(guard_name,matched_count)
select 'definition_owner_definer',pg_catalog.count(*)
from (values
  ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','26f51acb0a0f56677a86dbddec9974b2'),
  ('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','6b8d29b11797a346ae9387a9bd3ec6b9'),
  ('public.admin_list_events_v1(text,text,text,integer,integer)','7972f35024b6202a149afbe09f50d5a2'),
  ('public.admin_set_event_active(uuid,boolean)','b547b0c8d2b056273b10fe57f78f89c0'),
  ('public.admin_set_event_active_v2(uuid,boolean)','ad56e445e74634f540425d92ff93acb1'),
  ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','60301f5e0b290117105bc9637f10d3ce'),
  ('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','a525123389f3a646cd3da6f26e466ed5')
) expected(signature,fingerprint)
join pg_catalog.pg_proc procedure
  on procedure.oid=pg_catalog.to_regprocedure(expected.signature)
where pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
        pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
      ),E'\r',E'\n'))=expected.fingerprint
  and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
  and procedure.prosecdef;

insert into saas9d2b1_preflight_guards(guard_name,matched_count)
select 'execute_acl',pg_catalog.count(*)
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.proname=any(array[
    'admin_create_event','admin_create_event_v2','admin_list_events_v1',
    'admin_set_event_active','admin_set_event_active_v2',
    'admin_update_event','admin_update_event_v2'
  ])
  and not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
  and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
  and (
    pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
    is not distinct from (procedure.proname in (
      'admin_create_event_v2','admin_list_events_v1',
      'admin_set_event_active_v2','admin_update_event_v2'
    ))
  )
  and (
    pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')
    is not distinct from (procedure.proname in (
      'admin_create_event','admin_set_event_active','admin_update_event'
    ))
  );

create temporary table saas9d2b1_unchanged_definer_snapshot on commit drop as
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
    'admin_create_event','admin_create_event_v2','admin_list_events_v1',
    'admin_set_event_active','admin_set_event_active_v2',
    'admin_update_event','admin_update_event_v2'
  );

alter function public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])
  rename to admin_create_event_v2__saas9d2b1_core;
alter function public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])
  rename to admin_update_event_v2__saas9d2b1_core;
alter function public.admin_set_event_active_v2(uuid,boolean)
  rename to admin_set_event_active_v2__saas9d2b1_core;
alter function public.admin_list_events_v1(text,text,text,integer,integer)
  rename to admin_list_events_v1__saas9d2b1_core;

-- Patch only tenant ownership and tenant predicates inside the frozen business implementations.
do $patch_cores$
declare
  v_definition text;
  v_patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched:=pg_catalog.regexp_replace(v_definition,
    '([[:space:]]v_actor_role text;)',E'\\1\n  v_tenant_id uuid := public.active_single_tenant_id_v1();');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(insert into public[.]events [(][[:space:]]*)title,',E'\\1tenant_id,\n    title,');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '([)][[:space:]]*values [(][[:space:]]*)v_title,',E'\\1v_tenant_id,\n    v_title,');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    'insert into public[.]event_lanes [(]event_id, lane_id[)][[:space:]]*select v_event_id, requested[.]lane_id',
    E'insert into public.event_lanes (tenant_id, event_id, lane_id)\n  select v_tenant_id, v_event_id, requested.lane_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where reservation[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and reservation.tenant_id = v_tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where lane_block[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and lane_block.tenant_id = v_tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where event_lane[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and event_lane.tenant_id = v_tenant_id\n      and existing_event.tenant_id = v_tenant_id');
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'v_tenant_id uuid := public.active_single_tenant_id_v1()')=0
     or pg_catalog.strpos(v_patched,'insert into public.event_lanes (tenant_id, event_id, lane_id)')=0
     or pg_catalog.strpos(v_patched,'reservation.tenant_id = v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'lane_block.tenant_id = v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'existing_event.tenant_id = v_tenant_id')=0 then
    raise exception 'SAAS-9D-2B-1 failed to patch create-event tenant invariants.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.admin_update_event_v2__saas9d2b1_core(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched:=pg_catalog.regexp_replace(v_definition,
    'insert into public[.]event_lanes [(]event_id, lane_id[)][[:space:]]*select p_event_id, requested[.]lane_id',
    E'insert into public.event_lanes (tenant_id, event_id, lane_id)\n  select v_original.tenant_id, p_event_id, requested.lane_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where reservation[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and reservation.tenant_id = v_original.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where lane_block[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and lane_block.tenant_id = v_original.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where event_lane[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and event_lane.tenant_id = v_original.tenant_id\n      and existing_event.tenant_id = v_original.tenant_id');
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'insert into public.event_lanes (tenant_id, event_id, lane_id)')=0
     or pg_catalog.strpos(v_patched,'reservation.tenant_id = v_original.tenant_id')=0
     or pg_catalog.strpos(v_patched,'lane_block.tenant_id = v_original.tenant_id')=0
     or pg_catalog.strpos(v_patched,'existing_event.tenant_id = v_original.tenant_id')=0 then
    raise exception 'SAAS-9D-2B-1 failed to patch update-event tenant invariants.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.admin_set_event_active_v2__saas9d2b1_core(uuid,boolean)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched:=pg_catalog.regexp_replace(v_definition,
    '(where event_lane[.]event_id = p_event_id)',E'\\1\n    and event_lane.tenant_id = v_original.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where reservation[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and reservation.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where lane_block[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and lane_block.tenant_id = v_current.tenant_id');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where event_lane[.]lane_id = any[(]v_conflict_lane_ids[)])',E'\\1\n      and event_lane.tenant_id = v_current.tenant_id\n      and existing_event.tenant_id = v_current.tenant_id');
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'event_lane.tenant_id = v_original.tenant_id')=0
     or pg_catalog.strpos(v_patched,'reservation.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'lane_block.tenant_id = v_current.tenant_id')=0
     or pg_catalog.strpos(v_patched,'existing_event.tenant_id = v_current.tenant_id')=0 then
    raise exception 'SAAS-9D-2B-1 failed to patch activation tenant predicates.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched:=pg_catalog.regexp_replace(v_definition,
    '([[:space:]]v_role text;)',E'\\1\n  v_tenant_id uuid:=public.active_single_tenant_id_v1();');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    'where [(]v_search is null or event_record[.]title ilike',
    E'where event_record.tenant_id=v_tenant_id\n      and (v_search is null or event_record.title ilike');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(from public[.]events[[:space:]]*)([)], page_rows as)',
    E'\\1where tenant_id=v_tenant_id\n  \\2');
  v_patched:=pg_catalog.regexp_replace(v_patched,
    '(where relation[.]event_id=row[.]id)',
    E'\\1\n        and relation.tenant_id=row.tenant_id\n        and lane.tenant_id=row.tenant_id');
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'event_record.tenant_id=v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'where tenant_id=v_tenant_id')=0
     or pg_catalog.strpos(v_patched,'relation.tenant_id=row.tenant_id')=0 then
    raise exception 'SAAS-9D-2B-1 failed to patch admin list tenant scope.';
  end if;
  execute v_patched;
end;
$patch_cores$;

alter function public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) security invoker;
alter function public.admin_update_event_v2__saas9d2b1_core(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) security invoker;
alter function public.admin_set_event_active_v2__saas9d2b1_core(uuid,boolean) security invoker;
alter function public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer) security invoker;

revoke all on function public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.admin_update_event_v2__saas9d2b1_core(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.admin_set_event_active_v2__saas9d2b1_core(uuid,boolean) from public,anon,authenticated,service_role;
revoke all on function public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer) from public,anon,authenticated,service_role;

create function public.admin_create_event_v2(
  p_title text,p_description text,p_event_date date,
  p_start_time time without time zone,p_end_time time without time zone,
  p_location text,p_price numeric,p_max_participants integer,
  p_lane_ids uuid[] default '{}'::uuid[]
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant_id uuid; v_role text; v_foreign_lane uuid;
begin
  -- Stabilize the single-active bridge for this transaction against a tenant-status cutover.
  perform tenant.id from public.tenants tenant order by tenant.id for share;
  v_tenant_id:=public.active_single_tenant_id_v1();
  v_role:=public.get_my_tenant_role_v1(v_tenant_id);
  if v_tenant_id is null or v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',null);
  end if;
  select lane.id into v_foreign_lane
  from pg_catalog.unnest(coalesce(p_lane_ids,'{}'::uuid[])) requested(lane_id)
  join public.shooting_lanes lane on lane.id=requested.lane_id
  where lane.tenant_id is distinct from v_tenant_id
  order by lane.id limit 1;
  if found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',null);
  end if;
  return public.admin_create_event_v2__saas9d2b1_core(
    p_title,p_description,p_event_date,p_start_time,p_end_time,p_location,
    p_price,p_max_participants,p_lane_ids
  );
end;
$function$;

create function public.admin_update_event_v2(
  p_event_id uuid,p_title text,p_description text,p_event_date date,
  p_start_time time without time zone,p_end_time time without time zone,
  p_location text,p_price numeric,p_max_participants integer,
  p_lane_ids uuid[] default '{}'::uuid[]
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant_id uuid; v_role text; v_foreign_lane uuid;
begin
  if p_event_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_input','event_id',null);
  end if;
  select event_record.tenant_id into v_tenant_id
  from public.events event_record where event_record.id=p_event_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','event_not_found','event_id',p_event_id);
  end if;
  v_role:=public.get_my_tenant_role_v1(v_tenant_id);
  if v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',p_event_id);
  end if;
  select lane.id into v_foreign_lane
  from pg_catalog.unnest(coalesce(p_lane_ids,'{}'::uuid[])) requested(lane_id)
  join public.shooting_lanes lane on lane.id=requested.lane_id
  where lane.tenant_id is distinct from v_tenant_id
  order by lane.id limit 1;
  if found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',p_event_id);
  end if;
  return public.admin_update_event_v2__saas9d2b1_core(
    p_event_id,p_title,p_description,p_event_date,p_start_time,p_end_time,
    p_location,p_price,p_max_participants,p_lane_ids
  );
end;
$function$;

create function public.admin_set_event_active_v2(p_event_id uuid,p_is_active boolean)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant_id uuid; v_role text;
begin
  if p_event_id is null or p_is_active is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_input','event_id',p_event_id);
  end if;
  select event_record.tenant_id into v_tenant_id
  from public.events event_record where event_record.id=p_event_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','event_not_found','event_id',p_event_id);
  end if;
  v_role:=public.get_my_tenant_role_v1(v_tenant_id);
  if v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed','event_id',p_event_id);
  end if;
  return public.admin_set_event_active_v2__saas9d2b1_core(p_event_id,p_is_active);
end;
$function$;

create function public.admin_list_events_v1(
  p_search text default null,p_scope text default 'upcoming',
  p_sort text default 'nearest',p_page integer default 1,p_page_size integer default 20
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant_id uuid; v_role text;
begin
  -- STABLE preserves one statement snapshot for bridge resolution and the bounded list.
  v_tenant_id:=public.active_single_tenant_id_v1();
  v_role:=public.get_my_tenant_role_v1(v_tenant_id);
  if v_tenant_id is null or v_role is null or v_role not in ('admin','employee','instructor') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed');
  end if;
  return public.admin_list_events_v1__saas9d2b1_core(p_search,p_scope,p_sort,p_page,p_page_size);
end;
$function$;

alter function public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) owner to postgres;
alter function public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) owner to postgres;
alter function public.admin_set_event_active_v2(uuid,boolean) owner to postgres;
alter function public.admin_list_events_v1(text,text,text,integer,integer) owner to postgres;

revoke all on function public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.admin_set_event_active_v2(uuid,boolean) from public,anon,authenticated,service_role;
revoke all on function public.admin_list_events_v1(text,text,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) to authenticated;
grant execute on function public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) to authenticated;
grant execute on function public.admin_set_event_active_v2(uuid,boolean) to authenticated;
grant execute on function public.admin_list_events_v1(text,text,text,integer,integer) to authenticated;

-- The three legacy server-only signatures have zero active callers and become owner-only.
-- This is deliberately ACL-only: body, signature, owner and search_path stay unchanged.
revoke all on function public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.admin_set_event_active(uuid,boolean) from public,anon,authenticated,service_role;

do $postflight$
declare v_changed integer; v_unchanged integer; v_snapshot integer;
begin
  select pg_catalog.count(*) into v_changed
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname='public'
    and procedure.prosecdef
    and procedure.proname in (
      'admin_create_event_v2','admin_update_event_v2',
      'admin_set_event_active_v2','admin_list_events_v1'
    )
    and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
    and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[];
  if v_changed<>4 then raise exception 'SAAS-9D-2B-1 postflight failed: wrapper metadata differs.'; end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.proname like '%__saas9d2b1_core'
        and not procedure.prosecdef)<>4 then
    raise exception 'SAAS-9D-2B-1 postflight failed: core inventory differs.';
  end if;

  if exists (
    select 1 from (values
      ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
      ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
      ('public.admin_set_event_active(uuid,boolean)')
    ) legacy(signature)
    where pg_catalog.has_function_privilege('public',pg_catalog.to_regprocedure(legacy.signature),'EXECUTE')
       or pg_catalog.has_function_privilege('anon',pg_catalog.to_regprocedure(legacy.signature),'EXECUTE')
       or pg_catalog.has_function_privilege('authenticated',pg_catalog.to_regprocedure(legacy.signature),'EXECUTE')
       or pg_catalog.has_function_privilege('service_role',pg_catalog.to_regprocedure(legacy.signature),'EXECUTE')
  ) then raise exception 'SAAS-9D-2B-1 postflight failed: legacy function remains callable.'; end if;

  select pg_catalog.count(*) into v_unchanged
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  join saas9d2b1_unchanged_definer_snapshot snapshot
    on snapshot.proname=procedure.proname
   and snapshot.identity_arguments=pg_catalog.pg_get_function_identity_arguments(procedure.oid)
  where namespace.nspname='public' and procedure.prosecdef
    and snapshot.fingerprint=pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
    ),E'\r',E'\n'))
    and snapshot.proowner=procedure.proowner
    and snapshot.proconfig is not distinct from procedure.proconfig
    and snapshot.proacl is not distinct from procedure.proacl;
  select pg_catalog.count(*) into v_snapshot from saas9d2b1_unchanged_definer_snapshot;
  if v_unchanged<>v_snapshot then
    raise exception 'SAAS-9D-2B-1 postflight failed: an out-of-scope definer changed.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>73 then
    raise exception 'SAAS-9D-2B-1 postflight failed: SECURITY DEFINER count changed.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.get_public_event_availability_v1()'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))<>'40adf74cb5adec5df3b4745fc7851433'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.get_public_event_list_v2(text,text,integer,integer)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))<>'fe075d7057149b0a0bad0129419a3e99' then
    raise exception 'SAAS-9D-2B-1 postflight failed: deferred public reader changed.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;

commit;
