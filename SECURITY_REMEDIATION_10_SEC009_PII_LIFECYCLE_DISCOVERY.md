# CSK Booking — SECURITY REMEDIATION 10 / DISCOVERY
# SEC-009 — PII retention, anonymization and user data export

**SEC-ID:** SEC-009

**Original severity:** MEDIUM

**Analysis date:** 2026-09-04
**Repository baseline:** `main` at `d5668d0 — docs: record SEC-010 production verification`

## Scope and method

This is a repository-only design review. It examined the current migrations, the
baseline schema, account and administration UI, reservation and event flows,
check-in, e-mail delivery state, audit writers, and the existing security
reports. No production query, DDL, DML, migration, retention operation, export,
anonymization, or account deletion was performed.

## Current state

SEC-009 remains confirmed. The application has strong point controls around
ownership-scoped reads, trusted writers, append-only client-facing audit logs,
and time-bounded usability of check-in and promotion tokens. Those controls do
not form a data lifecycle:

- there is no self-service account deletion or deletion-request workflow;
- there is no owner-scoped complete personal-data export;
- there is no general anonymization operation for historical snapshots;
- there is no policy-backed scheduled cleanup for reservations, event
  registrations, audits, e-mail delivery state, or stale rate-limit rows;
- there are no approved retention periods in repository configuration;
- cancellation and expiry change operational usability, but do not remove the
  underlying record or its PII;
- the existing administrator reservation CSV is an operational bulk export of
  reservation data, not a user-owned data portability export.

The privacy page describes retention in general terms and lists access,
deletion, and portability rights, but no technical workflow currently realizes
them end to end.

## PII inventory

`Referenced by FK` describes relevant public-schema dependencies visible in
the current repository schema. Supabase-managed Auth internals have additional
provider-managed dependencies outside the public schema.

| TABLE | FIELD | PII CATEGORY | SOURCE | PURPOSE | USER-CONTROLLED? | CAN BE ANONYMIZED? | CAN BE DELETED? | REFERENCED BY FK? | NEEDED FOR HISTORY/AUDIT? |
|---|---|---|---|---|---|---|---|---|---|
| `auth.users` | `id` | account identifier | Supabase Auth | identity and ownership root | No | Pseudonymizable in business records, not in-place in Auth | Yes, through trusted Admin/Auth flow | Yes: `profiles.user_id` CASCADE, `email_deliveries.recipient_user_id` CASCADE, `reservations.user_id` RESTRICT | Identifier may need a non-reversible historical substitute |
| `auth.users` | `email`, optional phone | contact | registration/Auth | login, confirmation, recovery | Yes, validated by Auth | Not normally in-place; delete account after business handling | Yes with Auth account | Duplicated in profile/snapshots, not protected by one shared FK | No after approved account closure, subject to legal decision |
| `auth.users` | encrypted credential, identities, sessions, confirmation/recovery state | authentication secret/metadata | Supabase Auth | authentication and account recovery | Indirectly | No; revoke/delete through Auth | Provider-managed deletion/revocation | Managed by Supabase Auth | No business-history need |
| `auth.users` | `raw_user_meta_data`: first/last/full name, phone | identity/contact duplicate | registration form | initial profile creation and client display fallback | Yes | Yes by update before deletion, or removed with Auth user | Yes with Auth account | Copied to `profiles`; not automatically synchronized in every profile edit | No after closure |
| `auth.users` | accepted terms/privacy flags and timestamps | consent/acceptance evidence | registration form | evidence of accepted documents | Yes as an action, not arbitrary value in normal UI | Pseudonymize subject while retaining event if policy requires | Yes only if evidence need is resolved | No public FK | Requires business/legal decision |
| `profiles` | `id`, `user_id` | identifiers | trigger/setup and Auth user | link account to business profile | No | Replace linkage only through controlled lifecycle design | Profile is deleted by Auth-user CASCADE if deletion is not blocked | `permissions_verified_by` references `profiles.id` with SET NULL | A pseudonymous linkage may be needed for history |
| `profiles` | `first_name`, `last_name`, `full_name` | identity | user/admin | account and operational identification | Yes; admin correction exists | Yes | Yes with profile | Copied into reservation/event/audit snapshots | Not required in clear text after approved anonymization |
| `profiles` | `email`, `phone` | contact | Auth/user/admin | contact and notifications | Yes | Yes | Yes with profile | Copied into reservation/event snapshots | Not required in clear text after approved anonymization |
| `profiles` | `postal_code`, `city`, `street`, `house_number`, `apartment_number` | address | user/admin | account/contact record | Yes | Yes | Yes with profile | No downstream FK | Purpose and retention require owner decision |
| `profiles` | `weapon_permit_number`, `weapon_permit_type`, `weapon_permit_issuer`, `range_officer_number`, `instructor_number` | permit/qualification identifiers | legacy/user/admin data | eligibility verification | Yes/administratively corrected | Yes | Yes with profile | No downstream FK | Retention requires explicit business/legal decision |
| `profiles` | permission and qualification booleans | declarations/qualifications | user | declared eligibility | Yes | Yes, by clearing | Yes with profile | No downstream FK | Usually no clear-text history need after closure |
| `profiles` | verification status and timestamps | administrative/eligibility history | admin/employee workflow | operational verification | Partly; result is staff-controlled | Yes, while retaining neutral state if needed | Yes with profile | No except verifier reference described below | May require limited operational history |
| `profiles` | `verified_by`, `unverified_by`, `permissions_verified_by` | staff/user identifiers | verification workflow | attribution of verification | No | Yes/pseudonymize | Yes with target profile | Only `permissions_verified_by` has an FK and becomes NULL when verifier profile is deleted; the other identifiers can persist | Requires audit/operational decision |
| `profiles` | `admin_note`, `verification_note`, `permissions_verification_note` | free-text administrative PII | admin/employee | verification and operational notes | No | Yes; safest target is clear/delete or strictly allowlisted replacement | Yes with profile | No downstream FK | Requires business/legal decision; free text may contain incidental PII |
| `profiles` | `role` | authorization/occupation-like metadata | admin workflow | access control | No | Reset before deletion if account remains | Yes with profile | Consulted by RPC authorization | Security history belongs in audit, not necessarily live profile |
| `profiles` | `created_at`, `updated_at` | account activity metadata | database | lifecycle and diagnostics | No | Usually keep only if record retained | Yes with profile | No downstream FK | Limited historical usefulness |
| `reservations` | `id`, `user_id`, `creation_request_id` | identifiers/idempotency metadata | DB/Auth/client request | ownership and atomic creation | Partly (`creation_request_id`) | Yes: replace subject linkage with a non-reversible lifecycle value only after schema design | Record can be deleted, but deleting Auth user is currently blocked by `user_id` RESTRICT | `user_id` references `auth.users` RESTRICT; audit/email `target_id`/`record_id` are not FKs | Reservation ID and idempotency may be needed operationally; user identity need is a decision |
| `reservations` | `customer_name`, `customer_email`, `customer_phone` | identity/contact snapshots | profile at booking time | servicing and historical contact | Indirectly user-controlled | Yes; columns are NOT NULL, so anonymization needs approved non-PII replacements or a schema change | Yes with reservation | No downstream FK | Operational record may remain without clear-text contact |
| `reservations` | date, start/end, duration, lane and lane-name snapshot, shooters count | behavioral/operational history | user selection and DB snapshot | fulfilment, occupancy, reports | Partly | Keep as non-identifying history after unlinking identity | Yes with reservation | Lane/pricing FKs use RESTRICT | Usually useful for operational/statistical history |
| `reservations` | price, total price, price-per-hour, pricing label/day group, currency, payment status | financial/transaction-related metadata | DB pricing and staff operation | price evidence and payment operations | Partly | Keep without direct identity when policy allows | Yes with reservation | Pricing-rule FK uses RESTRICT | Accounting/legal input required; no invoice/payment-provider transaction fields were found |
| `reservations` | reservation and attendance status, `checked_in_at`, `completed_at` | participation/attendance history | trusted RPC | operational visit history | No | Keep only as anonymized operational history after cutoff | Yes with reservation | Audit records refer only by loose UUID | May be required for disputes/security for an approved period |
| `reservations` | `reservation_note`, `admin_note` | free-text PII | user / staff | booking request and staff operations | Yes / No | Yes; clear rather than transform unless policy requires content | Yes with reservation | No downstream FK | Requires explicit handling; not needed for aggregate statistics |
| `reservations` | `check_in_token` | bearer technical secret | database | check-in lookup | No | Rotate to an unlinkable tombstone or change schema to permit removal; currently UUID NOT NULL and unique | Deleted with reservation | No downstream FK | No history need after the approved window; SEC-005 limits usability but token remains stored |
| `reservations` | `created_at` | activity metadata | database | chronology | No | Keep with anonymized record if required | Yes with reservation | No downstream FK | Often useful with historical reservation |
| `event_registrations` | `id`, `user_id`, `event_id` | identifiers/participation link | Auth/RPC | ownership and event participation | No | `user_id` is nullable and can be cleared through a trusted workflow | Yes | `event_id` CASCADE to `events`; **no FK from `user_id` to `auth.users`** | Registration/event link may be retained in anonymized form |
| `event_registrations` | `customer_name`, `customer_email`, `customer_phone` | identity/contact snapshots | profile at registration | event operations and messaging | Indirectly user-controlled | Yes; NOT NULL fields require non-PII replacements or schema change | Yes with registration | No downstream FK | Clear text is not needed after approved lifecycle cutoff |
| `event_registrations` | registration/payment status and `created_at` | participation/financial metadata | user/trusted RPC/DB | event capacity, payment and history | Partly | Keep as anonymized event statistics if approved | Yes with registration | Audit records use loose IDs only | Operational/accounting decision required |
| `event_registrations` | promotion token, expiry, sent/confirmed timestamps | bearer secret and workflow metadata | trusted promotion RPC | reserve-list confirmation | No | Clear/rotate after lifecycle window; current constraints require a token when sent/confirmed timestamps exist | Yes with registration | Unique partial index on token | Token itself has no historical value; neutral outcome timestamps may have value |
| `event_registrations` | promotion claim ID/expiry, attempt timestamps/count, last error code | technical delivery state | trusted RPC | idempotency/retry control | No | Yes after workflow and diagnostic window | Yes with registration | No downstream FK | Short operational/diagnostic value only |
| `audit_logs` | `actor_user_id`, `actor_name`, `actor_role` | actor identity and authorization history | trusted RPC | security/operational attribution | No | Actor ID/name can be pseudonymized under an approved audit policy | Technically yes, but deletion weakens SEC-007 evidence | No FK to Auth/profile | Yes; preserve event integrity and chronology, not necessarily clear-text identity forever |
| `audit_logs` | `target_id`, `target_name`, `target_type` | target identifier/name | trusted RPC | identify affected business object | No | Yes where target is a person/profile; generic target names can remain | Technically yes | No FK | Structural audit link is valuable; direct PII may be replaceable |
| `audit_logs` | `action`, `created_at`, `details` | security/operational metadata; possible indirect PII | trusted RPC | immutable audit evidence | No | Allowlist and pseudonymize subject identifiers; keep action/time | Technically yes but not recommended without policy | No FK | Yes. Details contain reservation/event/profile UUIDs, statuses, times and before/after configuration; no blanket delete should be used |
| `email_deliveries` | `record_id`, `recipient_user_id` | pseudonymous identifiers | confirmation workflow | ownership, idempotency | No | Yes/delete after delivery retention window | Yes; Auth deletion CASCADE applies through `recipient_user_id` | Recipient references Auth CASCADE; `record_id` has no FK | Short operational history may be sufficient |
| `email_deliveries` | provider message ID, claim ID/expiry, attempt timestamps/count, error code, sent/created/updated time | provider/technical metadata | provider and trusted RPC | delivery idempotency and diagnostics | No | Yes | Yes | No downstream FK | Requires a bounded operational retention decision; full body/address is not stored |
| `confirmation_email_rate_limits` | user UUID in `scope_key` | pseudonymous identifier | rate-limit RPC | user abuse prevention | No | Delete exact scope after lifecycle/abuse window | Yes | Stored as text, no FK | Short security value only |
| `confirmation_email_rate_limits` | HMAC-SHA256 IP digest in `scope_key`, request timestamps | pseudonymous network telemetry | API rate limiting | IP abuse prevention | No | Delete stale timestamps/rows | Yes | No FK | Short security value only; not a raw IP |
| `events` | title, description, location | admin-authored content; possible incidental PII | admin/employee | event publication | Staff-controlled | Content-specific review/anonymization | Yes with event, cascading registrations and event lanes | Referenced by event registrations/event lanes CASCADE | Usually business content, but free text can accidentally contain PII |
| `lane_blocks` | reason | staff-authored free text; possible incidental PII | admin/employee | explain operational block | Staff-controlled | Clear/rewrite if it contains person data | Yes | Lane FK RESTRICT | Usually not personal data, but free text needs minimization guidance |

Tables such as lane definitions, duration/pricing rules, event-lane links, and
configuration versions contain business configuration rather than intended
user PII. They may still appear in audit relationships, but are not account
lifecycle targets.

## Data flow

### User account and profile

```text
CREATE
register form -> Supabase Auth user + raw user metadata -> public profile

READ
owner account/dashboard + admin-only user management + scoped staff profile readers

UPDATE
owner profile fields/Auth metadata + controlled staff/admin identity,
verification, role and note writers

HISTORICAL USE
profile is the live source; names/contact are copied into reservation and event
registration snapshots; actor/target display names can be copied into audit logs

DELETE / ANONYMIZE TODAY
no complete workflow; direct Auth deletion may be blocked by reservation FK and
would not sanitize independent snapshots or loose audit identifiers
```

### Reservation

```text
CREATE
authenticated create_reservation_v2 -> validated profile/contact -> immutable
booking/pricing/contact snapshots + check-in token -> trusted audit

READ
owner get_my_reservations_v2; admin/employee operational pages and reports;
scoped staff readers; minimal public check-in status by bearer token

UPDATE
controlled cancellation, attendance, payment and admin-note RPCs

HISTORICAL USE
calendar/reports, occupancy, attendance, cancellation and payment state,
pricing/lane snapshots, trusted audit

DELETE / ANONYMIZE TODAY
no lifecycle operation; cancellation retains record, contact snapshots, notes
and token; Auth deletion is blocked by reservations.user_id RESTRICT
```

### Event registration

```text
CREATE
authenticated register_for_event -> profile/contact snapshots -> event capacity
state and optional confirmation mail

READ
owner list + admin/employee event operations; current RLS rules govern staff
scope; no account-lifecycle reader/export exists

UPDATE
controlled cancellation, approval, reserve promotion confirmation and payment RPCs

HISTORICAL USE
event attendance/capacity/payment, promotion delivery state and trusted audit

DELETE / ANONYMIZE TODAY
no lifecycle operation; event deletion cascades registrations, but Auth deletion
does not because event_registrations.user_id has no Auth FK
```

### Check-in

```text
CREATE
reservation receives a random UUID check-in token

READ
anonymous minimal status RPC; full operational DTO only for authenticated
admin/employee

UPDATE
trusted attendance RPC, idempotent state transition and audit

HISTORICAL USE
attendance status and DB timestamps remain on reservation and in audit

DELETE / ANONYMIZE TODAY
token usability is limited to start-24h through end+2h and cancelled records are
unusable, but the token column remains populated indefinitely with the reservation
```

### Cancellation

```text
CREATE/UPDATE
owner or staff controlled RPC changes status and creates a trusted audit entry

READ/HISTORY
cancelled reservation/registration and its contact snapshot remain queryable to
authorized operations according to current RLS/read contracts

DELETE / ANONYMIZE TODAY
no automatic cleanup; cancellation is a state transition, not erasure
```

### Audit

```text
CREATE
trusted SECURITY DEFINER business RPCs only; clients have no direct mutation ACL

READ
admin-only SELECT policy

UPDATE
no application UPDATE/DELETE/TRUNCATE path

HISTORICAL USE
actor, action, target, time and allowlisted operational details

DELETE / ANONYMIZE TODAY
no lifecycle; append-only integrity is protected, but identity retention is not
time-bounded
```

### E-mail delivery and rate limiting

```text
CREATE/UPDATE
confirmation claims, provider message ID, attempt state and HMAC/user rate-limit
timestamps; full message body and recipient address are not stored in
email_deliveries

READ/HISTORY
trusted delivery coordination and diagnostics

DELETE / ANONYMIZE TODAY
no scheduled retention; active sliding-window arrays are pruned during subsequent
rate-limit calls, but an idle stale row can remain indefinitely
```

## Current account deletion behavior

There is no account deletion control in `/account`, no administrator deletion
operation in `/admin/users`, and no repository RPC/API that coordinates business
anonymization with Supabase Auth deletion.

If an Auth user were deleted directly today, the public-schema result would
depend on existing data:

| Situation | Current result |
|---|---|
| User has at least one reservation | `reservations.user_id -> auth.users.id ON DELETE RESTRICT` blocks Auth-user deletion. The attempted delete should fail atomically; profile and e-mail delivery cascades do not complete. |
| User has no reservation | Profile is eligible for CASCADE deletion; `email_deliveries` for that recipient is eligible for CASCADE deletion. |
| Profile is deleted | `profiles.permissions_verified_by` references another profile with `ON DELETE SET NULL`. `verified_by` and text `unverified_by` do not have equivalent FK cleanup and can retain loose identifiers. |
| Historical event registrations exist | They remain because `event_registrations.user_id` has no FK to Auth. The old UUID and all customer snapshots remain. |
| Historical audit logs exist | They remain because actor and target identifiers are deliberately loose, not FKs. Actor/target names and operational details also remain. |
| User rate-limit row exists | It remains because the user UUID is stored as text in `scope_key`, without an FK. |
| Reservation/event tokens exist | They remain with their business rows. Expiry/unusable state does not erase the stored token. |

This means neither “delete Auth first” nor “delete profile first” is a complete
or safe account-erasure strategy. A future workflow must first resolve business
records and references, then delete the Auth account last.

## Anonymization feasibility

| Object | Proposed lifecycle action | Feasibility and constraints |
|---|---|---|
| `auth.users` | DELETE after successful business anonymization | Use trusted server/Admin API only. Revoke sessions and delete last so `auth.uid()` remains available for owner confirmation and audit. Reservation RESTRICT must be resolved first. |
| `profiles` | DELETE after dependent handling, or ANONYMIZE during a grace/disabled state | Clear contact/address/permit/declaration/note fields and neutralize display identity if profile must temporarily remain. Coordinate duplicated Auth metadata. |
| `reservations` | ANONYMIZE by default; DELETE only under approved policy | Preserve date/time/lane/pricing/payment/attendance data if justified. Replace contact snapshots and free text, unlink user through a deliberate schema design, and retire the check-in token. Current NOT NULL/FK/unique constraints require migration design. |
| `event_registrations` | ANONYMIZE or DELETE based on event/history policy | `user_id` can become NULL, but contact fields are NOT NULL. Clear promotion secrets and claim state subject to existing sent/confirmed token constraints. |
| `audit_logs` | KEEP structure; PSEUDONYMIZE person identifiers/names after approved threshold | Preserve action/time/target type and integrity. Never expose client DML or silently rewrite arbitrary details. A controlled, audited, narrowly scoped lifecycle job is required so SEC-007 remains intact. |
| `email_deliveries` | DELETE after bounded delivery/idempotency/diagnostic period | Safe candidate for scheduled cleanup once retries and support window are over. `recipient_user_id` already cascades on successful Auth deletion, but record-based scheduled cleanup is still needed. |
| Rate-limit rows | DELETE stale user scopes and stale HMAC-IP rows | Use a server-controlled cutoff. Never let clients supply the cutoff. Existing per-request pruning is not complete retention. |
| `events` and `lane_blocks` free text | KEEP business record; REVIEW/ANONYMIZE only when linked to a deletion request or policy match | No authoritative subject link exists, so blanket automatic deletion would be unsafe. Add input guidance and reviewed exceptional handling if needed. |

### Recommended anonymized reservation shape

This is a design direction, not an approved policy. A retained historical
reservation could preserve operational and financial snapshots while replacing
the subject linkage, contact snapshots, notes, and active bearer secret. The
exact tombstone values and whether `user_id` becomes nullable, points to a
pseudonym table, or uses another non-reversible identifier require a migration
design after the retention decision. Hard-coded fake e-mail/phone values should
not be chosen before uniqueness, reporting, and downstream formatting have been
tested.

## Audit implications

SEC-007 makes audit records append-only from application roles and restricts
direct writes to trusted business RPCs. SEC-009 must not weaken that boundary.

Current audit rows may contain:

- actor UUID, actor display name and actor role;
- target UUID and, for profile/configuration actions, a target display name;
- reservation/event registration/profile identifiers inside `details`;
- reservation dates/times, attendance/payment/status transitions;
- configuration before/after JSON and renamed resource names.

There is no FK from audit actor/target identifiers to Auth/profile/business
rows. This protects audit continuity across business-object deletion, but means
PII is not automatically removed. A future policy should distinguish:

1. immutable event facts (`action`, database timestamp, neutral target type,
   status transition), which can usually remain;
2. direct identifiers and names, which can be replaced with an irreversible
   subject pseudonym after an approved period;
3. `details` keys, which need an action-by-action allowlist and lifecycle map;
4. exceptional legally/security-required holds, which require explicit scope
   and authorization.

Pseudonymization must be performed only by an owner-only trusted job/RPC,
produce its own non-PII completion record, be idempotent, and preserve ordering
and evidence that an action occurred. Bulk deletion of audit history is not the
recommended default.

## Supabase Auth and order of future account deletion

The Auth account and public business profile are separate stores. The verified
safe order for a future design is:

```text
1. Re-authenticate the requester and create an idempotent deletion request.
2. Freeze or reject incompatible new business actions for that subject.
3. Resolve future/pending reservations and event registrations according to an
   approved business policy.
4. Export data first if requested and still authorized.
5. In one trusted database transaction, anonymize/unlink business snapshots,
   notes, tokens, delivery/rate-limit metadata and approved audit identity.
6. Verify zero forbidden direct identifiers and no broken references.
7. Delete/revoke the Supabase Auth account through a server-only Admin API.
8. Verify profile/Auth cleanup and record a minimal, non-PII completion proof.
```

Auth must not be deleted first: the reservation RESTRICT FK can stop the
operation, and losing the authenticated identity early complicates ownership
proof, export, retry, and audit. The exact treatment of Supabase-managed
identities, sessions, refresh tokens, and Auth logs should be verified against
the provider contract during implementation.

## User data export design

### Recommended minimum dataset

An owner export should be generated server-side from `auth.uid()` and contain:

- export schema version and generation time;
- account identity/contact fields that belong to the requester;
- profile address and the requester’s declared permissions/qualifications;
- user-visible verification state, subject to the decision on internal notes;
- the requester’s reservations, including dates/times, resource snapshot,
  people count, price/currency, payment/reservation/attendance state and their
  own submitted reservation note;
- the requester’s event registrations and user-visible event details/status;
- consent/terms acceptance evidence that directly concerns the requester, if
  this remains part of the approved dataset.

It must exclude:

- all other users’ data;
- check-in, promotion, confirmation and provider claim tokens/IDs;
- password/session/recovery material, JWTs and Auth provider secrets;
- rate-limit keys, IP-derived values and internal service metadata;
- other users’ audit records and unrestricted audit `details`;
- staff-only administrative and verification notes by default, unless a
  reviewed legal/business process decides they must be included in a formal
  access response;
- service-role keys, raw database errors and internal authorization data.

### Format

Versioned UTF-8 JSON is the recommended first format because it preserves
nested reservations/events and explicit null/type semantics:

```json
{
  "schema_version": 1,
  "exported_at": "database timestamp",
  "account": {},
  "profile": {},
  "reservations": [],
  "event_registrations": [],
  "consents": []
}
```

CSV is useful only as an optional convenience for flat reservation/event lists.
A ZIP is unnecessary until multiple formats or attachments exist; it increases
temporary-file, encryption, expiry, and download-token obligations. The export
should stream or use short-lived encrypted server storage, return a non-cacheable
response, and never be generated in the browser from broad table reads.

## Retention categories

No concrete legal or business periods are encoded in the repository. Therefore
the table deliberately does not invent day/year values.

| Category | CURRENT RETENTION | TECHNICALLY POSSIBLE TARGET | BUSINESS DECISION REQUIRED? | LEGAL/ACCOUNTING INPUT REQUIRED? |
|---|---|---|---|---|
| A. Active account data | Indefinite while account/profile exists; no closure workflow | Keep while active; on approved closure clear profile/Auth data after dependent records are handled | YES: closure/grace/reactivation model | YES for consent/claims evidence |
| B. Operational booking data | Reservations and event registrations remain indefinitely, including cancelled/completed records and PII snapshots | Retain current/future operational data; after approved cutoff anonymize subject/contact/notes while preserving necessary occupancy/history | YES | YES where claims/safety obligations apply |
| C. Financial/accounting-related data | Price, currency and payment status remain with business record indefinitely | Preserve required transaction facts without direct contact identity where allowed; no payment-provider or invoice identifiers were found | YES | YES, authoritative accounting classification and period needed |
| D. Security/audit data | Audit rows remain indefinitely; client mutation is denied | Keep immutable event facts; pseudonymize actor/target identity after an approved security/legal period; support holds | YES | YES for evidentiary/claims requirements |
| E. E-mail delivery/rate-limit data | Delivery state persists; rate-limit arrays are pruned on use but stale rows can remain | Delete delivery metadata after retry/support window; delete stale user/HMAC-IP rate-limit scopes in server-controlled batches | YES for support/abuse window | Privacy/security input required; accounting generally NO |
| F. Cancelled/expired records | Same indefinite retention as active history; state alone changes usability | Apply a separately approved, potentially shorter anonymization schedule while retaining aggregate/financial facts if justified | YES | YES where cancellation/claims records matter |
| G. Technical tokens | Check-in token remains in NOT NULL reservation; promotion token/claims can remain after expiry or completion | Make tokens unusable immediately on state transition and erase/rotate them after the workflow/evidence window; adapt constraints safely | YES for support window | Security/privacy input required |

Any litigation, incident, payment dispute, or other approved hold must override a
scheduled action only for the exact affected records, with authorization and an
auditable expiry. The repository currently has no hold model.

## Technical design options

### Option A — minimal: manual admin-triggered export and anonymization

- **Complexity:** SMALL–MEDIUM.
- **Security:** acceptable only if implemented as narrowly scoped trusted RPCs
  and server routes with preview, explicit confirmation, idempotency and audit.
- **Operational burden:** HIGH; every request needs trained staff and manual
  cutoff/reference checks.
- **SaaS readiness:** LOW; easy to miss tenant and subject scope.
- **Regression risk:** MEDIUM; lower automation surface, but human error and
  inconsistent execution remain.

This can be an emergency bridge after policy approval, not the desired final
lifecycle.

### Option B — recommended: self-service request, controlled export and scheduled cleanup

- **Complexity:** MEDIUM–LARGE, best delivered in small checkpoints.
- **Security:** HIGH when owner identity is re-confirmed, destructive work stays
  server-side, jobs are fail-closed, and all actions are idempotent/audited.
- **Operational burden:** MEDIUM; staff handles exceptions/holds rather than
  every routine request.
- **SaaS readiness:** GOOD if every request/job is designed for a future tenant
  scope and no global client-supplied cutoff is accepted.
- **Regression risk:** HIGH around irreversible anonymization and FK/reporting
  behavior; manageable with dry-run manifests, batches and staged deployment.

Recommended staged delivery after decisions:

1. approve the category/retention/hold policy and machine-readable field map;
2. add an owner-only JSON export with no destructive behavior;
3. add deletion requests, re-authentication, idempotency and a manual approval
   gate/grace state;
4. add one atomic subject anonymization function and exhaustive FK/report tests;
5. delete Auth last through a server-only operation;
6. add scheduled cleanup for technical metadata and aged anonymizable records,
   initially in report-only mode, then bounded batches.

### Option C — advanced: complete automated lifecycle

- **Complexity:** LARGE.
- **Security:** potentially strongest, but the larger scheduler/storage/hold
  surface creates more failure modes.
- **Operational burden:** LOW after maturity; HIGH to build and monitor.
- **SaaS readiness:** HIGH.
- **Regression risk:** HIGH due to grace periods, export artifacts, legal holds,
  multi-category jobs and recovery requirements.

This is premature for the current application phase and should follow proven
Option B primitives.

## Recommended option

Adopt **Option B**, implemented in the staged order above. Start with the
non-destructive owner export, then add request/grace/audit mechanics, and only
then enable anonymization and scheduled retention. Do not begin irreversible
work until the owner answers the policy questions below and the expected
historical/reporting behavior is captured in tests.

## SaaS compatibility

No `tenant_id` is introduced in this remediation discovery. Future multi-tenant
support changes the safety boundary in these specific ways:

- an export must match both `auth.uid()` and authoritative tenant membership;
- admin export/deletion must be tenant-scoped and must not infer tenant from a
  client-provided ID alone;
- lifecycle requests, holds, pseudonyms and job cursors need tenant scope;
- retention workers must process bounded per-tenant batches and prevent one
  tenant’s failure or policy from affecting another;
- audit facts must retain tenant context even after subject anonymization;
- tenant deletion and individual deletion need separate operations;
- global HMAC/IP rate-limit data may not belong to one tenant and needs its own
  platform-level policy.

Before the second tenant, completeness tests should fail if a new PII-bearing
table is absent from the export/lifecycle registry. That is compatible with the
future SEC-004 multi-tenant architecture, but does not itself remediate SEC-004.

## Security requirements for implementation

### Export

- derive subject from `auth.uid()`; do not accept an arbitrary user ID for an
  owner export;
- use explicit allowlisted DTOs rather than `select('*')`;
- admin export of another person requires a separately justified capability,
  purpose logging and exact target confirmation;
- use non-cacheable responses and either direct streaming or short-lived,
  access-controlled artifacts;
- never include tokens, credentials, secrets, other users, broad audit details,
  or raw errors.

### Deletion and anonymization

- use a controlled server-side/RPC workflow; no direct destructive client DML;
- require recent authentication and explicit confirmation;
- lock the subject and dependent records in deterministic order;
- use an idempotency key and explicit states (`requested`, `eligible`,
  `blocked`, `anonymized`, `auth_deleted`, `completed` or equivalent);
- fail closed on unknown dependencies, count mismatches, holds or partial
  subject resolution;
- audit the action without storing erased PII in the new audit entry;
- never expose service-role credentials in browser code;
- never auto-retry a destructive call without the same idempotency key.

### Bulk retention

- run only from trusted backend/scheduler credentials;
- derive cutoffs from server-owned policy configuration, never request input;
- support report-only mode, exact manifests, bounded batches, row locking,
  idempotency, metrics and safe interruption;
- verify no orphan FKs, no forbidden PII and unchanged protected/current data;
- keep separate policies for business history, audit, delivery metadata,
  rate-limit telemetry and secrets.

## Decisions required from owner

1. Should account closure be immediate self-service deletion, or a verified
   request with a grace period and optional staff review?
2. What should happen to future/pending reservations and event registrations
   when deletion is requested: block deletion, cancel them, or wait until they
   finish?
3. May completed/cancelled reservations and event registrations remain as fully
   anonymized operational/statistical records, or must some/all be deleted?
4. Which current price/payment records are accounting or claims records, and
   what authoritative retention period/hold rules apply to them?
5. How long must trusted audit identity remain attributable before it may be
   pseudonymized, and which incident/legal holds can suspend that action?
6. Should profile/reservation administrative and verification notes be erased
   at account closure, retained under a hold, or reviewed case by case? Should
   any of them appear in a formal user access export?
7. Is versioned JSON sufficient for the first owner export, or is an additional
   CSV/ZIP format operationally required?
8. What approved retention windows should apply separately to active profile
   data, completed/cancelled operational records, e-mail delivery metadata,
   rate-limit telemetry, and expired technical tokens?

## Implementation scope after decisions

Expected work is LARGE and should be split into independent security
checkpoints:

1. policy document, field registry and decision record;
2. owner-scoped export RPC/server endpoint, UI and tests;
3. lifecycle/deletion-request state, indexes and recent-auth confirmation;
4. atomic anonymization RPC with dependency manifest and audit pseudonym rules;
5. server-only Auth deletion coordinator and recovery/idempotency handling;
6. report-only then active scheduled retention jobs for technical and business
   categories;
7. database contract tests, role/IDOR tests, cutoff-boundary tests, FK/orphan
   tests, export allowlist tests, audit-integrity tests, scheduler retry tests,
   and end-to-end deletion/export tests.

Likely affected areas include new migrations and DB tests, server-only lifecycle
and export modules/routes, account/admin request UI, scheduler configuration,
and privacy/policy documentation. Existing business tables should not receive
broad client DELETE/UPDATE privileges.

## Verdict

```text
SEC-009 CONFIRMED — BUSINESS DECISIONS REQUIRED
```

The finding is a lifecycle/control gap rather than a currently demonstrated
direct-access exploit. Its present exploitability is LOW, but the regression
and irreversible-data risk of remediation is HIGH. Implementation must wait for
the explicit retention, history, audit and export decisions above.
