-- Additive hierarchy-aware availability. The existing v2 RPC remains unchanged.

do $preflight$
declare
  v_v2 oid := pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v2(uuid,date)'
  );
  v_v2_definition text;
begin
  if pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.lane_blocks') is null
     or pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_lanes') is null then
    raise exception 'Preflight failed: required availability tables are missing.';
  end if;

  if (
    select pg_catalog.count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'shooting_lanes'
      and (
        (column_name = 'id' and data_type = 'uuid' and is_nullable = 'NO')
        or (column_name = 'is_active' and data_type = 'boolean' and is_nullable = 'NO')
        or (column_name = 'resource_kind' and data_type = 'text' and is_nullable = 'NO')
        or (column_name = 'parent_lane_id' and data_type = 'uuid')
      )
  ) <> 4 then
    raise exception 'Preflight failed: shooting_lanes hierarchy columns differ.';
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
         and constraint_record.conname = 'shooting_lanes_parent_lane_id_fkey'
         and constraint_record.contype = 'f'
     )
     or not exists (
       select 1
       from pg_catalog.pg_trigger as trigger_record
       where trigger_record.tgrelid = 'public.shooting_lanes'::pg_catalog.regclass
         and trigger_record.tgname = 'validate_shooting_lane_hierarchy_trigger'
         and not trigger_record.tgisinternal
         and trigger_record.tgenabled <> 'D'
     ) then
    raise exception 'Preflight failed: shooting_lanes hierarchy protection differs.';
  end if;

  if pg_catalog.to_regclass('public.shooting_lanes_parent_lane_id_idx') is null
     or pg_catalog.to_regclass('public.reservations_no_overlapping_active_booking') is null
     or pg_catalog.to_regclass('public.lane_blocks_active_schedule_idx') is null
     or pg_catalog.to_regclass('public.event_lanes_lane_event_idx') is null then
    raise exception 'Preflight failed: required availability indexes are missing.';
  end if;

  if v_v2 is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'get_lane_booking_busy_ranges_v2'
     ) <> 1 then
    raise exception 'Preflight failed: expected exactly one availability v2 overload.';
  end if;

  if (
    select language_record.lanname <> 'sql'
      or function_record.provolatile <> 's'
      or not function_record.prosecdef
      or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
      or function_record.proconfig is distinct from
           array['search_path=pg_catalog, public, pg_temp']::text[]
      or pg_catalog.pg_get_function_identity_arguments(function_record.oid)
           <> 'p_lane_id uuid, p_reservation_date date'
      or pg_catalog.pg_get_function_result(function_record.oid)
           <> 'TABLE(start_time time without time zone, end_time time without time zone, busy_type text)'
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_v2
  ) then
    raise exception 'Preflight failed: availability v2 function contract differs.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated', v_v2, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_v2, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_v2, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           function_record.proacl,
           pg_catalog.acldefault('f', function_record.proowner)
         )
       ) as privilege_record
       where function_record.oid = v_v2
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Preflight failed: availability v2 ACL differs.';
  end if;

  select pg_catalog.lower(pg_catalog.pg_get_functiondef(v_v2))
  into v_v2_definition;

  if v_v2_definition !~ 'from[[:space:]]+public[.]reservations'
     or v_v2_definition !~ 'from[[:space:]]+public[.]lane_blocks'
     or v_v2_definition !~ 'from[[:space:]]+public[.]event_lanes'
     or v_v2_definition !~ 'reservation[.]lane_id[[:space:]]*=[[:space:]]*p_lane_id'
     or v_v2_definition !~ 'block[.]lane_id[[:space:]]*=[[:space:]]*p_lane_id'
     or v_v2_definition !~ 'event_lane[.]lane_id[[:space:]]*=[[:space:]]*p_lane_id' then
    raise exception 'Preflight failed: availability v2 source semantics differ.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.resolve_lane_conflict_scope_v1(uuid)'
     ) is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'resolve_lane_conflict_scope_v1'
     )
     or pg_catalog.to_regprocedure(
       'public.get_lane_booking_busy_ranges_v3(uuid,date)'
     ) is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'get_lane_booking_busy_ranges_v3'
     ) then
    raise exception 'Preflight failed: resolver v1 or availability v3 already exists.';
  end if;
end;
$preflight$;

create temporary table csk_lane_availability_v3_baseline (
  v2_definition_md5 text not null,
  v2_acl_md5 text not null,
  source_schema_md5 text not null,
  source_acl_md5 text not null
) on commit drop;

insert into pg_temp.csk_lane_availability_v3_baseline
select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
  )),
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(
        function_record.proacl,
        pg_catalog.acldefault('f', function_record.proowner)
      )
    ) as privilege_record
    where function_record.oid =
      'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
  ), '')),
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(source_record.definition, E'\n'
      order by source_record.definition)
    from (
      select 'column:' || class_record.relname || ':' || attribute_record.attname || ':' ||
        pg_catalog.format_type(attribute_record.atttypid, attribute_record.atttypmod) || ':' ||
        attribute_record.attnotnull::text as definition
      from pg_catalog.pg_class as class_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = class_record.relnamespace
      join pg_catalog.pg_attribute as attribute_record
        on attribute_record.attrelid = class_record.oid
       and attribute_record.attnum > 0
       and not attribute_record.attisdropped
      where namespace_record.nspname = 'public'
        and class_record.relname = any(array[
          'shooting_lanes','reservations','lane_blocks','events','event_lanes'
        ]::text[])

      union all

      select 'constraint:' || constraint_record.conrelid::pg_catalog.regclass::text || ':' ||
        constraint_record.conname || ':' ||
        pg_catalog.pg_get_constraintdef(constraint_record.oid, true)
      from pg_catalog.pg_constraint as constraint_record
      where constraint_record.conrelid = any(array[
        'public.shooting_lanes'::pg_catalog.regclass,
        'public.reservations'::pg_catalog.regclass,
        'public.lane_blocks'::pg_catalog.regclass,
        'public.events'::pg_catalog.regclass,
        'public.event_lanes'::pg_catalog.regclass
      ]::oid[])

      union all

      select 'index:' || index_record.schemaname || '.' || index_record.indexname || ':' ||
        index_record.indexdef
      from pg_catalog.pg_indexes as index_record
      where index_record.schemaname = 'public'
        and index_record.tablename = any(array[
          'shooting_lanes','reservations','lane_blocks','events','event_lanes'
        ]::text[])
    ) as source_record
  ), '')),
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      class_record.relname || ':' || privilege_record.grantee::text || ':' ||
        privilege_record.privilege_type,
      ',' order by class_record.relname, privilege_record.grantee,
        privilege_record.privilege_type
    )
    from pg_catalog.pg_class as class_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = class_record.relnamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(class_record.relacl, pg_catalog.acldefault('r', class_record.relowner))
    ) as privilege_record
    where namespace_record.nspname = 'public'
      and class_record.relname = any(array[
        'shooting_lanes','reservations','lane_blocks','events','event_lanes'
      ]::text[])
  ), ''));

create function public.resolve_lane_conflict_scope_v1(
  p_lane_id uuid
)
returns table (
  conflict_lane_id uuid,
  root_lane_id uuid
)
language plpgsql
stable
security invoker
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_requested_kind text;
  v_requested_parent_id uuid;
  v_requested_active boolean;
  v_root_id uuid;
  v_root_kind text;
  v_root_parent_id uuid;
  v_root_active boolean;
begin
  if p_lane_id is null then
    raise exception 'Lane identifier is required.' using errcode = '22023';
  end if;

  select lane.resource_kind, lane.parent_lane_id, lane.is_active
  into v_requested_kind, v_requested_parent_id, v_requested_active
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    raise exception 'Shooting-lane resource does not exist.' using errcode = 'P0002';
  end if;

  if v_requested_kind not in ('lane', 'position')
     or v_requested_kind is null then
    raise exception 'Malformed shooting-lane resource kind.' using errcode = '55000';
  end if;

  if not v_requested_active then
    raise exception 'Requested shooting-lane resource is inactive.' using errcode = '55000';
  end if;

  if v_requested_kind = 'lane' then
    if v_requested_parent_id is not null then
      raise exception 'Malformed top-level shooting lane.' using errcode = '55000';
    end if;
    v_root_id := p_lane_id;
    v_root_kind := v_requested_kind;
    v_root_parent_id := v_requested_parent_id;
    v_root_active := v_requested_active;
  else
    if v_requested_parent_id is null or v_requested_parent_id = p_lane_id then
      raise exception 'Malformed shooting-lane position parent.' using errcode = '55000';
    end if;

    select parent.resource_kind, parent.parent_lane_id, parent.is_active
    into v_root_kind, v_root_parent_id, v_root_active
    from public.shooting_lanes as parent
    where parent.id = v_requested_parent_id;

    if not found
       or v_root_kind <> 'lane'
       or v_root_parent_id is not null then
      raise exception 'Position parent must be a top-level shooting lane.'
        using errcode = '55000';
    end if;

    if not v_root_active then
      raise exception 'Position parent is inactive.' using errcode = '55000';
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

  if v_requested_kind = 'position' then
    return query
      select scope_record.conflict_lane_id, v_root_id
      from (
        values
          (v_root_id, 0),
          (p_lane_id, 1)
      ) as scope_record(conflict_lane_id, scope_order)
      order by scope_record.scope_order, scope_record.conflict_lane_id;
    return;
  end if;

  return query
    select scope_record.conflict_lane_id, v_root_id
    from (
      select v_root_id as conflict_lane_id, 0 as scope_order
      union all
      select child.id, 1
      from public.shooting_lanes as child
      where child.parent_lane_id = v_root_id
    ) as scope_record
    order by scope_record.scope_order, scope_record.conflict_lane_id;
end;
$function$;

alter function public.resolve_lane_conflict_scope_v1(uuid)
owner to postgres;

alter function public.resolve_lane_conflict_scope_v1(uuid)
set search_path to pg_catalog, public, pg_temp;

comment on function public.resolve_lane_conflict_scope_v1(uuid) is
  'Resolves the private parent-position conflict scope and fails closed for malformed or unavailable resources.';

revoke all on function public.resolve_lane_conflict_scope_v1(uuid) from public;
revoke all on function public.resolve_lane_conflict_scope_v1(uuid) from anon;
revoke all on function public.resolve_lane_conflict_scope_v1(uuid) from authenticated;
revoke all on function public.resolve_lane_conflict_scope_v1(uuid) from service_role;

create function public.get_lane_booking_busy_ranges_v3(
  p_lane_id uuid,
  p_reservation_date date
)
returns table (
  start_time time without time zone,
  end_time time without time zone,
  busy_type text
)
language plpgsql
stable
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
begin
  if p_reservation_date is null then
    raise exception 'Reservation date is required.' using errcode = '22023';
  end if;

  return query
  with conflict_scope as materialized (
    select scope_record.conflict_lane_id
    from public.resolve_lane_conflict_scope_v1(p_lane_id) as scope_record
  ),
  busy_ranges as (
    select
      reservation.start_time,
      reservation.end_time,
      'reservation'::text as busy_type
    from public.reservations as reservation
    join conflict_scope as scope_record
      on scope_record.conflict_lane_id = reservation.lane_id
    where reservation.reservation_date = p_reservation_date
      and reservation.booking_period && pg_catalog.tsrange(
        p_reservation_date::timestamp without time zone,
        (p_reservation_date + 1)::timestamp without time zone,
        '[)'
      )
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed',
          'no_show',
          'cancelled',
          'canceled',
          'cancelled_by_admin',
          'cancelled_by_user'
        )

    union all

    select
      block.start_time,
      block.end_time,
      'lane_block'::text as busy_type
    from public.lane_blocks as block
    join conflict_scope as scope_record
      on scope_record.conflict_lane_id = block.lane_id
    where block.block_date = p_reservation_date
      and block.is_active is true

    union all

    select
      event_record.start_time,
      event_record.end_time,
      'event'::text as busy_type
    from public.events as event_record
    where event_record.event_date = p_reservation_date
      and event_record.is_active is true
      and exists (
        select 1
        from public.event_lanes as event_lane
        join conflict_scope as scope_record
          on scope_record.conflict_lane_id = event_lane.lane_id
        where event_lane.event_id = event_record.id
      )
  )
  select
    busy_range.start_time,
    busy_range.end_time,
    busy_range.busy_type
  from busy_ranges as busy_range
  order by
    busy_range.start_time,
    busy_range.end_time,
    busy_range.busy_type;
end;
$function$;

alter function public.get_lane_booking_busy_ranges_v3(uuid, date)
owner to postgres;

alter function public.get_lane_booking_busy_ranges_v3(uuid, date)
set search_path to pg_catalog, public, pg_temp;

comment on function public.get_lane_booking_busy_ranges_v3(uuid, date) is
  'Returns hierarchy-aware typed busy ranges without identifiers or personal data.';

revoke all on function public.get_lane_booking_busy_ranges_v3(uuid, date) from public;
revoke all on function public.get_lane_booking_busy_ranges_v3(uuid, date) from anon;
revoke all on function public.get_lane_booking_busy_ranges_v3(uuid, date) from authenticated;
revoke all on function public.get_lane_booking_busy_ranges_v3(uuid, date) from service_role;

grant execute on function public.get_lane_booking_busy_ranges_v3(uuid, date)
to authenticated;
grant execute on function public.get_lane_booking_busy_ranges_v3(uuid, date)
to service_role;

do $postflight$
declare
  v_resolver oid := pg_catalog.to_regprocedure(
    'public.resolve_lane_conflict_scope_v1(uuid)'
  );
  v_v3 oid := pg_catalog.to_regprocedure(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'
  );
begin
  if v_resolver is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'resolve_lane_conflict_scope_v1'
     ) <> 1
     or v_v3 is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname = 'get_lane_booking_busy_ranges_v3'
     ) <> 1 then
    raise exception 'Postflight failed: expected one resolver and one v3 overload.';
  end if;

  if (
    select language_record.lanname <> 'plpgsql'
      or function_record.provolatile <> 's'
      or function_record.prosecdef
      or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
      or function_record.proconfig is distinct from
           array['search_path=pg_catalog, public, pg_temp']::text[]
      or pg_catalog.pg_get_function_result(function_record.oid)
           <> 'TABLE(conflict_lane_id uuid, root_lane_id uuid)'
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_resolver
  ) then
    raise exception 'Postflight failed: resolver contract differs.';
  end if;

  if (
    select language_record.lanname <> 'plpgsql'
      or function_record.provolatile <> 's'
      or not function_record.prosecdef
      or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
      or function_record.proconfig is distinct from
           array['search_path=pg_catalog, public, pg_temp']::text[]
      or pg_catalog.pg_get_function_result(function_record.oid)
           <> 'TABLE(start_time time without time zone, end_time time without time zone, busy_type text)'
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_v3
  ) then
    raise exception 'Postflight failed: availability v3 contract differs.';
  end if;

  if pg_catalog.has_function_privilege('anon', v_resolver, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', v_resolver, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_resolver, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_resolver
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Postflight failed: resolver has direct client EXECUTE.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated', v_v3, 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', v_v3, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_v3, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid = v_v3
         and privilege_record.grantee = 0
         and privilege_record.privilege_type = 'EXECUTE'
     ) then
    raise exception 'Postflight failed: availability v3 ACL differs.';
  end if;

  if pg_catalog.md5(pg_catalog.pg_get_functiondef(
       'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
     )) <> (
       select baseline.v2_definition_md5
       from pg_temp.csk_lane_availability_v3_baseline as baseline
     )
     or pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(
         privilege_record.grantee::text || ':' || privilege_record.privilege_type,
         ',' order by privilege_record.grantee, privilege_record.privilege_type
       )
       from pg_catalog.pg_proc as function_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
       ) as privilege_record
       where function_record.oid =
         'public.get_lane_booking_busy_ranges_v2(uuid,date)'::pg_catalog.regprocedure
     ), '')) <> (
       select baseline.v2_acl_md5
       from pg_temp.csk_lane_availability_v3_baseline as baseline
     ) then
    raise exception 'Postflight failed: availability v2 changed.';
  end if;

  if pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(source_record.definition, E'\n'
      order by source_record.definition)
    from (
      select 'column:' || class_record.relname || ':' || attribute_record.attname || ':' ||
        pg_catalog.format_type(attribute_record.atttypid, attribute_record.atttypmod) || ':' ||
        attribute_record.attnotnull::text as definition
      from pg_catalog.pg_class as class_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid = class_record.relnamespace
      join pg_catalog.pg_attribute as attribute_record
        on attribute_record.attrelid = class_record.oid
       and attribute_record.attnum > 0
       and not attribute_record.attisdropped
      where namespace_record.nspname = 'public'
        and class_record.relname = any(array[
          'shooting_lanes','reservations','lane_blocks','events','event_lanes'
        ]::text[])

      union all

      select 'constraint:' || constraint_record.conrelid::pg_catalog.regclass::text || ':' ||
        constraint_record.conname || ':' ||
        pg_catalog.pg_get_constraintdef(constraint_record.oid, true)
      from pg_catalog.pg_constraint as constraint_record
      where constraint_record.conrelid = any(array[
        'public.shooting_lanes'::pg_catalog.regclass,
        'public.reservations'::pg_catalog.regclass,
        'public.lane_blocks'::pg_catalog.regclass,
        'public.events'::pg_catalog.regclass,
        'public.event_lanes'::pg_catalog.regclass
      ]::oid[])

      union all

      select 'index:' || index_record.schemaname || '.' || index_record.indexname || ':' ||
        index_record.indexdef
      from pg_catalog.pg_indexes as index_record
      where index_record.schemaname = 'public'
        and index_record.tablename = any(array[
          'shooting_lanes','reservations','lane_blocks','events','event_lanes'
        ]::text[])
    ) as source_record
  ), '')) <> (
    select baseline.source_schema_md5
    from pg_temp.csk_lane_availability_v3_baseline as baseline
  ) then
    raise exception 'Postflight failed: source-table schema changed.';
  end if;

  if pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      class_record.relname || ':' || privilege_record.grantee::text || ':' ||
        privilege_record.privilege_type,
      ',' order by class_record.relname, privilege_record.grantee,
        privilege_record.privilege_type
    )
    from pg_catalog.pg_class as class_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = class_record.relnamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(class_record.relacl, pg_catalog.acldefault('r', class_record.relowner))
    ) as privilege_record
    where namespace_record.nspname = 'public'
      and class_record.relname = any(array[
        'shooting_lanes','reservations','lane_blocks','events','event_lanes'
      ]::text[])
  ), '')) <> (
    select baseline.source_acl_md5
    from pg_temp.csk_lane_availability_v3_baseline as baseline
  ) then
    raise exception 'Postflight failed: source-table ACL changed.';
  end if;
end;
$postflight$;

drop table pg_temp.csk_lane_availability_v3_baseline;
