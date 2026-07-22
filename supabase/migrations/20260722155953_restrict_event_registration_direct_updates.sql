-- Ogranicz bezpośrednie aktualizacje zapisów na szkolenia do płatności.
revoke update on table public.event_registrations from authenticated;
revoke update on table public.event_registrations from anon;
revoke update on table public.event_registrations from public;

grant update (payment_status)
on table public.event_registrations
to authenticated;
