begin;

-- Owner-bound operational DTOs. Existing public table policies remain unchanged.
create function public.read_owned_event_confirmation_v1(p_registration_id uuid)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select pg_catalog.jsonb_build_object(
    'customer_name', r.customer_name, 'registration_status', r.registration_status,
    'title', e.title, 'event_date', e.event_date, 'start_time', e.start_time,
    'end_time', e.end_time, 'location', e.location, 'price', e.price)
  from public.event_registrations r
  join public.events e on e.id = r.event_id and e.tenant_id = r.tenant_id
  join public.tenants t on t.id = e.tenant_id
  where r.id = p_registration_id and auth.uid() is not null
    and r.user_id = auth.uid() and r.pii_anonymized_at is null
    and r.registration_status in ('registered', 'reserve')
    and e.is_active and e.cancelled_at is null and t.status = 'active'
    and public.get_public_tenant_feature_access_v1(t.id, 'events');
$$;

create function public.read_owned_booking_confirmation_v1(p_reservation_id uuid)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select pg_catalog.jsonb_build_object(
    'customer_name', r.customer_name, 'reservation_status', r.reservation_status,
    'reservation_date', r.reservation_date, 'start_time', r.start_time,
    'end_time', r.end_time, 'price', r.price, 'check_in_token', r.check_in_token,
    'lane_name', l.name)
  from public.reservations r
  join public.shooting_lanes l on l.id = r.lane_id and l.tenant_id = r.tenant_id
  join public.tenants t on t.id = r.tenant_id
  where r.id = p_reservation_id and auth.uid() is not null
    and r.user_id = auth.uid() and r.pii_anonymized_at is null
    and r.reservation_status = 'confirmed' and l.is_active and t.status = 'active'
    and public.get_public_tenant_feature_access_v1(t.id, 'booking');
$$;

alter function public.read_owned_event_confirmation_v1(uuid) owner to postgres;
alter function public.read_owned_booking_confirmation_v1(uuid) owner to postgres;
revoke all on function public.read_owned_event_confirmation_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.read_owned_booking_confirmation_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.read_owned_event_confirmation_v1(uuid) to authenticated;
grant execute on function public.read_owned_booking_confirmation_v1(uuid) to authenticated;

commit;
