-- Użytkownik nadal odczytuje własne zapisy przez politykę SELECT.
-- Rejestracja odbywa się przez kontrolowany endpoint /api/register-event.
-- Anulowanie odbywa się przez SECURITY DEFINER RPC cancel_event_registration,
-- dlatego bezpośredni UPDATE użytkownika nie jest już potrzebny.
drop policy if exists "Users can update own event registrations"
on public.event_registrations;
