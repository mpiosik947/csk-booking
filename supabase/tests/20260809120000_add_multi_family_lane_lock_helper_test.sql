\set ON_ERROR_STOP on

-- Contract test for psql. The migration and every [TEST][6B-4B1] fixture are
-- enclosed in one transaction and removed by the final ROLLBACK.

create temporary table csk_6b4b1_baseline
on commit preserve rows
as
select
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure
  )) as single_definition_md5,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  )) as reservation_v2_definition_md5,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure
  )) as availability_v3_definition_md5,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid =
      'public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure
  ), '')) as single_acl_md5,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid =
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  ), '')) as reservation_v2_acl_md5,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid =
      'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure
  ), '')) as availability_v3_acl_md5;

begin;

do $clean_preflight$
begin
  if pg_catalog.to_regprocedure(
       'public.lock_lane_conflict_families_v1(uuid[])'
     ) is not null
     or exists (
       select 1
       from public.shooting_lanes as lane
       where lane.name like '[TEST][6B-4B1]%'
     ) then
    raise exception 'Unexpected prior 6B-4B1 objects or fixtures.';
  end if;
end;
$clean_preflight$;

\ir ../migrations/20260809120000_add_multi_family_lane_lock_helper.sql

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

create function pg_temp.multi_helper_sqlstate(p_lane_ids uuid[])
returns text
language plpgsql
as $function$
begin
  perform 1
  from public.lock_lane_conflict_families_v1(p_lane_ids);
  return null;
exception when others then
  return sqlstate;
end;
$function$;

insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values
  ('6b4b1000-0000-4000-8000-000000000101','[TEST][6B-4B1][STANDALONE]','[TEST]','[TEST]',10,false,5,60,9910,'PLN','lane',null,false,false),
  ('6b4b1000-0000-4000-8000-000000000201','[TEST][6B-4B1][ROOT-A]','[TEST]','[TEST]',10,false,5,60,9920,'PLN','lane',null,false,true),
  ('6b4b1000-0000-4000-8000-000000000301','[TEST][6B-4B1][ROOT-B]','[TEST]','[TEST]',10,true,5,60,9930,'PLN','lane',null,true,false),
  ('6b4b1000-0000-4000-8000-000000000202','[TEST][6B-4B1][A-1]','[TEST]','[TEST]',10,false,1,60,9921,'PLN','position','6b4b1000-0000-4000-8000-000000000201',false,false),
  ('6b4b1000-0000-4000-8000-000000000203','[TEST][6B-4B1][A-2]','[TEST]','[TEST]',10,true,1,60,9922,'PLN','position','6b4b1000-0000-4000-8000-000000000201',false,false),
  ('6b4b1000-0000-4000-8000-000000000302','[TEST][6B-4B1][B-1]','[TEST]','[TEST]',10,false,1,60,9931,'PLN','position','6b4b1000-0000-4000-8000-000000000301',false,false),
  ('6b4b1000-0000-4000-8000-000000000303','[TEST][6B-4B1][B-2]','[TEST]','[TEST]',10,true,1,60,9932,'PLN','position','6b4b1000-0000-4000-8000-000000000301',false,false);

do $contract_tests$
declare
  v_standalone constant uuid := '6b4b1000-0000-4000-8000-000000000101';
  v_root_a constant uuid := '6b4b1000-0000-4000-8000-000000000201';
  v_a1 constant uuid := '6b4b1000-0000-4000-8000-000000000202';
  v_a2 constant uuid := '6b4b1000-0000-4000-8000-000000000203';
  v_root_b constant uuid := '6b4b1000-0000-4000-8000-000000000301';
  v_b1 constant uuid := '6b4b1000-0000-4000-8000-000000000302';
  v_b2 constant uuid := '6b4b1000-0000-4000-8000-000000000303';
  v_missing constant uuid := '6b4b1000-0000-4000-8000-000000009999';
  v_grandchild constant uuid := '6b4b1000-0000-4000-8000-000000000204';
  v_helper oid := 'public.lock_lane_conflict_families_v1(uuid[])'::pg_catalog.regprocedure;
  v_rows jsonb;
  v_rows_reversed jsonb;
  v_definition text;
  v_malformed_passed boolean;
begin
  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.root_lane_id, result_record.requested_lane_id)
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_standalone]) as result_record;
  perform pg_temp.record_result(1, 'A. Single standalone lane',
    pg_catalog.jsonb_array_length(v_rows) = 1
    and v_rows->0->>'requested_lane_id' = v_standalone::text
    and v_rows->0->>'root_lane_id' = v_standalone::text
    and v_rows->0->>'requested_resource_kind' = 'lane'
    and v_rows->0->'conflict_lane_ids' = pg_catalog.to_jsonb(array[v_standalone]),
    'Standalone lane returns its one-resource family.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.root_lane_id, result_record.requested_lane_id)
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_root_a]) as result_record;
  perform pg_temp.record_result(2, 'B. Parent includes direct children',
    v_rows->0->'conflict_lane_ids' = pg_catalog.to_jsonb(array[v_root_a,v_a1,v_a2]),
    'Parent scope is root plus all direct children in UUID order.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record))
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_a1]) as result_record;
  perform pg_temp.record_result(3, 'C. Single child',
    v_rows->0->>'requested_resource_kind' = 'position'
    and v_rows->0->>'root_lane_id' = v_root_a::text
    and v_rows->0->'conflict_lane_ids' = pg_catalog.to_jsonb(array[v_root_a,v_a1]),
    'Position scope is its root and requested position.');

  perform pg_temp.record_result(4, 'D. Child scope excludes siblings',
    not (v_rows->0->'conflict_lane_ids' @> pg_catalog.to_jsonb(array[v_a2])),
    'Sibling A-2 is absent from the A-1 conflict scope.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.requested_lane_id)
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_a2,v_a1]) as result_record;
  perform pg_temp.record_result(5, 'E. Two children of one root',
    pg_catalog.jsonb_array_length(v_rows) = 2
    and v_rows->0->>'requested_lane_id' = v_a1::text
    and v_rows->1->>'requested_lane_id' = v_a2::text
    and v_rows->0->'conflict_lane_ids' = pg_catalog.to_jsonb(array[v_root_a,v_a1])
    and v_rows->1->'conflict_lane_ids' = pg_catalog.to_jsonb(array[v_root_a,v_a2]),
    'Each requested child retains an independent sibling-free scope.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.requested_lane_id)
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_a1,v_root_a]) as result_record;
  perform pg_temp.record_result(6, 'F. Parent plus child selects full family mode',
    pg_catalog.jsonb_array_length(v_rows) = 2
    and (select result_record.conflict_lane_ids = array[v_root_a,v_a1,v_a2]
         from public.lock_lane_conflict_families_v1(array[v_root_a,v_a1]) as result_record
         where result_record.requested_lane_id = v_root_a),
    'Presence of the root promotes the root lock mode to FULL FAMILY.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.root_lane_id, result_record.requested_lane_id)
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_root_a,v_root_b]) as result_record;
  perform pg_temp.record_result(7, 'G. Two distinct roots',
    pg_catalog.jsonb_array_length(v_rows) = 2
    and v_rows->0->>'root_lane_id' = v_root_a::text
    and v_rows->1->>'root_lane_id' = v_root_b::text,
    'Both families are returned in global root UUID order.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.root_lane_id, result_record.requested_lane_id)
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_root_a,v_b1]) as result_record;
  perform pg_temp.record_result(8, 'H. Mixed root1 and root2 input',
    pg_catalog.jsonb_array_length(v_rows) = 2
    and v_rows->0->>'root_lane_id' = v_root_a::text
    and v_rows->1->>'root_lane_id' = v_root_b::text,
    'Mixed FULL/CHILD_ONLY families use stable root ordering.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.root_lane_id, result_record.requested_lane_id)
  into v_rows_reversed
  from public.lock_lane_conflict_families_v1(array[v_b1,v_root_a]) as result_record;
  perform pg_temp.record_result(9, 'I. Reversed input is logically identical',
    v_rows_reversed = v_rows,
    'Input permutation does not affect ordered output.');

  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(result_record) order by result_record.root_lane_id, result_record.requested_lane_id)
  into v_rows
  from public.lock_lane_conflict_families_v1(array[v_a1,v_a1,v_root_b,v_root_b]) as result_record;
  perform pg_temp.record_result(10, 'J. Duplicate input is deduplicated',
    pg_catalog.jsonb_array_length(v_rows) = 2,
    'Each unique requested UUID produces exactly one result row.');

  perform pg_temp.record_result(11, 'K. NULL array fails closed',
    pg_temp.multi_helper_sqlstate(null::uuid[]) = '22023',
    'NULL input returns controlled SQLSTATE 22023.');
  perform pg_temp.record_result(12, 'L. Empty array fails closed',
    pg_temp.multi_helper_sqlstate(array[]::uuid[]) = '22023',
    'Empty input returns controlled SQLSTATE 22023.');
  perform pg_temp.record_result(13, 'M. NULL element fails closed',
    pg_temp.multi_helper_sqlstate(array[v_a1,null::uuid]) = '22023',
    'NULL array element returns controlled SQLSTATE 22023.');
  perform pg_temp.record_result(14, 'N. Missing resource fails closed',
    pg_temp.multi_helper_sqlstate(array[v_missing]) = 'P0002',
    'Unknown UUID returns controlled SQLSTATE P0002.');

  alter table public.shooting_lanes disable trigger validate_shooting_lane_hierarchy_trigger;
  alter table public.shooting_lanes
    drop constraint shooting_lanes_resource_kind_check,
    drop constraint shooting_lanes_resource_parent_check,
    drop constraint shooting_lanes_parent_not_self_check,
    drop constraint shooting_lanes_position_booking_modes_check,
    drop constraint shooting_lanes_parent_lane_id_fkey;

  update public.shooting_lanes set parent_lane_id = null where id = v_a1;
  perform pg_temp.record_result(15, 'O. Malformed position fails closed',
    pg_temp.multi_helper_sqlstate(array[v_a1]) = '55000',
    'Position without parent returns controlled SQLSTATE 55000.');
  update public.shooting_lanes set parent_lane_id = v_root_a where id = v_a1;

  v_malformed_passed := true;

  update public.shooting_lanes set parent_lane_id = v_root_b where id = v_root_a;
  v_malformed_passed := v_malformed_passed
    and pg_temp.multi_helper_sqlstate(array[v_root_a]) = '55000';
  update public.shooting_lanes set parent_lane_id = null where id = v_root_a;

  update public.shooting_lanes set resource_kind = 'unknown' where id = v_root_a;
  v_malformed_passed := v_malformed_passed
    and pg_temp.multi_helper_sqlstate(array[v_root_a]) = '55000';
  update public.shooting_lanes set resource_kind = 'lane' where id = v_root_a;

  update public.shooting_lanes set parent_lane_id = v_a1 where id = v_a1;
  v_malformed_passed := v_malformed_passed
    and pg_temp.multi_helper_sqlstate(array[v_a1]) = '55000';
  update public.shooting_lanes set parent_lane_id = v_root_a where id = v_a1;

  update public.shooting_lanes set parent_lane_id = v_missing where id = v_a1;
  v_malformed_passed := v_malformed_passed
    and pg_temp.multi_helper_sqlstate(array[v_a1]) = '55000';
  update public.shooting_lanes set parent_lane_id = v_root_a where id = v_a1;

  update public.shooting_lanes set resource_kind = 'position', parent_lane_id = v_root_b where id = v_root_a;
  v_malformed_passed := v_malformed_passed
    and pg_temp.multi_helper_sqlstate(array[v_a1]) = '55000';
  update public.shooting_lanes set resource_kind = 'lane', parent_lane_id = null where id = v_root_a;

  perform pg_temp.record_result(16, 'P. Malformed parents and kinds fail closed',
    v_malformed_passed,
    'Lane-with-parent, unknown kind, self-parent, missing parent, and non-lane parent are rejected.');

  insert into public.shooting_lanes (
    id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values (
    v_grandchild,'[TEST][6B-4B1][GRANDCHILD]','[TEST]','[TEST]',10,false,
    1,60,9923,'PLN','position',v_a1,false,false
  );
  perform pg_temp.record_result(17, 'Q. Depth greater than one fails closed',
    pg_temp.multi_helper_sqlstate(array[v_root_a]) = '55000',
    'Grandchild topology returns controlled SQLSTATE 55000.');
  delete from public.shooting_lanes where id = v_grandchild;

  perform pg_temp.record_result(18, 'R. Exact typed return contract',
    (select function_record.pronargs = 1
       and pg_catalog.pg_get_function_identity_arguments(function_record.oid) = 'p_lane_ids uuid[]'
       and pg_catalog.pg_get_function_result(function_record.oid) =
         'TABLE(requested_lane_id uuid, root_lane_id uuid, requested_resource_kind text, conflict_lane_ids uuid[])'
     from pg_catalog.pg_proc as function_record where function_record.oid = v_helper),
    'One uuid[] input and exact TABLE output are present.');

  perform pg_temp.record_result(19, 'S. Private EXECUTE ACL',
    not pg_catalog.has_function_privilege('anon', v_helper, 'EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated', v_helper, 'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role', v_helper, 'EXECUTE')
    and not exists (
      select 1
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
      ) as privilege_record
      where function_record.oid = v_helper
        and privilege_record.grantee = 0
        and privilege_record.privilege_type = 'EXECUTE'
    ),
    'PUBLIC, anon, authenticated, and service_role have no EXECUTE.');

  select pg_catalog.lower(pg_catalog.pg_get_functiondef(v_helper)) into v_definition;
  perform pg_temp.record_result(20, 'T. Owner, path, volatility, invoker, and lock protocol',
    (select language_record.lanname = 'plpgsql'
       and function_record.provolatile = 'v'
       and not function_record.prosecdef
       and pg_catalog.pg_get_userbyid(function_record.proowner) = 'postgres'
       and function_record.proconfig is not distinct from
         array['search_path=pg_catalog, public, pg_temp']::text[]
     from pg_catalog.pg_proc as function_record
     join pg_catalog.pg_language as language_record on language_record.oid = function_record.prolang
     where function_record.oid = v_helper)
    and pg_catalog.strpos(v_definition, 'phase 1: lock every root') > 0
    and pg_catalog.strpos(v_definition, 'phase 2: only after all roots') >
        pg_catalog.strpos(v_definition, 'phase 1: lock every root')
    and pg_catalog.strpos(v_definition, 'for share') > 0
    and pg_catalog.strpos(v_definition, 'for update') > 0
    and pg_catalog.strpos(v_definition, 'is_active') = 0
    and pg_catalog.strpos(v_definition, 'online_bookable') = 0
    and pg_catalog.strpos(v_definition, 'pricing') = 0
    and pg_catalog.strpos(v_definition, 'duration') = 0,
    'Helper is private infrastructure with two-phase root-before-child locking and no bookability checks.');

  perform pg_temp.record_result(21, 'U. Existing single helper unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      'public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure
    )) = (select baseline.single_definition_md5 from pg_temp.csk_6b4b1_baseline as baseline)
    and pg_catalog.md5(coalesce((
      select pg_catalog.string_agg(
        privilege_record.grantee::text || ':' || privilege_record.privilege_type,
        ',' order by privilege_record.grantee, privilege_record.privilege_type
      )
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
      ) as privilege_record
      where function_record.oid = 'public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure
    ), '')) = (select baseline.single_acl_md5 from pg_temp.csk_6b4b1_baseline as baseline),
    'Definition and ACL hash match the pre-transaction baseline.');

  perform pg_temp.record_result(22, 'V. create_reservation_v2 unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
    )) = (select baseline.reservation_v2_definition_md5 from pg_temp.csk_6b4b1_baseline as baseline)
    and pg_catalog.md5(coalesce((
      select pg_catalog.string_agg(
        privilege_record.grantee::text || ':' || privilege_record.privilege_type,
        ',' order by privilege_record.grantee, privilege_record.privilege_type
      )
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
      ) as privilege_record
      where function_record.oid = 'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
    ), '')) = (select baseline.reservation_v2_acl_md5 from pg_temp.csk_6b4b1_baseline as baseline),
    'Definition and ACL hash match the pre-transaction baseline.');

  perform pg_temp.record_result(23, 'W. Availability V3 unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef(
      'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure
    )) = (select baseline.availability_v3_definition_md5 from pg_temp.csk_6b4b1_baseline as baseline)
    and pg_catalog.md5(coalesce((
      select pg_catalog.string_agg(
        privilege_record.grantee::text || ':' || privilege_record.privilege_type,
        ',' order by privilege_record.grantee, privilege_record.privilege_type
      )
      from pg_catalog.pg_proc as function_record
      cross join lateral pg_catalog.aclexplode(
        coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
      ) as privilege_record
      where function_record.oid = 'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure
    ), '')) = (select baseline.availability_v3_acl_md5 from pg_temp.csk_6b4b1_baseline as baseline),
    'Definition and ACL hash match the pre-transaction baseline.');
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
    result_record.test_order::text || ': ' || result_record.test_name,
    ', ' order by result_record.test_order
  )
  into v_failures
  from pg_temp.test_results as result_record
  where result_record.passed is false;

  if v_failures is not null then
    raise exception '6B-4B1 contract tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  pg_catalog.to_regprocedure('public.lock_lane_conflict_families_v1(uuid[])') is null
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure
  )) = (select baseline.single_definition_md5 from pg_temp.csk_6b4b1_baseline as baseline)
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  )) = (select baseline.reservation_v2_definition_md5 from pg_temp.csk_6b4b1_baseline as baseline)
  and pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure
  )) = (select baseline.availability_v3_definition_md5 from pg_temp.csk_6b4b1_baseline as baseline)
  and pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid = 'public.lock_lane_conflict_family_v1(uuid)'::pg_catalog.regprocedure
  ), '')) = (select baseline.single_acl_md5 from pg_temp.csk_6b4b1_baseline as baseline)
  and pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid = 'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  ), '')) = (select baseline.reservation_v2_acl_md5 from pg_temp.csk_6b4b1_baseline as baseline)
  and pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(
      privilege_record.grantee::text || ':' || privilege_record.privilege_type,
      ',' order by privilege_record.grantee, privilege_record.privilege_type
    )
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(function_record.proacl, pg_catalog.acldefault('f', function_record.proowner))
    ) as privilege_record
    where function_record.oid = 'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure
  ), '')) = (select baseline.availability_v3_acl_md5 from pg_temp.csk_6b4b1_baseline as baseline)
  and not exists (
    select 1 from public.shooting_lanes as lane
    where lane.name like '[TEST][6B-4B1]%'
  ) as rollback_confirmed;
