create unique index event_registrations_one_active_per_user_event_idx
on public.event_registrations (event_id, user_id)
where event_id is not null
  and user_id is not null
  and lower(btrim(registration_status)) in (
    'registered',
    'approved',
    'reserve',
    'participant'
  );

comment on index public.event_registrations_one_active_per_user_event_idx is
  'Ensures one active registration per user and event. Reserve participates in uniqueness; terminal records such as cancelled remain historical and do not block re-registration.';
