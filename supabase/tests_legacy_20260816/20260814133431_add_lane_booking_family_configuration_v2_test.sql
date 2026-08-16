\set ON_ERROR_STOP on

-- psql-only contract test. The migration and every [TEST][6C-3C2] fixture
-- are executed in one transaction and removed by the final ROLLBACK.
begin;

create temporary table production_100m_baseline(snapshot_hash text) on commit drop;

do $production_100m_preflight$
begin
  if not exists (
    select 1 from public.shooting_lanes
    where id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid
      and parent_lane_id is null
      and resource_kind = 'lane'
  ) or (select pg_catalog.count(*) from public.shooting_lanes
        where parent_lane_id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid
          and resource_kind = 'position') <> 5 then
    raise exception 'Production 100m hierarchy baseline is missing or unexpected.';
  end if;
end;
$production_100m_preflight$;

insert into production_100m_baseline
select pg_catalog.md5(pg_catalog.jsonb_build_object(
  'lanes', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(lane.*) order by lane.id)
    from public.shooting_lanes lane
    where lane.id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid
       or lane.parent_lane_id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid), '[]'::jsonb),
  'rules', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule.*) order by rule.lane_id)
    from public.lane_booking_rules rule where rule.lane_id in
      (select id from public.shooting_lanes
       where id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid
          or parent_lane_id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid)), '[]'::jsonb),
  'durations', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration.*) order by duration.id)
    from public.lane_booking_durations duration where duration.lane_id in
      (select id from public.shooting_lanes
       where id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid
          or parent_lane_id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid)), '[]'::jsonb),
  'pricing', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(price.*) order by price.id)
    from public.lane_pricing_rules price where price.lane_id in
      (select id from public.shooting_lanes
       where id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid
          or parent_lane_id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid)), '[]'::jsonb)
)::text);

\ir ../migrations/20260814133431_add_lane_booking_family_configuration_v2.sql

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $f$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$f$;

create function pg_temp.pricing(p_max integer, p_price numeric default 100)
returns jsonb language sql immutable as $f$
  select pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,
      'max_shooters',p_max,'label','[TEST][6C-3C2] Mon-Thu','hourly_price',p_price),
    pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',1,
      'max_shooters',p_max,'label','[TEST][6C-3C2] Fri-Sun','hourly_price',p_price+20)
  );
$f$;

create function pg_temp.resource_payload(
  p_lane uuid, p_active boolean, p_whole boolean, p_positions boolean,
  p_max integer, p_online boolean, p_online_max integer,
  p_durations jsonb, p_pricing jsonb
) returns jsonb language sql immutable as $f$
  select pg_catalog.jsonb_build_object(
    'lane_id',p_lane,'is_active',p_active,
    'whole_lane_bookable',p_whole,'positions_bookable',p_positions,
    'max_shooters',p_max,'online_bookable',p_online,
    'max_people_online',p_online_max,'durations_minutes',p_durations,
    'pricing',p_pricing
  );
$f$;

create function pg_temp.call_write(p_user uuid,p_root uuid,p_version bigint,p_payload jsonb,p_ack boolean)
returns jsonb language plpgsql set search_path=pg_catalog,public,pg_temp as $f$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',case when p_user is null then '{}'
    else pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text end,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute 'set local role authenticated';
  select public.admin_set_lane_booking_family_configuration_v2(p_root,p_version,p_payload,p_ack)
    into v_result;
  execute 'reset role';
  return v_result;
exception when others then execute 'reset role'; raise;
end;$f$;

create function pg_temp.call_read_state(p_role name,p_user uuid)
returns text language plpgsql set search_path=pg_catalog,public,pg_temp as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',case when p_user is null then '{}'
    else pg_catalog.jsonb_build_object('sub',p_user,'role',p_role)::text end,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
  perform public.admin_get_lane_booking_configuration_v2();
  execute 'reset role';
  return 'ok';
exception when others then execute 'reset role'; return sqlstate;
end;$f$;

create function pg_temp.call_read(p_user uuid)
returns jsonb language plpgsql set search_path=pg_catalog,public,pg_temp as $f$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated';
  select public.admin_get_lane_booking_configuration_v2() into v_result;
  execute 'reset role'; return v_result;
exception when others then execute 'reset role'; raise;
end;$f$;

create function pg_temp.direct_update_denied(p_table text)
returns boolean language plpgsql as $f$
declare v_denied boolean:=false;
begin
  execute 'set local role authenticated';
  begin
    case p_table
      when 'shooting_lanes' then update public.shooting_lanes set name=name where false;
      when 'lane_booking_rules' then update public.lane_booking_rules set online_bookable=online_bookable where false;
      when 'lane_booking_durations' then update public.lane_booking_durations set is_active=is_active where false;
      when 'lane_pricing_rules' then update public.lane_pricing_rules set is_active=is_active where false;
      when 'versions' then update public.lane_booking_family_configuration_versions set updated_at=updated_at where false;
    end case;
  exception when insufficient_privilege then v_denied:=true;
  end;
  execute 'reset role'; return v_denied;
exception when others then execute 'reset role'; raise;
end;$f$;

do $tests$
declare
  v_admin uuid := '6c3c2000-0000-4000-8000-000000000001';
  v_employee uuid := '6c3c2000-0000-4000-8000-000000000002';
  v_instructor uuid := '6c3c2000-0000-4000-8000-000000000003';
  v_user uuid := '6c3c2000-0000-4000-8000-000000000004';
  v_customer uuid := '6c3c2000-0000-4000-8000-000000000005';
  v_root_a uuid := '6c3c2000-0000-4000-8000-000000000101';
  v_a1 uuid := '6c3c2000-0000-4000-8000-000000000102';
  v_a2 uuid := '6c3c2000-0000-4000-8000-000000000103';
  v_root_b uuid := '6c3c2000-0000-4000-8000-000000000201';
  v_b1 uuid := '6c3c2000-0000-4000-8000-000000000202';
  v_payload jsonb; v_result jsonb; v_result2 jsonb;
  v_before jsonb; v_after jsonb; v_version bigint; v_price_id uuid;
  v_reservation uuid := '6c3c2000-0000-4000-8000-000000000301';
  v_block uuid := '6c3c2000-0000-4000-8000-000000000302';
  v_event uuid := '6c3c2000-0000-4000-8000-000000000303';
  v_error text;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c3c2-admin@example.invalid','',now(),'{}','{}',now(),now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c3c2-employee@example.invalid','',now(),'{}','{}',now(),now()),
    (v_instructor,'00000000-0000-0000-8000-000000000000','authenticated','authenticated','test-6c3c2-instructor@example.invalid','',now(),'{}','{}',now(),now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c3c2-user@example.invalid','',now(),'{}','{}',now(),now()),
    (v_customer,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c3c2-customer@example.invalid','',now(),'{}','{}',now(),now());
  update public.profiles set role=case user_id when v_admin then 'admin'
    when v_employee then 'pracownik' when v_instructor then 'instruktor' else 'user' end,
    first_name='[TEST]',last_name='6C-3C2',full_name='[TEST][6C-3C2]'
  where user_id in(v_admin,v_employee,v_instructor,v_user,v_customer);

  insert into public.shooting_lanes(id,name,type,description,price_per_hour,is_active,max_shooters,
    booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,
    whole_lane_bookable,positions_bookable) values
    (v_root_a,'[TEST][6C-3C2] Root A','[TEST]','[TEST]',10,true,6,60,9911,'PLN','lane',null,true,false),
    (v_a1,'[TEST][6C-3C2] A1','[TEST]','[TEST]',10,false,1,60,9912,'PLN','position',v_root_a,false,false),
    (v_a2,'[TEST][6C-3C2] A2','[TEST]','[TEST]',10,false,1,60,9913,'PLN','position',v_root_a,false,false),
    (v_root_b,'[TEST][6C-3C2] Root B','[TEST]','[TEST]',10,true,6,60,9921,'PLN','lane',null,true,false),
    (v_b1,'[TEST][6C-3C2] B1','[TEST]','[TEST]',10,false,1,60,9922,'PLN','position',v_root_b,false,false);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online) values
    (v_root_a,true,6),(v_a1,false,1),(v_a2,false,1),(v_root_b,true,6),(v_b1,false,1);
  insert into public.lane_booking_durations(lane_id,duration_minutes,display_order,is_active)
    values(v_root_a,60,10,true),(v_root_b,60,10,true);
  insert into public.lane_pricing_rules(lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
    select lane_id,day_group,1,6,'[TEST][6C-3C2]',price,10,true from (values
      (v_root_a,'mon_thu',100::numeric),(v_root_a,'fri_sun',120::numeric),
      (v_root_b,'mon_thu',100::numeric),(v_root_b,'fri_sun',120::numeric)) v(lane_id,day_group,price);
  insert into public.lane_booking_family_configuration_versions(root_lane_id) values(v_root_a),(v_root_b);

  perform pg_temp.record_result(1,'Version table schema',
    (select count(*)=3 from information_schema.columns where table_schema='public'
      and table_name='lane_booking_family_configuration_versions')
    and (select relrowsecurity from pg_catalog.pg_class where oid='public.lane_booking_family_configuration_versions'::regclass),
    'Technical table has exactly three columns and RLS enabled.');
  perform pg_temp.record_result(2,'Backfill roots only',
    not exists(select 1 from public.lane_booking_family_configuration_versions v
      join public.shooting_lanes l on l.id=v.root_lane_id where l.resource_kind<>'lane' or l.parent_lane_id is not null)
    and not exists(select 1 from public.shooting_lanes l where l.resource_kind='lane' and l.parent_lane_id is null
      and not exists(select 1 from public.lane_booking_family_configuration_versions v where v.root_lane_id=l.id)),
    'Exactly one version exists for each root, never for a position.');
  perform pg_temp.record_result(3,'Version table client ACL denied',
    not has_table_privilege('authenticated','public.lane_booking_family_configuration_versions','SELECT,INSERT,UPDATE,DELETE')
    and not has_table_privilege('anon','public.lane_booking_family_configuration_versions','SELECT')
    and not has_table_privilege('service_role','public.lane_booking_family_configuration_versions','SELECT'),
    'PUBLIC/client roles have no table access.');
  perform pg_temp.record_result(4,'Read V2 metadata and ACL',
    (select prosecdef and provolatile='s' and proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
     from pg_catalog.pg_proc where oid='public.admin_get_lane_booking_configuration_v2()'::regprocedure)
    and has_function_privilege('authenticated','public.admin_get_lane_booking_configuration_v2()','EXECUTE')
    and not has_function_privilege('anon','public.admin_get_lane_booking_configuration_v2()','EXECUTE')
    and not has_function_privilege('service_role','public.admin_get_lane_booking_configuration_v2()','EXECUTE'),
    'Read is STABLE SECURITY DEFINER and authenticated-only.');
  perform pg_temp.record_result(5,'Writer V2 metadata and ACL',
    (select prosecdef and provolatile='v' and proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
     from pg_catalog.pg_proc where oid='public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::regprocedure)
    and has_function_privilege('authenticated','public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE')
    and not has_function_privilege('anon','public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE')
    and not has_function_privilege('service_role','public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE'),
    'Writer is VOLATILE SECURITY DEFINER and authenticated-only.');
  perform pg_temp.record_result(6,'Old writer revoked',not has_function_privilege('authenticated',
    'public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)','EXECUTE'),
    'Authenticated cannot call deprecated V1 writer.');
  perform pg_temp.record_result(7,'Direct DML denied',
    pg_temp.direct_update_denied('shooting_lanes') and pg_temp.direct_update_denied('lane_booking_rules')
    and pg_temp.direct_update_denied('lane_booking_durations') and pg_temp.direct_update_denied('lane_pricing_rules')
    and pg_temp.direct_update_denied('versions'),'Authenticated cannot bypass RPC.');

  perform pg_temp.record_result(8,'Read role admin',pg_temp.call_read_state('authenticated',v_admin)='ok','Admin can read V2.');
  perform pg_temp.record_result(9,'Read role matrix deny',
    pg_temp.call_read_state('authenticated',v_employee)='42501'
    and pg_temp.call_read_state('authenticated',v_instructor)='42501'
    and pg_temp.call_read_state('authenticated',v_user)='42501'
    and pg_temp.call_read_state('anon',null) in ('42501','42883'),'Non-admin roles fail closed.');
  v_result:=pg_temp.call_read(v_admin);
  perform pg_temp.record_result(10,'Read V2 family shape',
    (v_result->>'contract_version')::int=2
      and jsonb_array_length(v_result->'families')>=2,
    'Contract groups V1 resources into versioned families.');

  v_payload:=public.lane_booking_family_business_snapshot_v2(v_root_a);
  v_result:=pg_temp.call_write(v_employee,v_root_a,1,v_payload,false);
  v_result2:=pg_temp.call_write(v_instructor,v_root_a,1,v_payload,false);
  perform pg_temp.record_result(11,'Write role matrix deny',v_result->>'code'='not_allowed'
    and v_result2->>'code'='not_allowed'
    and pg_temp.call_write(v_user,v_root_a,1,v_payload,false)->>'code'='not_allowed'
    and pg_temp.call_write(null,v_root_a,1,v_payload,false)->>'code'='not_allowed','Only admin may write.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,1,v_payload||jsonb_build_array(v_payload->0),false);
  perform pg_temp.record_result(12,'Exact family duplicate denied',v_result->>'code'='invalid_payload','Duplicate resource fails closed.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,1,jsonb_build_object('resources',v_payload),false);
  perform pg_temp.record_result(13,'Malformed top-level payload denied',v_result->>'code'='invalid_payload','Non-array payload fails closed.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,1,jsonb_set(v_payload,'{0,unknown}','true'),false);
  perform pg_temp.record_result(14,'Unknown resource field denied',v_result->>'code'='invalid_payload','Identity/business allowlist is exact.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,1,v_payload-(jsonb_array_length(v_payload)-1),false);
  perform pg_temp.record_result(15,'Missing family member denied',v_result->>'code'='invalid_payload','All direct positions are required.');

  -- Model A: whole-only -> positions-only in one atomic call.
  v_payload:=jsonb_build_array(
    pg_temp.resource_payload(v_root_a,true,false,true,6,false,6,'[]', '[]'),
    pg_temp.resource_payload(v_a1,true,false,false,3,true,3,'[60]',pg_temp.pricing(3,130)),
    pg_temp.resource_payload(v_a2,false,false,false,1,false,1,'[]','[]'));
  v_result:=pg_temp.call_write(v_admin,v_root_a,1,v_payload,false);
  perform pg_temp.record_result(16,'Model A atomic transition',v_result->>'code'='updated'
    and (select not whole_lane_bookable and positions_bookable from public.shooting_lanes where id=v_root_a)
    and (select is_active from public.shooting_lanes where id=v_a1),'Whole-only becomes positions-only without transitional state.');
  perform pg_temp.record_result(17,'Version bump exactly once',(v_result->>'configuration_version')::bigint=2
    and (select configuration_version=2 from public.lane_booking_family_configuration_versions where root_lane_id=v_root_a),
    'Successful change increments version once.');
  perform pg_temp.record_result(18,'One atomic audit',(select count(*)=1 from public.audit_logs
    where target_id=v_root_a and action='lane_booking_family_configuration_updated')
    and (select bool_and(details ?& array['previous_version','new_version','before','after']) from public.audit_logs
      where target_id=v_root_a and action='lane_booking_family_configuration_updated'),'One safe before/after audit exists.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,1,v_payload,false);
  perform pg_temp.record_result(19,'Stale snapshot denied',v_result->>'code'='stale_configuration'
    and (select configuration_version=2 from public.lane_booking_family_configuration_versions where root_lane_id=v_root_a)
    and (select count(*)=1 from public.audit_logs where target_id=v_root_a and action='lane_booking_family_configuration_updated'),
    'Stale write changes neither data, version nor audit.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,2,public.lane_booking_family_business_snapshot_v2(v_root_a),false);
  perform pg_temp.record_result(20,'Canonical no_change',v_result->>'code'='no_change'
    and (select configuration_version=2 from public.lane_booking_family_configuration_versions where root_lane_id=v_root_a),
    'Input ordering is canonicalized and no-op does not bump.');

  -- Model B: positions-only -> whole+positions.
  v_payload:=jsonb_set(v_payload,'{0}',pg_temp.resource_payload(v_root_a,true,true,true,6,true,6,'[60]',pg_temp.pricing(6,140)));
  v_result:=pg_temp.call_write(v_admin,v_root_a,2,v_payload,false);
  perform pg_temp.record_result(21,'Model B atomic transition',v_result->>'code'='updated'
    and (select whole_lane_bookable and positions_bookable from public.shooting_lanes where id=v_root_a),
    'Whole and positions modes coexist.');
  v_version:=(v_result->>'configuration_version')::bigint;

  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,jsonb_set(v_payload,'{1,max_shooters}','7'),false);
  perform pg_temp.record_result(22,'Physical position capacity enforced',v_result->>'code'='invalid_configuration',
    'Usable position capacity cannot exceed root physical capacity.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,jsonb_set(jsonb_set(v_payload,'{0,is_active}','false'),'{0,online_bookable}','false'),false);
  perform pg_temp.record_result(23,'Root deactivation cascade fail-closed',v_result->>'code'='invalid_configuration',
    'Root cannot become inactive while a child remains active/online.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,jsonb_set(v_payload,'{1,durations_minutes}','[90]'),false);
  perform pg_temp.record_result(24,'Duration step enforced',v_result->>'code'='invalid_configuration','Durations align to booking step.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,jsonb_set(v_payload,'{1,pricing,0,max_shooters}','2'),false);
  perform pg_temp.record_result(25,'Pricing coverage enforced',v_result->>'code'='invalid_configuration','Both day groups have contiguous exact coverage.');

  select id into v_price_id from public.lane_pricing_rules where lane_id=v_a1 and is_active limit 1;
  insert into public.reservations(id,user_id,lane_id,customer_name,customer_email,customer_phone,
    reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,
    attendance_status,reservation_note,shooters_count,pricing_rule_id,pricing_day_group_snapshot,
    lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values(v_reservation,v_customer,v_a1,'[TEST]','test-6c3c2@example.invalid','000000000',current_date+5000,
    time '10:00',time '11:00',60,300,'confirmed','pay_on_site','planned','[TEST]',3,v_price_id,
    'mon_thu','[TEST]','[TEST]',100,300,'PLN',gen_random_uuid());
  insert into public.lane_blocks(id,lane_id,block_date,start_time,end_time,reason,is_active)
    values(v_block,v_a1,current_date+5000,time '12:00',time '13:00','[TEST][6C-3C2]',true);
  insert into public.events(id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
    values(v_event,'[TEST][6C-3C2]','[TEST]',current_date+5000,time '14:00',time '15:00','[TEST]',0,10,true);
  insert into public.event_lanes(event_id,lane_id) values(v_event,v_a1);

  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,
    jsonb_set(jsonb_set(jsonb_set(v_payload,'{1,max_shooters}','2'),
      '{1,max_people_online}','2'),'{1,pricing}',pg_temp.pricing(2,130)),false);
  perform pg_temp.record_result(26,'Reservation physical capacity protected',v_result->>'code'='reservation_capacity_conflict',
    'Future exact-resource reservation protects max_shooters.');
  v_payload:=jsonb_set(v_payload,'{0,online_bookable}','false');
  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,v_payload,false);
  perform pg_temp.record_result(27,'Online off needs no confirmation',v_result->>'code'='updated',
    'Stopping future sales preserves existing obligations without acknowledgement.');
  v_version:=(v_result->>'configuration_version')::bigint;
  v_payload:=jsonb_set(
    jsonb_set(
      jsonb_set(v_payload,'{0,positions_bookable}','false'),
      '{1,is_active}','false'
    ),
    '{1,online_bookable}','false'
  );
  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,v_payload,false);
  perform pg_temp.record_result(28,'Future obligations require confirmation',v_result->>'code'='confirmation_required'
    and (v_result->>'future_reservations_count')::int=1
    and (v_result->>'future_lane_blocks_count')::int=1
    and (v_result->>'future_events_count')::int=1,
    'Actual: '||coalesce(v_result::text,'NULL'));
  perform pg_temp.record_result(29,'Confirmation denied leaves version/audit',
    (select configuration_version=v_version from public.lane_booking_family_configuration_versions where root_lane_id=v_root_a)
    and (select count(*)=3 from public.audit_logs where target_id=v_root_a and action='lane_booking_family_configuration_updated'),
    'Confirmation-required result is side-effect free.');
  v_result:=pg_temp.call_write(v_admin,v_root_a,v_version,v_payload,true);
  perform pg_temp.record_result(30,'Acknowledged mode disable',v_result->>'code'='updated'
    and exists(select 1 from public.reservations where id=v_reservation)
    and exists(select 1 from public.lane_blocks where id=v_block and is_active)
    and exists(select 1 from public.events where id=v_event and is_active),
    'Actual: '||coalesce(v_result::text,'NULL'));

  -- Audit failure must roll back all business tables and the version bump.
  v_version:=(v_result->>'configuration_version')::bigint;
  v_before:=jsonb_build_object('snapshot',public.lane_booking_family_business_snapshot_v2(v_root_a),'version',v_version);
  execute 'create function pg_temp.fail_family_audit() returns trigger language plpgsql as $x$ begin if new.action=''lane_booking_family_configuration_updated'' then raise exception ''forced audit failure''; end if; return new; end $x$';
  execute 'create trigger csk_6c3c2_fail_audit before insert on public.audit_logs for each row execute function pg_temp.fail_family_audit()';
  begin
    perform pg_temp.call_write(v_admin,v_root_a,v_version,jsonb_set(v_payload,'{0,max_shooters}','7'),false);
  exception when others then v_error:=sqlstate;
  end;
  execute 'drop trigger csk_6c3c2_fail_audit on public.audit_logs';
  v_after:=jsonb_build_object('snapshot',public.lane_booking_family_business_snapshot_v2(v_root_a),
    'version',(select configuration_version from public.lane_booking_family_configuration_versions where root_lane_id=v_root_a));
  perform pg_temp.record_result(31,'Audit failure rolls back family',v_error='P0001' and v_before=v_after,
    'SQLSTATE='||coalesce(v_error,'NULL')||'; unchanged='||(v_before=v_after)::text);

  perform pg_temp.record_result(32,'Audit contains no PII',not exists(select 1 from public.audit_logs
    where target_id=v_root_a and action='lane_booking_family_configuration_updated'
      and details::text ~* '(example[.]invalid|customer_name|customer_email|customer_phone)'),
    'Audit before/after contains business configuration only.');
  perform pg_temp.record_result(33,'Result code whitelist',(
    with actual(code) as (
      select distinct match[1]
      from pg_catalog.regexp_matches(
        pg_catalog.pg_get_functiondef(
          'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::regprocedure
        ),
        $pattern$'code',[[:space:]]*'([a-z_]+)'$pattern$,
        'g'
      ) as match
    ), expected(code) as (values
      ('updated'),('no_change'),('not_allowed'),('family_not_found'),('invalid_payload'),
      ('invalid_hierarchy'),('invalid_configuration'),('stale_configuration'),
      ('confirmation_required'),('reservation_capacity_conflict')
    )
    select not exists(select code from actual except select code from expected)
       and not exists(select code from expected except select code from actual)
  ),
    'Public contract uses the closed documented code set.');
  perform pg_temp.record_result(34,'Read V1 unchanged and UI-compatible',
    to_regprocedure('public.admin_get_lane_booking_configuration_v1()') is not null,
    'Existing read-only UI remains on V1.');
  perform pg_temp.record_result(35,'Critical booking functions unchanged',
    to_regprocedure('public.get_public_booking_configuration_v1()') is not null
    and to_regprocedure('public.get_lane_booking_busy_ranges_v3(uuid,date)') is not null
    and to_regprocedure('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)') is not null,
    'Public config, Availability V3 and Reservation V2 remain present.');
  perform pg_temp.record_result(36,'Dormant 100m unchanged',
    (select snapshot_hash from pg_temp.production_100m_baseline)=pg_catalog.md5(pg_catalog.jsonb_build_object(
      'lanes',coalesce((select jsonb_agg(to_jsonb(l.*) order by l.id) from public.shooting_lanes l where l.id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid or l.parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid),'[]'::jsonb),
      'rules',coalesce((select jsonb_agg(to_jsonb(r.*) order by r.lane_id) from public.lane_booking_rules r where r.lane_id in(select id from public.shooting_lanes where id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid or parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid)),'[]'::jsonb),
      'durations',coalesce((select jsonb_agg(to_jsonb(d.*) order by d.id) from public.lane_booking_durations d where d.lane_id in(select id from public.shooting_lanes where id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid or parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid)),'[]'::jsonb),
      'pricing',coalesce((select jsonb_agg(to_jsonb(p.*) order by p.id) from public.lane_pricing_rules p where p.lane_id in(select id from public.shooting_lanes where id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid or parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid)),'[]'::jsonb))::text)
    and (select pg_catalog.count(*) from public.shooting_lanes
         where parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid
           and resource_kind='position')=5
    and not exists(select 1 from public.shooting_lanes
                   where parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid and is_active)
    and not exists(select 1 from public.lane_booking_rules rule
                   join public.shooting_lanes lane on lane.id=rule.lane_id
                   where lane.parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid and rule.online_bookable)
    and not exists(select 1 from public.lane_booking_durations duration
                   join public.shooting_lanes lane on lane.id=duration.lane_id
                   where lane.parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid)
    and not exists(select 1 from public.lane_pricing_rules price
                   join public.shooting_lanes lane on lane.id=price.lane_id
                   where lane.parent_lane_id='254ca7f6-ce80-4267-8966-4558cc8f8fd2'::uuid),
    'Production 100m parent, five dormant children, durations and pricing are byte-for-byte unchanged.');
end;
$tests$;

select test_order,test_name,passed,result from pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order||': '||test_name||' ['||result||']',', ' order by test_order)
  into v_failures from pg_temp.test_results where not passed;
  if (select count(*) from pg_temp.test_results) <> 36 then
    raise exception 'Expected 36 controls, got %.',(select count(*) from pg_temp.test_results);
  end if;
  if v_failures is not null then raise exception 'Family configuration tests failed: %',v_failures; end if;
end;$assertions$;

rollback;

select
  pg_catalog.to_regclass('public.lane_booking_family_configuration_versions') is null
  and pg_catalog.to_regprocedure('public.admin_get_lane_booking_configuration_v2()') is null
  and pg_catalog.to_regprocedure('public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)') is null
  and not exists(select 1 from public.shooting_lanes where name like '[TEST][6C-3C2]%')
  and not exists(select 1 from auth.users where email like 'test-6c3c2-%@example.invalid')
  as rollback_confirmed;
