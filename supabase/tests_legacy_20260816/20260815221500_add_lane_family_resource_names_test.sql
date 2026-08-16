\set ON_ERROR_STOP on

-- psql-only rollback test. The migration and every [TEST][6C-3I] fixture
-- are executed in one transaction and removed by the final ROLLBACK.
select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.lane_booking_family_business_snapshot_v2(uuid)'::pg_catalog.regprocedure
  )) as snapshot_definition_before,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.normalize_lane_booking_family_payload_v2(jsonb)'::pg_catalog.regprocedure
  )) as normalize_definition_before,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
  )) as writer_definition_before
\gset

begin;

\ir ../migrations/20260815221500_add_lane_family_resource_names.sql

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

create function pg_temp.direct_name_update_denied(p_user uuid,p_lane uuid)
returns boolean
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_denied boolean := false;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated';
  begin
    update public.shooting_lanes set name=name where id=p_lane;
  exception when insufficient_privilege then
    v_denied := true;
  end;
  execute 'reset role';
  return v_denied;
exception
  when others then
    execute 'reset role';
    raise;
end;
$function$;

do $tests$
declare
  v_admin uuid := '6c3f0000-0000-4000-8000-000000000001';
  v_employee uuid := '6c3f0000-0000-4000-8000-000000000002';
  v_root uuid := '6c3f0000-0000-4000-8000-000000000101';
  v_position uuid := '6c3f0000-0000-4000-8000-000000000102';
  v_payload jsonb;
  v_result jsonb;
  v_read jsonb;
  v_version bigint := 1;
  v_business_before jsonb;
  v_business_after jsonb;
  v_rule_hash text;
  v_duration_hash text;
  v_pricing_hash text;
  v_audit_count bigint;
begin
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-6c3i-admin@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'test-6c3i-employee@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  update public.profiles
  set role=case when user_id=v_admin then 'admin' else 'pracownik' end,
      first_name='[TEST]',
      last_name='6C-3I',
      full_name='[TEST][6C-3I]'
  where user_id in(v_admin,v_employee);

  insert into public.shooting_lanes(
    id,name,type,description,price_per_hour,is_active,max_shooters,
    booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,
    whole_lane_bookable,positions_bookable
  ) values
    (v_root,'[TEST][6C-3I] Oś pierwotna','[TEST]','[TEST]',10,true,2,
      60,9981,'PLN','lane',null,true,false),
    (v_position,'[TEST][6C-3I] Stanowisko pierwotne','[TEST]','[TEST]',10,true,1,
      60,9982,'PLN','position',v_root,false,false);

  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)
  values(v_root,true,2),(v_position,false,1);

  insert into public.lane_booking_durations(lane_id,duration_minutes,display_order,is_active)
  values(v_root,60,10,true),(v_root,120,20,true),(v_position,60,10,true);

  insert into public.lane_pricing_rules(
    lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active
  ) values
    (v_root,'mon_thu',1,2,'[TEST][6C-3I] 1-2',100,10,true),
    (v_root,'fri_sun',1,2,'[TEST][6C-3I] 1-2',120,10,true),
    (v_position,'mon_thu',1,1,'[TEST][6C-3I] 1',60,10,true),
    (v_position,'fri_sun',1,1,'[TEST][6C-3I] 1',70,10,true);

  insert into public.lane_booking_family_configuration_versions(root_lane_id)
  values(v_root);

  v_payload := public.lane_booking_family_business_snapshot_v2(v_root);
  v_business_before := (
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',lane.id,
      'resource_kind',lane.resource_kind,
      'parent_lane_id',lane.parent_lane_id,
      'display_order',lane.display_order,
      'is_active',lane.is_active,
      'max_shooters',lane.max_shooters,
      'whole_lane_bookable',lane.whole_lane_bookable,
      'positions_bookable',lane.positions_bookable
    ) order by lane.id)
    from public.shooting_lanes as lane
    where lane.id in(v_root,v_position)
  );
  select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule.*) order by rule.lane_id)::text)
    into v_rule_hash from public.lane_booking_rules as rule where rule.lane_id in(v_root,v_position);
  select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration.*) order by duration.id)::text)
    into v_duration_hash from public.lane_booking_durations as duration where duration.lane_id in(v_root,v_position);
  select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(price.*) order by price.id)::text)
    into v_pricing_hash from public.lane_pricing_rules as price where price.lane_id in(v_root,v_position);

  perform pg_temp.record_result(1,'Snapshot exposes names',
    pg_catalog.jsonb_array_length(v_payload)=2
    and (v_payload->0 ? 'name') and (v_payload->1 ? 'name'),
    'Every full-family resource has a display name.');

  perform pg_temp.record_result(2,'Writer security contract',
    (select procedure.prosecdef and procedure.provolatile='v'
       and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
       and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
     from pg_catalog.pg_proc procedure
     where procedure.oid='public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure)
    and pg_catalog.has_function_privilege('authenticated',
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role',
      'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE'),
    'SECURITY DEFINER, owner, search_path and ACL remain unchanged.');

  perform pg_temp.record_result(3,'Direct name DML denied',
    pg_temp.direct_name_update_denied(v_admin,v_root),
    'Authenticated cannot bypass the family writer.');

  v_result := pg_temp.call_write(
    v_employee,v_root,v_version,
    pg_catalog.jsonb_set(v_payload,'{0,name}',pg_catalog.to_jsonb('[TEST][6C-3I] Denied'::text))
  );
  perform pg_temp.record_result(4,'Non-admin rename denied',
    v_result->>'code'='not_allowed'
    and (select name='[TEST][6C-3I] Oś pierwotna' from public.shooting_lanes where id=v_root),
    'Pracownik cannot rename a resource.');

  v_payload := pg_catalog.jsonb_set(
    v_payload,'{0,name}',pg_catalog.to_jsonb('  [TEST][6C-3I] Oś Żółta  '::text)
  );
  v_result := pg_temp.call_write(v_admin,v_root,v_version,v_payload);
  perform pg_temp.record_result(5,'Root rename succeeds',
    v_result->>'code'='updated'
    and (select name='[TEST][6C-3I] Oś Żółta' from public.shooting_lanes where id=v_root),
    'Unicode name is trimmed and written once.');

  perform pg_temp.record_result(6,'Version increments exactly once',
    (v_result->>'configuration_version')::bigint=2
    and (select configuration_version=2 from public.lane_booking_family_configuration_versions where root_lane_id=v_root),
    'One successful family write increments one version.');
  v_version := 2;

  v_business_after := (
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',lane.id,
      'resource_kind',lane.resource_kind,
      'parent_lane_id',lane.parent_lane_id,
      'display_order',lane.display_order,
      'is_active',lane.is_active,
      'max_shooters',lane.max_shooters,
      'whole_lane_bookable',lane.whole_lane_bookable,
      'positions_bookable',lane.positions_bookable
    ) order by lane.id)
    from public.shooting_lanes as lane
    where lane.id in(v_root,v_position)
  );
  perform pg_temp.record_result(7,'UUID and hierarchy unchanged',
    v_business_before=v_business_after
    and (select parent_lane_id=v_root from public.shooting_lanes where id=v_position),
    'Identity, kind, parent and display order are unchanged.');

  perform pg_temp.record_result(8,'Rules and limits unchanged',
    v_rule_hash=(select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule.*) order by rule.lane_id)::text)
      from public.lane_booking_rules rule where rule.lane_id in(v_root,v_position)),
    'Name-only path does not touch booking rules or limits.');

  perform pg_temp.record_result(9,'Durations unchanged',
    v_duration_hash=(select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration.*) order by duration.id)::text)
      from public.lane_booking_durations duration where duration.lane_id in(v_root,v_position)),
    'Name-only path does not delete or recreate durations.');

  perform pg_temp.record_result(10,'Pricing unchanged',
    v_pricing_hash=(select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(price.*) order by price.id)::text)
      from public.lane_pricing_rules price where price.lane_id in(v_root,v_position)),
    'Name-only path does not deactivate, insert or reorder pricing.');

  perform pg_temp.record_result(11,'Root audit contains rename contract',
    (select pg_catalog.count(*)=1 from public.audit_logs
      where target_id=v_root and action='lane_booking_family_configuration_updated')
    and exists(
      select 1 from public.audit_logs audit
      cross join lateral pg_catalog.jsonb_array_elements(audit.details->'renamed_resources') rename(value)
      where audit.target_id=v_root
        and audit.action='lane_booking_family_configuration_updated'
        and rename.value->>'resource_id'=v_root::text
        and rename.value->>'old_name'='[TEST][6C-3I] Oś pierwotna'
        and rename.value->>'new_name'='[TEST][6C-3I] Oś Żółta'
    ),
    'Audit stores resource UUID plus old and new names.');

  v_payload := public.lane_booking_family_business_snapshot_v2(v_root);
  v_result := pg_temp.call_write(v_admin,v_root,v_version,v_payload);
  perform pg_temp.record_result(12,'Unchanged name is no_change',
    v_result->>'code'='no_change'
    and (select configuration_version=2 from public.lane_booking_family_configuration_versions where root_lane_id=v_root)
    and (select pg_catalog.count(*)=1 from public.audit_logs
      where target_id=v_root and action='lane_booking_family_configuration_updated'),
    'Canonical unchanged target has no side effects.');

  v_result := pg_temp.call_write(
    v_admin,v_root,1,
    pg_catalog.jsonb_set(v_payload,'{0,name}',pg_catalog.to_jsonb('[TEST][6C-3I] Stale'::text))
  );
  perform pg_temp.record_result(13,'Stale rename rejected',
    v_result->>'code'='stale_configuration'
    and (select name='[TEST][6C-3I] Oś Żółta' from public.shooting_lanes where id=v_root)
    and (select configuration_version=2 from public.lane_booking_family_configuration_versions where root_lane_id=v_root),
    'Stale write cannot alter name, version or audit.');

  v_payload := public.lane_booking_family_business_snapshot_v2(v_root);
  v_payload := pg_catalog.jsonb_set(
    v_payload,'{1,name}',pg_catalog.to_jsonb(' [TEST][6C-3I] Stanowisko Lewe '::text)
  );
  v_result := pg_temp.call_write(v_admin,v_root,v_version,v_payload);
  perform pg_temp.record_result(14,'Position rename succeeds',
    v_result->>'code'='updated'
    and (select name='[TEST][6C-3I] Stanowisko Lewe' from public.shooting_lanes where id=v_position),
    'Position display name changes through the same family writer.');
  v_version := 3;

  perform pg_temp.record_result(15,'Position identity and configuration unchanged',
    (select parent_lane_id=v_root and resource_kind='position'
      and display_order=9982 and is_active and max_shooters=1
      and not whole_lane_bookable and not positions_bookable
      from public.shooting_lanes where id=v_position)
    and v_rule_hash=(select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rule.*) order by rule.lane_id)::text)
      from public.lane_booking_rules rule where rule.lane_id in(v_root,v_position))
    and v_duration_hash=(select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(duration.*) order by duration.id)::text)
      from public.lane_booking_durations duration where duration.lane_id in(v_root,v_position))
    and v_pricing_hash=(select pg_catalog.md5(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(price.*) order by price.id)::text)
      from public.lane_pricing_rules price where price.lane_id in(v_root,v_position)),
    'Position UUID, parent, business flags, limits, durations and pricing are unchanged.');

  perform pg_temp.record_result(16,'Position audit contains rename contract',
    exists(
      select 1 from public.audit_logs audit
      cross join lateral pg_catalog.jsonb_array_elements(audit.details->'renamed_resources') rename(value)
      where audit.target_id=v_root
        and audit.action='lane_booking_family_configuration_updated'
        and rename.value->>'resource_id'=v_position::text
        and rename.value->>'old_name'='[TEST][6C-3I] Stanowisko pierwotne'
        and rename.value->>'new_name'='[TEST][6C-3I] Stanowisko Lewe'
    ),
    'Second atomic audit identifies the renamed child resource.');

  v_payload := public.lane_booking_family_business_snapshot_v2(v_root);
  foreach v_result in array array[
    pg_catalog.jsonb_set(v_payload,'{0,name}',pg_catalog.to_jsonb('   '::text)),
    pg_catalog.jsonb_set(v_payload,'{0,name}',pg_catalog.to_jsonb('<b>Oś</b>'::text)),
    pg_catalog.jsonb_set(v_payload,'{0,name}',pg_catalog.to_jsonb(pg_catalog.repeat('x',121)))
  ]
  loop
    if pg_temp.call_write(v_admin,v_root,v_version,v_result)->>'code'<>'invalid_payload' then
      raise exception 'Unsafe name was not rejected.';
    end if;
  end loop;
  perform pg_temp.record_result(17,'Unsafe names rejected',
    (select name='[TEST][6C-3I] Oś Żółta' from public.shooting_lanes where id=v_root)
    and (select configuration_version=3 from public.lane_booking_family_configuration_versions where root_lane_id=v_root),
    'Empty, HTML-like and overlong names fail closed.');

  v_payload := public.lane_booking_family_business_snapshot_v2(v_root);
  v_payload := pg_catalog.jsonb_set(
    v_payload,'{1,name}',pg_catalog.to_jsonb('[TEST][6C-3I] Oś Żółta'::text)
  );
  v_result := pg_temp.call_write(v_admin,v_root,v_version,v_payload);
  perform pg_temp.record_result(18,'Duplicate names remain compatible',
    v_result->>'code'='updated'
    and (select pg_catalog.count(*)=2 from public.shooting_lanes
      where id in(v_root,v_position) and name='[TEST][6C-3I] Oś Żółta'),
    'Current schema intentionally has no name uniqueness constraint.');
  v_version := 4;

  v_read := pg_temp.call_read(v_admin);
  perform pg_temp.record_result(19,'Read V2 exposes fresh names',
    exists(
      select 1
      from pg_catalog.jsonb_array_elements(v_read->'families') family(value)
      cross join lateral pg_catalog.jsonb_array_elements(family.value->'resources') resource(value)
      where family.value->>'root_lane_id'=v_root::text
        and resource.value->>'lane_id'=v_root::text
        and resource.value->>'name'='[TEST][6C-3I] Oś Żółta'
    )
    and exists(
      select 1
      from pg_catalog.jsonb_array_elements(v_read->'families') family(value)
      cross join lateral pg_catalog.jsonb_array_elements(family.value->'resources') resource(value)
      where family.value->>'root_lane_id'=v_root::text
        and resource.value->>'lane_id'=v_position::text
        and resource.value->>'name'='[TEST][6C-3I] Oś Żółta'
    ),
    'Admin read contract reflects current display names after refresh.');

  perform pg_temp.record_result(20,'Audit cardinality and version parity',
    (select pg_catalog.count(*)=3 from public.audit_logs
      where target_id=v_root and action='lane_booking_family_configuration_updated')
    and (select configuration_version=4 from public.lane_booking_family_configuration_versions where root_lane_id=v_root),
    'Exactly one audit and one version increment exist per successful rename.');

  perform pg_temp.record_result(21,'No PII in rename details',
    not exists(
      select 1 from public.audit_logs
      where target_id=v_root
        and action='lane_booking_family_configuration_updated'
        and details::text ~* '(example[.]invalid|customer_email|customer_phone|access_token)'
    ),
    'Rename audit contains only technical identity and business display names.');

  perform pg_temp.record_result(22,'Rollback readiness',
    exists(select 1 from public.shooting_lanes where id in(v_root,v_position))
    and exists(select 1 from auth.users where id in(v_admin,v_employee)),
    'Migration, fixtures and audits remain inside the open transaction.');
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

  if (select pg_catalog.count(*) from pg_temp.test_results)<>22 then
    raise exception 'Expected 22 controls, got %.',
      (select pg_catalog.count(*) from pg_temp.test_results);
  end if;

  if v_failures is not null then
    raise exception 'Lane resource name tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.lane_booking_family_business_snapshot_v2(uuid)'::pg_catalog.regprocedure
  ))=:'snapshot_definition_before'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.normalize_lane_booking_family_payload_v2(jsonb)'::pg_catalog.regprocedure
  ))=:'normalize_definition_before'
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)'::pg_catalog.regprocedure
  ))=:'writer_definition_before'
  and not exists(select 1 from public.shooting_lanes where name like '[TEST][6C-3I]%')
  and not exists(select 1 from auth.users where email like 'test-6c3i-%@example.invalid')
  as rollback_confirmed;
