-- Add the five physical positions of the existing 100 m lane as dormant
-- hierarchy resources. This migration deliberately leaves the current parent
-- offer, its capacity, pricing, durations and public sale mode unchanged.

-- Keep the lock, preflight, inserts and postflight in one server-side statement.
-- Supabase CLI 2.109.1 executes top-level migration statements separately, so a
-- standalone LOCK TABLE is outside an explicit transaction block. A single DO
-- statement is atomic and lets PostgreSQL retain these locks until every check
-- and both inserts have succeeded.
do $migration$
declare
  v_parent_id constant uuid := '254ca7f6-ce80-4267-8966-4558cc8f8fd2';
  v_child_ids constant uuid[] := array[
    'f34d5c5c-9135-4a17-b513-d1bacaf57d79'::uuid,
    '5858c167-e48b-478a-88f3-ba3db4605798'::uuid,
    '9bf08601-0ff8-452e-985e-9e1695d1fe78'::uuid,
    '83e85c35-4d7f-4415-b00d-b0f2a7b9c789'::uuid,
    'b557d51a-554c-4cc2-868c-63121f2d5cb3'::uuid
  ];
  v_position_count bigint;
  v_parent_scope uuid[];
begin
  execute 'lock table public.shooting_lanes,
    public.lane_booking_rules,
    public.lane_booking_durations,
    public.lane_pricing_rules
    in share row exclusive mode';

  if pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regclass('public.lane_booking_rules') is null
     or pg_catalog.to_regclass('public.lane_booking_durations') is null
     or pg_catalog.to_regclass('public.lane_pricing_rules') is null
     or pg_catalog.to_regprocedure(
          'public.lock_lane_conflict_families_v1(uuid[])'
        ) is null
     or pg_catalog.to_regprocedure(
          'public.get_public_booking_configuration_v1()'
        ) is null
     or pg_catalog.to_regprocedure(
          'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'
        ) is null then
    raise exception '100 m hierarchy preflight failed: required schema is missing.';
  end if;

  if (select pg_catalog.count(*)
      from public.shooting_lanes as lane
      where lane.name = 'Oś 100 m'
        and lane.resource_kind = 'lane'
        and lane.parent_lane_id is null) <> 1
     or not exists (
       select 1
       from public.shooting_lanes as lane
       where lane.id = v_parent_id
         and lane.name = 'Oś 100 m'
         and lane.type = 'karabinowa'
         and lane.resource_kind = 'lane'
         and lane.parent_lane_id is null
         and lane.is_active
         and lane.display_order = 30
         and lane.max_shooters = 6
         and lane.booking_step_minutes = 60
         and lane.currency_code::text = 'PLN'
         and lane.whole_lane_bookable
         and not lane.positions_bookable
     ) then
    raise exception '100 m hierarchy preflight failed: parent baseline differs.';
  end if;

  if not exists (
    select 1
    from public.lane_booking_rules as rule
    where rule.lane_id = v_parent_id
      and rule.online_bookable
      and rule.max_people_online = 6
  ) then
    raise exception '100 m hierarchy preflight failed: parent booking rule differs.';
  end if;

  select pg_catalog.count(*)
  into v_position_count
  from public.shooting_lanes as lane
  where lane.resource_kind = 'position';

  if v_position_count not in (0, 5) then
    raise exception '100 m hierarchy preflight failed: partial or unexpected position set.';
  end if;

  if v_position_count = 0 then
    if exists (
      select 1
      from public.shooting_lanes as lane
      where lane.id = any(v_child_ids)
         or lane.parent_lane_id = v_parent_id
         or lane.name in (
           'Stanowisko 1', 'Stanowisko 2', 'Stanowisko 3',
           'Stanowisko 4', 'Stanowisko 5'
         )
    ) then
      raise exception '100 m hierarchy preflight failed: child identifiers or names are already used.';
    end if;
  elsif exists (
    select 1
    from public.shooting_lanes as lane
    where lane.resource_kind = 'position'
      and lane.id <> all(v_child_ids)
  )
  or (select pg_catalog.count(*)
      from public.shooting_lanes as lane
      where lane.parent_lane_id = v_parent_id
        and lane.id = any(v_child_ids)) <> 5
  or exists (
    select 1
    from (
      values
        (v_child_ids[1], 'Stanowisko 1'::text, 1),
        (v_child_ids[2], 'Stanowisko 2'::text, 2),
        (v_child_ids[3], 'Stanowisko 3'::text, 3),
        (v_child_ids[4], 'Stanowisko 4'::text, 4),
        (v_child_ids[5], 'Stanowisko 5'::text, 5)
    ) as expected(id, name, display_order)
    left join public.shooting_lanes as child on child.id = expected.id
    left join public.lane_booking_rules as rule on rule.lane_id = expected.id
    where child.id is null
       or child.name is distinct from expected.name
       or child.type is distinct from 'karabinowa'
       or child.description is not null
       or child.price_per_hour <> 0
       or child.is_active
       or child.max_shooters <> 1
       or child.booking_step_minutes <> 60
       or child.display_order <> expected.display_order
       or child.currency_code::text <> 'PLN'
       or child.resource_kind <> 'position'
       or child.parent_lane_id is distinct from v_parent_id
       or child.whole_lane_bookable
       or child.positions_bookable
       or rule.lane_id is null
       or rule.online_bookable
       or rule.max_people_online <> 1
  )
  or exists (
    select 1
    from public.lane_booking_durations as duration
    where duration.lane_id = any(v_child_ids)
    union all
    select 1
    from public.lane_pricing_rules as pricing
    where pricing.lane_id = any(v_child_ids)
  ) then
    raise exception '100 m hierarchy preflight failed: existing children differ from the exact dormant set.';
  end if;

insert into public.shooting_lanes (
  id,
  name,
  type,
  description,
  price_per_hour,
  is_active,
  max_shooters,
  booking_step_minutes,
  display_order,
  currency_code,
  resource_kind,
  parent_lane_id,
  whole_lane_bookable,
  positions_bookable
)
select
  child.id,
  child.name,
  'karabinowa',
  null,
  0,
  false,
  1,
  60,
  child.display_order,
  'PLN',
  'position',
  '254ca7f6-ce80-4267-8966-4558cc8f8fd2',
  false,
  false
from (
  values
    ('f34d5c5c-9135-4a17-b513-d1bacaf57d79'::uuid, 'Stanowisko 1'::text, 1),
    ('5858c167-e48b-478a-88f3-ba3db4605798'::uuid, 'Stanowisko 2'::text, 2),
    ('9bf08601-0ff8-452e-985e-9e1695d1fe78'::uuid, 'Stanowisko 3'::text, 3),
    ('83e85c35-4d7f-4415-b00d-b0f2a7b9c789'::uuid, 'Stanowisko 4'::text, 4),
    ('b557d51a-554c-4cc2-868c-63121f2d5cb3'::uuid, 'Stanowisko 5'::text, 5)
) as child(id, name, display_order)
where not exists (
  select 1
  from public.shooting_lanes as existing
  where existing.id = child.id
);

insert into public.lane_booking_rules (
  lane_id,
  online_bookable,
  max_people_online
)
select child_id, false, 1
from pg_catalog.unnest(array[
  'f34d5c5c-9135-4a17-b513-d1bacaf57d79'::uuid,
  '5858c167-e48b-478a-88f3-ba3db4605798'::uuid,
  '9bf08601-0ff8-452e-985e-9e1695d1fe78'::uuid,
  '83e85c35-4d7f-4415-b00d-b0f2a7b9c789'::uuid,
  'b557d51a-554c-4cc2-868c-63121f2d5cb3'::uuid
]) as child(child_id)
where not exists (
  select 1
  from public.lane_booking_rules as existing
  where existing.lane_id = child.child_id
);

  if (select pg_catalog.count(*)
      from public.shooting_lanes
      where resource_kind = 'position') <> 5
     or (select pg_catalog.count(*)
         from public.shooting_lanes
         where parent_lane_id = v_parent_id) <> 5
     or exists (
       select 1
       from public.shooting_lanes as child
       left join public.shooting_lanes as grandchild
         on grandchild.parent_lane_id = child.id
       where child.id = any(v_child_ids)
         and (
           child.resource_kind <> 'position'
           or child.parent_lane_id is distinct from v_parent_id
           or child.is_active
           or child.max_shooters <> 1
           or child.whole_lane_bookable
           or child.positions_bookable
           or grandchild.id is not null
         )
     ) then
    raise exception '100 m hierarchy postflight failed: hierarchy invariants differ.';
  end if;

  if (select pg_catalog.count(*)
      from public.lane_booking_rules as rule
      where rule.lane_id = any(v_child_ids)
        and not rule.online_bookable
        and rule.max_people_online = 1) <> 5
     or exists (
       select 1 from public.lane_booking_durations
       where lane_id = any(v_child_ids)
       union all
       select 1 from public.lane_pricing_rules
       where lane_id = any(v_child_ids)
     ) then
    raise exception '100 m hierarchy postflight failed: dormant configuration differs.';
  end if;

  if not exists (
       select 1
       from public.shooting_lanes as lane
       join public.lane_booking_rules as rule on rule.lane_id = lane.id
       where lane.id = v_parent_id
         and lane.name = 'Oś 100 m'
         and lane.resource_kind = 'lane'
         and lane.parent_lane_id is null
         and lane.is_active
         and lane.max_shooters = 6
         and lane.whole_lane_bookable
         and not lane.positions_bookable
         and rule.online_bookable
         and rule.max_people_online = 6
     )
     or not exists (
       select 1
       from public.get_public_booking_configuration_v1() as config
       where config.lane_id = v_parent_id
         and config.resource_kind = 'lane'
         and config.parent_lane_id is null
         and config.effective_online_bookable
         and config.whole_lane_bookable
         and not config.positions_bookable
         and config.max_people_online = 6
         and config.durations_minutes = array[60, 120, 180, 240]
         and pg_catalog.jsonb_array_length(config.pricing) = 8
     )
     or exists (
       select 1
       from public.get_public_booking_configuration_v1() as config
       where config.lane_id = any(v_child_ids)
     ) then
    raise exception '100 m hierarchy postflight failed: public parent behavior changed.';
  end if;

  select scope.conflict_lane_ids
  into v_parent_scope
  from public.lock_lane_conflict_families_v1(array[v_parent_id]) as scope
  where scope.requested_lane_id = v_parent_id;

  if pg_catalog.cardinality(v_parent_scope) <> 6
     or not v_parent_id = any(v_parent_scope)
     or exists (
       select 1
       from pg_catalog.unnest(v_child_ids) as child(id)
       where not child.id = any(v_parent_scope)
     )
     or exists (
       select 1
       from public.lock_lane_conflict_families_v1(v_child_ids) as scope
       where scope.root_lane_id is distinct from v_parent_id
          or scope.requested_resource_kind <> 'position'
          or scope.conflict_lane_ids
             is distinct from array[v_parent_id, scope.requested_lane_id]::uuid[]
     ) then
    raise exception '100 m hierarchy postflight failed: conflict-family scopes differ.';
  end if;
end;
$migration$;
