\set ON_ERROR_STOP on

select
  (select pg_catalog.count(*) from public.shooting_lanes
   where resource_kind = 'position') as baseline_position_count,
  pg_catalog.md5(pg_catalog.to_jsonb(parent)::text) as baseline_parent_hash,
  (select pg_catalog.md5(pg_catalog.to_jsonb(rule)::text)
   from public.lane_booking_rules as rule
   where rule.lane_id = parent.id) as baseline_rule_hash,
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(duration)::text), E'\n'
     order by duration.duration_minutes, duration.id), ''))
   from public.lane_booking_durations as duration
   where duration.lane_id = parent.id) as baseline_durations_hash,
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(pricing)::text), E'\n'
     order by pricing.day_group, pricing.min_shooters, pricing.id), ''))
   from public.lane_pricing_rules as pricing
   where pricing.lane_id = parent.id) as baseline_pricing_hash,
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(reservation)::text), E'\n'
     order by reservation.id), ''))
   from public.reservations as reservation) as baseline_reservations_hash,
  (select pg_catalog.md5(pg_catalog.to_jsonb(config)::text)
   from public.get_public_booking_configuration_v1() as config
   where config.lane_id = parent.id) as baseline_public_parent_hash
from public.shooting_lanes as parent
where parent.id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2'
\gset

begin;

-- The migration is one atomic DO statement, so its table locks, preflight,
-- inserts and postflight remain inside this outer rollback transaction.
\ir ../migrations/20260810133000_add_100m_lane_positions.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create temporary table test_baseline (
  parent_rule_hash text not null,
  parent_durations_hash text not null,
  parent_pricing_hash text not null,
  reservations_hash text not null,
  public_parent_hash text not null
) on commit drop;

insert into test_baseline values (
  :'baseline_rule_hash',
  :'baseline_durations_hash',
  :'baseline_pricing_hash',
  :'baseline_reservations_hash',
  :'baseline_public_parent_hash'
);

create function pg_temp.call_dormant_child_as_user(p_lane_id uuid)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', '6c100000-0000-4000-8000-000000000001',
      'role', 'authenticated'
    )::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.sub',
    '6c100000-0000-4000-8000-000000000001',
    true
  );
  execute 'set local role authenticated';
  select public.create_reservation_v2(
    p_lane_id,
    current_date + 365,
    time '10:00',
    60,
    1,
    pg_catalog.gen_random_uuid(),
    '[TEST][6C-1]'
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.availability_child_is_fail_closed(p_lane_id uuid)
returns boolean
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
begin
  perform pg_catalog.count(*)
  from public.get_lane_booking_busy_ranges_v3(p_lane_id, current_date + 365);
  return false;
exception
  when sqlstate '55000' then
    return true;
end;
$function$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) values (
  '6c100000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated',
  'test-6c1@example.invalid', '',
  '{}'::jsonb, '{}'::jsonb,
  pg_catalog.transaction_timestamp(), pg_catalog.transaction_timestamp()
);

insert into public.profiles (
  user_id, role, first_name, last_name, full_name, email, phone,
  verification_status, permissions_verified
) values (
  '6c100000-0000-4000-8000-000000000001',
  'user', '[TEST]', '6C-1', '[TEST][6C-1]',
  'test-6c1-profile@example.invalid', '000000000', 'verified', true
)
on conflict (user_id) do update set
  role = excluded.role,
  first_name = excluded.first_name,
  last_name = excluded.last_name,
  full_name = excluded.full_name,
  email = excluded.email,
  phone = excluded.phone,
  verification_status = excluded.verification_status,
  permissions_verified = excluded.permissions_verified;

-- A second application must be a no-op for the exact expected state.
\ir ../migrations/20260810133000_add_100m_lane_positions.sql

do $tests$
declare
  v_parent constant uuid := '254ca7f6-ce80-4267-8966-4558cc8f8fd2';
  v_children constant uuid[] := array[
    'f34d5c5c-9135-4a17-b513-d1bacaf57d79'::uuid,
    '5858c167-e48b-478a-88f3-ba3db4605798'::uuid,
    '9bf08601-0ff8-452e-985e-9e1695d1fe78'::uuid,
    '83e85c35-4d7f-4415-b00d-b0f2a7b9c789'::uuid,
    'b557d51a-554c-4cc2-868c-63121f2d5cb3'::uuid
  ];
  v_parent_scope uuid[];
  v_first_scope uuid[];
  v_second_scope uuid[];
  v_v2_definition text := pg_catalog.lower(pg_catalog.pg_get_functiondef(
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  ));
  v_availability_definition text := pg_catalog.lower(pg_catalog.pg_get_functiondef(
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'::pg_catalog.regprocedure
  ));
  v_block_definitions text;
  v_event_definitions text;
begin
  select scope.conflict_lane_ids into strict v_parent_scope
  from public.lock_lane_conflict_families_v1(array[v_parent]) as scope;

  select scope.conflict_lane_ids into strict v_first_scope
  from public.lock_lane_conflict_families_v1(array[v_children[1]]) as scope;

  select scope.conflict_lane_ids into strict v_second_scope
  from public.lock_lane_conflict_families_v1(array[v_children[2]]) as scope;

  select pg_catalog.string_agg(
    pg_catalog.lower(pg_catalog.pg_get_functiondef(function_record.oid)), E'\n'
    order by function_record.proname
  ) into v_block_definitions
  from pg_catalog.pg_proc as function_record
  join pg_catalog.pg_namespace as namespace_record
    on namespace_record.oid = function_record.pronamespace
  where namespace_record.nspname = 'public'
    and function_record.proname in (
      'admin_create_lane_block', 'admin_update_lane_block',
      'admin_set_lane_block_active'
    );

  select pg_catalog.string_agg(
    pg_catalog.lower(pg_catalog.pg_get_functiondef(function_record.oid)), E'\n'
    order by function_record.proname
  ) into v_event_definitions
  from pg_catalog.pg_proc as function_record
  join pg_catalog.pg_namespace as namespace_record
    on namespace_record.oid = function_record.pronamespace
  where namespace_record.nspname = 'public'
    and function_record.proname in (
      'admin_create_event_v2', 'admin_update_event_v2',
      'admin_set_event_active_v2'
    );

  insert into test_results values
  (1, 'A. Parent istnieje dokładnie raz',
    (select pg_catalog.count(*) from public.shooting_lanes
     where id = v_parent and name = 'Oś 100 m'
       and resource_kind = 'lane' and parent_lane_id is null) = 1,
    'Oczekiwano jednego ustalonego parent UUID.'),
  (2, 'B. Utworzono dokładnie pięć children',
    (select pg_catalog.count(*) from public.shooting_lanes
     where parent_lane_id = v_parent and id = any(v_children)) = 5
      and (select pg_catalog.count(*) from public.shooting_lanes
           where resource_kind = 'position') = 5,
    'Nie może istnieć częściowy ani dodatkowy zestaw positions.'),
  (3, 'C. Children mają resource_kind position',
    not exists (select 1 from public.shooting_lanes
                where id = any(v_children) and resource_kind <> 'position'),
    'Każdy child jest position.'),
  (4, 'D. Parent UUID jest poprawny',
    not exists (select 1 from public.shooting_lanes
                where id = any(v_children) and parent_lane_id is distinct from v_parent),
    'Każdy child wskazuje Oś 100 m.'),
  (5, 'E. Hierarchia ma depth 1',
    exists (select 1 from public.shooting_lanes
            where id = v_parent and parent_lane_id is null)
      and not exists (
        select 1 from public.shooting_lanes as child
        join public.shooting_lanes as parent on parent.id = child.parent_lane_id
        where child.id = any(v_children)
          and (parent.resource_kind <> 'lane' or parent.parent_lane_id is not null)
      ),
    'Parent jest top-level lane, children są direct positions.'),
  (6, 'F. Brak grandchildren',
    not exists (select 1 from public.shooting_lanes
                where parent_lane_id = any(v_children)),
    'Nie może powstać depth większy niż 1.'),
  (7, 'G. Brak self-parent',
    not exists (select 1 from public.shooting_lanes
                where id = any(v_children) and id = parent_lane_id),
    'Żaden child nie wskazuje siebie.'),
  (8, 'H. Children są offline',
    (select pg_catalog.count(*)
     from public.shooting_lanes as child
     join public.lane_booking_rules as rule on rule.lane_id = child.id
     where child.id = any(v_children)
       and not child.is_active
       and not child.whole_lane_bookable
       and not child.positions_bookable
       and not rule.online_bookable
       and rule.max_people_online = 1) = 5,
    'Każdy child ma dormant lane row i booking rule.'),
  (9, 'I. Children nie są publicznie bookable',
    not exists (select 1 from public.get_public_booking_configuration_v1()
                where lane_id = any(v_children)),
    'Public reader nie może wystawić dormant positions.'),
  (10, 'J. Publiczne zachowanie parenta jest bez zmian',
    exists (select 1 from public.get_public_booking_configuration_v1()
            where lane_id = v_parent and effective_online_bookable
              and whole_lane_bookable and not positions_bookable
              and max_people_online = 6
              and durations_minutes = array[60,120,180,240]
              and pg_catalog.jsonb_array_length(pricing) = 8),
    'Oś 100 m pozostaje ofertą whole-lane.'),
  (11, 'K. Parent availability scope obejmuje children',
    pg_catalog.cardinality(v_parent_scope) = 6
      and v_parent = any(v_parent_scope)
      and not exists (select 1 from pg_catalog.unnest(v_children) as child(id)
                      where not child.id = any(v_parent_scope))
      and pg_catalog.strpos(
        v_availability_definition,
        'resolve_lane_conflict_scope_v1'
      ) > 0,
    'V3 rozwiązuje parent oraz wszystkie direct children.'),
  (12, 'L. Child availability scope wyklucza siblings',
    v_first_scope = array[v_parent, v_children[1]]::uuid[]
      and v_second_scope = array[v_parent, v_children[2]]::uuid[]
      and not v_children[2] = any(v_first_scope),
    'Child obejmuje tylko siebie i parenta.'),
  (13, 'M. Parent reservation konfliktuje z child',
    pg_catalog.strpos(v_v2_definition, 'lock_lane_conflict_family_v1') > 0
      and v_children[1] = any(v_parent_scope),
    'Reservation writer używa wspólnego parent scope.'),
  (14, 'N. Sibling reservations są niezależne',
    not v_children[2] = any(v_first_scope)
      and not v_children[1] = any(v_second_scope)
      and pg_catalog.strpos(v_v2_definition, 'conflict_lane_ids') > 0,
    'Sibling nie należy do child conflict scope.'),
  (15, 'O. Parent lane block konfliktuje z child',
    pg_catalog.strpos(v_block_definitions, 'lock_lane_conflict_families_v1') > 0
      and v_children[1] = any(v_parent_scope),
    'Lane-block writery używają family scope.'),
  (16, 'P. Sibling lane blocks są niezależne',
    not v_children[2] = any(v_first_scope)
      and pg_catalog.strpos(v_block_definitions, 'v_conflict_lane_ids') > 0,
    'Child1 block nie obejmuje child2.'),
  (17, 'Q. Parent event konfliktuje z child',
    pg_catalog.strpos(v_event_definitions, 'lock_lane_conflict_families_v1') > 0
      and v_children[1] = any(v_parent_scope),
    'Event V2 używa family scope.'),
  (18, 'R. Sibling events są niezależne',
    not v_children[2] = any(v_first_scope)
      and pg_catalog.strpos(v_event_definitions, 'v_conflict_lane_ids') > 0,
    'Child1 event nie obejmuje child2.'),
  (19, 'S. Parent pricing pozostaje identyczne',
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       pg_catalog.md5(pg_catalog.to_jsonb(pricing)::text), E'\n'
       order by pricing.day_group, pricing.min_shooters, pricing.id), ''))
     from public.lane_pricing_rules as pricing where pricing.lane_id = v_parent)
       = (select parent_pricing_hash from test_baseline),
    'Migracja nie zmienia ośmiu reguł parenta.'),
  (20, 'T. Parent durations pozostają identyczne',
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       pg_catalog.md5(pg_catalog.to_jsonb(duration)::text), E'\n'
       order by duration.duration_minutes, duration.id), ''))
     from public.lane_booking_durations as duration where duration.lane_id = v_parent)
       = (select parent_durations_hash from test_baseline),
    'Migracja nie zmienia czterech durations parenta.'),
  (21, 'U. Parent booking rule pozostaje identyczna',
    (select pg_catalog.md5(pg_catalog.to_jsonb(rule)::text)
     from public.lane_booking_rules as rule where rule.lane_id = v_parent)
       = (select parent_rule_hash from test_baseline),
    'Online flag i max_people_online parenta są bez zmian.'),
  (22, 'V. Istniejące reservations pozostają identyczne',
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       pg_catalog.md5(pg_catalog.to_jsonb(reservation)::text), E'\n'
       order by reservation.id), '')) from public.reservations as reservation)
       = (select reservations_hash from test_baseline),
    'Migracja nie dotyka istniejących rezerwacji.'),
  (23, 'W. Public config parenta pozostaje identyczny',
    (select pg_catalog.md5(pg_catalog.to_jsonb(config)::text)
     from public.get_public_booking_configuration_v1() as config
     where config.lane_id = v_parent) = (select public_parent_hash from test_baseline),
    'Publiczny kontrakt Osi 100 m nie zmienia się.'),
  (24, 'X. Dormant children fail-closed',
    not exists (
      select 1 from pg_catalog.unnest(v_children) as child(id)
      where pg_temp.call_dormant_child_as_user(child.id)->>'code'
            is distinct from 'lane_inactive'
    )
      and not exists (
        select 1 from pg_catalog.unnest(v_children) as child(id)
        where not pg_temp.availability_child_is_fail_closed(child.id)
      )
      and not exists (select 1 from public.reservations
                      where reservation_note = '[TEST][6C-1]'),
    'Każdy child zwraca lane_inactive, Availability V3 zgłasza 55000 i brak INSERT.'),
  (25, 'Y. Migracja jest idempotency-aware',
    (select pg_catalog.count(*) from public.shooting_lanes
     where id = any(v_children)) = 5
      and (select pg_catalog.count(*) from public.lane_booking_rules
           where lane_id = any(v_children)) = 5,
    'Ponowne zastosowanie dokładnego zestawu nie tworzy duplikatów.');
end;
$tests$;

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
  ) into v_failures
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception '100 m hierarchy tests failed: %', v_failures;
  end if;
end;
$assertions$;

rollback;

select
  (
    (select pg_catalog.count(*) from public.shooting_lanes
     where resource_kind = 'position') = :'baseline_position_count'::bigint
    and (select pg_catalog.md5(pg_catalog.to_jsonb(parent)::text)
         from public.shooting_lanes as parent
         where parent.id = '254ca7f6-ce80-4267-8966-4558cc8f8fd2')
          = :'baseline_parent_hash'
    and not exists (
      select 1 from auth.users
      where id = '6c100000-0000-4000-8000-000000000001'
    )
    and not exists (
      select 1 from public.profiles
      where user_id = '6c100000-0000-4000-8000-000000000001'
    )
  ) as rollback_confirmed
\gset

\if :rollback_confirmed
select
  26 as test_order,
  'Z. ROLLBACK przywrócił baseline' as test_name,
  true as passed,
  'Positions, parent i synthetic user/profile wróciły do baseline.' as result;
\else
\echo '100 m hierarchy test failed: Z. ROLLBACK nie przywrócił baseline.'
\quit 1
\endif
