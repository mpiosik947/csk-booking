drop policy if exists "Admins and staff can insert event registrations"
on public.event_registrations;

create policy "Admins and staff can insert event registrations"
on public.event_registrations
for insert
to authenticated
with check (public.is_admin_or_employee());

drop policy if exists "Admins and staff can update event registrations"
on public.event_registrations;

create policy "Admins and staff can update event registrations"
on public.event_registrations
for update
to authenticated
using (public.is_admin_or_employee())
with check (public.is_admin_or_employee());

drop policy if exists "Admins and staff can delete event registrations"
on public.event_registrations;

create policy "Admins and staff can delete event registrations"
on public.event_registrations
for delete
to authenticated
using (public.is_admin_or_employee());

-- Rejestracja użytkownika działa przez uwierzytelniony endpoint
-- /api/register-event korzystający z service_role.
-- Bezpośredni INSERT umożliwiał omijanie limitów, statusów i walidacji.
drop policy if exists "Users can insert own event registrations"
on public.event_registrations;

-- Bezpośredni UPDATE pozostaje tymczasowo tylko dla roli user,
-- ponieważ anulowanie w app/my-events nie zostało jeszcze przeniesione
-- do kontrolowanego RPC lub endpointu.
-- Polityka nadal pozwala zmieniać wszystkie kolumny własnego wiersza
-- i zostanie usunięta w kolejnym etapie.
drop policy if exists "Users can update own event registrations"
on public.event_registrations;

create policy "Users can update own event registrations"
on public.event_registrations
for update
to authenticated
using (
  user_id = auth.uid()
  and exists (
    select 1
    from public.profiles as profile
    where profile.user_id = auth.uid()
      and lower(btrim(profile.role::text)) = 'user'
  )
)
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.profiles as profile
    where profile.user_id = auth.uid()
      and lower(btrim(profile.role::text)) = 'user'
  )
);

revoke truncate on table public.event_registrations
from anon;

revoke truncate on table public.event_registrations
from authenticated;
