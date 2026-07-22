-- Add durable, privacy-safe delivery state for confirmation emails.
-- API integration and user/IP rate limiting are intentionally handled later.

create table public.email_deliveries (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  message_type text not null,
  record_id uuid not null,
  recipient_user_id uuid not null
    references auth.users (id) on delete cascade,
  sent_at timestamptz null,
  provider_message_id text null,
  claim_id uuid null,
  claim_expires_at timestamptz null,
  attempt_count integer not null default 0,
  attempt_window_started_at timestamptz null,
  last_attempt_at timestamptz null,
  last_error_code text null,
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null default pg_catalog.transaction_timestamp(),
  constraint email_deliveries_message_record_key
    unique (message_type, record_id),
  constraint email_deliveries_message_type_check
    check (
      message_type in (
        'event_registration_confirmation',
        'reservation_confirmation'
      )
    ),
  constraint email_deliveries_attempt_count_check
    check (attempt_count >= 0),
  constraint email_deliveries_claim_pair_check
    check (
      (
        claim_id is null
        and claim_expires_at is null
      )
      or
      (
        claim_id is not null
        and claim_expires_at is not null
      )
    ),
  constraint email_deliveries_provider_message_id_length_check
    check (
      provider_message_id is null
      or pg_catalog.char_length(provider_message_id) <= 256
    ),
  constraint email_deliveries_last_error_code_length_check
    check (
      last_error_code is null
      or pg_catalog.char_length(last_error_code) <= 128
    )
);

comment on table public.email_deliveries is
  'Technical delivery state for idempotent confirmation emails; contains no message content or recipient PII.';

comment on column public.email_deliveries.message_type is
  'Closed technical category of the confirmation email.';

comment on column public.email_deliveries.record_id is
  'Identifier of the source reservation or event registration.';

comment on column public.email_deliveries.recipient_user_id is
  'Authenticated owner of the source record; no recipient address is stored.';

comment on column public.email_deliveries.claim_id is
  'Opaque identifier of the currently leased delivery attempt.';

comment on column public.email_deliveries.last_error_code is
  'Bounded technical error code without provider message or personal data.';

alter table public.email_deliveries enable row level security;

revoke all on table public.email_deliveries from public;
revoke all on table public.email_deliveries from anon;
revoke all on table public.email_deliveries from authenticated;

create or replace function public.prepare_confirmation_email(
  p_message_type text,
  p_record_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_message_type text := pg_catalog.lower(pg_catalog.btrim(p_message_type));
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_source_user_id uuid;
  v_source_status text;
  v_delivery public.email_deliveries%rowtype;
  v_attempt_count integer;
  v_attempt_window_started_at timestamptz;
  v_claim_id uuid;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'unauthorized'
    );
  end if;

  if p_record_id is null
     or v_message_type is null
     or v_message_type not in (
       'event_registration_confirmation',
       'reservation_confirmation'
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'invalid_status'
    );
  end if;

  if v_message_type = 'event_registration_confirmation' then
    select
      registration.user_id,
      pg_catalog.lower(pg_catalog.btrim(registration.registration_status))
    into
      v_source_user_id,
      v_source_status
    from public.event_registrations as registration
    where registration.id = p_record_id
      and registration.user_id = v_actor_user_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'not_found'
      );
    end if;

    if v_source_status not in ('registered', 'reserve') then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'invalid_status'
      );
    end if;
  else
    select
      reservation.user_id,
      pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
    into
      v_source_user_id,
      v_source_status
    from public.reservations as reservation
    where reservation.id = p_record_id
      and reservation.user_id = v_actor_user_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'not_found'
      );
    end if;

    if v_source_status <> 'confirmed' then
      return pg_catalog.jsonb_build_object(
        'ok', false,
        'changed', false,
        'code', 'invalid_status'
      );
    end if;
  end if;

  insert into public.email_deliveries (
    message_type,
    record_id,
    recipient_user_id
  )
  values (
    v_message_type,
    p_record_id,
    v_source_user_id
  )
  on conflict (message_type, record_id) do nothing;

  select delivery.*
  into v_delivery
  from public.email_deliveries as delivery
  where delivery.message_type = v_message_type
    and delivery.record_id = p_record_id
  for update;

  if not found
     or v_delivery.recipient_user_id is distinct from v_actor_user_id then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'not_found'
    );
  end if;

  if v_delivery.sent_at is not null then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'already_sent'
    );
  end if;

  if v_delivery.claim_id is not null
     and v_delivery.claim_expires_at > v_now then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'in_progress'
    );
  end if;

  v_attempt_count := v_delivery.attempt_count;
  v_attempt_window_started_at := v_delivery.attempt_window_started_at;

  if v_attempt_window_started_at is null
     or v_attempt_window_started_at <= v_now - interval '24 hours' then
    v_attempt_count := 0;
    v_attempt_window_started_at := v_now;
  end if;

  if v_attempt_count >= 3 then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'attempt_limit_reached'
    );
  end if;

  v_claim_id := pg_catalog.gen_random_uuid();
  v_attempt_count := v_attempt_count + 1;

  update public.email_deliveries as delivery
  set
    claim_id = v_claim_id,
    claim_expires_at = v_now + interval '5 minutes',
    attempt_count = v_attempt_count,
    attempt_window_started_at = v_attempt_window_started_at,
    last_attempt_at = v_now,
    last_error_code = null,
    updated_at = v_now
  where delivery.id = v_delivery.id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'ready',
    'delivery_id', v_delivery.id,
    'claim_id', v_claim_id,
    'claim_expires_at', v_now + interval '5 minutes',
    'attempt_count', v_attempt_count,
    'idempotency_key',
      'confirmation/' || v_message_type || '/' || v_delivery.id::text
  );
end;
$function$;

alter function public.prepare_confirmation_email(text, uuid)
  owner to postgres;

comment on function public.prepare_confirmation_email(text, uuid) is
  'Validates ownership and status, then atomically leases one bounded confirmation-email attempt.';

revoke all on function public.prepare_confirmation_email(text, uuid)
  from public;
revoke all on function public.prepare_confirmation_email(text, uuid)
  from anon;
revoke all on function public.prepare_confirmation_email(text, uuid)
  from authenticated;
revoke all on function public.prepare_confirmation_email(text, uuid)
  from service_role;
grant execute on function public.prepare_confirmation_email(text, uuid)
  to authenticated;

create or replace function public.complete_confirmation_email(
  p_claim_id uuid,
  p_success boolean,
  p_provider_message_id text default null,
  p_error_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_delivery public.email_deliveries%rowtype;
  v_provider_message_id text;
  v_error_code text;
begin
  if p_claim_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'claim_not_found'
    );
  end if;

  select delivery.*
  into v_delivery
  from public.email_deliveries as delivery
  where delivery.claim_id = p_claim_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'claim_not_found'
    );
  end if;

  if v_delivery.sent_at is not null then
    update public.email_deliveries as delivery
    set
      claim_id = null,
      claim_expires_at = null,
      updated_at = v_now
    where delivery.id = v_delivery.id;

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'sent'
    );
  end if;

  if p_success is true then
    v_provider_message_id := nullif(
      pg_catalog.left(pg_catalog.btrim(p_provider_message_id), 256),
      ''
    );

    update public.email_deliveries as delivery
    set
      sent_at = coalesce(delivery.sent_at, v_now),
      provider_message_id = coalesce(
        delivery.provider_message_id,
        v_provider_message_id
      ),
      claim_id = null,
      claim_expires_at = null,
      last_error_code = null,
      updated_at = v_now
    where delivery.id = v_delivery.id;

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', true,
      'code', 'sent'
    );
  end if;

  v_error_code := pg_catalog.lower(pg_catalog.btrim(p_error_code));
  v_error_code := pg_catalog.regexp_replace(
    coalesce(v_error_code, 'delivery_failed'),
    '[^a-z0-9_.:-]+',
    '_',
    'g'
  );
  v_error_code := pg_catalog.left(
    coalesce(nullif(v_error_code, ''), 'delivery_failed'),
    128
  );

  update public.email_deliveries as delivery
  set
    claim_id = null,
    claim_expires_at = null,
    last_error_code = v_error_code,
    updated_at = v_now
  where delivery.id = v_delivery.id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'failed'
  );
end;
$function$;

alter function public.complete_confirmation_email(uuid, boolean, text, text)
  owner to postgres;

comment on function public.complete_confirmation_email(uuid, boolean, text, text) is
  'Completes only the current opaque confirmation-email claim and stores bounded technical delivery state.';

revoke all on function public.complete_confirmation_email(uuid, boolean, text, text)
  from public;
revoke all on function public.complete_confirmation_email(uuid, boolean, text, text)
  from anon;
revoke all on function public.complete_confirmation_email(uuid, boolean, text, text)
  from authenticated;
revoke all on function public.complete_confirmation_email(uuid, boolean, text, text)
  from service_role;
grant execute on function public.complete_confirmation_email(uuid, boolean, text, text)
  to service_role;
