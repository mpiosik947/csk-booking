-- Additive, dormant hierarchy-aware administration RPCs for lane blocks.
-- Existing direct table DML, RLS policies, grants, and triggers remain unchanged.

do $preflight$
declare
  v_signature text;
  v_expected_fingerprint text;
  v_function oid;
  v_actual_fingerprint text;
  v_hash text;
begin
  if pg_catalog.to_regclass('public.lane_blocks') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.events') is null
     or pg_catalog.to_regclass('public.event_lanes') is null
     or pg_catalog.to_regclass('public.profiles') is null then
    raise exception 'Preflight failed: required lane-block tables are missing.';
  end if;

  if (
       select pg_catalog.jsonb_agg(
         pg_catalog.jsonb_build_object(
           'ordinal', column_record.ordinal_position,
           'name', column_record.column_name,
           'type', column_record.udt_schema || '.' || column_record.udt_name,
           'nullable', column_record.is_nullable,
           'default', column_record.column_default
         )
         order by column_record.ordinal_position
       )
       from information_schema.columns as column_record
       where column_record.table_schema = 'public'
         and column_record.table_name = 'lane_blocks'
     ) is distinct from '[
       {"ordinal":1,"name":"id","type":"pg_catalog.uuid","nullable":"NO","default":"gen_random_uuid()"},
       {"ordinal":2,"name":"lane_id","type":"pg_catalog.uuid","nullable":"NO","default":null},
       {"ordinal":3,"name":"block_date","type":"pg_catalog.date","nullable":"NO","default":null},
       {"ordinal":4,"name":"start_time","type":"pg_catalog.time","nullable":"NO","default":null},
       {"ordinal":5,"name":"end_time","type":"pg_catalog.time","nullable":"NO","default":null},
       {"ordinal":6,"name":"reason","type":"pg_catalog.text","nullable":"YES","default":null},
       {"ordinal":7,"name":"created_at","type":"pg_catalog.timestamptz","nullable":"YES","default":"now()"},
       {"ordinal":8,"name":"is_active","type":"pg_catalog.bool","nullable":"NO","default":"true"}
     ]'::jsonb then
    raise exception 'Preflight failed: public.lane_blocks columns differ.';
  end if;

  if (
       select pg_catalog.jsonb_agg(
         pg_catalog.jsonb_build_object(
           'name', constraint_record.conname,
           'type', constraint_record.contype,
           'definition', pg_catalog.pg_get_constraintdef(
             constraint_record.oid,
             true
           )
         )
         order by constraint_record.conname
       )
       from pg_catalog.pg_constraint as constraint_record
       where constraint_record.conrelid =
         'public.lane_blocks'::pg_catalog.regclass
     ) is distinct from '[
       {"name":"lane_blocks_lane_id_fkey","type":"f","definition":"FOREIGN KEY (lane_id) REFERENCES shooting_lanes(id) ON DELETE RESTRICT"},
       {"name":"lane_blocks_pkey","type":"p","definition":"PRIMARY KEY (id)"},
       {"name":"lane_blocks_time_range_check","type":"c","definition":"CHECK (end_time > start_time)"}
     ]'::jsonb then
    raise exception 'Preflight failed: public.lane_blocks constraints differ.';
  end if;

  if pg_catalog.to_regclass('public.lane_blocks_active_schedule_idx') is null
     or pg_catalog.pg_get_indexdef(
          'public.lane_blocks_active_schedule_idx'::pg_catalog.regclass
        ) <> 'CREATE INDEX lane_blocks_active_schedule_idx ON public.lane_blocks USING btree (lane_id, block_date, is_active, start_time, end_time)' then
    raise exception 'Preflight failed: lane-block schedule index differs.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_class as table_record
       where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass
         and table_record.relrowsecurity
         and not table_record.relforcerowsecurity
         and pg_catalog.pg_get_userbyid(table_record.relowner) = 'postgres'
     ) then
    raise exception 'Preflight failed: lane-block owner or RLS state differs.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    policy_record.policyname || '|' || policy_record.permissive || '|' ||
    policy_record.roles::text || '|' || policy_record.cmd || '|' ||
    coalesce(policy_record.qual, '<null>') || '|' ||
    coalesce(policy_record.with_check, '<null>'),
    E'\n' order by policy_record.policyname
  ), ''))
  into v_hash
  from pg_catalog.pg_policies as policy_record
  where policy_record.schemaname = 'public'
    and policy_record.tablename = 'lane_blocks';

  if v_hash <> '5d2b1222a01f28927d9912b953e210a1' then
    raise exception
      'Preflight failed: lane-block RLS policies differ (expected %, actual %).',
      '5d2b1222a01f28927d9912b953e210a1',
      v_hash;
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    (case when privilege_record.grantee = 0 then 'PUBLIC'
          else pg_catalog.pg_get_userbyid(privilege_record.grantee) end) || '|' ||
    privilege_record.privilege_type || '|' ||
    privilege_record.is_grantable::text,
    E'\n' order by
      case when privilege_record.grantee = 0 then 'PUBLIC'
           else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
      privilege_record.privilege_type
  ), ''))
  into v_hash
  from pg_catalog.pg_class as table_record
  cross join lateral pg_catalog.aclexplode(coalesce(
    table_record.relacl,
    pg_catalog.acldefault('r', table_record.relowner)
  )) as privilege_record
  where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass;

  if v_hash <> 'a03ce94ab4abc5e8aab109765dfe682e' then
    raise exception 'Preflight failed: lane-block table ACL differs.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    trigger_record.tgname || '|' || trigger_record.tgenabled::text || '|' ||
    trigger_record.tgtype::text || '|' ||
    trigger_record.tgfoid::pg_catalog.regprocedure::text || '|' ||
    pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
    E'\n' order by trigger_record.tgname
  ), ''))
  into v_hash
  from pg_catalog.pg_trigger as trigger_record
  where trigger_record.tgrelid = 'public.lane_blocks'::pg_catalog.regclass
    and not trigger_record.tgisinternal;

  if v_hash <> '7bee80a61b291589ddcfc414afef1f96' then
    raise exception 'Preflight failed: lane-block trigger differs.';
  end if;

  for v_signature, v_expected_fingerprint in
    select baseline.signature, baseline.fingerprint
    from (values
      ('public.lock_lane_booking_configuration()'::text,
       '4ad32a3407b996f96b1329f2cc59c25a'::text),
      ('public.lock_lane_conflict_families_v1(uuid[])'::text,
       '0815401da8ad1f909c26622355c0db5f'::text),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::text,
       '893c71de856609d33240d1ebad37e86c'::text),
      ('public.get_lane_booking_busy_ranges_v3(uuid,date)'::text,
       'db4581c84792f5209fb76607942fecf2'::text)
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
      'config', coalesce(
        pg_catalog.to_jsonb(function_record.proconfig),
        '[]'::jsonb
      ),
      'acl', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'grantor', pg_catalog.pg_get_userbyid(privilege_record.grantor),
          'grantee', case when privilege_record.grantee = 0 then 'PUBLIC'
                          else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          'privilege', privilege_record.privilege_type,
          'grantable', privilege_record.is_grantable
        ) order by
          case when privilege_record.grantee = 0 then 'PUBLIC'
               else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          privilege_record.privilege_type,
          pg_catalog.pg_get_userbyid(privilege_record.grantor))
        from pg_catalog.aclexplode(coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )) as privilege_record
      ), '[]'::jsonb)
    )::text)
    into v_actual_fingerprint
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = function_record.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function;

    if v_actual_fingerprint is distinct from v_expected_fingerprint then
      raise exception 'Preflight failed: function % differs.', v_signature;
    end if;
  end loop;

  if exists (
       select 1
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname in (
           'admin_create_lane_block',
           'admin_update_lane_block',
           'admin_set_lane_block_active'
         )
     ) then
    raise exception 'Preflight failed: lane-block administration RPC already exists.';
  end if;
end;
$preflight$;

create function public.admin_create_lane_block(
  p_lane_id uuid,
  p_block_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_lane public.shooting_lanes%rowtype;
  v_conflict_lane_ids uuid[];
  v_requested_kind text;
  v_block_id uuid;
  v_constraint_name text;
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', null
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', null
    );
  end if;

  if p_lane_id is null
     or p_block_date is null
     or p_start_time is null
     or p_end_time is null
     or p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', null
    );
  end if;

  begin
    select scope_record.conflict_lane_ids,
           scope_record.requested_resource_kind
    into v_conflict_lane_ids, v_requested_kind
    from public.lock_lane_conflict_families_v1(
      array[p_lane_id]::uuid[]
    ) as scope_record
    where scope_record.requested_lane_id = p_lane_id;
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_lane',
        'lane_block_id', null
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_block_id', null
      );
    when sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_input',
        'lane_block_id', null
      );
  end;

  if v_conflict_lane_ids is null or v_requested_kind is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', null
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'lane_block_id', null
    );
  end if;

  if v_lane.resource_kind is distinct from v_requested_kind then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', null
    );
  end if;

  if not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'lane_block_id', null
    );
  end if;

  if exists (
    select 1
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = p_block_date
      and reservation.start_time < p_end_time
      and reservation.end_time > p_start_time
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_reservation',
      'lane_block_id', null
    );
  end if;

  if exists (
    select 1
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    where event_lane.lane_id = any(v_conflict_lane_ids)
      and event_record.is_active is true
      and event_record.event_date = p_block_date
      and event_record.start_time < p_end_time
      and event_record.end_time > p_start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_event',
      'lane_block_id', null
    );
  end if;

  begin
    insert into public.lane_blocks (
      lane_id,
      block_date,
      start_time,
      end_time,
      reason,
      is_active
    )
    values (
      p_lane_id,
      p_block_date,
      p_start_time,
      p_end_time,
      p_reason,
      true
    )
    returning id into v_block_id;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'lane_blocks_no_active_reservation_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_reservation',
          'lane_block_id', null
        );
      end if;

      if v_constraint_name = 'lane_blocks_no_active_event_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_event',
          'lane_block_id', null
        );
      end if;

      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'created',
    'lane_block_id', v_block_id
  );
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
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_original public.lane_blocks%rowtype;
  v_current public.lane_blocks%rowtype;
  v_lane public.shooting_lanes%rowtype;
  v_conflict_lane_ids uuid[];
  v_requested_kind text;
  v_constraint_name text;
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  if p_block_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', null
    );
  end if;

  select lane_block.*
  into v_original
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  if p_lane_id is null
     or p_block_date is null
     or p_start_time is null
     or p_end_time is null
     or p_is_active is null
     or p_end_time <= p_start_time then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    select scope_record.conflict_lane_ids,
           scope_record.requested_resource_kind
    into v_conflict_lane_ids, v_requested_kind
    from public.lock_lane_conflict_families_v1(
      array[v_original.lane_id, p_lane_id]::uuid[]
    ) as scope_record
    where scope_record.requested_lane_id = p_lane_id;
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_lane',
        'lane_block_id', p_block_id
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_block_id', p_block_id
      );
    when sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_input',
        'lane_block_id', p_block_id
      );
  end;

  if v_conflict_lane_ids is null or v_requested_kind is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  select lane_block.*
  into v_current
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  if v_current is distinct from v_original then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error',
      'lane_block_id', p_block_id
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = p_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if v_lane.resource_kind is distinct from v_requested_kind then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  if p_is_active and not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if p_is_active and exists (
    select 1
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = p_block_date
      and reservation.start_time < p_end_time
      and reservation.end_time > p_start_time
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_reservation',
      'lane_block_id', p_block_id
    );
  end if;

  if p_is_active and exists (
    select 1
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    where event_lane.lane_id = any(v_conflict_lane_ids)
      and event_record.is_active is true
      and event_record.event_date = p_block_date
      and event_record.start_time < p_end_time
      and event_record.end_time > p_start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_event',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    update public.lane_blocks
    set lane_id = p_lane_id,
        block_date = p_block_date,
        start_time = p_start_time,
        end_time = p_end_time,
        reason = p_reason,
        is_active = p_is_active
    where id = p_block_id;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'lane_blocks_no_active_reservation_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_reservation',
          'lane_block_id', p_block_id
        );
      end if;

      if v_constraint_name = 'lane_blocks_no_active_event_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_event',
          'lane_block_id', p_block_id
        );
      end if;

      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'lane_block_id', p_block_id
  );
end;
$function$;

create function public.admin_set_lane_block_active(
  p_block_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_original public.lane_blocks%rowtype;
  v_current public.lane_blocks%rowtype;
  v_lane public.shooting_lanes%rowtype;
  v_conflict_lane_ids uuid[];
  v_requested_kind text;
  v_constraint_name text;
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_role is null or v_actor_role not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'lane_block_id', p_block_id
    );
  end if;

  if p_block_id is null or p_is_active is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input',
      'lane_block_id', p_block_id
    );
  end if;

  select lane_block.*
  into v_original
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    select scope_record.conflict_lane_ids,
           scope_record.requested_resource_kind
    into v_conflict_lane_ids, v_requested_kind
    from public.lock_lane_conflict_families_v1(
      array[v_original.lane_id]::uuid[]
    ) as scope_record
    where scope_record.requested_lane_id = v_original.lane_id;
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_lane',
        'lane_block_id', p_block_id
      );
    when sqlstate '55000' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'lane_block_id', p_block_id
      );
    when sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_input',
        'lane_block_id', p_block_id
      );
  end;

  if v_conflict_lane_ids is null or v_requested_kind is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  select lane_block.*
  into v_current
  from public.lane_blocks as lane_block
  where lane_block.id = p_block_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'block_not_found',
      'lane_block_id', p_block_id
    );
  end if;

  if v_current is distinct from v_original then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'internal_error',
      'lane_block_id', p_block_id
    );
  end if;

  if v_current.is_active = p_is_active then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'lane_block_id', p_block_id
    );
  end if;

  if not p_is_active then
    update public.lane_blocks
    set is_active = false
    where id = p_block_id;

    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', true, 'code', 'deactivated',
      'lane_block_id', p_block_id
    );
  end if;

  select lane.*
  into v_lane
  from public.shooting_lanes as lane
  where lane.id = v_current.lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if v_lane.resource_kind is distinct from v_requested_kind then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'lane_block_id', p_block_id
    );
  end if;

  if not v_lane.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'inactive_lane',
      'lane_block_id', p_block_id
    );
  end if;

  if exists (
    select 1
    from public.reservations as reservation
    where reservation.lane_id = any(v_conflict_lane_ids)
      and reservation.reservation_date = v_current.block_date
      and reservation.start_time < v_current.end_time
      and reservation.end_time > v_current.start_time
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
        not in (
          'completed', 'no_show', 'cancelled', 'canceled',
          'cancelled_by_admin', 'cancelled_by_user'
        )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_reservation',
      'lane_block_id', p_block_id
    );
  end if;

  if exists (
    select 1
    from public.event_lanes as event_lane
    join public.events as event_record
      on event_record.id = event_lane.event_id
    where event_lane.lane_id = any(v_conflict_lane_ids)
      and event_record.is_active is true
      and event_record.event_date = v_current.block_date
      and event_record.start_time < v_current.end_time
      and event_record.end_time > v_current.start_time
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'conflict_event',
      'lane_block_id', p_block_id
    );
  end if;

  begin
    update public.lane_blocks
    set is_active = true
    where id = p_block_id;
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name = 'lane_blocks_no_active_reservation_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_reservation',
          'lane_block_id', p_block_id
        );
      end if;

      if v_constraint_name = 'lane_blocks_no_active_event_overlap' then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'conflict_event',
          'lane_block_id', p_block_id
        );
      end if;

      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'activated',
    'lane_block_id', p_block_id
  );
end;
$function$;

alter function public.admin_create_lane_block(
  uuid,date,time without time zone,time without time zone,text
) owner to postgres;
alter function public.admin_update_lane_block(
  uuid,uuid,date,time without time zone,time without time zone,text,boolean
) owner to postgres;
alter function public.admin_set_lane_block_active(uuid,boolean)
owner to postgres;

comment on function public.admin_create_lane_block(
  uuid,date,time without time zone,time without time zone,text
) is 'Creates one active lane block after hierarchy-aware reservation and event conflict checks.';
comment on function public.admin_update_lane_block(
  uuid,uuid,date,time without time zone,time without time zone,text,boolean
) is 'Updates one lane block under globally ordered old/new hierarchy family locks.';
comment on function public.admin_set_lane_block_active(uuid,boolean) is
  'Activates or deactivates one lane block under a hierarchy-aware family lock.';

revoke all on function public.admin_create_lane_block(
  uuid,date,time without time zone,time without time zone,text
) from public;
revoke all on function public.admin_create_lane_block(
  uuid,date,time without time zone,time without time zone,text
) from anon;
revoke all on function public.admin_create_lane_block(
  uuid,date,time without time zone,time without time zone,text
) from authenticated;
revoke all on function public.admin_create_lane_block(
  uuid,date,time without time zone,time without time zone,text
) from service_role;
grant execute on function public.admin_create_lane_block(
  uuid,date,time without time zone,time without time zone,text
) to authenticated;

revoke all on function public.admin_update_lane_block(
  uuid,uuid,date,time without time zone,time without time zone,text,boolean
) from public;
revoke all on function public.admin_update_lane_block(
  uuid,uuid,date,time without time zone,time without time zone,text,boolean
) from anon;
revoke all on function public.admin_update_lane_block(
  uuid,uuid,date,time without time zone,time without time zone,text,boolean
) from authenticated;
revoke all on function public.admin_update_lane_block(
  uuid,uuid,date,time without time zone,time without time zone,text,boolean
) from service_role;
grant execute on function public.admin_update_lane_block(
  uuid,uuid,date,time without time zone,time without time zone,text,boolean
) to authenticated;

revoke all on function public.admin_set_lane_block_active(uuid,boolean)
from public;
revoke all on function public.admin_set_lane_block_active(uuid,boolean)
from anon;
revoke all on function public.admin_set_lane_block_active(uuid,boolean)
from authenticated;
revoke all on function public.admin_set_lane_block_active(uuid,boolean)
from service_role;
grant execute on function public.admin_set_lane_block_active(uuid,boolean)
to authenticated;

do $postflight$
declare
  v_signature text;
  v_expected_fingerprint text;
  v_function oid;
  v_actual_fingerprint text;
  v_hash text;
  v_definition text;
begin
  for v_signature in
    select expected.signature
    from (values
      ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::text),
      ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::text),
      ('public.admin_set_lane_block_active(uuid,boolean)'::text)
    ) as expected(signature)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

    if v_function is null then
      raise exception 'Postflight failed: function % is missing.', v_signature;
    end if;

    select pg_catalog.pg_get_functiondef(function_record.oid)
    into v_definition
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function
      and language_record.lanname = 'plpgsql'
      and function_record.provolatile = 'v'
      and function_record.prosecdef
      and pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
      and function_record.proconfig is not distinct from
        array['search_path=pg_catalog, public, pg_temp']::text[]
      and pg_catalog.pg_get_function_result(function_record.oid) = 'jsonb';

    if v_definition is null
       or v_definition !~ 'auth[.]uid[(][)]'
       or v_definition !~ 'from[[:space:]]+public[.]profiles'
       or v_definition !~ 'lock_lane_conflict_families_v1'
       or v_definition ~* '[[:<:]]execute[[:>:]]'
       or pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
       or not pg_catalog.has_function_privilege(
         'authenticated', v_function, 'EXECUTE'
       )
       or pg_catalog.has_function_privilege(
         'service_role', v_function, 'EXECUTE'
       )
       or exists (
         select 1
         from pg_catalog.pg_proc as function_record
         cross join lateral pg_catalog.aclexplode(coalesce(
           function_record.proacl,
           pg_catalog.acldefault('f', function_record.proowner)
         )) as privilege_record
         where function_record.oid = v_function
           and privilege_record.grantee = 0
           and privilege_record.privilege_type = 'EXECUTE'
       ) then
      raise exception 'Postflight failed: function % contract differs.',
        v_signature;
    end if;
  end loop;

  if (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as function_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = function_record.pronamespace
       where namespace_record.nspname = 'public'
         and function_record.proname in (
           'admin_create_lane_block',
           'admin_update_lane_block',
           'admin_set_lane_block_active'
         )
     ) <> 3 then
    raise exception 'Postflight failed: unexpected lane-block RPC overloads.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    policy_record.policyname || '|' || policy_record.permissive || '|' ||
    policy_record.roles::text || '|' || policy_record.cmd || '|' ||
    coalesce(policy_record.qual, '<null>') || '|' ||
    coalesce(policy_record.with_check, '<null>'),
    E'\n' order by policy_record.policyname
  ), ''))
  into v_hash
  from pg_catalog.pg_policies as policy_record
  where policy_record.schemaname = 'public'
    and policy_record.tablename = 'lane_blocks';

  if v_hash <> '5d2b1222a01f28927d9912b953e210a1' then
    raise exception 'Postflight failed: lane-block RLS policies changed.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    (case when privilege_record.grantee = 0 then 'PUBLIC'
          else pg_catalog.pg_get_userbyid(privilege_record.grantee) end) || '|' ||
    privilege_record.privilege_type || '|' ||
    privilege_record.is_grantable::text,
    E'\n' order by
      case when privilege_record.grantee = 0 then 'PUBLIC'
           else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
      privilege_record.privilege_type
  ), ''))
  into v_hash
  from pg_catalog.pg_class as table_record
  cross join lateral pg_catalog.aclexplode(coalesce(
    table_record.relacl,
    pg_catalog.acldefault('r', table_record.relowner)
  )) as privilege_record
  where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass;

  if v_hash <> 'a03ce94ab4abc5e8aab109765dfe682e' then
    raise exception 'Postflight failed: lane-block table ACL changed.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    trigger_record.tgname || '|' || trigger_record.tgenabled::text || '|' ||
    trigger_record.tgtype::text || '|' ||
    trigger_record.tgfoid::pg_catalog.regprocedure::text || '|' ||
    pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
    E'\n' order by trigger_record.tgname
  ), ''))
  into v_hash
  from pg_catalog.pg_trigger as trigger_record
  where trigger_record.tgrelid = 'public.lane_blocks'::pg_catalog.regclass
    and not trigger_record.tgisinternal;

  if v_hash <> '7bee80a61b291589ddcfc414afef1f96' then
    raise exception 'Postflight failed: lane-block trigger changed.';
  end if;

  for v_signature, v_expected_fingerprint in
    select baseline.signature, baseline.fingerprint
    from (values
      ('public.lock_lane_booking_configuration()'::text,
       '4ad32a3407b996f96b1329f2cc59c25a'::text),
      ('public.lock_lane_conflict_families_v1(uuid[])'::text,
       '0815401da8ad1f909c26622355c0db5f'::text),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::text,
       '893c71de856609d33240d1ebad37e86c'::text),
      ('public.get_lane_booking_busy_ranges_v3(uuid,date)'::text,
       'db4581c84792f5209fb76607942fecf2'::text)
    ) as baseline(signature, fingerprint)
  loop
    v_function := pg_catalog.to_regprocedure(v_signature);

    select pg_catalog.md5(pg_catalog.jsonb_build_object(
      'definition', pg_catalog.pg_get_functiondef(function_record.oid),
      'owner', owner_role.rolname,
      'language', language_record.lanname,
      'volatility', function_record.provolatile,
      'security_definer', function_record.prosecdef,
      'config', coalesce(
        pg_catalog.to_jsonb(function_record.proconfig),
        '[]'::jsonb
      ),
      'acl', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'grantor', pg_catalog.pg_get_userbyid(privilege_record.grantor),
          'grantee', case when privilege_record.grantee = 0 then 'PUBLIC'
                          else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          'privilege', privilege_record.privilege_type,
          'grantable', privilege_record.is_grantable
        ) order by
          case when privilege_record.grantee = 0 then 'PUBLIC'
               else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          privilege_record.privilege_type,
          pg_catalog.pg_get_userbyid(privilege_record.grantor))
        from pg_catalog.aclexplode(coalesce(
          function_record.proacl,
          pg_catalog.acldefault('f', function_record.proowner)
        )) as privilege_record
      ), '[]'::jsonb)
    )::text)
    into v_actual_fingerprint
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = function_record.proowner
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid = v_function;

    if v_actual_fingerprint is distinct from v_expected_fingerprint then
      raise exception 'Postflight failed: function % changed.', v_signature;
    end if;
  end loop;
end;
$postflight$;
