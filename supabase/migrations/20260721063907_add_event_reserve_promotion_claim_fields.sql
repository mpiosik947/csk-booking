-- Add the minimal technical state required for atomic reserve-promotion claims.
-- Existing promotion tokens and historical registration data remain unchanged.

alter table public.event_registrations
  add column promotion_claim_id uuid null,
  add column promotion_claim_expires_at timestamptz null,
  add column promotion_attempt_count integer not null default 0,
  add column promotion_last_attempt_at timestamptz null,
  add column promotion_last_error_code text null;

alter table public.event_registrations
  add constraint event_registrations_promotion_claim_pair_check
    check (
      (
        promotion_claim_id is null
        and promotion_claim_expires_at is null
      )
      or
      (
        promotion_claim_id is not null
        and promotion_claim_expires_at is not null
      )
    ),
  add constraint event_registrations_promotion_claim_timing_check
    check (
      promotion_claim_id is null
      or (
        promotion_last_attempt_at is not null
        and promotion_claim_expires_at > promotion_last_attempt_at
      )
    ),
  add constraint event_registrations_promotion_attempt_count_check
    check (promotion_attempt_count >= 0),
  add constraint event_registrations_promotion_token_expiry_check
    check (
      promotion_token is not null
      or promotion_token_expires_at is null
    ),
  add constraint event_registrations_promotion_sent_token_check
    check (
      promotion_email_sent_at is null
      or promotion_token is not null
    ),
  add constraint event_registrations_promotion_confirmed_token_check
    check (
      promotion_confirmed_at is null
      or promotion_token is not null
    );

comment on column public.event_registrations.promotion_claim_id is
  'Identyfikator procesu, który atomowo przejął próbę wysyłki promocji.';

comment on column public.event_registrations.promotion_claim_expires_at is
  'Koniec dzierżawy claimu, po którym inny proces może bezpiecznie przejąć próbę.';

comment on column public.event_registrations.promotion_attempt_count is
  'Liczba prób przygotowania wysyłki promocji.';

comment on column public.event_registrations.promotion_last_attempt_at is
  'Moment ostatniego założenia claimu promocji.';

comment on column public.event_registrations.promotion_last_error_code is
  'Wyłącznie techniczny kod ostatniego błędu, bez danych osobowych i komunikatu dostawcy.';
