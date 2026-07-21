create or replace function public.prepare_event_reserve_promotions(
  p_event_id uuid
)
returns table (
  registration_id uuid,
  claim_id uuid,
  promotion_token text,
  promotion_token_expires_at timestamptz,
  token_reused boolean
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_event public.events%rowtype;
  v_reserve record;
  v_participants_count integer;
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_claim_id uuid;
  v_token text;
  v_token_expires_at timestamptz;
  v_token_reused boolean;
begin
  if p_event_id is null then
    raise exception using
      errcode = '22023',
      message = 'Identyfikator szkolenia jest wymagany.';
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Nie znaleziono szkolenia.';
  end if;

  select count(*)
  into v_participants_count
  from public.event_registrations as registration
  where registration.event_id = p_event_id
    and registration.registration_status in ('registered', 'approved');

  if v_participants_count >= coalesce(v_event.max_participants, 0) then
    return;
  end if;

  for v_reserve in
    select
      registration.id,
      registration.promotion_token,
      registration.promotion_token_expires_at,
      registration.promotion_email_sent_at,
      registration.promotion_confirmed_at
    from public.event_registrations as registration
    where registration.event_id = p_event_id
      and registration.registration_status = 'reserve'
      and not (
        registration.promotion_claim_id is not null
        and registration.promotion_claim_expires_at > v_now
      )
      and not (
        registration.promotion_email_sent_at is not null
        and registration.promotion_token is not null
        and registration.promotion_token_expires_at > v_now
      )
    order by registration.created_at, registration.id
    for update
  loop
    v_token_reused :=
      v_reserve.promotion_token is not null
      and v_reserve.promotion_token_expires_at > v_now
      and v_reserve.promotion_email_sent_at is null;

    if v_token_reused then
      v_token := v_reserve.promotion_token;
      v_token_expires_at := v_reserve.promotion_token_expires_at;
    else
      v_token := pg_catalog.gen_random_uuid()::text;
      v_token_expires_at := v_now + interval '24 hours';
    end if;

    v_claim_id := pg_catalog.gen_random_uuid();

    update public.event_registrations as registration
    set
      promotion_token = v_token,
      promotion_token_expires_at = v_token_expires_at,
      promotion_email_sent_at = case
        when v_token_reused then registration.promotion_email_sent_at
        else null
      end,
      promotion_confirmed_at = case
        when v_token_reused then registration.promotion_confirmed_at
        else null
      end,
      promotion_claim_id = v_claim_id,
      promotion_claim_expires_at = v_now + interval '10 minutes',
      promotion_attempt_count = registration.promotion_attempt_count + 1,
      promotion_last_attempt_at = v_now,
      promotion_last_error_code = null
    where registration.id = v_reserve.id;

    registration_id := v_reserve.id;
    claim_id := v_claim_id;
    promotion_token := v_token;
    promotion_token_expires_at := v_token_expires_at;
    token_reused := v_token_reused;

    return next;
  end loop;
end;
$function$;

comment on function public.prepare_event_reserve_promotions(uuid) is
  'Atomowo przygotowuje i claimuje techniczne tokeny promocji listy rezerwowej.';

revoke all on function public.prepare_event_reserve_promotions(uuid) from public;
revoke all on function public.prepare_event_reserve_promotions(uuid) from anon;
revoke all on function public.prepare_event_reserve_promotions(uuid) from authenticated;
grant execute on function public.prepare_event_reserve_promotions(uuid) to service_role;

create or replace function public.complete_event_reserve_promotion(
  p_registration_id uuid,
  p_claim_id uuid,
  p_success boolean,
  p_error_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_registration public.event_registrations%rowtype;
  v_error_code text;
begin
  if p_registration_id is null or p_claim_id is null then
    raise exception using
      errcode = '22023',
      message = 'Identyfikator zapisu i claimu są wymagane.';
  end if;

  if p_success is null then
    raise exception using
      errcode = '22023',
      message = 'Wynik wysyłki jest wymagany.';
  end if;

  if not p_success then
    v_error_code := lower(btrim(coalesce(p_error_code, '')));

    if v_error_code = '' then
      v_error_code := 'delivery_failed';
    end if;

    if char_length(v_error_code) > 100
       or v_error_code !~ '^[a-z][a-z0-9_]{0,99}$' then
      raise exception using
        errcode = '22023',
        message = 'Nieprawidłowy techniczny kod błędu.';
    end if;
  end if;

  select registration.*
  into v_registration
  from public.event_registrations as registration
  where registration.id = p_registration_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Nie znaleziono zapisu na szkolenie.';
  end if;

  if v_registration.promotion_claim_id is null then
    if p_success and v_registration.promotion_email_sent_at is not null then
      return pg_catalog.jsonb_build_object(
        'registration_id', v_registration.id,
        'changed', false,
        'success', true,
        'claim_cleared', true,
        'email_sent_recorded', true
      );
    end if;

    if not p_success then
      return pg_catalog.jsonb_build_object(
        'registration_id', v_registration.id,
        'changed', false,
        'success', false,
        'claim_cleared', true,
        'email_sent_recorded', v_registration.promotion_email_sent_at is not null
      );
    end if;

    raise exception using
      errcode = '55000',
      message = 'Claim promocji nie jest aktywny.';
  end if;

  if v_registration.promotion_claim_id <> p_claim_id then
    raise exception using
      errcode = '55000',
      message = 'Claim promocji należy do innego procesu.';
  end if;

  if p_success then
    update public.event_registrations as registration
    set
      promotion_email_sent_at = coalesce(
        registration.promotion_email_sent_at,
        pg_catalog.transaction_timestamp()
      ),
      promotion_claim_id = null,
      promotion_claim_expires_at = null,
      promotion_last_error_code = null
    where registration.id = v_registration.id;

    return pg_catalog.jsonb_build_object(
      'registration_id', v_registration.id,
      'changed', true,
      'success', true,
      'claim_cleared', true,
      'email_sent_recorded', true
    );
  end if;

  update public.event_registrations as registration
  set
    promotion_claim_id = null,
    promotion_claim_expires_at = null,
    promotion_last_error_code = v_error_code
  where registration.id = v_registration.id;

  return pg_catalog.jsonb_build_object(
    'registration_id', v_registration.id,
    'changed', true,
    'success', false,
    'claim_cleared', true,
    'email_sent_recorded', v_registration.promotion_email_sent_at is not null
  );
end;
$function$;

comment on function public.complete_event_reserve_promotion(uuid, uuid, boolean, text) is
  'Finalizuje zgodny claim promocji po technicznej próbie wysyłki wiadomości.';

revoke all on function public.complete_event_reserve_promotion(uuid, uuid, boolean, text) from public;
revoke all on function public.complete_event_reserve_promotion(uuid, uuid, boolean, text) from anon;
revoke all on function public.complete_event_reserve_promotion(uuid, uuid, boolean, text) from authenticated;
grant execute on function public.complete_event_reserve_promotion(uuid, uuid, boolean, text) to service_role;

create or replace function public.confirm_event_reserve_promotion(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_event_id uuid;
  v_registration public.event_registrations%rowtype;
  v_event public.events%rowtype;
  v_participants_count integer;
begin
  select registration.event_id
  into v_event_id
  from public.event_registrations as registration
  where registration.promotion_token = p_token;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', 'Link jest nieprawidłowy albo nie istnieje.'
    );
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
  where registration.promotion_token = p_token
    and registration.event_id = v_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', 'Link jest nieprawidłowy albo nie istnieje.'
    );
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

  select count(*)
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
    promotion_confirmed_at = pg_catalog.transaction_timestamp()
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

comment on function public.confirm_event_reserve_promotion(text) is
  'Potwierdza aktywny token promocji z blokadami w kolejności wydarzenie, następnie rejestracja.';

revoke all on function public.confirm_event_reserve_promotion(text) from public;
revoke all on function public.confirm_event_reserve_promotion(text) from anon;
revoke all on function public.confirm_event_reserve_promotion(text) from authenticated;
grant execute on function public.confirm_event_reserve_promotion(text) to service_role;
