# PRODUCT-10G-C2 — local security review

Base: `f20f4bd9be028b2bca678248e63851d8d2c14802`.
Local implementation only. No staging, commit, push, deployment, production access or real email send.

## Scope and authority

- One forward-only migration: `20261016100000_add_event_registration_cancellation_delivery.sql`.
- SHA-256: `6D8CEC67755B423BC12A397AAC596906A5671B59B3D0A01BCC8EF86E24C2FA52`.
- New message type: `event_registration_cancellation`. Other delivery types retain their contracts.
- Authenticated prepare takes only registration UUID, derives registration/event/tenant/recipient,
  requires an active tenant membership and owner OR same-tenant admin/employee, cancelled status,
  non-anonymized resource, and tenant active/suspended. Profiles/global platform authority is not used.
- Prepare is authenticated-only; completion is service-role-only; purge is operator-only.
  Marker trigger has no application EXECUTE. No table grants or RLS widening.
- Receipt endpoint accepts only `{registrationId}` with verified Bearer auth; it cannot cancel,
  promote, accept, or change the tenant. Privileged recipient read follows successful DB claim.
- Existing business cancellation completes before receipt attempt. Thrown receipt failures are
  caught before the unchanged reserve-promotion code. Continuity invokes the receipt-only route
  after its existing cancellation RPC; no promotion is added to continuity.

## Marker and retention

- `cancellation_email_initialized_at` is immutable after first initialization; no caller input.
- Existing cancelled rows are backfilled at migration time under the migration's table lock,
  without creating any delivery. There is no reliable canonical cancellation timestamp to reuse.
- Prepare locks the registration, atomically sets the marker and inserts the delivery.
  A failing insert rolls back the marker; business cancellation is a prior transaction.
- Existing marker plus missing delivery returns `retired`, including after operator purge.
- Sent/failed deliveries are purged after 90 days; pending/sending are not silently discarded.
  Marker remains on the registration, including after account anonymization. Existing account
  anonymization removes recipient deliveries and prevents subsequent preparation.
- Suspended guard exception compares the complete OLD/NEW row and permits ONLY the initial
  marker change on an already-cancelled row. New business/promotion/acceptance guards are unchanged.

## Delivery semantics

- One logical `(message_type, record_id)` row, 5-minute lease, three lifetime attempts,
  and no blind retry beyond 23 hours from first attempt.
- Stable Resend key: `event-registration-cancellation/{tenant UUID}/{registration UUID}`.
- Provider success followed by completion failure returns `uncertain`; this is NOT exactly-once.
- No scheduler, automatic worker, event-wide fan-out, SMTP/domain/DNS or sender-address changes.
- Sender remains the existing StrzelajTu.pl operational sender. Content is an allowlist of
  tenant name, event title/date/time and cancellation statement. No operator identity or tokens.
- Authenticated CTA uses PLATFORM_BASE_URL and resolver-derived technical slug, never public slug/Host.

## Evidence

The local gate uses a schema-only local Docker bootstrap and replays all migrations in historical
order into a temporary database through 20261016100000. It does not copy users/data from the app DB.
Runner/log: `../10gc-preflight-evidence/c2-local-gate.mjs`, `c2-local-gate.log`.

- Focused C2 SQL: 44 assertions.
- Actual pre-C2 historical cancelled fixture: marker set, delivery count zero.
- Eight real concurrent prepare connections: one ready, seven in_progress, one delivery.
- Existing acceptance concurrency: one accepted transition and one receipt claimant.
- Full DB: 2259/2259 assertions, 70 files, zero failures. Post-test schema/data diff = 0;
  fixture cleanup = 0 and temporary database cleanup = 0.
- SECURITY DEFINER: baseline 110, target 111. Exact ACL inventory: 179 functions;
  PUBLIC EXECUTE absent and grants match the explicit inventory.
- Existing regression tests with hardcoded inventory counts updated precisely from 110 to 111;
  function ACL list adds exactly four functions, and delivery-type allowlist adds exactly one type.
  No historical migration was edited; no behavior assertion was removed.
- Targeted Node: 14/14. Full Node: 886 regular + 79 react-server = 965/965.
- Playwright: 3/3 local HTTP checks (anonymous denial, forged authority fields rejected before
  auth/provider access, GET cannot send). No real authenticated email/browser delivery test.
- TypeScript: PASS. Production Webpack build: PASS. Changed TS/JS ESLint: PASS.
- Schema check means pre/post-test public schema equality on the fresh replay, NOT production drift audit.
- Existing Next middleware deprecation and Node module-type warnings remain; not introduced here.

## Synthetic content previews (no send)

CSK subject: StrzelajTu.pl / CSK — Centrum Szkolenia Krutla — Zapis na wydarzenie anulowany

StrzelajTu.pl / CSK — Centrum Szkolenia Krutla
Twój udział w wydarzeniu został anulowany.
Wydarzenie: Szkolenie testowe A; Data: 2026-11-30; Godzina: 10:00–11:00.
Obiekt: CSK — Centrum Szkolenia Krutla.
CTA: https://strzelajtu.pl/t/csk/my-events

Tenant B subject: StrzelajTu.pl / Synthetic Range B — Zapis na wydarzenie anulowany

StrzelajTu.pl / Synthetic Range B
Twój udział w wydarzeniu został anulowany.
Wydarzenie: Szkolenie testowe B; Data: 2026-11-30; Godzina: 10:00–11:00.
Obiekt: Synthetic Range B.
CTA: https://strzelajtu.pl/t/synthetic-range-b/my-events

Admin/employee cancellation uses exactly the same neutral wording; no operator name/email/reason.
Event-wide cancellation email remains MISSING / C2B.

## Next gate

Security/clean preflight must review this exact local scope and live production migration state
read-only before any separate staging/deployment authorization. Production readiness is NO.
