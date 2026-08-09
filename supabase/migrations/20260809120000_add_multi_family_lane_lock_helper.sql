-- Additive, private multi-family lock protocol for hierarchy-aware writers.
-- This helper validates topology only; writer-specific bookability belongs to call sites.

do $preflight$
declare
  v_resolver oid := pg_catalog.to_regprocedure(
    'public.resolve_lane_conflict_scope_v1(uuid)'
  );
  v_single_helper oid := pg_catalog.to_regprocedure(
    'public.lock_lane_conflict_family_v1(uuid)'
  );
  v_create_reservation_v2 oid := pg_catalog.to_regprocedure(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
  );
  v_availability_v3 oid := pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'
  );
begin
  if pg_catalog.to_regclass('public.shooting_lanes') is null then
    raise exception 'Preflight failed: hierarchy foundation table is missing.';
  end if;

  if v_resolver is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'resolve_lane_conflict_scope_v1'
     ) <> 1
     or v_single_helper is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'lock_lane_conflict_family_v1'
     ) <> 1
     or v_create_reservation_v2 is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'create_reservation_v2'
     ) <> 1
     or v_availability_v3 is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'get_lane_booking_busy_ranges_v3'
     ) <> 1 then
    raise exception 'Preflight failed: required hierarchy functions differ.';
  end if;

  if (
       select pg_catalog.count(*)
       from information_schema.columns as column_record
       where column_record.table_schema = 'public'
         and column_record.table_name = 'shooting_lanes'
         and (
           (
             column_record.column_name = 'resource_kind'
             and column_record.data_type = 'text'
             and column_record.is_nullable = 'NO'
           )
           or (
             column_record.column_name = 'parent_lane_id'
             and column_record.data_type = 'uuid'
             and column_record.is_nullable = 'YES'
           )
         )
     ) <> 2 then
    raise exception 'Preflight failed: hierarchy columns differ.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_resource_kind_check'
         and constraint_record.contype = 'c'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_resource_parent_check'
         and constraint_record.contype = 'c'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_parent_not_self_check'
         and constraint_record.contype = 'c'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_position_booking_modes_check'
         and constraint_record.contype = 'c'
     )
     or not exists (
       select 1
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and constraint_record.conname = 'shooting_lanes_parent_lane_id_fkey'
         and constraint_record.contype = 'f'
     ) then
    raise exception 'Preflight failed: hierarchy constraints differ.';
  end if;

  if pg_catalog.to_regclass('public.shooting_lanes_parent_lane_id_idx') is null
     or not exists (
       select 1
       from pg_catalog.pg_trigger as trigger_record
       where trigger_record.tgrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and trigger_record.tgname = 'validate_shooting_lane_hierarchy_trigger'
         and not trigger_record.tgisinternal
         and trigger_record.tgenabled <> 'D'
         and trigger_record.tgfoid = pg_catalog.to_regprocedure(
           'public.validate_shooting_lane_hierarchy()'
         )
     ) then
    raise exception 'Preflight failed: hierarchy index or trigger differs.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.lock_lane_conflict_families_v1(uuid[])'
     ) is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'lock_lane_conflict_families_v1'
     ) then
    raise exception 'Preflight failed: multi-family helper already exists.';
  end if;
end;
$preflight$;

create function public.lock_lane_conflict_families_v1(p_lane_ids uuid[])
returns table (
  requested_lane_id uuid,
  root_lane_id uuid,
  requested_resource_kind text,
  conflict_lane_ids uuid[]
)
language plpgsql
volatile
security invoker
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_requested_ids uuid[];
  v_expected_root_ids uuid[] := array[]::uuid[];
  v_expected_kinds text[] := array[]::text[];
  v_root_ids uuid[];
  v_full_root_ids uuid[];
  v_requested_id uuid;
  v_requested_kind text;
  v_requested_parent_id uuid;
  v_parent_kind text;
  v_parent_parent_id uuid;
  v_root_id uuid;
  v_current_kind text;
  v_current_parent_id uuid;
  v_index integer;
begin
  if p_lane_ids is null then
    raise exception 'Lane identifiers are required.' using errcode = '22023';
  end if;

  if pg_catalog.cardinality(p_lane_ids) = 0 then
    raise exception 'At least one lane identifier is required.' using errcode = '22023';
  end if;

  if pg_catalog.array_position(p_lane_ids, null::uuid) is not null then
    raise exception 'Lane identifiers cannot contain NULL.' using errcode = '22023';
  end if;

  select pg_catalog.array_agg(distinct input_record.lane_id order by input_record.lane_id)
  into v_requested_ids
  from pg_catalog.unnest(p_lane_ids) as input_record(lane_id);

  -- Preliminary topology resolution only. No lock and no bookability validation.
  for v_requested_id in
    select input_record.lane_id
    from pg_catalog.unnest(v_requested_ids) as input_record(lane_id)
    order by input_record.lane_id
  loop
    select lane.resource_kind, lane.parent_lane_id
    into v_requested_kind, v_requested_parent_id
    from public.shooting_lanes as lane
    where lane.id = v_requested_id;

    if not found then
      raise exception 'Shooting-lane resource does not exist.' using errcode = 'P0002';
    end if;

    if v_requested_kind not in ('lane', 'position')
       or v_requested_kind is null then
      raise exception 'Malformed shooting-lane resource kind.' using errcode = '55000';
    end if;

    if v_requested_kind = 'lane' then
      if v_requested_parent_id is not null then
        raise exception 'Malformed top-level shooting lane.' using errcode = '55000';
      end if;

      v_root_id := v_requested_id;
    else
      if v_requested_parent_id is null
         or v_requested_parent_id = v_requested_id then
        raise exception 'Malformed shooting-lane position parent.' using errcode = '55000';
      end if;

      select parent.resource_kind, parent.parent_lane_id
      into v_parent_kind, v_parent_parent_id
      from public.shooting_lanes as parent
      where parent.id = v_requested_parent_id;

      if not found
         or v_parent_kind is distinct from 'lane'
         or v_parent_parent_id is not null then
        raise exception 'Position parent must be an existing top-level lane.'
          using errcode = '55000';
      end if;

      v_root_id := v_requested_parent_id;
    end if;

    if exists (
         select 1
         from public.shooting_lanes as child
         where child.parent_lane_id = v_root_id
           and (
             child.id = v_root_id
             or child.resource_kind is distinct from 'position'
           )
       )
       or exists (
         select 1
         from public.shooting_lanes as child
         join public.shooting_lanes as grandchild
           on grandchild.parent_lane_id = child.id
         where child.parent_lane_id = v_root_id
       ) then
      raise exception 'Malformed shooting-lane hierarchy depth.' using errcode = '55000';
    end if;

    v_expected_root_ids := pg_catalog.array_append(v_expected_root_ids, v_root_id);
    v_expected_kinds := pg_catalog.array_append(v_expected_kinds, v_requested_kind);
  end loop;

  select pg_catalog.array_agg(distinct root_record.root_id order by root_record.root_id)
  into v_root_ids
  from pg_catalog.unnest(v_expected_root_ids) as root_record(root_id);

  select pg_catalog.array_agg(mode_record.root_id order by mode_record.root_id)
  into v_full_root_ids
  from (
    select distinct v_expected_root_ids[index_record.index_value] as root_id
    from pg_catalog.generate_subscripts(v_requested_ids, 1) as index_record(index_value)
    where v_requested_ids[index_record.index_value]
          = v_expected_root_ids[index_record.index_value]
  ) as mode_record;

  -- Phase 1: lock every root globally before taking any child lock.
  for v_root_id in
    select root_record.root_id
    from pg_catalog.unnest(v_root_ids) as root_record(root_id)
    order by root_record.root_id
  loop
    if pg_catalog.array_position(v_full_root_ids, v_root_id) is not null then
      perform root.id
      from public.shooting_lanes as root
      where root.id = v_root_id
      for update;
    else
      perform root.id
      from public.shooting_lanes as root
      where root.id = v_root_id
      for share;
    end if;

    if not found then
      raise exception 'Resolved shooting-lane root disappeared.' using errcode = '55000';
    end if;
  end loop;

  -- Phase 2: only after all roots, lock children root-by-root and child-id ordered.
  for v_root_id in
    select root_record.root_id
    from pg_catalog.unnest(v_root_ids) as root_record(root_id)
    order by root_record.root_id
  loop
    if pg_catalog.array_position(v_full_root_ids, v_root_id) is not null then
      perform child.id
      from public.shooting_lanes as child
      where child.parent_lane_id = v_root_id
      order by child.id
      for update;
    else
      perform child.id
      from public.shooting_lanes as child
      where child.parent_lane_id = v_root_id
        and child.id = any(v_requested_ids)
      order by child.id
      for update;
    end if;
  end loop;

  -- Re-read the locked resources and fail closed if topology changed.
  for v_index in 1..pg_catalog.cardinality(v_requested_ids) loop
    select lane.resource_kind, lane.parent_lane_id
    into v_current_kind, v_current_parent_id
    from public.shooting_lanes as lane
    where lane.id = v_requested_ids[v_index];

    if not found
       or v_current_kind is distinct from v_expected_kinds[v_index]
       or (
         v_current_kind = 'lane'
         and (
           v_current_parent_id is not null
           or v_requested_ids[v_index] is distinct from v_expected_root_ids[v_index]
         )
       )
       or (
         v_current_kind = 'position'
         and (
           v_current_parent_id is distinct from v_expected_root_ids[v_index]
           or v_current_parent_id = v_requested_ids[v_index]
         )
       ) then
      raise exception 'Shooting-lane topology changed during locking.' using errcode = '55000';
    end if;
  end loop;

  for v_root_id in
    select root_record.root_id
    from pg_catalog.unnest(v_root_ids) as root_record(root_id)
    order by root_record.root_id
  loop
    select root.resource_kind, root.parent_lane_id
    into v_current_kind, v_current_parent_id
    from public.shooting_lanes as root
    where root.id = v_root_id;

    if not found
       or v_current_kind is distinct from 'lane'
       or v_current_parent_id is not null
       or exists (
         select 1
         from public.shooting_lanes as child
         where child.parent_lane_id = v_root_id
           and (
             child.id = v_root_id
             or child.resource_kind is distinct from 'position'
           )
       )
       or exists (
         select 1
         from public.shooting_lanes as child
         join public.shooting_lanes as grandchild
           on grandchild.parent_lane_id = child.id
         where child.parent_lane_id = v_root_id
       ) then
      raise exception 'Shooting-lane hierarchy changed during locking.' using errcode = '55000';
    end if;
  end loop;

  return query
  select
    v_requested_ids[index_record.index_value],
    v_expected_root_ids[index_record.index_value],
    v_expected_kinds[index_record.index_value],
    case v_expected_kinds[index_record.index_value]
      when 'lane' then (
        select pg_catalog.array_agg(
          scope_record.lane_id
          order by scope_record.scope_order, scope_record.lane_id
        )
        from (
          select v_expected_root_ids[index_record.index_value] as lane_id, 0 as scope_order
          union all
          select child.id, 1
          from public.shooting_lanes as child
          where child.parent_lane_id = v_expected_root_ids[index_record.index_value]
        ) as scope_record
      )
      else array[
        v_expected_root_ids[index_record.index_value],
        v_requested_ids[index_record.index_value]
      ]::uuid[]
    end
  from pg_catalog.generate_subscripts(v_requested_ids, 1) as index_record(index_value)
  order by
    v_expected_root_ids[index_record.index_value],
    v_requested_ids[index_record.index_value];
end;
$function$;

alter function public.lock_lane_conflict_families_v1(uuid[]) owner to postgres;
alter function public.lock_lane_conflict_families_v1(uuid[])
  set search_path to pg_catalog, public, pg_temp;

comment on function public.lock_lane_conflict_families_v1(uuid[]) is
  'Privately locks one or more lane-position conflict families in a global root-first order.';

revoke all on function public.lock_lane_conflict_families_v1(uuid[]) from public;
revoke all on function public.lock_lane_conflict_families_v1(uuid[]) from anon;
revoke all on function public.lock_lane_conflict_families_v1(uuid[]) from authenticated;
revoke all on function public.lock_lane_conflict_families_v1(uuid[]) from service_role;

do $postflight$
declare
  v_helper oid := pg_catalog.to_regprocedure(
    'public.lock_lane_conflict_families_v1(uuid[])'
  );
begin
  if v_helper is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'lock_lane_conflict_families_v1'
     ) <> 1 then
    raise exception 'Postflight failed: expected exactly one multi-family helper.';
  end if;

  if (
       select language_record.lanname <> 'plpgsql'
         or function_record.provolatile <> 'v'
         or function_record.prosecdef
         or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
         or function_record.proconfig is distinct from
              array['search_path=pg_catalog, public, pg_temp']::text[]
         or pg_catalog.pg_get_function_result(function_record.oid) <>
              'TABLE(requested_lane_id uuid, root_lane_id uuid, requested_resource_kind text, conflict_lane_ids uuid[])'
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_language as language_record
         on language_record.oid = function_record.prolang
       where function_record.oid = v_helper
     ) then
    raise exception 'Postflight failed: multi-family helper contract differs.';
  end if;

  if pg_catalog.has_function_privilege('anon', v_helper, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', v_helper, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_helper, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_helper
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Postflight failed: multi-family helper is not private.';
  end if;
end;
$postflight$;
