do $preflight$
declare
  v_invalid_event_count bigint;
begin
  if pg_catalog.to_regclass('public.events') is null then
    raise exception 'Brak wymaganej tabeli public.events.';
  end if;

  if pg_catalog.to_regclass('public.shooting_lanes') is null then
    raise exception 'Brak wymaganej tabeli public.shooting_lanes.';
  end if;

  if pg_catalog.to_regprocedure('public.is_admin_or_staff()') is null then
    raise exception 'Brak wymaganego helpera public.is_admin_or_staff().';
  end if;

  select pg_catalog.count(*)
  into v_invalid_event_count
  from public.events as event_record
  where event_record.end_time <= event_record.start_time;

  if v_invalid_event_count > 0 then
    raise exception
      'Nie można utworzyć modelu event_lanes: % eventów ma end_time <= start_time.',
      v_invalid_event_count
      using errcode = '23514';
  end if;
end;
$preflight$;

alter table public.events
  add constraint events_time_range_check
  check (end_time > start_time);

create table public.event_lanes (
  event_id uuid not null,
  lane_id uuid not null,
  created_at timestamp with time zone not null
    default pg_catalog.transaction_timestamp(),
  constraint event_lanes_pkey
    primary key (event_id, lane_id),
  constraint event_lanes_event_id_fkey
    foreign key (event_id)
    references public.events (id)
    on delete cascade,
  constraint event_lanes_lane_id_fkey
    foreign key (lane_id)
    references public.shooting_lanes (id)
    on delete restrict
);

create index event_lanes_lane_event_idx
  on public.event_lanes (lane_id, event_id);

alter table public.event_lanes enable row level security;

revoke all on table public.event_lanes from public;
revoke all on table public.event_lanes from anon;
revoke all on table public.event_lanes from authenticated;

grant select on table public.event_lanes to authenticated;
grant all on table public.event_lanes to service_role;

create policy "Admins and staff can view event lanes"
on public.event_lanes
for select
to authenticated
using (public.is_admin_or_staff());

comment on table public.event_lanes is
  'Relacja eventów z zajmowanymi osiami; brak rekordów oznacza event globalny.';

comment on column public.event_lanes.event_id is
  'Event zajmujący wskazaną oś.';

comment on column public.event_lanes.lane_id is
  'Oś zajmowana przez event.';

comment on column public.event_lanes.created_at is
  'Techniczny czas utworzenia przypisania eventu do osi.';
