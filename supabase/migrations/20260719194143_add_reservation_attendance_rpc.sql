create or replace function public.update_reservation_attendance(
  p_reservation_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_reservation public.reservations%rowtype;
  updated_reservation public.reservations%rowtype;
  actor_role text;
  actor_name text;
  normalized_action text;
  current_reservation_status text;
  current_attendance_status text;
  result_reservation_status text;
  result_attendance_status text;
  audit_action text;
  operation_timestamp timestamptz;
  checked_in_at_changed boolean := false;
  completed_at_changed boolean := false;
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  if p_reservation_id is null then
    raise exception 'Brak identyfikatora rezerwacji.'
      using errcode = '22023';
  end if;

  normalized_action := lower(btrim(p_action));

  if coalesce(normalized_action, '') not in ('complete', 'no_show') then
    raise exception 'Nieprawidłowa operacja rezerwacji.'
      using errcode = '22023';
  end if;

  select profile.*
  into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found then
    raise exception 'Brak profilu operatora.'
      using errcode = '42501';
  end if;

  actor_role := lower(btrim(actor_profile.role::text));

  if coalesce(actor_role, '') not in ('admin', 'pracownik', 'instruktor') then
    raise exception 'Brak uprawnień do zmiany statusu obecności rezerwacji.'
      using errcode = '42501';
  end if;

  select reservation.*
  into target_reservation
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;

  if not found then
    raise exception 'Nie znaleziono rezerwacji.'
      using errcode = 'P0002';
  end if;

  current_reservation_status := lower(
    btrim(target_reservation.reservation_status)
  );
  current_attendance_status := lower(
    btrim(target_reservation.attendance_status)
  );

  if normalized_action = 'complete' then
    result_reservation_status := 'completed';
    result_attendance_status := 'completed';
    audit_action := 'CHECK_IN_COMPLETED';

    if current_reservation_status = 'completed'
       and current_attendance_status = 'completed'
       and target_reservation.checked_in_at is not null
       and target_reservation.completed_at is not null then
      return jsonb_build_object(
        'reservation_id', target_reservation.id,
        'changed', false,
        'action', normalized_action,
        'operator_role', actor_role,
        'previous_reservation_status', target_reservation.reservation_status,
        'new_reservation_status', target_reservation.reservation_status,
        'previous_attendance_status', target_reservation.attendance_status,
        'new_attendance_status', target_reservation.attendance_status,
        'checked_in_at_changed', false,
        'completed_at_changed', false
      );
    end if;

    if current_reservation_status not in ('confirmed', 'completed')
       or current_reservation_status is null then
      raise exception 'Rezerwacji w tym statusie nie można zakończyć.'
        using errcode = '55000';
    end if;
  else
    result_reservation_status := 'no_show';
    result_attendance_status := 'no_show';
    audit_action := 'RESERVATION_NO_SHOW';

    if current_reservation_status = 'no_show'
       and current_attendance_status = 'no_show'
       and target_reservation.completed_at is null then
      return jsonb_build_object(
        'reservation_id', target_reservation.id,
        'changed', false,
        'action', normalized_action,
        'operator_role', actor_role,
        'previous_reservation_status', target_reservation.reservation_status,
        'new_reservation_status', target_reservation.reservation_status,
        'previous_attendance_status', target_reservation.attendance_status,
        'new_attendance_status', target_reservation.attendance_status,
        'checked_in_at_changed', false,
        'completed_at_changed', false
      );
    end if;

    if current_reservation_status not in ('confirmed', 'no_show')
       or current_reservation_status is null then
      raise exception 'Rezerwacji w tym statusie nie można oznaczyć jako nieobecność.'
        using errcode = '55000';
    end if;
  end if;

  operation_timestamp := transaction_timestamp();

  update public.reservations
  set reservation_status = result_reservation_status,
      attendance_status = result_attendance_status,
      checked_in_at = case
        when normalized_action = 'complete' then operation_timestamp
        else target_reservation.checked_in_at
      end,
      completed_at = case
        when normalized_action = 'complete' then operation_timestamp
        else null
      end
  where id = p_reservation_id
  returning * into updated_reservation;

  checked_in_at_changed :=
    target_reservation.checked_in_at is distinct from
      updated_reservation.checked_in_at;
  completed_at_changed :=
    target_reservation.completed_at is distinct from
      updated_reservation.completed_at;

  actor_name := coalesce(
    nullif(
      btrim(
        concat_ws(
          ' ',
          nullif(btrim(actor_profile.first_name), ''),
          nullif(btrim(actor_profile.last_name), '')
        )
      ),
      ''
    ),
    nullif(btrim(actor_profile.full_name), ''),
    nullif(btrim(actor_profile.email), ''),
    'Nieznany użytkownik'
  );

  insert into public.audit_logs (
    actor_user_id,
    actor_name,
    actor_role,
    action,
    target_type,
    target_id,
    target_name,
    details
  )
  values (
    actor_user_id,
    actor_name,
    actor_role,
    audit_action,
    'reservation',
    target_reservation.id,
    'Rezerwacja',
    jsonb_build_object(
      'action', normalized_action,
      'operator_role', actor_role,
      'previous_reservation_status', target_reservation.reservation_status,
      'new_reservation_status', updated_reservation.reservation_status,
      'previous_attendance_status', target_reservation.attendance_status,
      'new_attendance_status', updated_reservation.attendance_status,
      'checked_in_at_changed', checked_in_at_changed,
      'completed_at_changed', completed_at_changed
    )
  );

  return jsonb_build_object(
    'reservation_id', updated_reservation.id,
    'changed', true,
    'action', normalized_action,
    'operator_role', actor_role,
    'previous_reservation_status', target_reservation.reservation_status,
    'new_reservation_status', updated_reservation.reservation_status,
    'previous_attendance_status', target_reservation.attendance_status,
    'new_attendance_status', updated_reservation.attendance_status,
    'checked_in_at_changed', checked_in_at_changed,
    'completed_at_changed', completed_at_changed
  );
end;
$$;

comment on function public.update_reservation_attendance(uuid, text) is
  'Atomowo kończy wizytę lub oznacza nieobecność z kontrolą sesji, roli i statusu oraz zapisuje audit log.';

revoke all on function public.update_reservation_attendance(uuid, text)
from public;

revoke all on function public.update_reservation_attendance(uuid, text)
from anon;

grant execute on function public.update_reservation_attendance(uuid, text)
to authenticated;

-- Szerokie bezpośrednie UPDATE rezerwacji dla instruktora zostanie ograniczone
-- dopiero po przełączeniu ekranów check-in i calendar na to RPC.
