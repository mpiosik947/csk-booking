create or replace function public.is_admin_or_employee()
returns boolean
language sql
stable
security definer
set search_path to public
as $function$
  select exists (
    select 1
    from public.profiles
    where user_id = auth.uid()
      and lower(btrim(role::text)) in ('admin', 'pracownik')
  );
$function$;

revoke all on function public.is_admin_or_employee()
from public;

revoke all on function public.is_admin_or_employee()
from anon;

grant execute on function public.is_admin_or_employee()
to authenticated;

drop policy if exists "Admins and staff can insert reservations"
on public.reservations;

create policy "Admins and staff can insert reservations"
on public.reservations
for insert
to authenticated
with check (public.is_admin_or_employee());

drop policy if exists "Admins and staff can update reservations"
on public.reservations;

create policy "Admins and staff can update reservations"
on public.reservations
for update
to authenticated
using (public.is_admin_or_employee())
with check (public.is_admin_or_employee());

drop policy if exists "Users can insert own reservations"
on public.reservations;

create policy "Users can insert own reservations"
on public.reservations
for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.profiles as profile
    where profile.user_id = auth.uid()
      and lower(btrim(profile.role::text)) = 'user'
  )
);
