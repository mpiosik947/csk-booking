-- SEC-003: reserve promotion confirmation must be an authenticated,
-- ownership-scoped mutation invoked by POST rather than a public GET.

create or replace function public.confirm_event_reserve_promotion(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_token text := pg_catalog.btrim(p_token);
  v_event_id uuid;
  v_registration_user_id uuid;
  v_registration public.event_registrations%rowtype;
  v_event public.events%rowtype;
  v_participants_count integer;
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication is required.';
  end if;

  if v_token is null or v_token = '' then
    raise exception using
      errcode = '22023',
      message = 'Promotion token is required.';
  end if;

  select registration.event_id, registration.user_id
  into v_event_id, v_registration_user_id
  from public.event_registrations as registration
  where registration.promotion_token = v_token;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', 'Link jest nieprawidłowy albo nie istnieje.'
    );
  end if;

  if v_registration_user_id is null
     or v_registration_user_id is distinct from v_user_id then
    raise exception using
      errcode = '42501',
      message = 'You cannot confirm this registration.';
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = v_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'event_not_found',
      'message', 'Nie znaleziono szkolenia.'
    );
  end if;

  select registration.*
  into v_registration
  from public.event_registrations as registration
  where registration.promotion_token = v_token
    and registration.event_id = v_event_id
    and registration.user_id = v_user_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'You cannot confirm this registration.';
  end if;

  if v_registration.registration_status <> 'reserve' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'not_reserve',
      'message', 'Ten zapis nie znajduje się już na liście rezerwowej.'
    );
  end if;

  if v_registration.promotion_token_expires_at is null
     or v_registration.promotion_token_expires_at
       < pg_catalog.transaction_timestamp() then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'expired',
      'message', 'Link do potwierdzenia miejsca wygasł.'
    );
  end if;

  select pg_catalog.count(*)
  into v_participants_count
  from public.event_registrations as registration
  where registration.event_id = v_registration.event_id
    and registration.registration_status in ('registered', 'approved');

  if v_participants_count >= coalesce(v_event.max_participants, 0) then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'full',
      'message', 'Miejsce zostało już zajęte przez inną osobę.'
    );
  end if;

  update public.event_registrations as registration
  set
    registration_status = 'registered',
    promotion_confirmed_at = pg_catalog.transaction_timestamp(),
    promotion_claim_id = null,
    promotion_claim_expires_at = null,
    promotion_last_error_code = null
  where registration.id = v_registration.id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'code', 'confirmed',
    'message', 'Twoje miejsce zostało potwierdzone.',
    'event_id', v_registration.event_id,
    'registration_id', v_registration.id
  );
end;
$function$;

alter function public.confirm_event_reserve_promotion(text) owner to postgres;

revoke all on function public.confirm_event_reserve_promotion(text) from public;
revoke all on function public.confirm_event_reserve_promotion(text) from anon;
revoke all on function public.confirm_event_reserve_promotion(text) from service_role;
grant execute on function public.confirm_event_reserve_promotion(text) to authenticated;

comment on function public.confirm_event_reserve_promotion(text) is
  'Potwierdza własny aktywny token promocji zalogowanego użytkownika z blokadami w kolejności wydarzenie, następnie rejestracja.';
