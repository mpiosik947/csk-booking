-- Read-only invariant suite for the isolated 6B-4E cross-writer regression.
-- The caller must scope the database to synthetic fixtures; this query performs no DML.
with
active_reservations as (
  select reservation.id, reservation.lane_id, reservation.reservation_date,
         reservation.start_time, reservation.end_time
  from public.reservations as reservation
  where lower(btrim(reservation.reservation_status)) not in (
    'completed', 'no_show', 'cancelled', 'canceled',
    'cancelled_by_admin', 'cancelled_by_user'
  )
),
resource_scope as (
  select lane.id, lane.resource_kind, coalesce(lane.parent_lane_id, lane.id) as root_id
  from public.shooting_lanes as lane
),
reservation_parent_child as (
  select count(*)::bigint as violations
  from active_reservations as left_reservation
  join active_reservations as right_reservation
    on left_reservation.id < right_reservation.id
   and left_reservation.reservation_date = right_reservation.reservation_date
   and left_reservation.start_time < right_reservation.end_time
   and right_reservation.start_time < left_reservation.end_time
  join resource_scope as left_scope on left_scope.id = left_reservation.lane_id
  join resource_scope as right_scope on right_scope.id = right_reservation.lane_id
  where left_scope.root_id = right_scope.root_id
    and (left_scope.resource_kind = 'lane' or right_scope.resource_kind = 'lane')
),
reservation_block as (
  select count(*)::bigint as violations
  from active_reservations as reservation
  join public.lane_blocks as block
    on block.is_active
   and block.block_date = reservation.reservation_date
   and block.start_time < reservation.end_time
   and reservation.start_time < block.end_time
  join resource_scope as reservation_scope on reservation_scope.id = reservation.lane_id
  join resource_scope as block_scope on block_scope.id = block.lane_id
  where reservation_scope.root_id = block_scope.root_id
    and (
      reservation_scope.id = block_scope.id
      or reservation_scope.resource_kind = 'lane'
      or block_scope.resource_kind = 'lane'
    )
),
reservation_event as (
  select count(*)::bigint as violations
  from active_reservations as reservation
  join public.events as event
    on event.is_active
   and event.event_date = reservation.reservation_date
   and event.start_time < reservation.end_time
   and reservation.start_time < event.end_time
  join public.event_lanes as event_lane on event_lane.event_id = event.id
  join resource_scope as reservation_scope on reservation_scope.id = reservation.lane_id
  join resource_scope as event_scope on event_scope.id = event_lane.lane_id
  where reservation_scope.root_id = event_scope.root_id
    and (
      reservation_scope.id = event_scope.id
      or reservation_scope.resource_kind = 'lane'
      or event_scope.resource_kind = 'lane'
    )
),
block_event as (
  select count(*)::bigint as violations
  from public.lane_blocks as block
  join public.events as event
    on block.is_active
   and event.is_active
   and event.event_date = block.block_date
   and event.start_time < block.end_time
   and block.start_time < event.end_time
  join public.event_lanes as event_lane on event_lane.event_id = event.id
  join resource_scope as block_scope on block_scope.id = block.lane_id
  join resource_scope as event_scope on event_scope.id = event_lane.lane_id
  where block_scope.root_id = event_scope.root_id
    and (
      block_scope.id = event_scope.id
      or block_scope.resource_kind = 'lane'
      or event_scope.resource_kind = 'lane'
    )
),
invalid_hierarchy as (
  select count(*)::bigint as violations
  from public.shooting_lanes as lane
  left join public.shooting_lanes as parent on parent.id = lane.parent_lane_id
  where lane.id = lane.parent_lane_id
     or (lane.resource_kind = 'lane' and lane.parent_lane_id is not null)
     or (
       lane.resource_kind = 'position'
       and (
         lane.parent_lane_id is null
         or parent.id is null
         or parent.resource_kind is distinct from 'lane'
         or parent.parent_lane_id is not null
       )
     )
),
duplicate_durations as (
  select count(*)::bigint as violations
  from (
    select duration.lane_id, duration.duration_minutes
    from public.lane_booking_durations as duration
    group by duration.lane_id, duration.duration_minutes
    having count(*) > 1
  ) as duplicate
),
priced_intervals as (
  select pricing.lane_id, pricing.day_group, pricing.min_shooters,
         pricing.max_shooters,
         lag(pricing.max_shooters) over (
           partition by pricing.lane_id, pricing.day_group
           order by pricing.min_shooters, pricing.max_shooters, pricing.id
         ) as previous_max,
         row_number() over (
           partition by pricing.lane_id, pricing.day_group
           order by pricing.min_shooters, pricing.max_shooters, pricing.id
         ) as sequence_number,
         max(pricing.max_shooters) over (
           partition by pricing.lane_id, pricing.day_group
         ) as final_max
  from public.lane_pricing_rules as pricing
  where pricing.is_active
),
pricing_coverage as (
  select count(*)::bigint as violations
  from priced_intervals as interval
  join public.lane_booking_rules as rule on rule.lane_id = interval.lane_id
  where interval.min_shooters > interval.max_shooters
     or interval.max_shooters > rule.max_people_online
     or (interval.sequence_number = 1 and interval.min_shooters <> 1)
     or (interval.sequence_number > 1 and interval.min_shooters <> interval.previous_max + 1)
     or interval.final_max <> rule.max_people_online
),
invalid_capacity as (
  select count(*)::bigint as violations
  from public.lane_booking_rules as rule
  join public.shooting_lanes as lane on lane.id = rule.lane_id
  where rule.max_people_online < 1
     or rule.max_people_online > lane.max_shooters
),
orphan_event_lanes as (
  select count(*)::bigint as violations
  from public.event_lanes as event_lane
  left join public.events as event on event.id = event_lane.event_id
  left join public.shooting_lanes as lane on lane.id = event_lane.lane_id
  where event.id is null or lane.id is null
),
incomplete_online_configuration as (
  select count(*)::bigint as violations
  from public.shooting_lanes as lane
  join public.lane_booking_rules as rule on rule.lane_id = lane.id
  where rule.online_bookable
    and (
      not exists (
        select 1 from public.lane_booking_durations as duration
        where duration.lane_id = lane.id and duration.is_active
      )
      or exists (
        select required_group.day_group
        from (values ('mon_thu'::text), ('fri_sun'::text)) as required_group(day_group)
        where not exists (
          select 1 from priced_intervals as interval
          where interval.lane_id = lane.id
            and interval.day_group = required_group.day_group
            and interval.sequence_number = 1
            and interval.min_shooters = 1
            and interval.final_max = rule.max_people_online
        )
      )
    )
),
reader_exposes_incomplete_configuration as (
  select count(*)::bigint as violations
  from public.get_public_booking_configuration_v1() as configuration
  left join public.lane_booking_rules as rule
    on rule.lane_id = configuration.lane_id
  where rule.lane_id is null
     or not rule.online_bookable
     or not exists (
       select 1
       from public.lane_booking_durations as duration
       where duration.lane_id = configuration.lane_id
         and duration.is_active
     )
     or exists (
       select required_group.day_group
       from (values ('mon_thu'::text), ('fri_sun'::text)) as required_group(day_group)
       where not exists (
         select 1
         from priced_intervals as interval
         where interval.lane_id = configuration.lane_id
           and interval.day_group = required_group.day_group
           and interval.sequence_number = 1
           and interval.min_shooters = 1
           and interval.final_max = rule.max_people_online
       )
     )
),
summary as (
  select
    reservation_parent_child.violations as parent_child_reservations,
    reservation_block.violations as reservation_block,
    reservation_event.violations as reservation_event,
    block_event.violations as block_event,
    invalid_hierarchy.violations as invalid_hierarchy,
    duplicate_durations.violations as duplicate_durations,
    pricing_coverage.violations as pricing_coverage,
    invalid_capacity.violations as invalid_capacity,
    orphan_event_lanes.violations as orphan_event_lanes,
    incomplete_online_configuration.violations as incomplete_online_configuration,
    reader_exposes_incomplete_configuration.violations as reader_exposes_incomplete_configuration
  from reservation_parent_child, reservation_block, reservation_event,
       block_event, invalid_hierarchy, duplicate_durations, pricing_coverage,
       invalid_capacity, orphan_event_lanes, incomplete_online_configuration,
       reader_exposes_incomplete_configuration
)
select
  'total_violations=' || (
    parent_child_reservations + reservation_block + reservation_event +
    block_event + invalid_hierarchy + duplicate_durations + pricing_coverage +
    invalid_capacity + orphan_event_lanes + incomplete_online_configuration +
    reader_exposes_incomplete_configuration
  ) ||
  ';parent_child_reservations=' || parent_child_reservations ||
  ';reservation_block=' || reservation_block ||
  ';reservation_event=' || reservation_event ||
  ';block_event=' || block_event ||
  ';invalid_hierarchy=' || invalid_hierarchy ||
  ';duplicate_durations=' || duplicate_durations ||
  ';pricing_coverage=' || pricing_coverage ||
  ';invalid_capacity=' || invalid_capacity ||
  ';orphan_event_lanes=' || orphan_event_lanes ||
  ';incomplete_online_configuration=' || incomplete_online_configuration ||
  ';reader_exposes_incomplete_configuration=' || reader_exposes_incomplete_configuration
from summary;
