\set ON_ERROR_STOP on

-- Contract test for psql. The migration and all [TEST][6B-4B2] fixtures are
-- enclosed in one transaction and removed by the final ROLLBACK.
begin;

do $clean_preflight$
begin
  if pg_catalog.to_regprocedure(
       'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
     ) is not null
     or pg_catalog.to_regprocedure(
       'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
     ) is not null
     or pg_catalog.to_regprocedure(
       'public.admin_set_lane_block_active(uuid,boolean)'
     ) is not null
     or exists (
       select 1 from public.shooting_lanes
       where name like '[TEST][6B-4B2]%'
     )
     or exists (
       select 1 from public.lane_blocks
       where reason like '[TEST][6B-4B2]%'
     )
     or exists (
       select 1 from public.events
       where title like '[TEST][6B-4B2]%'
     )
     or exists (
       select 1 from public.reservations
       where reservation_note = '[TEST][6B-4B2]'
     )
     or exists (
       select 1 from auth.users
       where email like 'test-6b4b2-%@example.invalid'
     ) then
    raise exception 'Unexpected prior 6B-4B2 objects or fixtures.';
  end if;
end;
$clean_preflight$;

\ir ../migrations/20260809130000_add_hierarchy_aware_lane_block_rpcs.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(
  p_test_order integer,
  p_test_name text,
  p_passed boolean,
  p_result text
)
returns void
language sql
as $function$
  insert into pg_temp.test_results(test_order, test_name, passed, result)
  values (p_test_order, p_test_name, coalesce(p_passed, false), p_result);
$function$;

create function pg_temp.function_fingerprint(p_function oid)
returns text
language sql
stable
as $function$
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
  from pg_catalog.pg_proc as function_record
  join pg_catalog.pg_roles as owner_role
    on owner_role.oid = function_record.proowner
  join pg_catalog.pg_language as language_record
    on language_record.oid = function_record.prolang
  where function_record.oid = p_function;
$function$;

create function pg_temp.call_create_block(
  p_user_id uuid,
  p_lane_id uuid,
  p_block_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_reason text
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', p_user_id::text, true
  );
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_create_lane_block(
    p_lane_id, p_block_date, p_start_time, p_end_time, p_reason
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_update_block(
  p_user_id uuid,
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
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', p_user_id::text, true
  );
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_update_lane_block(
    p_block_id, p_lane_id, p_block_date, p_start_time, p_end_time,
    p_reason, p_is_active
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_set_block_active(
  p_user_id uuid,
  p_block_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', p_user_id::text, true
  );
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_set_lane_block_active(
    p_block_id, p_is_active
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_reservation_v2(
  p_user_id uuid,
  p_lane_id uuid,
  p_reservation_date date,
  p_request_id uuid
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claim.sub', p_user_id::text, true
  );
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', p_user_id,
      'role', 'authenticated'
    )::text,
    true
  );
  execute 'set local role authenticated';
  select public.create_reservation_v2(
    p_lane_id,
    p_reservation_date,
    time '10:00',
    60,
    1,
    p_request_id,
    '[TEST][6B-4B2]'
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $fixtures$
declare
  v_lane uuid;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    ('6b4b2000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4b2-admin@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    ('6b4b2000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4b2-employee@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    ('6b4b2000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4b2-instructor@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    ('6b4b2000-0000-4000-8000-000000000004','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4b2-user@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    ('6b4b2000-0000-4000-8000-000000000005','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4b2-reservation@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
        when '6b4b2000-0000-4000-8000-000000000001'::uuid then 'admin'
        when '6b4b2000-0000-4000-8000-000000000002'::uuid then 'pracownik'
        when '6b4b2000-0000-4000-8000-000000000003'::uuid then 'instruktor'
        else 'user'
      end,
      first_name = '[TEST]',
      last_name = '6B-4B2',
      full_name = '[TEST][6B-4B2]',
      email = 'test-6b4b2-profile@example.invalid',
      phone = '000000000',
      verification_status = 'verified'
  where user_id in (
    '6b4b2000-0000-4000-8000-000000000001',
    '6b4b2000-0000-4000-8000-000000000002',
    '6b4b2000-0000-4000-8000-000000000003',
    '6b4b2000-0000-4000-8000-000000000004',
    '6b4b2000-0000-4000-8000-000000000005'
  );

  if (
       select pg_catalog.count(*)
       from public.profiles
       where user_id in (
         '6b4b2000-0000-4000-8000-000000000001',
         '6b4b2000-0000-4000-8000-000000000002',
         '6b4b2000-0000-4000-8000-000000000003',
         '6b4b2000-0000-4000-8000-000000000004',
         '6b4b2000-0000-4000-8000-000000000005'
       )
     ) <> 5 then
    raise exception 'Synthetic profiles were not created.';
  end if;

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values
    ('6b4b2000-0000-4000-8000-000000000101','[TEST][6B-4B2][STANDALONE]','[TEST]','[TEST]',10,true,5,60,9810,'PLN','lane',null,true,false),
    ('6b4b2000-0000-4000-8000-000000000201','[TEST][6B-4B2][ROOT-A]','[TEST]','[TEST]',10,true,5,60,9820,'PLN','lane',null,true,true),
    ('6b4b2000-0000-4000-8000-000000000202','[TEST][6B-4B2][A-1]','[TEST]','[TEST]',10,true,5,60,9821,'PLN','position','6b4b2000-0000-4000-8000-000000000201',false,false),
    ('6b4b2000-0000-4000-8000-000000000203','[TEST][6B-4B2][A-2]','[TEST]','[TEST]',10,true,5,60,9822,'PLN','position','6b4b2000-0000-4000-8000-000000000201',false,false),
    ('6b4b2000-0000-4000-8000-000000000301','[TEST][6B-4B2][ROOT-B]','[TEST]','[TEST]',10,true,5,60,9830,'PLN','lane',null,true,true),
    ('6b4b2000-0000-4000-8000-000000000302','[TEST][6B-4B2][B-1]','[TEST]','[TEST]',10,true,5,60,9831,'PLN','position','6b4b2000-0000-4000-8000-000000000301',false,false),
    ('6b4b2000-0000-4000-8000-000000000303','[TEST][6B-4B2][B-2]','[TEST]','[TEST]',10,true,5,60,9832,'PLN','position','6b4b2000-0000-4000-8000-000000000301',false,false),
    ('6b4b2000-0000-4000-8000-000000000401','[TEST][6B-4B2][INACTIVE]','[TEST]','[TEST]',10,false,5,60,9840,'PLN','lane',null,true,false),
    ('6b4b2000-0000-4000-8000-000000000402','[TEST][6B-4B2][LATER-INACTIVE]','[TEST]','[TEST]',10,true,5,60,9841,'PLN','lane',null,true,false);

  insert into public.lane_booking_rules(
    lane_id, online_bookable, max_people_online
  )
  select lane.id, true, lane.max_shooters
  from public.shooting_lanes as lane
  where lane.name like '[TEST][6B-4B2]%'
    and lane.is_active;

  insert into public.lane_booking_durations(
    lane_id, duration_minutes, display_order, is_active
  )
  select lane.id, 60, 1, true
  from public.shooting_lanes as lane
  where lane.name like '[TEST][6B-4B2]%'
    and lane.is_active;

  for v_lane in
    select lane.id
    from public.shooting_lanes as lane
    where lane.name like '[TEST][6B-4B2]%'
      and lane.is_active
  loop
    insert into public.lane_pricing_rules(
      lane_id, day_group, min_shooters, max_shooters,
      label, hourly_price, display_order, is_active
    ) values
      (v_lane,'mon_thu',1,5,'[TEST][6B-4B2]',10,1,true),
      (v_lane,'fri_sun',1,5,'[TEST][6B-4B2]',10,1,true);
  end loop;
end;
$fixtures$;

do $contract_tests$
declare
  v_base_date date := current_date + 7000;
  v_admin constant uuid := '6b4b2000-0000-4000-8000-000000000001';
  v_employee constant uuid := '6b4b2000-0000-4000-8000-000000000002';
  v_instructor constant uuid := '6b4b2000-0000-4000-8000-000000000003';
  v_user constant uuid := '6b4b2000-0000-4000-8000-000000000004';
  v_reservation_user constant uuid := '6b4b2000-0000-4000-8000-000000000005';
  v_standalone constant uuid := '6b4b2000-0000-4000-8000-000000000101';
  v_root_a constant uuid := '6b4b2000-0000-4000-8000-000000000201';
  v_a1 constant uuid := '6b4b2000-0000-4000-8000-000000000202';
  v_a2 constant uuid := '6b4b2000-0000-4000-8000-000000000203';
  v_root_b constant uuid := '6b4b2000-0000-4000-8000-000000000301';
  v_b1 constant uuid := '6b4b2000-0000-4000-8000-000000000302';
  v_inactive constant uuid := '6b4b2000-0000-4000-8000-000000000401';
  v_later_inactive constant uuid := '6b4b2000-0000-4000-8000-000000000402';
  v_missing constant uuid := '6b4b2000-0000-4000-8000-000000009999';
  v_result jsonb;
  v_result2 jsonb;
  v_block_id uuid;
  v_block_id2 uuid;
  v_event_id uuid;
  v_definition text;
  v_passed boolean;
begin
  -- A. Standalone create.
  v_result := pg_temp.call_create_block(
    v_admin, v_standalone, v_base_date, time '10:00', time '11:00',
    '[TEST][6B-4B2][A]'
  );
  perform pg_temp.record_result(1, 'A. Create standalone block',
    v_result->>'code' = 'created'
    and (v_result->>'changed')::boolean
    and exists (
      select 1 from public.lane_blocks
      where id = (v_result->>'lane_block_id')::uuid
        and lane_id = v_standalone
        and is_active
    ),
    'Admin creates one active standalone block.');

  -- B. Parent block conflicts with child reservation.
  v_result := pg_temp.call_reservation_v2(
    v_reservation_user, v_a1, v_base_date + 1,
    '6b4b2000-0000-4000-8000-000000001001'
  );
  v_result2 := pg_temp.call_create_block(
    v_admin, v_root_a, v_base_date + 1, time '10:00', time '11:00',
    '[TEST][6B-4B2][B]'
  );
  perform pg_temp.record_result(2, 'B. Parent block conflicts with child reservation',
    v_result->>'code' = 'created'
    and v_result2->>'code' = 'conflict_reservation',
    'Parent scope includes the reserved child.');

  -- C. Child block conflicts with parent reservation.
  v_result := pg_temp.call_reservation_v2(
    v_reservation_user, v_root_a, v_base_date + 2,
    '6b4b2000-0000-4000-8000-000000001002'
  );
  v_result2 := pg_temp.call_create_block(
    v_admin, v_a1, v_base_date + 2, time '10:00', time '11:00',
    '[TEST][6B-4B2][C]'
  );
  perform pg_temp.record_result(3, 'C. Child block conflicts with parent reservation',
    v_result->>'code' = 'created'
    and v_result2->>'code' = 'conflict_reservation',
    'Child scope includes its parent.');

  -- D. Sibling reservation does not block a child.
  v_result := pg_temp.call_reservation_v2(
    v_reservation_user, v_a2, v_base_date + 3,
    '6b4b2000-0000-4000-8000-000000001003'
  );
  v_result2 := pg_temp.call_create_block(
    v_admin, v_a1, v_base_date + 3, time '10:00', time '11:00',
    '[TEST][6B-4B2][D]'
  );
  perform pg_temp.record_result(4, 'D. Sibling reservation remains independent',
    v_result->>'code' = 'created' and v_result2->>'code' = 'created',
    'Sibling child is outside the requested child scope.');

  -- E-H. Event hierarchy semantics.
  insert into public.events(
    title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values (
    '[TEST][6B-4B2][E]', v_base_date + 4,
    time '10:00', time '11:00', 0, 5, true
  ) returning id into v_event_id;
  insert into public.event_lanes(event_id, lane_id)
  values (v_event_id, v_a1);
  v_result := pg_temp.call_create_block(
    v_admin, v_root_a, v_base_date + 4, time '10:00', time '11:00',
    '[TEST][6B-4B2][E]'
  );
  perform pg_temp.record_result(5, 'E. Parent block conflicts with child event',
    v_result->>'code' = 'conflict_event',
    'Parent scope sees the child event.');

  insert into public.events(
    title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values (
    '[TEST][6B-4B2][F]', v_base_date + 5,
    time '10:00', time '11:00', 0, 5, true
  ) returning id into v_event_id;
  insert into public.event_lanes(event_id, lane_id)
  values (v_event_id, v_root_a);
  v_result := pg_temp.call_create_block(
    v_admin, v_a1, v_base_date + 5, time '10:00', time '11:00',
    '[TEST][6B-4B2][F]'
  );
  perform pg_temp.record_result(6, 'F. Child block conflicts with parent event',
    v_result->>'code' = 'conflict_event',
    'Child scope sees the parent event.');

  insert into public.events(
    title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values (
    '[TEST][6B-4B2][G]', v_base_date + 6,
    time '10:00', time '11:00', 0, 5, true
  ) returning id into v_event_id;
  insert into public.event_lanes(event_id, lane_id)
  values (v_event_id, v_a2);
  v_result := pg_temp.call_create_block(
    v_admin, v_a1, v_base_date + 6, time '10:00', time '11:00',
    '[TEST][6B-4B2][G]'
  );
  perform pg_temp.record_result(7, 'G. Sibling event remains independent',
    v_result->>'code' = 'created',
    'Sibling event is outside the requested child scope.');

  insert into public.events(
    title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values (
    '[TEST][6B-4B2][H]', v_base_date + 7,
    time '10:00', time '11:00', 0, 5, true
  );
  v_result := pg_temp.call_create_block(
    v_admin, v_a1, v_base_date + 7, time '10:00', time '11:00',
    '[TEST][6B-4B2][H]'
  );
  perform pg_temp.record_result(8, 'H. Global event is ignored',
    v_result->>'code' = 'created',
    'Event without event_lanes is informational only.');

  -- I-M. Active-resource and role authorization.
  v_result := pg_temp.call_create_block(
    v_admin, v_inactive, v_base_date + 8, time '10:00', time '11:00',
    '[TEST][6B-4B2][I]'
  );
  perform pg_temp.record_result(9, 'I. Inactive lane is rejected',
    v_result->>'code' = 'inactive_lane',
    'New active blocks require an active requested resource.');

  v_result := pg_temp.call_create_block(
    v_user, v_standalone, v_base_date + 9, time '10:00', time '11:00',
    '[TEST][6B-4B2][J]'
  );
  perform pg_temp.record_result(10, 'J. User is not allowed',
    v_result->>'code' = 'not_allowed',
    'Regular user cannot call administration RPCs.');

  v_result := pg_temp.call_create_block(
    v_instructor, v_standalone, v_base_date + 10,
    time '10:00', time '11:00', '[TEST][6B-4B2][K]'
  );
  perform pg_temp.record_result(11, 'K. Instructor is not allowed',
    v_result->>'code' = 'not_allowed',
    'Instructor cannot call administration RPCs.');

  v_result := pg_temp.call_create_block(
    v_employee, v_standalone, v_base_date + 11,
    time '10:00', time '11:00', '[TEST][6B-4B2][L]'
  );
  perform pg_temp.record_result(12, 'L. Employee is allowed',
    v_result->>'code' = 'created',
    'Pracownik can create a block.');

  v_result := pg_temp.call_create_block(
    v_admin, v_standalone, v_base_date + 12,
    time '10:00', time '11:00', '[TEST][6B-4B2][M]'
  );
  perform pg_temp.record_result(13, 'M. Admin is allowed',
    v_result->>'code' = 'created',
    'Admin can create a block.');

  -- N. Update inside one family.
  v_result := pg_temp.call_create_block(
    v_admin, v_a1, v_base_date + 13,
    time '10:00', time '11:00', '[TEST][6B-4B2][N-OLD]'
  );
  v_block_id := (v_result->>'lane_block_id')::uuid;
  v_result := pg_temp.call_update_block(
    v_admin, v_block_id, v_a2, v_base_date + 13,
    time '11:00', time '12:00', '[TEST][6B-4B2][N-NEW]', true
  );
  perform pg_temp.record_result(14, 'N. Update inside one family',
    v_result->>'code' = 'updated'
    and exists (
      select 1 from public.lane_blocks
      where id = v_block_id and lane_id = v_a2
        and start_time = time '11:00' and is_active
    ),
    'Old and new sibling resources are locked through one family.');

  -- O. Update across roots.
  v_result := pg_temp.call_create_block(
    v_admin, v_a1, v_base_date + 14,
    time '10:00', time '11:00', '[TEST][6B-4B2][O-OLD]'
  );
  v_block_id := (v_result->>'lane_block_id')::uuid;
  v_result := pg_temp.call_update_block(
    v_admin, v_block_id, v_b1, v_base_date + 14,
    time '10:00', time '11:00', '[TEST][6B-4B2][O-NEW]', true
  );
  perform pg_temp.record_result(15, 'O. Update across two roots',
    v_result->>'code' = 'updated'
    and exists (
      select 1 from public.lane_blocks
      where id = v_block_id and lane_id = v_b1
    ),
    'Multi-family helper owns global old/new root ordering.');

  -- P. Activation reservation conflict.
  insert into public.lane_blocks(
    lane_id, block_date, start_time, end_time, reason, is_active
  ) values (
    v_root_a, v_base_date + 15, time '10:00', time '11:00',
    '[TEST][6B-4B2][P]', false
  ) returning id into v_block_id;
  v_result := pg_temp.call_reservation_v2(
    v_reservation_user, v_a1, v_base_date + 15,
    '6b4b2000-0000-4000-8000-000000001015'
  );
  v_result2 := pg_temp.call_set_block_active(v_admin, v_block_id, true);
  perform pg_temp.record_result(16, 'P. Activation detects reservation conflict',
    v_result->>'code' = 'created'
    and v_result2->>'code' = 'conflict_reservation'
    and not (select is_active from public.lane_blocks where id = v_block_id),
    'Failed activation leaves the block inactive.');

  -- Q. Activation event conflict.
  insert into public.lane_blocks(
    lane_id, block_date, start_time, end_time, reason, is_active
  ) values (
    v_root_a, v_base_date + 16, time '10:00', time '11:00',
    '[TEST][6B-4B2][Q]', false
  ) returning id into v_block_id;
  insert into public.events(
    title, event_date, start_time, end_time,
    price, max_participants, is_active
  ) values (
    '[TEST][6B-4B2][Q]', v_base_date + 16,
    time '10:00', time '11:00', 0, 5, true
  ) returning id into v_event_id;
  insert into public.event_lanes(event_id, lane_id)
  values (v_event_id, v_a1);
  v_result := pg_temp.call_set_block_active(v_admin, v_block_id, true);
  perform pg_temp.record_result(17, 'Q. Activation detects event conflict',
    v_result->>'code' = 'conflict_event'
    and not (select is_active from public.lane_blocks where id = v_block_id),
    'Failed activation leaves the block inactive.');

  -- R-S. Deactivation and idempotent active state.
  v_result := pg_temp.call_create_block(
    v_admin, v_standalone, v_base_date + 17,
    time '10:00', time '11:00', '[TEST][6B-4B2][R]'
  );
  v_block_id := (v_result->>'lane_block_id')::uuid;
  v_result := pg_temp.call_set_block_active(v_admin, v_block_id, false);
  perform pg_temp.record_result(18, 'R. Deactivation succeeds',
    v_result->>'code' = 'deactivated'
    and (v_result->>'changed')::boolean
    and not (select is_active from public.lane_blocks where id = v_block_id),
    'Deactivation performs no reservation or event mutation.');

  v_result := pg_temp.call_set_block_active(v_admin, v_block_id, false);
  v_passed := v_result->>'code' = 'no_change'
    and not (v_result->>'changed')::boolean;
  v_result := pg_temp.call_set_block_active(v_admin, v_block_id, true);
  v_passed := v_passed and v_result->>'code' = 'activated';
  v_result := pg_temp.call_set_block_active(v_admin, v_block_id, true);
  perform pg_temp.record_result(19, 'S. Repeated state changes are idempotent',
    v_passed and v_result->>'code' = 'no_change'
    and not (v_result->>'changed')::boolean,
    'Repeated activation and deactivation return no_change.');

  -- T-U. Missing target and malformed input.
  v_result := pg_temp.call_set_block_active(v_admin, v_missing, true);
  perform pg_temp.record_result(20, 'T. Missing block is controlled',
    v_result->>'code' = 'block_not_found',
    'Unknown block identifier does not raise raw SQL.');

  v_result := pg_temp.call_create_block(
    v_admin, v_standalone, null, time '11:00', time '10:00',
    '[TEST][6B-4B2][U]'
  );
  perform pg_temp.record_result(21, 'U. Malformed input is controlled',
    v_result->>'code' = 'invalid_input',
    'NULL date and reverse range return invalid_input.');

  -- V. Exact safe JSON response contract.
  v_result := pg_temp.call_create_block(
    v_admin, v_standalone, v_base_date + 18,
    time '10:00', time '11:00', '[TEST][6B-4B2][V]'
  );
  perform pg_temp.record_result(22, 'V. Exact return and error contract',
    (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(v_result)) = 4
    and v_result ?& array['ok','changed','code','lane_block_id']
    and v_result->>'code' = 'created',
    'Response exposes only four technical keys.');

  -- W. Function construction and ACL.
  v_passed := true;
  for v_definition in
    select pg_catalog.pg_get_functiondef(function_record.oid)
    from pg_catalog.pg_proc as function_record
    where function_record.oid in (
      'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure,
      'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure,
      'public.admin_set_lane_block_active(uuid,boolean)'::pg_catalog.regprocedure
    )
  loop
    v_passed := v_passed
      and v_definition ~ 'auth[.]uid[(][)]'
      and v_definition ~ 'lock_lane_conflict_families_v1'
      and v_definition !~* '[[:<:]]execute[[:>:]]'
      and v_definition !~* 'sqlerrm|message_text|when[[:space:]]+others';
  end loop;

  v_passed := v_passed and not exists (
    select 1
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_language as language_record
      on language_record.oid = function_record.prolang
    where function_record.oid in (
      'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure,
      'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure,
      'public.admin_set_lane_block_active(uuid,boolean)'::pg_catalog.regprocedure
    )
      and (
        language_record.lanname <> 'plpgsql'
        or function_record.provolatile <> 'v'
        or not function_record.prosecdef
        or pg_catalog.pg_get_userbyid(function_record.proowner) <> 'postgres'
        or function_record.proconfig is distinct from
          array['search_path=pg_catalog, public, pg_temp']::text[]
        or pg_catalog.pg_get_function_result(function_record.oid) <> 'jsonb'
        or pg_catalog.has_function_privilege('anon', function_record.oid, 'EXECUTE')
        or not pg_catalog.has_function_privilege(
          'authenticated', function_record.oid, 'EXECUTE'
        )
        or pg_catalog.has_function_privilege(
          'service_role', function_record.oid, 'EXECUTE'
        )
        or exists (
          select 1
          from pg_catalog.aclexplode(coalesce(
            function_record.proacl,
            pg_catalog.acldefault('f', function_record.proowner)
          )) as privilege_record
          where privilege_record.grantee = 0
            and privilege_record.privilege_type = 'EXECUTE'
        )
      )
  );
  perform pg_temp.record_result(23, 'W. ACL security and search_path',
    v_passed,
    'Three SECURITY DEFINER RPCs are executable only by authenticated clients.');

  -- X-AA. Existing objects are byte-contract stable.
  perform pg_temp.record_result(24, 'X. Existing trigger is unchanged',
    pg_temp.function_fingerprint(
      'public.lock_lane_booking_configuration()'::pg_catalog.regprocedure
    ) = '4ad32a3407b996f96b1329f2cc59c25a'
    and (
      select pg_catalog.md5(coalesce(pg_catalog.string_agg(
        trigger_record.tgname || '|' || trigger_record.tgenabled::text || '|' ||
        trigger_record.tgtype::text || '|' ||
        trigger_record.tgfoid::pg_catalog.regprocedure::text || '|' ||
        pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
        E'\n' order by trigger_record.tgname
      ), ''))
      from pg_catalog.pg_trigger as trigger_record
      where trigger_record.tgrelid = 'public.lane_blocks'::pg_catalog.regclass
        and not trigger_record.tgisinternal
    ) = '7bee80a61b291589ddcfc414afef1f96',
    'Trigger definition, helper definition, and trigger ACL are unchanged.');

  perform pg_temp.record_result(25, 'Y. Existing grants and policies are unchanged',
    (
      select pg_catalog.md5(coalesce(pg_catalog.string_agg(
        policy_record.policyname || '|' || policy_record.permissive || '|' ||
        policy_record.roles::text || '|' || policy_record.cmd || '|' ||
        coalesce(policy_record.qual, '<null>') || '|' ||
        coalesce(policy_record.with_check, '<null>'),
        E'\n' order by policy_record.policyname
      ), ''))
      from pg_catalog.pg_policies as policy_record
      where policy_record.schemaname = 'public'
        and policy_record.tablename = 'lane_blocks'
    ) = '5d2b1222a01f28927d9912b953e210a1'
    and (
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
      from pg_catalog.pg_class as table_record
      cross join lateral pg_catalog.aclexplode(coalesce(
        table_record.relacl,
        pg_catalog.acldefault('r', table_record.relowner)
      )) as privilege_record
      where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass
    ) = 'a03ce94ab4abc5e8aab109765dfe682e',
    'Direct DML rollback path is untouched.');

  perform pg_temp.record_result(26, 'Z. create_reservation_v2 is unchanged',
    pg_temp.function_fingerprint(
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
    ) = '893c71de856609d33240d1ebad37e86c',
    'Definition, owner, security, path, volatility, and ACL are identical.');

  perform pg_temp.record_result(27, 'AA. Multi-family helper is unchanged',
    pg_temp.function_fingerprint(
      'public.lock_lane_conflict_families_v1(uuid[])'::pg_catalog.regprocedure
    ) = '0815401da8ad1f909c26622355c0db5f',
    'Definition, owner, security, path, volatility, and ACL are identical.');

  -- Additional authorization and current-model controls.
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
  perform pg_catalog.set_config('request.jwt.claims', '{}', true);
  execute 'set local role authenticated';
  select public.admin_create_lane_block(
    v_standalone, v_base_date + 19,
    time '10:00', time '11:00', '[TEST][6B-4B2][AB]'
  ) into v_result;
  execute 'reset role';
  perform pg_temp.record_result(28, 'AB. Missing session is not allowed',
    v_result->>'code' = 'not_allowed',
    'auth.uid() is mandatory.');

  v_result := pg_temp.call_create_block(
    v_admin, v_missing, v_base_date + 20,
    time '10:00', time '11:00', '[TEST][6B-4B2][AC]'
  );
  perform pg_temp.record_result(29, 'AC. Invalid lane is controlled',
    v_result->>'code' = 'invalid_lane',
    'Unknown resource returns invalid_lane without raw SQL.');

  v_result := pg_temp.call_create_block(
    v_admin, v_standalone, v_base_date + 21,
    time '10:00', time '11:00', '[TEST][6B-4B2][AD-1]'
  );
  v_result2 := pg_temp.call_create_block(
    v_admin, v_standalone, v_base_date + 21,
    time '10:00', time '11:00', '[TEST][6B-4B2][AD-2]'
  );
  perform pg_temp.record_result(30, 'AD. Existing block overlap semantics are preserved',
    v_result->>'code' = 'created'
    and v_result2->>'code' = 'created'
    and (
      select pg_catalog.count(*) from public.lane_blocks
      where lane_id = v_standalone
        and block_date = v_base_date + 21
        and start_time = time '10:00'
        and end_time = time '11:00'
        and is_active
    ) = 2,
    'Current schema allows overlapping active blocks; RPC adds no new rule.');

  v_result := pg_temp.call_create_block(
    v_admin, v_later_inactive, v_base_date + 22,
    time '10:00', time '11:00', '[TEST][6B-4B2][AE]'
  );
  v_block_id2 := (v_result->>'lane_block_id')::uuid;
  update public.shooting_lanes
  set is_active = false
  where id = v_later_inactive;
  v_result := pg_temp.call_set_block_active(v_admin, v_block_id2, false);
  perform pg_temp.record_result(31, 'AE. Deactivation survives later lane deactivation',
    v_result->>'code' = 'deactivated'
    and not (select is_active from public.lane_blocks where id = v_block_id2),
    'Inactive requested resource does not prevent deactivation.');

  perform pg_temp.record_result(32, 'AF. Ready for rollback',
    (
      select pg_catalog.count(*) from pg_temp.test_results
      where passed is false
    ) = 0,
    'All migration objects and fixtures remain inside the test transaction.');
end;
$contract_tests$;

select test_order, test_name, passed, result
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  )
  into v_failures
  from pg_temp.test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'Lane-block RPC rollback tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure(
    'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
  ) is null
  and pg_catalog.to_regprocedure(
    'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'
  ) is null
  and pg_catalog.to_regprocedure(
    'public.admin_set_lane_block_active(uuid,boolean)'
  ) is null
  and not exists (
    select 1 from public.shooting_lanes
    where name like '[TEST][6B-4B2]%'
  )
  and not exists (
    select 1 from public.lane_blocks
    where reason like '[TEST][6B-4B2]%'
  )
  and not exists (
    select 1 from public.events
    where title like '[TEST][6B-4B2]%'
  )
  and not exists (
    select 1 from public.reservations
    where reservation_note = '[TEST][6B-4B2]'
  )
  and not exists (
    select 1 from auth.users
    where email like 'test-6b4b2-%@example.invalid'
  )
  and (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      policy_record.policyname || '|' || policy_record.permissive || '|' ||
      policy_record.roles::text || '|' || policy_record.cmd || '|' ||
      coalesce(policy_record.qual, '<null>') || '|' ||
      coalesce(policy_record.with_check, '<null>'),
      E'\n' order by policy_record.policyname
    ), '')) = '5d2b1222a01f28927d9912b953e210a1'
    from pg_catalog.pg_policies as policy_record
    where policy_record.schemaname = 'public'
      and policy_record.tablename = 'lane_blocks'
  )
  and (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      (case when privilege_record.grantee = 0 then 'PUBLIC'
            else pg_catalog.pg_get_userbyid(privilege_record.grantee) end) || '|' ||
      privilege_record.privilege_type || '|' ||
      privilege_record.is_grantable::text,
      E'\n' order by
        case when privilege_record.grantee = 0 then 'PUBLIC'
             else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
        privilege_record.privilege_type
    ), '')) = 'a03ce94ab4abc5e8aab109765dfe682e'
    from pg_catalog.pg_class as table_record
    cross join lateral pg_catalog.aclexplode(coalesce(
      table_record.relacl,
      pg_catalog.acldefault('r', table_record.relowner)
    )) as privilege_record
    where table_record.oid = 'public.lane_blocks'::pg_catalog.regclass
  )
  and (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      trigger_record.tgname || '|' || trigger_record.tgenabled::text || '|' ||
      trigger_record.tgtype::text || '|' ||
      trigger_record.tgfoid::pg_catalog.regprocedure::text || '|' ||
      pg_catalog.pg_get_triggerdef(trigger_record.oid, true),
      E'\n' order by trigger_record.tgname
    ), '')) = '7bee80a61b291589ddcfc414afef1f96'
    from pg_catalog.pg_trigger as trigger_record
    where trigger_record.tgrelid = 'public.lane_blocks'::pg_catalog.regclass
      and not trigger_record.tgisinternal
  )
  and not exists (
    select 1
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
    left join lateral (
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
      )::text) as fingerprint
      from pg_catalog.pg_proc as function_record
      join pg_catalog.pg_roles as owner_role
        on owner_role.oid = function_record.proowner
      join pg_catalog.pg_language as language_record
        on language_record.oid = function_record.prolang
      where function_record.oid = pg_catalog.to_regprocedure(baseline.signature)
    ) as actual on true
    where actual.fingerprint is distinct from baseline.fingerprint
  )
  as rollback_confirmed;
