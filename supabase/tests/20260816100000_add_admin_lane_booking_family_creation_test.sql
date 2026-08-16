\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

-- Current-state pgTAP-compatible contract test. The consolidated baseline and
-- subsequent migrations already provide the RPC under test. Every [TEST][6C-3J]
-- fixture is created in one transaction and removed by the final ROLLBACK.
select '1..22';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.resource_payload(
  p_name text,
  p_max integer default 2,
  p_active boolean default false,
  p_online boolean default false
)
returns jsonb
language sql
immutable
as $function$
  select pg_catalog.jsonb_build_object(
    'name',p_name,
    'is_active',p_active,
    'online_bookable',p_online,
    'max_shooters',p_max,
    'max_people_online',p_max,
    'booking_step_minutes',60,
    'durations_minutes',pg_catalog.jsonb_build_array(60,120),
    'pricing',pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'day_group','mon_thu','min_shooters',1,'max_shooters',p_max,
        'label','[TEST][6C-3J] Pon-Czw','hourly_price',100
      ),
      pg_catalog.jsonb_build_object(
        'day_group','fri_sun','min_shooters',1,'max_shooters',p_max,
        'label','[TEST][6C-3J] Pt-Nd','hourly_price',120
      )
    )
  );
$function$;

create function pg_temp.family_payload(
  p_name text,
  p_positions jsonb default '[]'::jsonb,
  p_active boolean default false,
  p_online boolean default false,
  p_whole boolean default true,
  p_positions_bookable boolean default false,
  p_max integer default 2
)
returns jsonb
language sql
immutable
as $function$
  select pg_catalog.jsonb_build_object(
    'root',pg_temp.resource_payload(p_name,p_max,p_active,p_online)
      || pg_catalog.jsonb_build_object(
        'whole_lane_bookable',p_whole,
        'positions_bookable',p_positions_bookable
      ),
    'positions',p_positions
  );
$function$;

create function pg_temp.call_create(p_user uuid,p_payload jsonb)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute 'set local role authenticated';
  select public.admin_create_lane_booking_family_v1(p_payload) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $tests$
declare
  v_admin uuid := '6c3f0000-0000-4000-8000-000000000031';
  v_employee uuid := '6c3f0000-0000-4000-8000-000000000032';
  v_instructor uuid := '6c3f0000-0000-4000-8000-000000000033';
  v_user uuid := '6c3f0000-0000-4000-8000-000000000034';
  v_result jsonb;
  v_payload jsonb;
  v_root uuid;
  v_hierarchy_root uuid;
  v_before bigint;
  v_invalid_name text;
  v_names_rejected boolean := true;
begin
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-6c3j-admin@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-6c3j-employee@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-6c3j-instructor@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-6c3j-user@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(
    user_id, role, first_name, last_name, full_name, email
  ) values
    (v_admin,'admin','[TEST]','6C-3J','[TEST][6C-3J]',
      'test-6c3j-admin@example.invalid'),
    (v_employee,'pracownik','[TEST]','6C-3J','[TEST][6C-3J]',
      'test-6c3j-employee@example.invalid'),
    (v_instructor,'instruktor','[TEST]','6C-3J','[TEST][6C-3J]',
      'test-6c3j-instructor@example.invalid'),
    (v_user,'user','[TEST]','6C-3J','[TEST][6C-3J]',
      'test-6c3j-user@example.invalid');

  perform pg_temp.record_result(1,'Creator security contract',
    (select procedure.prosecdef and procedure.provolatile='v'
       and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
       and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
     from pg_catalog.pg_proc procedure
     where procedure.oid='public.admin_create_lane_booking_family_v1(jsonb)'::pg_catalog.regprocedure)
    and pg_catalog.has_function_privilege('authenticated',
      'public.admin_create_lane_booking_family_v1(jsonb)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'public.admin_create_lane_booking_family_v1(jsonb)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role',
      'public.admin_create_lane_booking_family_v1(jsonb)','EXECUTE')
    and not exists(
      select 1 from pg_catalog.pg_proc procedure
      cross join lateral pg_catalog.aclexplode(coalesce(
        procedure.proacl,pg_catalog.acldefault('f',procedure.proowner)
      )) acl
      where procedure.oid='public.admin_create_lane_booking_family_v1(jsonb)'::pg_catalog.regprocedure
        and acl.grantee=0 and acl.privilege_type='EXECUTE'
    ),
    'SECURITY DEFINER, owner, search_path and ACL are exact.');

  perform pg_temp.record_result(2,'Direct authenticated writes remain denied',
    not has_table_privilege('authenticated','public.shooting_lanes','INSERT,UPDATE,DELETE')
    and not has_table_privilege('authenticated','public.lane_booking_rules','INSERT,UPDATE,DELETE')
    and not has_table_privilege('authenticated','public.lane_booking_durations','INSERT,UPDATE,DELETE')
    and not has_table_privilege('authenticated','public.lane_pricing_rules','INSERT,UPDATE,DELETE'),
    'Authenticated has no alternate direct-DML creation path.');

  v_result:=pg_temp.call_create(v_admin,pg_temp.family_payload('[TEST][6C-3J] Samodzielna'));
  v_root:=(v_result->>'root_lane_id')::uuid;
  perform pg_temp.record_result(3,'Standalone family creation',
    v_result->>'code'='created' and (v_result->>'created_resource_count')::integer=1
    and exists(select 1 from public.shooting_lanes lane
      where lane.id=v_root and lane.resource_kind='lane' and lane.parent_lane_id is null
        and not lane.is_active and lane.whole_lane_bookable and not lane.positions_bookable),
    'Admin creates one safe inactive/offline standalone lane.');

  perform pg_temp.record_result(4,'Standalone complete configuration',
    exists(select 1 from public.lane_booking_rules rule
      where rule.lane_id=v_root and not rule.online_bookable and rule.max_people_online=2)
    and (select count(*)=2 from public.lane_booking_durations where lane_id=v_root)
    and (select count(*)=2 from public.lane_pricing_rules where lane_id=v_root and is_active),
    'Rule, durations and both pricing groups are created atomically.');

  perform pg_temp.record_result(5,'Initial version exactly one',
    (select count(*)=1 and min(configuration_version)=1
     from public.lane_booking_family_configuration_versions where root_lane_id=v_root),
    'The new root has exactly one version row initialized to 1.');

  perform pg_temp.record_result(6,'Exactly one safe creation audit',
    (select count(*)=1 from public.audit_logs
      where target_id=v_root and action='lane_booking_family_created')
    and not exists(select 1 from public.audit_logs
      where target_id=v_root and action='lane_booking_family_created'
        and details::text ~* '(example[.]invalid|customer_email|customer_phone|access_token)'),
    'One technical audit exists without customer PII or secrets.');

  v_payload:=pg_temp.family_payload(
    '[TEST][6C-3J] Hierarchia',
    pg_catalog.jsonb_build_array(
      pg_temp.resource_payload('[TEST][6C-3J] Stanowisko 1',1,true,true),
      pg_temp.resource_payload('[TEST][6C-3J] Stanowisko 2',1,true,true)
    ),true,false,true,true,2
  );
  v_result:=pg_temp.call_create(v_admin,v_payload);
  v_hierarchy_root:=(v_result->>'root_lane_id')::uuid;
  perform pg_temp.record_result(7,'Hierarchy family creation',
    v_result->>'code'='created' and (v_result->>'created_resource_count')::integer=3
    and (select count(*)=2 from public.shooting_lanes
      where resource_kind='position' and parent_lane_id=v_hierarchy_root),
    'Admin creates one root and two dynamically generated child identities.');

  perform pg_temp.record_result(8,'Hierarchy UUID and invariants',
    (select count(distinct id)=3 from public.shooting_lanes
      where id=v_hierarchy_root or parent_lane_id=v_hierarchy_root)
    and not exists(select 1 from public.shooting_lanes
      where parent_lane_id=v_hierarchy_root and (whole_lane_bookable or positions_bookable))
    and (select count(*)=2 from public.lane_booking_rules rule
      join public.shooting_lanes child on child.id=rule.lane_id
      where child.parent_lane_id=v_hierarchy_root and rule.online_bookable),
    'Server UUIDs are distinct and children keep position semantics.');

  v_result:=pg_temp.call_create(v_admin,pg_temp.family_payload('[TEST][6C-3J] Samodzielna'));
  perform pg_temp.record_result(9,'Duplicate display names allowed',
    v_result->>'code'='created'
    and (select count(*)=2 from public.shooting_lanes
      where name='[TEST][6C-3J] Samodzielna' and resource_kind='lane'),
    'Display-name duplicates do not replace UUID identity.');

  select count(*) into v_before from public.shooting_lanes where name like '[TEST][6C-3J]%';
  v_result:=pg_temp.call_create(v_employee,pg_temp.family_payload('[TEST][6C-3J] DENIED employee'));
  perform pg_temp.record_result(10,'Pracownik denied',
    v_result->>'code'='not_allowed'
    and (select count(*)=v_before from public.shooting_lanes where name like '[TEST][6C-3J]%'),
    'Only admin can create a family.');

  v_result:=pg_temp.call_create(v_instructor,pg_temp.family_payload('[TEST][6C-3J] DENIED instructor'));
  perform pg_temp.record_result(11,'Instructor denied',
    v_result->>'code'='not_allowed'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] DENIED instructor'),
    'Instructor cannot create a family.');

  v_result:=pg_temp.call_create(v_user,pg_temp.family_payload('[TEST][6C-3J] DENIED user'));
  perform pg_temp.record_result(12,'User denied',
    v_result->>'code'='not_allowed'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] DENIED user'),
    'User cannot create a family.');

  v_result:=pg_temp.call_create(null,pg_temp.family_payload('[TEST][6C-3J] DENIED no auth'));
  perform pg_temp.record_result(13,'Missing auth denied',
    v_result->>'code'='not_allowed'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] DENIED no auth'),
    'Missing session fails closed.');

  foreach v_invalid_name in array array[
    ''::text,
    '<script>'::text,
    ('[TEST][6C-3J] control'||pg_catalog.chr(10))::text,
    pg_catalog.repeat('x',121)::text
  ]
  loop
    v_payload:=pg_temp.family_payload('[TEST][6C-3J] invalid name');
    v_payload:=pg_catalog.jsonb_set(
      v_payload,'{root,name}',pg_catalog.to_jsonb(v_invalid_name)
    );
    v_result:=pg_temp.call_create(v_admin,v_payload);
    v_names_rejected:=v_names_rejected and v_result->>'code'='invalid_payload';
  end loop;
  perform pg_temp.record_result(14,'Invalid names rejected',
    v_names_rejected
    and not exists(select 1 from public.shooting_lanes
      where name in('', '<script>') or name=pg_catalog.repeat('x',121)),
    'HTML/control/empty/overlong name contract is enforced by the same validation family.');

  v_payload:=pg_temp.family_payload('[TEST][6C-3J] invalid limits');
  v_payload:=pg_catalog.jsonb_set(v_payload,'{root,max_people_online}','3'::jsonb);
  v_result:=pg_temp.call_create(v_admin,v_payload);
  perform pg_temp.record_result(15,'Invalid limits rejected atomically',
    v_result->>'code'='invalid_payload'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] invalid limits'),
    'Online capacity cannot exceed physical capacity.');

  v_payload:=pg_temp.family_payload('[TEST][6C-3J] empty durations');
  v_payload:=pg_catalog.jsonb_set(v_payload,'{root,durations_minutes}','[]'::jsonb);
  v_result:=pg_temp.call_create(v_admin,v_payload);
  perform pg_temp.record_result(16,'Missing duration rejected atomically',
    v_result->>'code'='invalid_payload'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] empty durations'),
    'Every created resource requires at least one valid duration.');

  v_payload:=pg_temp.family_payload('[TEST][6C-3J] gap pricing',p_max=>3);
  v_payload:=pg_catalog.jsonb_set(v_payload,'{root,pricing}',pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',1,'label','one','hourly_price',10),
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',3,'max_shooters',3,'label','three','hourly_price',30),
    pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',3,'label','all','hourly_price',40)
  ));
  v_result:=pg_temp.call_create(v_admin,v_payload);
  perform pg_temp.record_result(17,'Pricing gap rejected',
    v_result->>'code'='invalid_configuration'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] gap pricing'),
    'Pricing coverage cannot contain gaps.');

  v_payload:=pg_temp.family_payload('[TEST][6C-3J] overlap pricing',p_max=>3);
  v_payload:=pg_catalog.jsonb_set(v_payload,'{root,pricing}',pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',2,'label','first','hourly_price',10),
    pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',2,'max_shooters',3,'label','second','hourly_price',30),
    pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',3,'label','all','hourly_price',40)
  ));
  v_result:=pg_temp.call_create(v_admin,v_payload);
  perform pg_temp.record_result(18,'Pricing overlap rejected',
    v_result->>'code'='invalid_configuration'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] overlap pricing'),
    'Pricing coverage cannot overlap.');

  v_payload:=pg_temp.family_payload('[TEST][6C-3J] unsafe hierarchy',
    pg_catalog.jsonb_build_array(
      pg_temp.resource_payload('[TEST][6C-3J] active child',1,true,false)
    ),false,false,true,false,2);
  v_result:=pg_temp.call_create(v_admin,v_payload);
  perform pg_temp.record_result(19,'Unsafe activation rejected',
    v_result->>'code'='invalid_configuration'
    and not exists(select 1 from public.shooting_lanes where name='[TEST][6C-3J] unsafe hierarchy'),
    'Inactive root cannot contain an active child.');

  perform pg_temp.record_result(20,'Read V2 refresh includes created families',
    exists(
      select 1
      from pg_catalog.jsonb_array_elements(
        public.admin_get_lane_booking_configuration_v2()->'families'
      ) as family(value)
      where family.value->>'root_lane_id'=v_root::text
        and (family.value->>'configuration_version')::integer=1
    )
    and exists(
      select 1
      from pg_catalog.jsonb_array_elements(
        public.admin_get_lane_booking_configuration_v2()->'families'
      ) as family(value)
      where family.value->>'root_lane_id'=v_hierarchy_root::text
        and pg_catalog.jsonb_array_length(family.value->'resources')=3
    ),
    'Successful create is visible through the unchanged V2 read contract.');

  perform pg_temp.record_result(21,'No partial objects after rejected calls',
    not exists(select 1 from public.shooting_lanes where name like '[TEST][6C-3J] invalid%')
    and not exists(select 1 from public.shooting_lanes where name in(
      '[TEST][6C-3J] empty durations','[TEST][6C-3J] gap pricing',
      '[TEST][6C-3J] overlap pricing','[TEST][6C-3J] unsafe hierarchy'
    )),
    'Every invalid call leaves all family tables unchanged.');

  perform pg_temp.record_result(22,'Rollback readiness',
    exists(select 1 from public.shooting_lanes where name like '[TEST][6C-3J]%')
    and exists(select 1 from auth.users where email like 'test-6c3j-%@example.invalid'),
    'Migration and isolated fixtures remain inside the open transaction.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end
       || test_order::text || ' - ' || test_name
       || case when passed then '' else ' # ' || result end
from pg_temp.test_results
where test_order < 22
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text||': '||test_name||' ['||result||']',
    ', ' order by test_order
  )
  into v_failures
  from pg_temp.test_results
  where not passed;

  if (select pg_catalog.count(*) from pg_temp.test_results)<>22 then
    raise exception 'Expected 22 controls, got %.',
      (select pg_catalog.count(*) from pg_temp.test_results);
  end if;

  if v_failures is not null then
    raise exception 'Lane family creation tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;

select case when
  pg_catalog.to_regprocedure('public.admin_create_lane_booking_family_v1(jsonb)') is not null
  and not exists(select 1 from public.shooting_lanes where name like '[TEST][6C-3J]%')
  and not exists(select 1 from auth.users where email like 'test-6c3j-%@example.invalid')
then 'ok 22 - Rollback restored the current baseline contract'
else 'not ok 22 - Rollback did not remove every synthetic fixture'
end;
