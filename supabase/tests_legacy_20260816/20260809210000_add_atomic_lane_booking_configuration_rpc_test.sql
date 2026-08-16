\set ON_ERROR_STOP on

-- psql-only contract test. The migration and every [TEST][6B-4D1] fixture
-- run in one transaction and are removed by the final ROLLBACK.
begin;

create function pg_temp.function_fingerprint(p_function pg_catalog.regprocedure)
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(pg_catalog.jsonb_build_object(
    'definition', pg_catalog.pg_get_functiondef(function_record.oid),
    'owner', owner_role.rolname,
    'language', language_record.lanname,
    'volatility', function_record.provolatile,
    'security_definer', function_record.prosecdef,
    'config', coalesce(pg_catalog.to_jsonb(function_record.proconfig), '[]'::jsonb),
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
  join pg_catalog.pg_roles as owner_role on owner_role.oid = function_record.proowner
  join pg_catalog.pg_language as language_record on language_record.oid = function_record.prolang
  where function_record.oid = p_function;
$function$;

create function pg_temp.table_security_fingerprint(p_table pg_catalog.regclass)
returns text
language sql
stable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.md5(pg_catalog.jsonb_build_object(
    'rls', table_record.relrowsecurity,
    'force_rls', table_record.relforcerowsecurity,
    'acl', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'grantee', case when privilege_record.grantee = 0 then 'PUBLIC'
                        else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
        'privilege', privilege_record.privilege_type,
        'grantable', privilege_record.is_grantable
      ) order by
        case when privilege_record.grantee = 0 then 'PUBLIC'
             else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
        privilege_record.privilege_type)
      from pg_catalog.aclexplode(coalesce(
        table_record.relacl,
        pg_catalog.acldefault('r', table_record.relowner)
      )) as privilege_record
    ), '[]'::jsonb),
    'policies', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'name', policy_record.polname,
        'command', policy_record.polcmd,
        'roles', policy_record.polroles,
        'qual', pg_catalog.pg_get_expr(policy_record.polqual, policy_record.polrelid),
        'check', pg_catalog.pg_get_expr(policy_record.polwithcheck, policy_record.polrelid)
      ) order by policy_record.polname)
      from pg_catalog.pg_policy as policy_record
      where policy_record.polrelid = table_record.oid
    ), '[]'::jsonb)
  )::text)
  from pg_catalog.pg_class as table_record
  where table_record.oid = p_table;
$function$;

create temporary table baseline_objects (
  object_name text primary key,
  fingerprint text not null
) on commit drop;

insert into baseline_objects(object_name, fingerprint) values
  ('public_config', pg_temp.function_fingerprint('public.get_public_booking_configuration_v1()')),
  ('family_helper', pg_temp.function_fingerprint('public.lock_lane_conflict_families_v1(uuid[])')),
  ('reservation_v2', pg_temp.function_fingerprint('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)')),
  ('block_create', pg_temp.function_fingerprint('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)')),
  ('block_update', pg_temp.function_fingerprint('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)')),
  ('block_active', pg_temp.function_fingerprint('public.admin_set_lane_block_active(uuid,boolean)')),
  ('event_create_v2', pg_temp.function_fingerprint('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')),
  ('event_update_v2', pg_temp.function_fingerprint('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')),
  ('event_active_v2', pg_temp.function_fingerprint('public.admin_set_event_active_v2(uuid,boolean)')),
  ('durations_security', pg_temp.table_security_fingerprint('public.lane_booking_durations')),
  ('pricing_security', pg_temp.table_security_fingerprint('public.lane_pricing_rules'));

\ir ../migrations/20260809210000_add_atomic_lane_booking_configuration_rpc.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.valid_pricing(
  p_max_people integer,
  p_hourly_price numeric default 100
)
returns jsonb
language sql
immutable
set search_path to pg_catalog, public, pg_temp
as $function$
  select pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'day_group', 'mon_thu', 'min_shooters', 1,
      'max_shooters', p_max_people, 'label', '[TEST][6B-4D1] Mon-Thu',
      'hourly_price', p_hourly_price
    ),
    pg_catalog.jsonb_build_object(
      'day_group', 'fri_sun', 'min_shooters', 1,
      'max_shooters', p_max_people, 'label', '[TEST][6B-4D1] Fri-Sun',
      'hourly_price', p_hourly_price + 20
    )
  );
$function$;

create function pg_temp.call_config(
  p_user_id uuid,
  p_lane_id uuid,
  p_is_active boolean,
  p_whole_lane_bookable boolean,
  p_positions_bookable boolean,
  p_max_shooters integer,
  p_online_bookable boolean,
  p_max_people_online integer,
  p_durations integer[],
  p_pricing jsonb
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    case when p_user_id is null then '{}'
         else pg_catalog.jsonb_build_object(
           'sub', p_user_id, 'role', 'authenticated'
         )::text end,
    true
  );
  execute 'set local role authenticated';
  select public.admin_set_lane_booking_configuration(
    p_lane_id, p_is_active, p_whole_lane_bookable,
    p_positions_bookable, p_max_shooters, p_online_bookable,
    p_max_people_online, p_durations, p_pricing
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.add_reservation(
  p_user_id uuid,
  p_lane_id uuid,
  p_pricing_rule_id uuid,
  p_shooters integer
)
returns uuid
language plpgsql
as $function$
declare
  v_id uuid;
begin
  insert into public.reservations(
    user_id, lane_id, customer_name, customer_email, customer_phone,
    reservation_date, start_time, end_time, duration_minutes,
    price, reservation_status, payment_status, attendance_status,
    reservation_note, shooters_count, pricing_rule_id,
    pricing_day_group_snapshot, lane_name_snapshot, pricing_label_snapshot,
    price_per_hour_snapshot, total_price, currency_code, creation_request_id
  ) values (
    p_user_id, p_lane_id, '[TEST][6B-4D1]',
    'test-6b4d1-reservation@example.invalid', '000000000',
    current_date + 6000, time '10:00', time '12:00', 120,
    200, 'confirmed', 'pay_on_site', 'planned', '[TEST][6B-4D1]',
    p_shooters, p_pricing_rule_id, 'mon_thu', '[TEST][6B-4D1]',
    '[TEST][6B-4D1] historical', 100, 200, 'PLN',
    pg_catalog.gen_random_uuid()
  ) returning id into v_id;
  return v_id;
end;
$function$;

do $contract_tests$
declare
  v_admin_id uuid := '6b4d1000-0000-4000-8000-000000000001';
  v_employee_id uuid := '6b4d1000-0000-4000-8000-000000000002';
  v_instructor_id uuid := '6b4d1000-0000-4000-8000-000000000003';
  v_user_id uuid := '6b4d1000-0000-4000-8000-000000000004';
  v_reservation_user_id uuid := '6b4d1000-0000-4000-8000-000000000005';
  v_lane_a uuid := '6b4d1000-0000-4000-8000-000000000101';
  v_lane_b uuid := '6b4d1000-0000-4000-8000-000000000102';
  v_parent uuid := '6b4d1000-0000-4000-8000-000000000201';
  v_position uuid := '6b4d1000-0000-4000-8000-000000000202';
  v_result jsonb;
  v_result2 jsonb;
  v_pricing_rule_id uuid;
  v_reservation_id uuid;
  v_lane_updated_at timestamptz;
  v_rule_updated_at timestamptz;
  v_reservation_before jsonb;
  v_reservation_after jsonb;
  v_state_before jsonb;
  v_state_after jsonb;
begin
  insert into auth.users(
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4d1-admin@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_employee_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4d1-employee@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_instructor_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4d1-instructor@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4d1-user@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_reservation_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4d1-reservation@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
    when v_admin_id then 'admin'
    when v_employee_id then 'pracownik'
    when v_instructor_id then 'instruktor'
    else 'user' end,
    first_name = '[TEST]', last_name = '6B-4D1',
    full_name = '[TEST][6B-4D1]',
    email = 'test-6b4d1-profile@example.invalid',
    phone = '000000000', verification_status = 'verified'
  where user_id in (
    v_admin_id, v_employee_id, v_instructor_id,
    v_user_id, v_reservation_user_id
  );

  insert into public.shooting_lanes(
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable,
    positions_bookable
  ) values
    (v_lane_a,'[TEST][6B-4D1][A]','[TEST]','[TEST]',10,true,6,60,9971,'PLN','lane',null,true,false),
    (v_lane_b,'[TEST][6B-4D1][B]','[TEST]','[TEST]',10,true,6,60,9972,'PLN','lane',null,true,false),
    (v_parent,'[TEST][6B-4D1][PARENT]','[TEST]','[TEST]',10,true,6,60,9973,'PLN','lane',null,true,true),
    (v_position,'[TEST][6B-4D1][POSITION]','[TEST]','[TEST]',10,true,2,60,9974,'PLN','position',v_parent,false,false);

  -- A-B. Allowed actors and complete snapshots.
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,6,true,3,array[120,60],pg_temp.valid_pricing(3));
  insert into test_results values (1,'A. admin standalone valid config',
    v_result->>'code'='updated' and v_result->>'changed'='true'
    and (select pg_catalog.array_agg(duration_minutes order by duration_minutes) from public.lane_booking_durations where lane_id=v_lane_a and is_active)=array[60,120]
    and (select count(*) from public.lane_pricing_rules where lane_id=v_lane_a and is_active)=2,
    'Admin atomically writes the normalized duration and pricing snapshot.');

  v_result := pg_temp.call_config(v_employee_id,v_lane_b,true,true,false,6,true,3,array[60,120],pg_temp.valid_pricing(3));
  insert into test_results values (2,'B. pracownik valid config',v_result->>'code'='updated','Pracownik is allowed.');

  -- C-F. Authorization and target errors.
  v_result := pg_temp.call_config(v_instructor_id,v_lane_a,true,true,false,6,true,3,array[60,120],pg_temp.valid_pricing(3));
  insert into test_results values (3,'C. instructor not allowed',v_result->>'code'='not_allowed','Instructor cannot call the writer.');
  v_result := pg_temp.call_config(v_user_id,v_lane_a,true,true,false,6,true,3,array[60,120],pg_temp.valid_pricing(3));
  insert into test_results values (4,'D. user not allowed',v_result->>'code'='not_allowed','User cannot call the writer.');
  v_result := pg_temp.call_config(v_admin_id,'6b4d1000-0000-4000-8000-000000009999',true,true,false,6,true,3,array[60],pg_temp.valid_pricing(3));
  insert into test_results values (5,'E. resource not found',v_result->>'code'='resource_not_found','Missing resource is controlled.');
  v_result := pg_temp.call_config(v_admin_id,v_position,true,true,false,2,true,2,array[60],pg_temp.valid_pricing(2));
  insert into test_results values (6,'F. invalid hierarchy',v_result->>'code'='invalid_hierarchy','Position cannot receive parent-only flags.');

  -- G-I. Duration validation.
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,array[60,60],pg_temp.valid_pricing(3));
  insert into test_results values (7,'G. duplicate durations rejected',v_result->>'code'='invalid_configuration','Duplicate durations fail before DML.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,array[90],pg_temp.valid_pricing(3));
  insert into test_results values (8,'H. invalid duration rejected',v_result->>'code'='invalid_configuration','Duration must align to booking_step_minutes.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,'{}',pg_temp.valid_pricing(3));
  insert into test_results values (9,'I. empty online durations rejected',v_result->>'code'='invalid_configuration','Online resource needs a duration.');

  -- J-M. Strict pricing validation.
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,array[60],pg_temp.valid_pricing(3) || pg_catalog.jsonb_build_array((pg_temp.valid_pricing(3)->0)));
  insert into test_results values (10,'J. pricing duplicate rejected',v_result->>'code'='invalid_configuration','Duplicate range is rejected.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,array[60],pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',2,'label','A','hourly_price',10),
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',2,'max_shooters',3,'label','B','hourly_price',20),
    pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',3,'label','C','hourly_price',30)));
  insert into test_results values (11,'K. pricing overlap rejected',v_result->>'code'='invalid_configuration','Overlapping intervals fail.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,array[60],pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',1,'label','A','hourly_price',10),
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',3,'max_shooters',3,'label','B','hourly_price',20),
    pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',3,'label','C','hourly_price',30)));
  insert into test_results values (12,'L. pricing gap rejected',v_result->>'code'='invalid_configuration','Gaps fail.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,array[60],pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',3,'label','A','hourly_price',10)));
  insert into test_results values (13,'M. missing day group rejected',v_result->>'code'='invalid_configuration','Both day groups are required.');

  -- N-P. Capacity and contact-required boundary.
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,true,3,array[60],pg_temp.valid_pricing(3));
  insert into test_results values (14,'N. coverage through online maximum valid',v_result->>'code' in ('updated','no_change'),'Coverage ends at max_people_online.');
  insert into test_results values (15,'O. contact-required range needs no pricing',
    not exists(select 1 from public.lane_pricing_rules where lane_id=v_lane_b and is_active and max_shooters>3)
    and (select max_shooters from public.shooting_lanes where id=v_lane_b)=6,
    'People 4..6 stay in contact_required semantics without online prices.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,3,true,4,array[60],pg_temp.valid_pricing(4));
  insert into test_results values (16,'P. online maximum above physical rejected',v_result->>'code'='invalid_configuration','Online capacity cannot exceed physical capacity.');

  -- Q-T. Parent modes and position invariants.
  v_result := pg_temp.call_config(v_admin_id,v_parent,true,true,false,6,true,3,array[60],pg_temp.valid_pricing(3));
  insert into test_results values (17,'Q. parent whole-only',v_result->>'code'='updated','Whole-only is valid.');
  v_result := pg_temp.call_config(v_admin_id,v_parent,true,false,true,6,true,3,array[60],pg_temp.valid_pricing(3));
  insert into test_results values (18,'R. parent positions-only',v_result->>'code'='updated','Positions-only is valid.');
  v_result := pg_temp.call_config(v_admin_id,v_parent,true,true,true,6,true,3,array[60],pg_temp.valid_pricing(3));
  insert into test_results values (19,'S. parent both modes',v_result->>'code'='updated','Both modes are valid.');
  v_result := pg_temp.call_config(v_admin_id,v_position,true,false,true,2,true,2,array[60],pg_temp.valid_pricing(2));
  insert into test_results values (20,'T. invalid position flags rejected',v_result->>'code'='invalid_hierarchy','Position flags remain false.');

  -- Establish one historical commitment on lane A.
  select id into v_pricing_rule_id
  from public.lane_pricing_rules
  where lane_id=v_lane_a and day_group='mon_thu' and is_active
  order by id limit 1;
  v_reservation_id := pg_temp.add_reservation(v_reservation_user_id,v_lane_a,v_pricing_rule_id,4);
  select pg_catalog.to_jsonb(reservation.*) into v_reservation_before
  from public.reservations as reservation where reservation.id=v_reservation_id;

  -- U-X. Existing obligations and immutable snapshots.
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,false,true,false,6,true,3,array[60,120],pg_temp.valid_pricing(3));
  insert into test_results values (21,'U. deactivate preserves reservations',v_result->>'code'='updated' and exists(select 1 from public.reservations where id=v_reservation_id),'Deactivation does not cancel obligations.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,6,false,3,array[60,120],pg_temp.valid_pricing(3));
  insert into test_results values (22,'V. disable online preserves reservations',v_result->>'code'='updated' and exists(select 1 from public.reservations where id=v_reservation_id),'Offline mode does not delete reservations.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,6,true,3,array[60,120],pg_temp.valid_pricing(3,150));
  select pg_catalog.to_jsonb(reservation.*) into v_reservation_after from public.reservations as reservation where reservation.id=v_reservation_id;
  insert into test_results values (23,'W. pricing change preserves reservation snapshot',v_result->>'code'='updated' and v_reservation_after=v_reservation_before,'Historical reservation row is byte-for-byte unchanged.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,6,true,3,array[120,180],pg_temp.valid_pricing(3,150));
  select pg_catalog.to_jsonb(reservation.*) into v_reservation_after from public.reservations as reservation where reservation.id=v_reservation_id;
  insert into test_results values (24,'X. duration change preserves reservation',v_result->>'code'='updated' and v_reservation_after=v_reservation_before,'Duration snapshot replacement does not mutate history.');

  -- Y. Semantic no-change does not advance versions.
  select updated_at into v_lane_updated_at from public.shooting_lanes where id=v_lane_a;
  select updated_at into v_rule_updated_at from public.lane_booking_rules where lane_id=v_lane_a;
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,6,true,3,array[120,180],pg_temp.valid_pricing(3,150));
  insert into test_results values (25,'Y. no_change',v_result->>'code'='no_change' and v_result->>'changed'='false'
    and (select updated_at=v_lane_updated_at from public.shooting_lanes where id=v_lane_a)
    and (select updated_at=v_rule_updated_at from public.lane_booking_rules where lane_id=v_lane_a),
    'Equivalent normalized snapshot performs no DML.');

  -- AI-AJ. Physical capacity obligations.
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,3,true,3,array[120],pg_temp.valid_pricing(3,150));
  insert into test_results values (26,'AI. lowering below future obligation rejected',v_result->>'code'='conflict_reservation' and (select max_shooters=6 from public.shooting_lanes where id=v_lane_a),'Future active booking with four people is protected.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,5,true,3,array[120],pg_temp.valid_pricing(3,150));
  insert into test_results values (27,'AJ. lowering above obligations allowed',v_result->>'code'='updated' and (select max_shooters=5 from public.shooting_lanes where id=v_lane_a),'Physical capacity five still covers the four-person obligation.');

  -- Public-reader compatibility and fail-closed behavior.
  insert into test_results values (28,'Public config returns valid snapshot',
    exists(select 1 from public.get_public_booking_configuration_v1() as config where config.lane_id=v_lane_a and config.effective_online_bookable and config.durations_minutes=array[120] and pg_catalog.jsonb_array_length(config.pricing)=2),
    'Unchanged reader exposes the valid complete snapshot.');
  v_result := pg_temp.call_config(v_admin_id,v_lane_b,true,true,false,6,false,3,'{}','[]'::jsonb);
  insert into test_results values (29,'Incomplete offline config remains fail-closed',
    v_result->>'code'='updated' and not exists(select 1 from public.get_public_booking_configuration_v1() as config where config.lane_id=v_lane_b),
    'Reader does not expose a resource without complete online configuration.');

  -- Strict JSON object allowlist and no partial writes.
  select pg_catalog.jsonb_build_object(
    'lane', (select pg_catalog.to_jsonb(lane.*) from public.shooting_lanes as lane where id=v_lane_a),
    'rule', (select pg_catalog.to_jsonb(rule.*) from public.lane_booking_rules as rule where lane_id=v_lane_a),
    'durations', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration.*) order by duration.id) from public.lane_booking_durations as duration where lane_id=v_lane_a),
    'pricing', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(pricing.*) order by pricing.id) from public.lane_pricing_rules as pricing where lane_id=v_lane_a)
  ) into v_state_before;
  v_result := pg_temp.call_config(v_admin_id,v_lane_a,true,true,false,5,true,3,array[60],
    pg_temp.valid_pricing(3) || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',3,'label','X','hourly_price',1,'unknown',true)));
  select pg_catalog.jsonb_build_object(
    'lane', (select pg_catalog.to_jsonb(lane.*) from public.shooting_lanes as lane where id=v_lane_a),
    'rule', (select pg_catalog.to_jsonb(rule.*) from public.lane_booking_rules as rule where lane_id=v_lane_a),
    'durations', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration.*) order by duration.id) from public.lane_booking_durations as duration where lane_id=v_lane_a),
    'pricing', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(pricing.*) order by pricing.id) from public.lane_pricing_rules as pricing where lane_id=v_lane_a)
  ) into v_state_after;
  insert into test_results values (30,'Unknown pricing keys fail before DML',v_result->>'code'='invalid_configuration' and v_state_after=v_state_before,'Strict allowlist and atomic validation are enforced.');

  -- Static security and unchanged dependencies.
  insert into test_results values (31,'AB. RPC security and ACL',
    (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='admin_set_lane_booking_configuration' and p.prosecdef and p.provolatile='v' and pg_catalog.pg_get_userbyid(p.proowner)='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and pg_catalog.pg_get_function_result(p.oid)='jsonb')=1
    and pg_catalog.has_function_privilege('authenticated','public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)','EXECUTE')
    and not exists(select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a where p.oid='public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'::pg_catalog.regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'),
    'One VOLATILE SECURITY DEFINER RPC exposes EXECUTE only to authenticated.');
  insert into test_results values (32,'AC. existing duration and pricing ACL unchanged',
    pg_temp.table_security_fingerprint('public.lane_booking_durations')=(select fingerprint from baseline_objects where object_name='durations_security')
    and pg_temp.table_security_fingerprint('public.lane_pricing_rules')=(select fingerprint from baseline_objects where object_name='pricing_security'),
    'Direct authenticated DML remains temporarily unchanged.');
  insert into test_results values (33,'AD. public reader unchanged',pg_temp.function_fingerprint('public.get_public_booking_configuration_v1()')=(select fingerprint from baseline_objects where object_name='public_config'),'Public configuration V1 is identical.');
  insert into test_results values (34,'AE. family helper unchanged',pg_temp.function_fingerprint('public.lock_lane_conflict_families_v1(uuid[])')=(select fingerprint from baseline_objects where object_name='family_helper'),'Multi-family lock helper is identical.');
  insert into test_results values (35,'AF. reservation V2 unchanged',pg_temp.function_fingerprint('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)')=(select fingerprint from baseline_objects where object_name='reservation_v2'),'Reservation V2 is identical.');
  insert into test_results values (36,'AG. lane-block RPCs unchanged',
    pg_temp.function_fingerprint('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)')=(select fingerprint from baseline_objects where object_name='block_create')
    and pg_temp.function_fingerprint('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)')=(select fingerprint from baseline_objects where object_name='block_update')
    and pg_temp.function_fingerprint('public.admin_set_lane_block_active(uuid,boolean)')=(select fingerprint from baseline_objects where object_name='block_active'),'All lane-block RPCs are identical.');
  insert into test_results values (37,'AH. Event V2 RPCs unchanged',
    pg_temp.function_fingerprint('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')=(select fingerprint from baseline_objects where object_name='event_create_v2')
    and pg_temp.function_fingerprint('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')=(select fingerprint from baseline_objects where object_name='event_update_v2')
    and pg_temp.function_fingerprint('public.admin_set_event_active_v2(uuid,boolean)')=(select fingerprint from baseline_objects where object_name='event_active_v2'),'All Event V2 RPCs are identical.');
  insert into test_results values (38,'Safe response contract',false,
    'Pending exact-key check after the scenario block.');

  v_result := pg_temp.call_config(null,v_lane_a,true,true,false,5,true,3,array[120],pg_temp.valid_pricing(3,150));
  insert into test_results values (39,'Missing session is not allowed',v_result->>'code'='not_allowed','auth.uid() is required.');
end;
$contract_tests$;

-- Test 38 is a static exact-key contract independent of prior local variables.
update test_results
set passed = (
  select pg_catalog.array_agg(key order by key)
    = array['changed','code','lane_id','ok']::text[]
  from pg_catalog.jsonb_object_keys(
    pg_temp.call_config(
      '6b4d1000-0000-4000-8000-000000000001',
      '6b4d1000-0000-4000-8000-000000000101',
      true,true,false,5,true,3,array[120],pg_temp.valid_pricing(3,150)
    )
  ) as keys(key)
), result = 'Exactly four non-PII technical keys.'
where test_order = 38;

select test_order, test_name, passed, result
from test_results
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
  from test_results
  where passed is false;

  if (select count(*) from test_results) <> 39 then
    raise exception 'Expected exactly 39 booking configuration contract controls.';
  end if;

  if v_failures is not null then
    raise exception 'Booking configuration contract tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure(
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'
  ) is null
  and not exists(
    select 1 from public.shooting_lanes where name like '[TEST][6B-4D1]%'
  )
  and not exists(
    select 1 from auth.users where email like 'test-6b4d1-%@example.invalid'
  )
  as rollback_confirmed;
