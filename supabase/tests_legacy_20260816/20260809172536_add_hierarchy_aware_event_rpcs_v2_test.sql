\set ON_ERROR_STOP on

-- psql-only contract test. The migration and every [TEST][6B-4C1] fixture
-- are executed in one transaction and removed by the final ROLLBACK.
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

select
  pg_temp.function_fingerprint('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') as v1_create_fp,
  pg_temp.function_fingerprint('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') as v1_update_fp,
  pg_temp.function_fingerprint('public.admin_set_event_active(uuid,boolean)') as v1_active_fp,
  pg_temp.function_fingerprint('public.lock_lane_conflict_families_v1(uuid[])') as family_helper_fp,
  pg_temp.function_fingerprint('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)') as reservation_v2_fp,
  pg_temp.function_fingerprint('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)') as block_create_fp,
  pg_temp.function_fingerprint('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)') as block_update_fp,
  pg_temp.function_fingerprint('public.admin_set_lane_block_active(uuid,boolean)') as block_active_fp
\gset

create temporary table baseline_fingerprints (
  signature text primary key,
  fingerprint text not null
) on commit drop;

insert into baseline_fingerprints(signature,fingerprint) values
  ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', :'v1_create_fp'),
  ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])', :'v1_update_fp'),
  ('public.admin_set_event_active(uuid,boolean)', :'v1_active_fp'),
  ('public.lock_lane_conflict_families_v1(uuid[])', :'family_helper_fp'),
  ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)', :'reservation_v2_fp'),
  ('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)', :'block_create_fp'),
  ('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)', :'block_update_fp'),
  ('public.admin_set_lane_block_active(uuid,boolean)', :'block_active_fp');

\ir ../migrations/20260809172536_add_hierarchy_aware_event_rpcs_v2.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.call_create_v2(
  p_user_id uuid,
  p_title text,
  p_event_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_lane_ids uuid[]
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_create_event_v2(
    p_title, ' [TEST][6B-4C1] ', p_event_date, p_start_time, p_end_time,
    ' [TEST][6B-4C1] ', 10, 10, p_lane_ids
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_update_v2(
  p_user_id uuid,
  p_event_id uuid,
  p_title text,
  p_event_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_lane_ids uuid[]
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_update_event_v2(
    p_event_id, p_title, ' [TEST][6B-4C1] ', p_event_date,
    p_start_time, p_end_time, ' [TEST][6B-4C1] ', 10, 10, p_lane_ids
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_active_v2(
  p_user_id uuid,
  p_event_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.admin_set_event_active_v2(p_event_id, p_is_active)
  into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.add_event(
  p_title text,
  p_event_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_active boolean,
  p_lane_ids uuid[]
)
returns uuid
language plpgsql
as $function$
declare
  v_event_id uuid;
begin
  insert into public.events(
    title, description, event_date, start_time, end_time,
    location, price, max_participants, is_active
  ) values (
    p_title, '[TEST][6B-4C1]', p_event_date, p_start_time, p_end_time,
    '[TEST][6B-4C1]', 10, 10, p_active
  ) returning id into v_event_id;

  insert into public.event_lanes(event_id, lane_id)
  select v_event_id, requested.lane_id
  from pg_catalog.unnest(p_lane_ids) as requested(lane_id)
  order by requested.lane_id;

  return v_event_id;
end;
$function$;

create function pg_temp.add_reservation(
  p_user_id uuid,
  p_lane_id uuid,
  p_date date,
  p_start_time time without time zone,
  p_end_time time without time zone,
  p_pricing_rule_id uuid
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
    p_user_id, p_lane_id, '[TEST][6B-4C1]',
    'test-6b4c1@example.invalid', '000000000',
    p_date, p_start_time, p_end_time,
    extract(epoch from (p_end_time - p_start_time))::integer / 60,
    10, 'confirmed', 'pay_on_site', 'planned', '[TEST][6B-4C1]',
    1, p_pricing_rule_id, 'mon_thu', '[TEST][6B-4C1]',
    '[TEST][6B-4C1]', 10, 10, 'PLN', pg_catalog.gen_random_uuid()
  ) returning id into v_id;
  return v_id;
end;
$function$;

do $contract_tests$
declare
  v_base_date date := current_date + 6000;
  v_admin_id uuid := '6b4c1000-0000-4000-8000-000000000001';
  v_employee_id uuid := '6b4c1000-0000-4000-8000-000000000002';
  v_instructor_id uuid := '6b4c1000-0000-4000-8000-000000000003';
  v_user_id uuid := '6b4c1000-0000-4000-8000-000000000004';
  v_reservation_user_id uuid := '6b4c1000-0000-4000-8000-000000000005';
  v_root_a uuid := '6b4c1000-0000-4000-8000-000000000101';
  v_a1 uuid := '6b4c1000-0000-4000-8000-000000000102';
  v_a2 uuid := '6b4c1000-0000-4000-8000-000000000103';
  v_root_b uuid := '6b4c1000-0000-4000-8000-000000000201';
  v_b1 uuid := '6b4c1000-0000-4000-8000-000000000202';
  v_b2 uuid := '6b4c1000-0000-4000-8000-000000000203';
  v_standalone uuid := '6b4c1000-0000-4000-8000-000000000301';
  v_pricing_rule_id uuid := '6b4c1000-0000-4000-8000-000000000401';
  v_result jsonb;
  v_result2 jsonb;
  v_event_id uuid;
  v_event_id2 uuid;
begin
  insert into auth.users(
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (v_admin_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4c1-admin@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_employee_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4c1-employee@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_instructor_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4c1-instructor@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4c1-user@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_reservation_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4c1-reservation@example.invalid','',pg_catalog.transaction_timestamp(),'{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
    when v_admin_id then 'admin'
    when v_employee_id then 'pracownik'
    when v_instructor_id then 'instruktor'
    else 'user' end,
    first_name = '[TEST]', last_name = '6B-4C1', full_name = '[TEST][6B-4C1]',
    email = 'test-6b4c1-profile@example.invalid', phone = '000000000',
    verification_status = 'verified'
  where user_id in (
    v_admin_id, v_employee_id, v_instructor_id, v_user_id,
    v_reservation_user_id
  );

  insert into public.shooting_lanes(
    id,name,type,description,price_per_hour,is_active,max_shooters,
    booking_step_minutes,display_order,currency_code,resource_kind,
    parent_lane_id,whole_lane_bookable,positions_bookable
  ) values
    (v_root_a,'[TEST][6B-4C1][ROOT-A]','[TEST]','[TEST]',10,true,5,60,9901,'PLN','lane',null,true,true),
    (v_a1,'[TEST][6B-4C1][A1]','[TEST]','[TEST]',10,true,5,60,9902,'PLN','position',v_root_a,false,false),
    (v_a2,'[TEST][6B-4C1][A2]','[TEST]','[TEST]',10,true,5,60,9903,'PLN','position',v_root_a,false,false),
    (v_root_b,'[TEST][6B-4C1][ROOT-B]','[TEST]','[TEST]',10,true,5,60,9911,'PLN','lane',null,true,true),
    (v_b1,'[TEST][6B-4C1][B1]','[TEST]','[TEST]',10,true,5,60,9912,'PLN','position',v_root_b,false,false),
    (v_b2,'[TEST][6B-4C1][B2]','[TEST]','[TEST]',10,true,5,60,9913,'PLN','position',v_root_b,false,false),
    (v_standalone,'[TEST][6B-4C1][STANDALONE]','[TEST]','[TEST]',10,true,5,60,9920,'PLN','lane',null,true,false);

  insert into public.lane_pricing_rules(
    id,lane_id,day_group,min_shooters,max_shooters,label,
    hourly_price,display_order,is_active
  ) values (
    v_pricing_rule_id,v_root_a,'mon_thu',1,5,'[TEST][6B-4C1]',10,1,true
  );

  -- A. Global event.
  v_result := pg_temp.call_create_v2(
    v_admin_id,'[TEST][6B-4C1][A]',v_base_date,time '07:00',time '21:00','{}'
  );
  insert into test_results values (1,'A. create global event',
    v_result->>'code'='created' and v_result->>'changed'='true'
    and not exists(select 1 from public.event_lanes where event_id=(v_result->>'event_id')::uuid),
    'Global event preserves V1 semantics and has no lane links.');

  -- B. Standalone lane event.
  v_result := pg_temp.call_create_v2(
    v_admin_id,'[TEST][6B-4C1][B]',v_base_date+1,time '10:00',time '11:00',array[v_standalone]
  );
  insert into test_results values (2,'B. create standalone lane event',
    v_result->>'code'='created' and (select count(*) from public.event_lanes where event_id=(v_result->>'event_id')::uuid)=1,
    'One standalone lane is linked once.');

  -- C-E. Reservation hierarchy and sibling independence.
  perform pg_temp.add_reservation(v_reservation_user_id,v_a1,v_base_date+2,time '10:00',time '11:00',v_pricing_rule_id);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][C]',v_base_date+2,time '10:00',time '11:00',array[v_root_a]);
  insert into test_results values (3,'C. parent event vs child reservation',v_result->>'code'='reservation_conflict' and (v_result->>'conflict_lane_id')::uuid=v_a1,'Parent scope includes children.');

  perform pg_temp.add_reservation(v_reservation_user_id,v_root_a,v_base_date+3,time '10:00',time '11:00',v_pricing_rule_id);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][D]',v_base_date+3,time '10:00',time '11:00',array[v_a1]);
  insert into test_results values (4,'D. child event vs parent reservation',v_result->>'code'='reservation_conflict' and (v_result->>'conflict_lane_id')::uuid=v_root_a,'Child scope includes its parent.');

  perform pg_temp.add_reservation(v_reservation_user_id,v_a2,v_base_date+4,time '10:00',time '11:00',v_pricing_rule_id);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][E]',v_base_date+4,time '10:00',time '11:00',array[v_a1]);
  insert into test_results values (5,'E. child1 event and child2 reservation',v_result->>'code'='created','Sibling resources remain independent.');

  -- F-H. Lane-block hierarchy and sibling independence.
  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_a1,v_base_date+5,time '10:00',time '11:00','[TEST][6B-4C1][F]',true);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][F]',v_base_date+5,time '10:00',time '11:00',array[v_root_a]);
  insert into test_results values (6,'F. parent event vs child block',v_result->>'code'='lane_block_conflict' and (v_result->>'conflict_lane_id')::uuid=v_a1,'Parent scope detects child block.');

  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_root_a,v_base_date+6,time '10:00',time '11:00','[TEST][6B-4C1][G]',true);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][G]',v_base_date+6,time '10:00',time '11:00',array[v_a1]);
  insert into test_results values (7,'G. child event vs parent block',v_result->>'code'='lane_block_conflict' and (v_result->>'conflict_lane_id')::uuid=v_root_a,'Child scope detects parent block.');

  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_a2,v_base_date+7,time '10:00',time '11:00','[TEST][6B-4C1][H]',true);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][H]',v_base_date+7,time '10:00',time '11:00',array[v_a1]);
  insert into test_results values (8,'H. child1 event and child2 block',v_result->>'code'='created','Sibling block does not conflict.');

  -- I-K. Event hierarchy and sibling independence.
  perform pg_temp.add_event('[TEST][6B-4C1][I-SEED]',v_base_date+8,time '10:00',time '11:00',true,array[v_a1]);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][I]',v_base_date+8,time '10:00',time '11:00',array[v_root_a]);
  insert into test_results values (9,'I. parent event vs child event',v_result->>'code'='event_conflict' and (v_result->>'conflict_lane_id')::uuid=v_a1,'Parent scope detects child event.');

  perform pg_temp.add_event('[TEST][6B-4C1][J-SEED]',v_base_date+9,time '10:00',time '11:00',true,array[v_root_a]);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][J]',v_base_date+9,time '10:00',time '11:00',array[v_a1]);
  insert into test_results values (10,'J. child event vs parent event',v_result->>'code'='event_conflict' and (v_result->>'conflict_lane_id')::uuid=v_root_a,'Child scope detects parent event.');

  perform pg_temp.add_event('[TEST][6B-4C1][K-SEED]',v_base_date+10,time '10:00',time '11:00',true,array[v_a2]);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][K]',v_base_date+10,time '10:00',time '11:00',array[v_a1]);
  insert into test_results values (11,'K. child1 event and child2 event',v_result->>'code'='created','Sibling events remain independent.');

  -- L-N. Dedupe, multi-root and input permutation.
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][L]',v_base_date+11,time '10:00',time '11:00',array[v_a1,v_a1]);
  insert into test_results values (12,'L. duplicate lane IDs are deduplicated',v_result->>'code'='created' and (select count(*) from public.event_lanes where event_id=(v_result->>'event_id')::uuid)=1,'Duplicate input creates one link.');

  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][M]',v_base_date+12,time '10:00',time '11:00',array[v_root_a,v_root_b]);
  insert into test_results values (13,'M. multi-root event',v_result->>'code'='created' and (select count(*) from public.event_lanes where event_id=(v_result->>'event_id')::uuid)=2,'Two roots are locked and linked.');

  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][N]',v_base_date+13,time '10:00',time '11:00',array[v_root_b,v_root_a]);
  insert into test_results values (14,'N. input permutation is stable',v_result->>'code'='created' and (select pg_catalog.array_agg(lane_id order by created_at,lane_id) from public.event_lanes where event_id=(v_result->>'event_id')::uuid)=array[v_root_a,v_root_b],'Links are inserted in lane_id order.');

  -- O-Q. Update flows.
  v_event_id := pg_temp.add_event('[TEST][6B-4C1][O-SEED]',v_base_date+14,time '10:00',time '11:00',true,array[v_a1]);
  v_result := pg_temp.call_update_v2(v_admin_id,v_event_id,'[TEST][6B-4C1][O]',v_base_date+14,time '11:00',time '12:00',array[v_a1]);
  insert into test_results values (15,'O. update within same root',v_result->>'code'='updated' and (select start_time=time '11:00' from public.events where id=v_event_id),'Same-family update succeeds.');

  v_event_id := pg_temp.add_event('[TEST][6B-4C1][P-SEED]',v_base_date+15,time '10:00',time '11:00',true,array[v_root_a]);
  v_result := pg_temp.call_update_v2(v_admin_id,v_event_id,'[TEST][6B-4C1][P]',v_base_date+15,time '10:00',time '11:00',array[v_root_b]);
  insert into test_results values (16,'P. update root A to root B',v_result->>'code'='updated' and (select pg_catalog.array_agg(lane_id order by lane_id) from public.event_lanes where event_id=v_event_id)=array[v_root_b],'Old and new families are locked together.');

  v_event_id := pg_temp.add_event('[TEST][6B-4C1][Q-SEED]',v_base_date+16,time '10:00',time '11:00',true,array[v_root_a]);
  v_result := pg_temp.call_update_v2(v_admin_id,v_event_id,'[TEST][6B-4C1][Q]',v_base_date+16,time '10:00',time '11:00',array[v_root_b,v_root_a]);
  insert into test_results values (17,'Q. update to multi-root',v_result->>'code'='updated' and (select pg_catalog.array_agg(lane_id order by lane_id) from public.event_lanes where event_id=v_event_id)=array[v_root_a,v_root_b],'Replacement is deterministic.');

  -- R-T. Activation conflicts.
  perform pg_temp.add_reservation(v_reservation_user_id,v_a1,v_base_date+17,time '10:00',time '11:00',v_pricing_rule_id);
  v_event_id := pg_temp.add_event('[TEST][6B-4C1][R]',v_base_date+17,time '10:00',time '11:00',false,array[v_root_a]);
  v_result := pg_temp.call_active_v2(v_admin_id,v_event_id,true);
  insert into test_results values (18,'R. activation reservation conflict',v_result->>'code'='reservation_conflict' and not (select is_active from public.events where id=v_event_id),'Activation remains atomic.');

  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_a1,v_base_date+18,time '10:00',time '11:00','[TEST][6B-4C1][S]',true);
  v_event_id := pg_temp.add_event('[TEST][6B-4C1][S]',v_base_date+18,time '10:00',time '11:00',false,array[v_root_a]);
  v_result := pg_temp.call_active_v2(v_admin_id,v_event_id,true);
  insert into test_results values (19,'S. activation lane-block conflict',v_result->>'code'='lane_block_conflict' and not (select is_active from public.events where id=v_event_id),'Blocked activation does not change state.');

  perform pg_temp.add_event('[TEST][6B-4C1][T-SEED]',v_base_date+19,time '10:00',time '11:00',true,array[v_root_a]);
  v_event_id := pg_temp.add_event('[TEST][6B-4C1][T]',v_base_date+19,time '10:00',time '11:00',false,array[v_a1]);
  v_result := pg_temp.call_active_v2(v_admin_id,v_event_id,true);
  insert into test_results values (20,'T. activation event conflict',v_result->>'code'='event_conflict' and not (select is_active from public.events where id=v_event_id),'Self is excluded and another event is detected.');

  -- U-V. Deactivation and idempotency.
  v_event_id := pg_temp.add_event('[TEST][6B-4C1][U]',v_base_date+20,time '10:00',time '11:00',true,array[v_root_a]);
  v_result := pg_temp.call_active_v2(v_admin_id,v_event_id,false);
  insert into test_results values (21,'U. deactivation succeeds',v_result->>'code'='deactivated' and not (select is_active from public.events where id=v_event_id),'Deactivation performs no conflict check.');

  v_event_id := pg_temp.add_event('[TEST][6B-4C1][V]',v_base_date+21,time '07:00',time '21:00',false,'{}');
  v_result := pg_temp.call_active_v2(v_admin_id,v_event_id,true);
  v_result2 := pg_temp.call_active_v2(v_admin_id,v_event_id,true);
  perform pg_temp.call_active_v2(v_admin_id,v_event_id,false);
  v_result := pg_temp.call_active_v2(v_admin_id,v_event_id,false);
  insert into test_results values (22,'V. repeated activation and deactivation',v_result2->>'code'='no_change' and v_result->>'code'='no_change','Repeated state is idempotent.');

  -- W-Z. Roles.
  v_result := pg_temp.call_create_v2(v_user_id,'[TEST][6B-4C1][W]',v_base_date+22,time '10:00',time '11:00','{}');
  insert into test_results values (23,'W. unauthorized user',v_result->>'code'='not_allowed','User cannot manage events.');

  v_result := pg_temp.call_create_v2(v_instructor_id,'[TEST][6B-4C1][X]',v_base_date+23,time '10:00',time '11:00','{}');
  insert into test_results values (24,'X. instructor not allowed',v_result->>'code'='not_allowed','Instructor cannot manage events.');

  v_result := pg_temp.call_create_v2(v_employee_id,'[TEST][6B-4C1][Y]',v_base_date+24,time '10:00',time '11:00',array[v_standalone]);
  insert into test_results values (25,'Y. employee allowed',v_result->>'code'='created','Employee may create through V2.');

  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][Z]',v_base_date+25,time '10:00',time '11:00',array[v_standalone]);
  insert into test_results values (26,'Z. admin allowed',v_result->>'code'='created','Admin may create through V2.');

  -- AA-AC. Error and global contracts.
  v_result := pg_temp.call_update_v2(v_admin_id,'6b4c1000-0000-4000-8000-000000009999','[TEST][6B-4C1][AA]',v_base_date+26,time '10:00',time '11:00','{}');
  insert into test_results values (27,'AA. event not found',v_result->>'code'='event_not_found','Missing target is controlled.');

  v_result := pg_temp.call_create_v2(v_admin_id,null,v_base_date+27,time '11:00',time '10:00',array[v_root_a,null]);
  insert into test_results values (28,'AB. malformed input',v_result->>'code'='invalid_input','Malformed values fail closed.');

  perform pg_temp.add_reservation(v_reservation_user_id,v_a1,v_base_date+28,time '10:00',time '11:00',v_pricing_rule_id);
  insert into public.lane_blocks(lane_id,block_date,start_time,end_time,reason,is_active)
  values (v_b1,v_base_date+28,time '10:00',time '11:00','[TEST][6B-4C1][AC]',true);
  perform pg_temp.add_event('[TEST][6B-4C1][AC-SEED]',v_base_date+28,time '10:00',time '11:00',true,array[v_a2]);
  v_result := pg_temp.call_create_v2(v_admin_id,'[TEST][6B-4C1][AC]',v_base_date+28,time '07:00',time '21:00','{}');
  insert into test_results values (29,'AC. global event bypasses family conflicts',v_result->>'code'='created' and not exists(select 1 from public.event_lanes where event_id=(v_result->>'event_id')::uuid),'Global events do not call lane conflict scope.');

  -- AD-AH. Static security and unchanged dependencies.
  insert into test_results values (30,'AD. ACL security and search_path',
    (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('admin_create_event_v2','admin_update_event_v2','admin_set_event_active_v2') and p.prosecdef and p.provolatile='v' and pg_catalog.pg_get_userbyid(p.proowner)='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])=3
    and pg_catalog.has_function_privilege('authenticated','public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.admin_set_event_active_v2(uuid,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.admin_set_event_active_v2(uuid,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.admin_set_event_active_v2(uuid,boolean)','EXECUTE')
    and not exists(select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a where p.proname in ('admin_create_event_v2','admin_update_event_v2','admin_set_event_active_v2') and a.grantee=0 and a.privilege_type='EXECUTE'),
    'Exactly three SECURITY DEFINER RPCs expose EXECUTE only to authenticated.');

  insert into test_results values (31,'AE. Event V1 fingerprints unchanged',
    pg_temp.function_fingerprint('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')=(select fingerprint from baseline_fingerprints where signature='public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')
    and pg_temp.function_fingerprint('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')=(select fingerprint from baseline_fingerprints where signature='public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')
    and pg_temp.function_fingerprint('public.admin_set_event_active(uuid,boolean)')=(select fingerprint from baseline_fingerprints where signature='public.admin_set_event_active(uuid,boolean)'),
    'All three live V1 definitions and ACL remain identical.');

  insert into test_results values (32,'AF. multi-family helper unchanged',
    pg_temp.function_fingerprint('public.lock_lane_conflict_families_v1(uuid[])')=(select fingerprint from baseline_fingerprints where signature='public.lock_lane_conflict_families_v1(uuid[])'),
    'Global family lock helper is unchanged.');

  insert into test_results values (33,'AG. create_reservation_v2 unchanged',
    pg_temp.function_fingerprint('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)')=(select fingerprint from baseline_fingerprints where signature='public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'),
    'Reservation V2 is unchanged.');

  insert into test_results values (34,'AH. lane-block RPCs unchanged',
    pg_temp.function_fingerprint('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)')=(select fingerprint from baseline_fingerprints where signature='public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)')
    and pg_temp.function_fingerprint('public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)')=(select fingerprint from baseline_fingerprints where signature='public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)')
    and pg_temp.function_fingerprint('public.admin_set_lane_block_active(uuid,boolean)')=(select fingerprint from baseline_fingerprints where signature='public.admin_set_lane_block_active(uuid,boolean)'),
    'Hierarchy-aware lane-block writers are unchanged.');
end;
$contract_tests$;

select test_order,test_name,passed,result
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

  if (select count(*) from test_results) <> 34 then
    raise exception 'Expected exactly 34 Event V2 contract controls.';
  end if;

  if v_failures is not null then
    raise exception 'Event V2 contract tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

with function_state as (
  select
    function_record.oid::pg_catalog.regprocedure::text as signature,
    pg_catalog.md5(pg_catalog.jsonb_build_object(
      'definition', pg_catalog.pg_get_functiondef(function_record.oid),
      'owner', owner_role.rolname,
      'language', language_record.lanname,
      'volatility', function_record.provolatile,
      'security_definer', function_record.prosecdef,
      'config', coalesce(pg_catalog.to_jsonb(function_record.proconfig), '[]'::jsonb),
      'acl', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'grantor', pg_catalog.pg_get_userbyid(privilege_record.grantor),
          'grantee', case when privilege_record.grantee=0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,
          'privilege', privilege_record.privilege_type,
          'grantable', privilege_record.is_grantable
        ) order by case when privilege_record.grantee=0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(privilege_record.grantee) end,privilege_record.privilege_type,pg_catalog.pg_get_userbyid(privilege_record.grantor))
        from pg_catalog.aclexplode(coalesce(function_record.proacl,pg_catalog.acldefault('f',function_record.proowner))) as privilege_record
      ),'[]'::jsonb)
    )::text) as fingerprint
  from pg_catalog.pg_proc as function_record
  join pg_catalog.pg_roles as owner_role on owner_role.oid=function_record.proowner
  join pg_catalog.pg_language as language_record on language_record.oid=function_record.prolang
  where function_record.oid in (
    'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::pg_catalog.regprocedure,
    'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::pg_catalog.regprocedure,
    'public.admin_set_event_active(uuid,boolean)'::pg_catalog.regprocedure,
    'public.lock_lane_conflict_families_v1(uuid[])'::pg_catalog.regprocedure,
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure,
    'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'::pg_catalog.regprocedure,
    'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::pg_catalog.regprocedure,
    'public.admin_set_lane_block_active(uuid,boolean)'::pg_catalog.regprocedure
  )
)
select
  pg_catalog.to_regprocedure('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is null
  and pg_catalog.to_regprocedure('public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is null
  and pg_catalog.to_regprocedure('public.admin_set_event_active_v2(uuid,boolean)') is null
  and not exists(select 1 from public.events where title like '[TEST][6B-4C1]%')
  and not exists(select 1 from public.shooting_lanes where name like '[TEST][6B-4C1]%')
  and not exists(select 1 from auth.users where email like 'test-6b4c1-%@example.invalid')
  and (select fingerprint from function_state where signature='admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')=:'v1_create_fp'
  and (select fingerprint from function_state where signature='admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])')=:'v1_update_fp'
  and (select fingerprint from function_state where signature='admin_set_event_active(uuid,boolean)')=:'v1_active_fp'
  and (select fingerprint from function_state where signature='lock_lane_conflict_families_v1(uuid[])')=:'family_helper_fp'
  and (select fingerprint from function_state where signature='create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)')=:'reservation_v2_fp'
  and (select fingerprint from function_state where signature='admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)')=:'block_create_fp'
  and (select fingerprint from function_state where signature='admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)')=:'block_update_fp'
  and (select fingerprint from function_state where signature='admin_set_lane_block_active(uuid,boolean)')=:'block_active_fp'
  as rollback_confirmed;
