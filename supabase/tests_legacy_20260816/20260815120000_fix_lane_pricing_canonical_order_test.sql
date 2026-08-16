\set ON_ERROR_STOP on

-- psql-only rollback test. The hotfix and every [TEST][6C-3E-HOTFIX] fixture
-- are executed in one transaction and removed by the final ROLLBACK.
select pg_catalog.md5(
  pg_catalog.pg_get_functiondef(
    'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
  )
) as writer_definition_before \gset

begin;

create temporary table production_pricing_baseline(snapshot_hash text) on commit drop;
insert into production_pricing_baseline
select pg_catalog.md5(
  coalesce(
    pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule.*) order by rule.id),
    '[]'::jsonb
  )::text
)
from public.lane_pricing_rules as rule;

\ir ../migrations/20260815120000_fix_lane_pricing_canonical_order.sql

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

create function pg_temp.call_write(
  p_user uuid,
  p_root uuid,
  p_version bigint,
  p_payload jsonb
)
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
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated';
  select public.admin_set_lane_booking_family_configuration_v2(
    p_root,p_version,p_payload,false
  ) into v_result;
  execute 'reset role';
  return v_result;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

create function pg_temp.call_read(p_user uuid)
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
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated';
  select public.admin_get_lane_booking_configuration_v2() into v_result;
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
  v_admin uuid := '6c3e0000-0000-4000-8000-000000000001';
  v_root uuid := '6c3e0000-0000-4000-8000-000000000101';
  v_payload jsonb;
  v_result jsonb;
  v_read jsonb;
  v_family jsonb;
  v_pricing jsonb;
  v_reused_ids uuid[];
begin
  perform pg_temp.record_result(
    1,
    'Migration is definition-only',
    (select snapshot_hash from pg_temp.production_pricing_baseline) = (
      select pg_catalog.md5(
        coalesce(
          pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule.*) order by rule.id),
          '[]'::jsonb
        )::text
      )
      from public.lane_pricing_rules as rule
    ),
    'Applying the hotfix does not rewrite existing pricing data.'
  );

  perform pg_temp.record_result(
    2,
    'Writer security contract',
    (
      select procedure.prosecdef
         and procedure.provolatile = 'v'
         and procedure.proconfig =
             array['search_path=pg_catalog, public, pg_temp']::text[]
         and procedure.proowner = (
           select role.oid
           from pg_catalog.pg_roles as role
           where role.rolname = 'postgres'
         )
      from pg_catalog.pg_proc as procedure
      where procedure.oid =
        'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
    )
    and pg_catalog.has_function_privilege(
      'authenticated',
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)',
      'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon',
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)',
      'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'service_role',
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)',
      'EXECUTE'
    ),
    'Signature, SECURITY DEFINER, owner, search_path and client ACL are preserved.'
  );

  perform pg_temp.record_result(
    3,
    'Canonical insert implementation',
    pg_catalog.strpos(
      pg_catalog.lower(
        pg_catalog.regexp_replace(
          pg_catalog.pg_get_functiondef(
            'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
          ),
          '[[:space:]]+',
          ' ',
          'g'
        )
      ),
      'target_price.hourly_price, target_price.display_order, true from target_price'
    ) > 0,
    'INSERT consumes display_order computed over the complete target day group.'
  );

  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values (
    v_admin,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'test-6c3e-hotfix-admin@example.invalid',
    '',
    pg_catalog.now(),
    '{}',
    '{}',
    pg_catalog.now(),
    pg_catalog.now()
  );

  update public.profiles
  set role='admin',
      first_name='[TEST]',
      last_name='6C-3E-HOTFIX',
      full_name='[TEST][6C-3E-HOTFIX]'
  where user_id=v_admin;

  insert into public.shooting_lanes(
    id,name,type,description,price_per_hour,is_active,max_shooters,
    booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,
    whole_lane_bookable,positions_bookable
  ) values (
    v_root,'[TEST][6C-3E-HOTFIX] Root','[TEST]','[TEST]',10,true,6,
    60,9991,'PLN','lane',null,true,false
  );

  insert into public.lane_booking_rules(
    lane_id,online_bookable,max_people_online
  ) values (v_root,true,6);

  insert into public.lane_booking_durations(
    lane_id,duration_minutes,display_order,is_active
  ) values (v_root,60,10,true);

  insert into public.lane_pricing_rules(
    lane_id,day_group,min_shooters,max_shooters,label,
    hourly_price,display_order,is_active
  ) values
    (v_root,'mon_thu',1,1,'1 osoba',60,10,true),
    (v_root,'mon_thu',2,2,'2 osoby',120,20,true),
    (v_root,'mon_thu',3,3,'3 osoby',180,30,true),
    (v_root,'mon_thu',4,6,'Pakiet historyczny',250,40,true),
    (v_root,'fri_sun',1,1,'1 osoba',70,10,true),
    (v_root,'fri_sun',2,2,'2 osoby',140,20,true),
    (v_root,'fri_sun',3,3,'3 osoby',210,30,true),
    (v_root,'fri_sun',4,6,'Pakiet historyczny',300,40,true),
    (v_root,'mon_thu',4,6,'Historia A',230,40,false),
    (v_root,'mon_thu',4,6,'Historia B',240,40,false),
    (v_root,'fri_sun',4,6,'Historia A',280,40,false),
    (v_root,'fri_sun',4,6,'Historia B',290,40,false);

  insert into public.lane_booking_family_configuration_versions(root_lane_id)
  values(v_root);

  select pg_catalog.array_agg(rule.id order by rule.day_group,rule.min_shooters)
  into v_reused_ids
  from public.lane_pricing_rules as rule
  where rule.lane_id=v_root
    and rule.is_active
    and rule.max_shooters <= 3;

  perform pg_temp.record_result(
    4,
    'Synthetic baseline',
    (select pg_catalog.count(*)=8 from public.lane_pricing_rules where lane_id=v_root and is_active)
    and (select pg_catalog.count(*)=4 from public.lane_pricing_rules where lane_id=v_root and not is_active),
    'The fixture has eight active target rows and repeated inactive 4-6 history.'
  );

  v_payload := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'lane_id',v_root,
      'is_active',true,
      'whole_lane_bookable',true,
      'positions_bookable',false,
      'max_shooters',6,
      'online_bookable',true,
      'max_people_online',6,
      'durations_minutes',pg_catalog.jsonb_build_array(60),
      'pricing',pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',1,'label','1 osoba','hourly_price',60),
        pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',2,'max_shooters',2,'label','2 osoby','hourly_price',120),
        pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',3,'max_shooters',3,'label','3 osoby','hourly_price',180),
        pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',4,'max_shooters',6,'label','Cała oś na wyłączność','hourly_price',290),
        pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',1,'label','1 osoba','hourly_price',70),
        pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',2,'max_shooters',2,'label','2 osoby','hourly_price',140),
        pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',3,'max_shooters',3,'label','3 osoby','hourly_price',210),
        pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',4,'max_shooters',6,'label','Cała oś na wyłączność','hourly_price',350)
      )
    )
  );

  v_result := pg_temp.call_write(v_admin,v_root,1,v_payload);

  perform pg_temp.record_result(
    5,
    'Writer succeeds once',
    v_result->>'code'='updated'
    and (v_result->>'configuration_version')::bigint=2,
    'The controlled family write returns updated and bumps exactly one version.'
  );

  perform pg_temp.record_result(
    6,
    'Unchanged rows are reused',
    v_reused_ids = (
      select pg_catalog.array_agg(rule.id order by rule.day_group,rule.min_shooters)
      from public.lane_pricing_rules as rule
      where rule.lane_id=v_root
        and rule.is_active
        and rule.max_shooters <= 3
    ),
    'Active 1, 2 and 3-person rows retain their identities.'
  );

  perform pg_temp.record_result(
    7,
    'Changed rows use copy-on-write',
    not exists(
      select 1 from public.lane_pricing_rules
      where lane_id=v_root
        and is_active
        and label='Pakiet historyczny'
    )
    and (
      select pg_catalog.count(*)=2
      from public.lane_pricing_rules
      where lane_id=v_root
        and is_active
        and min_shooters=4
        and max_shooters=6
        and label='Cała oś na wyłączność'
    ),
    'Old 4-6 rows are historical and exactly two new target rows are active.'
  );

  perform pg_temp.record_result(
    8,
    'Canonical active display order',
    not exists(
      select 1
      from (
        select
          rule.display_order,
          pg_catalog.row_number() over(
            partition by rule.lane_id,rule.day_group
            order by rule.min_shooters,rule.max_shooters,rule.label,rule.id
          )*10 as expected_order
        from public.lane_pricing_rules as rule
        where rule.lane_id=v_root and rule.is_active
      ) as ordered
      where ordered.display_order<>ordered.expected_order
    ),
    'Every active day group is ordered 10,20,30,40 over the complete target.'
  );

  perform pg_temp.record_result(
    9,
    'No duplicate active display order',
    not exists(
      select 1
      from public.lane_pricing_rules
      where lane_id=v_root and is_active
      group by day_group,display_order
      having pg_catalog.count(*)>1
    ),
    'The regression 10,10,20,30 cannot occur.'
  );

  perform pg_temp.record_result(
    10,
    'Business prices preserved',
    exists(select 1 from public.lane_pricing_rules where lane_id=v_root and is_active and day_group='mon_thu' and min_shooters=1 and hourly_price=60)
    and exists(select 1 from public.lane_pricing_rules where lane_id=v_root and is_active and day_group='mon_thu' and min_shooters=2 and hourly_price=120)
    and exists(select 1 from public.lane_pricing_rules where lane_id=v_root and is_active and day_group='mon_thu' and min_shooters=3 and hourly_price=180)
    and exists(select 1 from public.lane_pricing_rules where lane_id=v_root and is_active and day_group='mon_thu' and min_shooters=4 and hourly_price=290)
    and exists(select 1 from public.lane_pricing_rules where lane_id=v_root and is_active and day_group='fri_sun' and min_shooters=4 and hourly_price=350),
    'Only the explicit synthetic target prices are present; the hotfix supplies no prices.'
  );

  perform pg_temp.record_result(
    11,
    'Inactive history retained',
    (select pg_catalog.count(*)=6 from public.lane_pricing_rules where lane_id=v_root and not is_active)
    and (select pg_catalog.count(*)=3 from public.lane_pricing_rules where lane_id=v_root and day_group='mon_thu' and min_shooters=4 and max_shooters=6 and not is_active)
    and (select pg_catalog.count(*)=3 from public.lane_pricing_rules where lane_id=v_root and day_group='fri_sun' and min_shooters=4 and max_shooters=6 and not is_active),
    'Repeated historical rows remain available for the admin read contract.'
  );

  v_read := pg_temp.call_read(v_admin);
  select family.value
  into v_family
  from pg_catalog.jsonb_array_elements(v_read->'families') as family(value)
  where family.value->>'root_lane_id'=v_root::text;

  select resource.value->'pricing'
  into v_pricing
  from pg_catalog.jsonb_array_elements(v_family->'resources') as resource(value)
  where resource.value->>'lane_id'=v_root::text;

  perform pg_temp.record_result(
    12,
    'Read V2 includes active and historical pricing',
    (v_read->>'contract_version')::integer=2
    and pg_catalog.jsonb_array_length(v_pricing)=14
    and (
      select pg_catalog.count(*)=8
      from pg_catalog.jsonb_array_elements(v_pricing) as rule(value)
      where (rule.value->>'is_active')::boolean
    )
    and (
      select pg_catalog.count(*)=6
      from pg_catalog.jsonb_array_elements(v_pricing) as rule(value)
      where not (rule.value->>'is_active')::boolean
    ),
    'The read shape retains history without losing the eight-row active target.'
  );

  perform pg_temp.record_result(
    13,
    'Version and audit remain atomic',
    (select configuration_version=2 from public.lane_booking_family_configuration_versions where root_lane_id=v_root)
    and (
      select pg_catalog.count(*)=1
      from public.audit_logs
      where target_id=v_root
        and action='lane_booking_family_configuration_updated'
    ),
    'The original versioning and one-audit contract is unchanged.'
  );

  perform pg_temp.record_result(
    14,
    'No position activation',
    not exists(
      select 1 from public.shooting_lanes
      where parent_lane_id=v_root and (is_active or resource_kind<>'position')
    ),
    'The synthetic family has no positions and the hotfix activates none.'
  );

  perform pg_temp.record_result(
    15,
    'Rollback readiness',
    exists(select 1 from public.shooting_lanes where id=v_root)
    and exists(select 1 from auth.users where id=v_admin),
    'All fixture and function changes remain inside the open transaction.'
  );
end;
$tests$;

select test_order,test_name,passed,result
from pg_temp.test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text||': '||test_name||' ['||result||']',
    ', '
    order by test_order
  )
  into v_failures
  from pg_temp.test_results
  where not passed;

  if (select pg_catalog.count(*) from pg_temp.test_results)<>15 then
    raise exception 'Expected 15 controls, got %.',
      (select pg_catalog.count(*) from pg_temp.test_results);
  end if;

  if v_failures is not null then
    raise exception 'Pricing order hotfix tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.md5(
    pg_catalog.pg_get_functiondef(
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
    )
  )=:'writer_definition_before'
  and not exists(
    select 1 from public.shooting_lanes
    where name like '[TEST][6C-3E-HOTFIX]%'
  )
  and not exists(
    select 1 from auth.users
    where email='test-6c3e-hotfix-admin@example.invalid'
  )
  as rollback_confirmed;
