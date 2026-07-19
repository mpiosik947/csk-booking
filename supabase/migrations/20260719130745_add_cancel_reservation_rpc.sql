create or replace function public.cancel_reservation(
  p_reservation_id uuid
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
  actor_role text;
  actor_name text;
  current_status text;
  result_status text;
  cancelled_by_value text;
  audit_action text;
  reservation_start_at timestamptz;
  cancellation_window_hours_raw numeric;
  cancellation_window_hours_rounded numeric;
  within_client_cancellation_window boolean;
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  if p_reservation_id is null then
    raise exception 'Brak identyfikatora rezerwacji.'
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

  if coalesce(actor_role, '') not in ('user', 'admin', 'pracownik') then
    raise exception 'Brak uprawnień do anulowania rezerwacji.'
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

  if actor_role = 'user'
     and target_reservation.user_id is distinct from actor_user_id then
    raise exception 'Brak uprawnień do anulowania tej rezerwacji.'
      using errcode = '42501';
  end if;

  current_status := lower(btrim(target_reservation.reservation_status));
  reservation_start_at :=
    (target_reservation.reservation_date + target_reservation.start_time)
      at time zone 'Europe/Warsaw';
  cancellation_window_hours_raw := extract(
    epoch from (reservation_start_at - transaction_timestamp())
  ) / 3600.0;
  cancellation_window_hours_rounded := round(
    cancellation_window_hours_raw,
    2
  );
  within_client_cancellation_window :=
    cancellation_window_hours_raw >= 12;

  if current_status in (
    'cancelled',
    'canceled',
    'cancelled_by_user',
    'cancelled_by_admin'
  ) then
    cancelled_by_value := case current_status
      when 'cancelled_by_user' then 'user'
      when 'cancelled_by_admin' then 'staff'
      else null
    end;

    return jsonb_build_object(
      'reservation_id', target_reservation.id,
      'changed', false,
      'previous_status', target_reservation.reservation_status,
      'new_status', target_reservation.reservation_status,
      'cancelled_by', cancelled_by_value,
      'operator_role', actor_role,
      'cancellation_window_hours', cancellation_window_hours_rounded,
      'within_client_cancellation_window', within_client_cancellation_window
    );
  end if;

  if current_status is distinct from 'confirmed' then
    raise exception 'Rezerwacji w tym statusie nie można anulować.'
      using errcode = '55000';
  end if;

  if actor_role = 'user' and not within_client_cancellation_window then
    raise exception 'Rezerwację można anulować najpóźniej 12 godzin przed rozpoczęciem.'
      using errcode = '55000';
  end if;

  if actor_role = 'user' then
    result_status := 'cancelled_by_user';
    cancelled_by_value := 'user';
    audit_action := 'reservation_cancelled_by_user';
  else
    result_status := 'cancelled_by_admin';
    cancelled_by_value := 'staff';
    audit_action := 'reservation_cancelled_by_staff';
  end if;

  update public.reservations
  set reservation_status = result_status
  where id = p_reservation_id
  returning reservation_status into result_status;

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
      'previous_status', target_reservation.reservation_status,
      'new_status', result_status,
      'operator_role', actor_role,
      'cancellation_window_hours', cancellation_window_hours_rounded,
      'within_client_cancellation_window', within_client_cancellation_window
    )
  );

  return jsonb_build_object(
    'reservation_id', target_reservation.id,
    'changed', true,
    'previous_status', target_reservation.reservation_status,
    'new_status', result_status,
    'cancelled_by', cancelled_by_value,
    'operator_role', actor_role,
    'cancellation_window_hours', cancellation_window_hours_rounded,
    'within_client_cancellation_window', within_client_cancellation_window
  );
end;
$$;

comment on function public.cancel_reservation(uuid) is
  'Atomowo anuluje rezerwację z kontrolą sesji, roli, własności, statusu i limitu czasu oraz zapisuje audit log.';

revoke all on function public.cancel_reservation(uuid) from public;
revoke all on function public.cancel_reservation(uuid) from anon;
grant execute on function public.cancel_reservation(uuid) to authenticated;

-- Bezpośrednie UPDATE zostaną wyłączone dopiero po podłączeniu wszystkich
-- ekranów anulowania rezerwacji do tego RPC.
