# PRODUCT-10G-C — SECURITY REVIEW HANDOFF

Local implementation only. Base HEAD: `3545045e389699b49e0d8341be926a15a22bf2f7`.
No staging, commit, push, deployment, production write, provider send, scheduler or worker.

## Scope and migration

`20261015100000_add_event_reserve_acceptance_delivery.sql`

SHA-256: `3C4AEAC932641B275F914327454A166E9EBC6D00B44CF8A6DF25D83D03DB49D7`

Forward-only: no deployed migration edited. New delivery category:
`event_reserve_acceptance_confirmation`. Existing categories keep their state contract
(`delivery_state` is NULL for them). No new table grants or RLS policies.

Three new functions: service-only claim and completion, postgres-only retention purge.
Claim is SECURITY DEFINER, postgres-owned, fixed search_path, exact registration UUID
input. This narrowly reads tenant lifecycle without granting service_role direct SELECT
on tenants. Completion and purge are SECURITY INVOKER. SECURITY DEFINER: 109 → 110.
Function inventory: 172 → 175; service EXECUTE allowlist: 7 → 9.
PUBLIC/anon/authenticated cannot execute the new functions. Platform Admin is not an
exception. Operator postgres retains administrative database privileges.

35 existing SQL regression files changed only for current inventory: 33 files update
the exact definer count, one updates exact function/ACL inventory, one updates the
closed message-type allowlist. No security assertion was removed.

## Atomic business/delivery boundary

Existing owner authentication, active membership and resource binding remain before
the original acceptance core. The existing event/registration locks and lifecycle
guards remain unchanged. The wrapper inserts the pending receipt in the same RPC
transaction as reserve → registered. Receipt insert failure rolls back both.
Duplicate acceptance does not create another logical receipt.

After commit, the route invokes the server-only delivery entrypoint with the returned
registration UUID. Caller tenant/user/email/slug fields are rejected by the existing
strict token-only request parser. Claim derives tenant and recipient user from the
joined registration/event; the server reloads and matches registration, tenant and
user before deriving recipient email. The browser never receives those fields.

Email failure cannot undo the accepted seat. UI reports that the seat remains accepted
and email sending could not be confirmed; it does not ask the user to accept again.

## Delivery/retry contract

States: pending → sending → sent/failed. Claim is row-locked, lease 5 minutes,
maximum 3 lifetime attempts, maximum retry window 23 hours from first claim.
Expired lease can be reclaimed, but only one concurrent claimant wins. Completion
requires the current, unexpired claim. Sent receipts cannot be resent by this contract.

Stable provider key: `event-reserve-acceptance/{tenantUUID}/{registrationUUID}`.
The rotating claim ID is never part of this key. Invitation key uses tenant UUID,
registration UUID and SHA-256 of the stable logical invitation token; never raw token,
timestamp or retry UUID. Invitation body now displays the actual stored expiry.

Resend deduplicates for 24 hours and requires an identical payload for the same key:
[official provider contract](https://resend.com/changelog/idempotency-keys).
The 23-hour acceptance retry window leaves a safety margin. If source/template/sender
data changes between attempts, a provider idempotency conflict must fail safely;
do not rotate the key to bypass it. No email payload/recipient snapshot is persisted.

`sent` means provider acceptance plus committed sent marker, NOT inbox delivery.
Provider acceptance + failed/expired marker is UNCERTAIN, recoverable within the
bounded window using the same key. A network failure can also be uncertain despite
the `failed` state; its technical error code says `delivery_failed_or_uncertain`.
After exhaustion/window expiry, operator investigation is required. No exactly-once
or guaranteed eventual-delivery claim is made.

Retry entrypoint: `retryEventAcceptanceEmail(registrationId)` in the server-only module.
It must be invoked explicitly in a controlled server/operator context with the existing
server credentials. No browser retry RPC, public retry route, cron or worker was added.
The function performs one attempt, not an automatic retry loop. Pending rows can remain
pending until an operator acts; this is an intentional consequence of no worker.

## Privacy, retention and lifecycle

Delivery rows contain technical IDs/state/counts/timestamps/provider ID and a bounded
technical error code only. No email address/body, promotion/auth token or private metadata.
Sent/failed rows older than 90 days are eligible for the postgres-only purge function.
Running retention is an explicit operator responsibility; nothing schedules it yet.
Pending rows are not silently purged. Account anonymization deletes this new category
through the existing recipient-user cleanup contract (tested with a real new-type row).

Suspended promotion and reserve acceptance remain DENY. Sending an existing accepted
receipt on a suspended tenant is allowed as communication about an existing obligation;
it creates no new registration, seat or entitlement. Unknown/anonymized/cancelled
resources cannot be claimed for a new attempt.

## Event email inventory

| Flow | Result |
|---|---|
| Registration confirmation | Existing tenant-aware foundation preserved |
| Waitlist registration confirmation | Existing status-dependent template preserved |
| Promotion invitation | Tenant-aware; stable provider key; actual expiry; marker checked |
| Accepted reserve seat receipt | Durable atomic pending state and bounded server retry |
| Event cancellation email | MISSING; not implemented without a separate scoped decision |
| Admin cancellation/update notifications | No existing email flow found; not invented |

Resource-derived tenant subject/header and canonical platform links remain. Generic
event email runtime contains no hardcoded `/t/csk/my-events`. Synthetic Tenant B
renders without CSK/Krutla fallback. Authenticated history CTA is tenant-scoped;
invitation CTA uses the existing canonical token confirmation route.

Eight synthetic A/B previews (excluded from the clean checkpoint; retained in the source worktree) render actual
HTML/text template literals and subjects: registration, waitlist, invitation, acceptance.
They contain only synthetic data; no real provider send was performed.

## Verification

Local isolated history-preserving replay: 131 migrations through 20261015100000.
The existing local application database was not migrated/reset. Scratch database is
created on the explicitly checked local Docker port 54322 and removed after testing.

| Check | Evidence |
|---|---|
| Focused SQL | 53/53 PASS |
| Full DB | 2215 assertions, 69 files, 0 failures |
| Concurrent acceptance | 8 actual DB connections: 1 confirmed, 7 not_reserve, 1 pending delivery |
| Concurrent claim | 8 actual DB connections: 1 ready, 7 in_progress |
| Targeted Node | 39/39 PASS |
| Full Node | 951/951 PASS (856 ordinary + 95 server-condition) |
| TypeScript | PASS |
| Webpack production build | PASS |
| ESLint changed JS/TS | PASS, 0 errors/warnings |
| git diff --check | PASS |
| Post-test public schema diff | 0 |
| Post-test public data fingerprint diff | 0 across all public tables |
| Fixture/scratch cleanup | 0 |

Playwright: 2/2 PASS against the built candidate (read-only confirmation GET,
anonymous acceptance denied; no real email). Live mailbox/device tests not run.

LOCAL IMPLEMENTATION RESULT: PASS — historical implementation gate; not deployment approval.
PRODUCTION PREFLIGHT: PASS. Production deployment still requires separate authorization.
Open operational items: explicitly operated retry/retention (no scheduler), manual
resolution of exhausted/uncertain provider outcomes, separately scoped cancellation
email proposal if desired, future approved live-email verification.

## Fresh clean preflight — PASS after approved narrow continuity

Fresh origin/main and candidate base: `3545045e389699b49e0d8341be926a15a22bf2f7`, divergence 0/0.
Candidate branch: `review/10gc-clean-preflight`. Raw files 50; clean files 48;
generated HTML preview and temporary diagnostic runner excluded. No staging.

User approved retry of an existing acceptance receipt after suspension. New delivery
insertion requires an active tenant (FOR SHARE lifecycle serialization), a registered
registration and recorded promotion confirmation. Acceptance and pending delivery
remain atomic. Receipt identity is immutable; retry only claims an existing row and
requires registration_status = registered. Suspended new promotion, acceptance and
fresh receipt creation remain denied. Dormant/disabled tenants remain denied.

Focused tests cover active and suspended pending/failed retry, lifecycle denials,
cross-tenant denial, no duplicate receipt/status mutation and bounded attempts.
One failed retry consumes one of the existing three attempts; the limit was not raised.

Fresh production read-only snapshot: 130 migration versions through 20261014100000
match canonical replay. All 172 function definitions (normalized line endings),
function ACL/security modes, 22 RLS policies and table ACL/RLS settings match replay.
SECURITY DEFINER production = 109; local target = 110. PUBLIC EXECUTE = 0.
Exactly one active production tenant. No production fixture or mutation was performed.
Dry-run lists exactly 20261015100000_add_event_reserve_acceptance_delivery.sql.
No applied migration edits. Post-test local schema/data fingerprint diff = 0.

Evidence: sibling 10gc-preflight-evidence directory (manifest, local gate log,
baseline/production catalogs, isolated browser tests). No staging, commit, push,
deployment, production write or provider send. Retry and retention remain manual;
provider success followed by marker failure remains uncertain/recoverable, not exactly-once.
