# SAAS-9D — Tenant-Aware RPC / SECURITY DEFINER Hardening

Technical implementation plan with the approved SAAS-9D-1 local execution record. Planning and local implementation date: 2026-09-11 (Europe/Warsaw).

Repository baseline: `02af6857a88e37d30b6e4b1159496cecff91bac1` on `main`, identical to `origin/main` when this plan was prepared.

The original plan was planning-only. SAAS-9D-1 is now closed with production PASS, and the later sections record its checkpoint plus the reviewed SAAS-9D-2 plan. Nothing in this document authorizes SAAS-9D-2 implementation, a production write or a second tenant.

## 1. Executive summary

SAAS-9C closed the direct-table RLS boundary, but every `SECURITY DEFINER` function can execute outside that boundary. The authoritative SAAS-9C-2E production catalog contains exactly 73 such functions, fingerprint `0dd807bea5ca20cfbaae9434b53d97a4`. The local schema reconstructed from the same migration history has the same 73 signatures and security metadata.

The central 9D invariant is:

1. resolve the authenticated actor with `auth.uid()`;
2. derive the tenant from an existing trusted resource whenever one exists;
3. require an active membership and the exact allowed tenant role;
4. bind every related read, mutation and audit row to that same tenant;
5. reject a caller-supplied tenant when it differs from the resource tenant;
6. never use global `profiles.role` as tenant authorization.

Existing-resource operations can normally preserve their signatures because tenant is derived from `reservation_id`, `registration_id`, `event_id`, `lane_id`, `block_id`, token or claim. Create/list/report/user-management/public-list operations have no trusted target and need either a versioned tenant argument plus application cutover, or a narrowly bounded CSK compatibility wrapper while the single-active-tenant guard remains effective. The compatibility wrapper is not permission to activate Tenant B.

The recommended first implementation slice is 9D-1A: reservation creation, cancellation, check-in and operational reservation RPCs. It needs no application tenant selector because all target tenants can be derived. Production write remains separately gated.

## 2. Authoritative 73-function inventory

Legend used to keep the complete inventory readable:

- `SP1` = `pg_catalog, public, pg_temp` (target baseline); `SP2` = `public, pg_temp`; `SP3` = `public`.
- grants list direct EXECUTE grantees in addition to owner `postgres`: `A` authenticated, `N` anon, `S` service_role, `—` none.
- caller codes: `RES` reservation UI/API, `EVT` event UI/API, `LANE` lane admin UI, `REP` reports UI, `USR` users/check-in UI, `PUB` public UI, `MAIL` email route/helper, `PROMO` reserve-promotion helper, `ACCT` account API/UI, `DB` trigger/internal SQL, `LEG` no current TypeScript caller or retained legacy version.
- `derive` names the trusted lookup; `context` means the function must receive or resolve a selected tenant before a second tenant can exist.
- all rows below are `SECURITY DEFINER=yes`, owner `postgres`, and therefore an RLS-bypass boundary.

| # | Function signature | Path | Grants | Callers | Global role check | Tenant arg | Resource arg | Can derive tenant? | Cross-tenant risk | Severity | Target phase |
|---:|---|---|---|---|---:|---:|---:|---|---|---|---|
| 1 | `active_single_tenant_id_v1()` | SP1 | — | DB | no | no | no | single-active guard only | bridge misuse after Tenant B | SAFE now | 9D-5 review |
| 2 | `admin_create_event(text,text,date,time,time,text,numeric,int,uuid[])` | SP2 | S | LEG | yes | no | lane IDs | only if every lane is same tenant; empty list cannot | global create/bypass | CRITICAL | 9D-2 retire |
| 3 | `admin_create_event_v2(text,text,date,time,time,text,numeric,int,uuid[])` | SP1 | A | EVT | yes | no | lane IDs | partial; explicit context still required | global create | CRITICAL | 9D-2A |
| 4 | `admin_create_lane_block(uuid,date,time,time,text)` | SP1 | A | LANE | yes | no | lane | lane | foreign-lane write | CRITICAL | 9D-3A |
| 5 | `admin_create_lane_booking_family_v1(jsonb)` | SP1 | A | LANE | yes | no | payload only | no trusted existing resource | global create | CRITICAL | 9D-3B |
| 6 | `admin_get_lane_booking_configuration_v1()` | SP1 | A | LEG | yes | no | no | context required | global admin read | HIGH | 9D-3 retire |
| 7 | `admin_get_lane_booking_configuration_v2()` | SP1 | A | LANE | yes | no | no | context required | global admin read | HIGH | 9D-3B |
| 8 | `admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)` | SP1 | A | REP | yes | no | optional resource | resource if supplied; context otherwise | global report/PII | HIGH | 9D-4A |
| 9 | `admin_get_reservation_report_v1(date,date,int,int)` | SP1 | A | LEG | yes | no | no | context required | global report/PII | HIGH | 9D-4 retire |
| 10 | `admin_get_reservation_report_v2(date,date,uuid,text,text,text,int,int)` | SP1 | A | REP | yes | no | optional resource | resource if supplied; context otherwise | global report/PII | HIGH | 9D-4A |
| 11 | `admin_list_event_registrations_v1(uuid,text,text,int,int)` | SP1 | A | EVT | yes | no | event | event | participant PII across tenants | HIGH | 9D-2B |
| 12 | `admin_list_events_v1(text,text,text,int,int)` | SP1 | A | EVT | yes | no | no | context required | global admin list | HIGH | 9D-2B |
| 13 | `admin_list_users_v1(int,int,text,text,text,text)` | SP1 | A | USR | yes | no | target absent | context + operational relation required | global profile PII | CRITICAL | 9D-4B |
| 14 | `admin_set_event_active(uuid,bool)` | SP2 | S | LEG | yes | no | event | event | service/global mutation | CRITICAL | 9D-2 retire |
| 15 | `admin_set_event_active_v2(uuid,bool)` | SP1 | A | EVT | yes | no | event | event | foreign event mutation | CRITICAL | 9D-2A |
| 16 | `admin_set_lane_block_active(uuid,bool)` | SP1 | A | LANE | yes | no | block | block -> lane tenant | foreign block mutation | CRITICAL | 9D-3A |
| 17 | `admin_set_lane_booking_configuration(uuid,bool,bool,bool,int,bool,int,int[],jsonb)` | SP1 | — | LEG | yes | no | lane | lane | internal legacy writer | HIGH | 9D-3 retire |
| 18 | `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,bool)` | SP1 | A | LANE | yes | no | root lane | root/family | foreign family mutation | CRITICAL | 9D-3A |
| 19 | `admin_set_user_note_v1(uuid,text)` | SP1 | A | USR | yes | no | user only | context + target relationship | cross-tenant profile update | CRITICAL | 9D-4B |
| 20 | `admin_set_user_role_v1(uuid,text)` | SP1 | A | USR | yes | no | user only | selected tenant membership | global privilege mutation | CRITICAL | 9D-4B |
| 21 | `admin_update_event(uuid,text,text,date,time,time,text,numeric,int,uuid[])` | SP2 | S | LEG | yes | no | event/lanes | event, then cross-check lanes | service/global mutation | CRITICAL | 9D-2 retire |
| 22 | `admin_update_event_v2(uuid,text,text,date,time,time,text,numeric,int,uuid[])` | SP1 | A | EVT | yes | no | event/lanes | event, cross-check every lane | foreign event/lane binding | CRITICAL | 9D-2A |
| 23 | `admin_update_lane_block(uuid,uuid,date,time,time,text,bool)` | SP1 | A | LANE | yes | no | block/lane | block and lane; must match | cross-tenant reparent/write | CRITICAL | 9D-3A |
| 24 | `anonymize_my_account_v1()` | SP1 | A | ACCT | yes | no | caller UID | caller-owned rows across memberships | global lifecycle spill | HIGH | 9D-4C |
| 25 | `approve_event_registration(uuid)` | SP2 | A | EVT | yes | no | registration | registration -> event | foreign participant mutation | CRITICAL | 9D-2A |
| 26 | `cancel_event_registration(uuid)` | SP2 | A,S | EVT | yes | no | registration | registration -> event | owner/staff cross-tenant confusion | CRITICAL | 9D-2A |
| 27 | `cancel_reservation(uuid)` | SP1 | A,S | RES | yes | no | reservation | reservation | owner/staff cross-tenant confusion | CRITICAL | 9D-1A |
| 28 | `check_confirmation_email_rate_limit(uuid,text)` | SP2 | S | MAIL | no | no | user/IP | caller/claim context; user is not sufficient | cross-tenant rate-limit coupling | MEDIUM | 9D-2C |
| 29 | `complete_confirmation_email(uuid,bool,text,text)` | SP2 | S | MAIL | no | no | claim | claim -> delivery tenant | foreign claim completion | HIGH | 9D-2C |
| 30 | `complete_event_reserve_promotion(uuid,uuid,bool,text)` | SP2 | S | PROMO | no | no | registration/claim | both; must match | service cross-tenant completion | CRITICAL | 9D-2C |
| 31 | `confirm_event_reserve_promotion(text)` | SP2 | A | EVT | no | no | bearer token | token -> registration -> event; actor owner | token/owner mismatch | CRITICAL | 9D-2A |
| 32 | `create_reservation(uuid,date,time,int,int,uuid,text)` | SP1 | S | LEG | yes | no | lane | lane | legacy service/global writer | CRITICAL | 9D-1 retire |
| 33 | `create_reservation_v2(uuid,date,time,int,int,uuid,text)` | SP1 | A,S | RES | yes | no | lane | lane | foreign-lane create | CRITICAL | 9D-1A |
| 34 | `export_my_data_v1()` | SP1 | A | ACCT | no | no | caller UID | caller rows, preserving each row tenant | cross-tenant owner export ambiguity | HIGH | 9D-4C |
| 35 | `get_check_in_reservation_v1(uuid)` | SP1 | A | USR | yes | no | check-in token | token -> reservation | staff PII/token bypass | HIGH | 9D-1B |
| 36 | `get_lane_booking_busy_ranges(uuid,date)` | SP1 | A,S | LEG | no | no | lane | lane | tenant-blind legacy availability | MEDIUM | 9D-1 retire |
| 37 | `get_lane_booking_busy_ranges_v2(uuid,date)` | SP1 | A,S | LEG | no | no | lane | lane | tenant-blind legacy availability | MEDIUM | 9D-1 retire |
| 38 | `get_lane_booking_busy_ranges_v3(uuid,date)` | SP1 | A,S | PUB/RES | no | no | lane | lane | cross-tenant availability inference | HIGH | 9D-1B |
| 39 | `get_my_event_registrations_v1(text,text,int,int)` | SP1 | A | EVT | no | no | caller UID | rows by UID; selected context needed in 9E | cross-tenant aggregation in future | MEDIUM | 9D-2B/9E |
| 40 | `get_my_reservations_v2()` | SP1 | A | RES | no | no | caller UID | rows by UID; selected context needed in 9E | cross-tenant aggregation in future | MEDIUM | 9D-1B/9E |
| 41 | `get_my_role()` | SP3 | A | PUB/admin pages | yes | no | no | no | global authorization | CRITICAL | 9D-4D then 9E |
| 42 | `get_my_tenant_role_v1(uuid)` | SP1 | A | DB/future app | no | yes | no | explicit tenant + membership | caller chooses tenant but check binds actor | SAFE | retain |
| 43 | `get_public_booking_configuration_v1()` | SP1 | N,A,S | PUB | no | no | no | active-single bridge only | wrong tenant after activation | HIGH | 9D-4E/9E |
| 44 | `get_public_check_in_status_v1(uuid)` | SP1 | N | PUB | no | no | token | token -> reservation | bearer cross-tenant disclosure | HIGH | 9D-1B |
| 45 | `get_public_event_availability_v1()` | SP1 | N,A | PUB | no | no | no | active-single bridge only | aggregate tenant mixing | HIGH | 9D-2B/9E |
| 46 | `get_public_event_list_v2(text,text,int,int)` | SP1 | N,A | PUB | no | no | no | active-single bridge only | public tenant mixing | HIGH | 9D-2B/9E |
| 47 | `get_reservation_customer_profiles_v1(uuid[])` | SP1 | A | USR/MAIL | yes | no | reservations | every reservation; same tenant required | bulk cross-tenant PII | CRITICAL | 9D-1B |
| 48 | `handle_new_user()` | SP2 | — | DB trigger | yes | no | NEW user | no tenant without onboarding context | wrong automatic membership | HIGH | 9D-4D/9E |
| 49 | `has_tenant_role_v1(uuid,text[])` | SP1 | A | RLS/9D functions | no | yes | no | explicit tenant + membership | low if roles allowlisted | SAFE | retain |
| 50 | `is_active_public_tenant_v1(uuid)` | SP1 | N,A | RLS/public helpers | no | yes | no | explicit tenant + active status | low; public boolean only | SAFE | retain |
| 51 | `is_admin()` | SP3 | A | DB/legacy | yes | no | no | no | global authorization | CRITICAL | 9D-4D retire |
| 52 | `is_admin_or_employee()` | SP3 | A | DB/legacy | yes | no | no | no | global authorization | CRITICAL | 9D-4D retire |
| 53 | `is_admin_or_staff()` | SP3 | A | DB/legacy | yes | no | no | no | global authorization | CRITICAL | 9D-4D retire |
| 54 | `is_tenant_member_v1(uuid)` | SP1 | A | RLS/9D functions | no | yes | no | explicit tenant + membership | low | SAFE | retain |
| 55 | `lane_booking_family_business_snapshot_v2(uuid)` | SP1 | — | DB internal | no | no | root lane | root/family | internal data leak only if grant widens | SAFE | 9D-3 review |
| 56 | `mark_event_registration_paid(uuid)` | SP1 | A | EVT | yes | no | registration | registration -> event | foreign participant/payment mutation | CRITICAL | 9D-2A |
| 57 | `normalize_lane_booking_family_payload_v2(jsonb)` | SP1 | — | DB internal | no | no | payload | caller function must bind result | no direct client surface | SAFE | 9D-3 review |
| 58 | `prepare_confirmation_email(text,uuid)` | SP2 | A | MAIL | yes | no | typed record | message type -> record tenant | cross-tenant recipient/claim | CRITICAL | 9D-2C |
| 59 | `prepare_event_reserve_promotions(uuid)` | SP2 | S | PROMO | no | no | event | event | service cross-tenant token creation | CRITICAL | 9D-2C |
| 60 | `prevent_non_admin_profile_privilege_changes()` | SP1 | — | DB trigger | yes | no | OLD/NEW profile | membership context absent | legacy privilege guard mismatch | HIGH | 9D-4D |
| 61 | `register_for_event(uuid,bool)` | SP2 | A | EVT | no | no | event | event + actor membership/owner semantics | foreign-event registration | CRITICAL | 9D-2A |
| 62 | `sync_csk_membership_role_to_profile()` | SP1 | — | DB trigger | yes | no | NEW membership | fixed CSK bridge | unsafe beyond CSK | HIGH bridge | 9D-5/9E retire |
| 63 | `sync_profile_role_to_csk_membership()` | SP1 | — | DB trigger | no | no | NEW profile | fixed CSK bridge | unsafe beyond CSK | HIGH bridge | 9D-5/9E retire |
| 64 | `update_my_profile_v1(text,text,text,text,text,text,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool)` | SP1 | A | ACCT | yes | no | caller UID | owner profile; membership status policy needed | cross-tenant membership ambiguity | HIGH | 9D-4C |
| 65 | `update_profile_contact_details(uuid,text,text,text,text,text,text)` | SP2 | A,S | USR | yes | no | target user | context + operational relationship | cross-tenant PII mutation | CRITICAL | 9D-4B |
| 66 | `update_profile_identity(uuid,text,text)` | SP2 | A,S | USR | yes | no | target user | context + operational relationship | cross-tenant PII mutation | CRITICAL | 9D-4B |
| 67 | `update_profile_verification(uuid,text,text)` | SP2 | A,S | USR | yes | no | target user | context + operational relationship | cross-tenant privilege/PII | CRITICAL | 9D-4B |
| 68 | `update_reservation_admin_note(uuid,text)` | SP1 | A | RES | yes | no | reservation | reservation | foreign reservation PII mutation | CRITICAL | 9D-1A |
| 69 | `update_reservation_attendance(uuid,text)` | SP1 | A,S | RES/USR | yes | no | reservation | reservation | foreign attendance mutation | CRITICAL | 9D-1A |
| 70 | `update_reservation_payment(uuid,text)` | SP1 | A | RES/USR | yes | no | reservation | reservation | foreign payment mutation | CRITICAL | 9D-1A |
| 71 | `validate_lane_booking_rule_capacity()` | SP1 | — | DB trigger | no | no | NEW lane_id | lane | trigger integrity only | SAFE | 9D-3 review |
| 72 | `validate_shooting_lane_capacity_change()` | SP1 | — | DB trigger | no | no | OLD/NEW lane | lane/root | trigger integrity only | SAFE | 9D-3 review |
| 73 | `validate_shooting_lane_hierarchy()` | SP1 | — | DB trigger | no | no | OLD/NEW lane | lane/root | trigger integrity only | SAFE | 9D-3 review |

Catalog conclusions:

- 73/73 are RLS-bypass boundaries; 73/73 are owned by `postgres`.
- No function has a tenant argument except the four approved tenant helpers (`get_my_tenant_role_v1`, `has_tenant_role_v1`, `is_active_public_tenant_v1`, `is_tenant_member_v1`).
- Four legacy functions use `search_path=public`; sixteen use `public, pg_temp`; 53 use the target SP1 baseline.
- No new EXECUTE grant is needed. Existing grants are an upper bound; obsolete v1/service-role grants should be removed only after zero-caller proof.

## 3. Severity classification

| Class | Meaning | Functions | Required result |
|---|---|---|---|
| CRITICAL | Mutates tenant-owned data, privileged PII or roles and lacks a complete tenant-bound authorization invariant | 36 functions, including active reservation/event/lane writers, admin profile mutations, email/promotion claims and legacy global-role helpers | harden before Tenant B; cross-tenant deny and audit proof mandatory |
| HIGH | Privileged read, public aggregate, lifecycle, trigger or bridge can cross/mix tenants | 22 functions (including two CSK-only bridge triggers) | tenant-bound read/DTO or explicit retirement gate |
| MEDIUM | Technical/owner/list helper has bounded impact but lacks future tenant context | 5 functions | review and test in its domain phase |
| SAFE / NO CHANGE | approved tenant helpers or internal trigger/normalizer with no client grant and no authorization decision | 10 functions | preserve fingerprint unless review proves a narrowly scoped hardening need |

Counts are planning classifications, not a claim that SAFE functions cease to be privileged. All remain in the final fingerprint/ACL audit.

## 4. Reservation RPCs

### 4.1 Write invariant

- `create_reservation_v2`: load `shooting_lanes.tenant_id` for `p_lane_id` before validation/locking; require the caller to be an active member of that tenant with the existing customer role semantics; explicitly insert `reservations.tenant_id`; keep atomic capacity checks and idempotency key unchanged.
- `cancel_reservation`: load reservation once under lock; derive tenant; allow owner only under the existing cutoff rule or tenant admin/employee under current staff semantics; never authorize using global profile role.
- attendance/payment/admin-note: derive tenant from reservation, require active admin/employee membership, keep existing action transition, no-change and audit semantics.
- profile batch read: every requested reservation must belong to the caller's authorized tenant. Mixed-tenant arrays fail closed; do not silently return a partial set.

### 4.2 Check-in and availability

- authenticated check-in derives tenant from the token's reservation, then requires the current staff role.
- public check-in remains bearer-token scoped and PII-minimized; tenant is derived from the reservation and never supplied by the browser.
- busy ranges derive tenant from the lane and query only rows/blocks/events with matching tenant. Public booking access must still require an active public tenant/lane.
- preserve hierarchy locks, canonical overlap semantics and active/inactive historical visibility.

### 4.3 Compatibility

All active 9D-1 signatures can remain unchanged. That makes `OLD APP + NEW DB` safe for this phase. Legacy `create_reservation` and busy-range v1/v2 remain non-browser contracts and are revoked/retired only after dependency and production-call verification.

## 5. Event RPCs

- Targeted event/registration functions derive tenant from the event or registration and cross-check every lane in `event_lanes`.
- Create requires an explicit trusted tenant because an event can have zero lanes. Introduce a versioned signature or a server-resolved wrapper; do not infer tenant solely from the first lane.
- Update derives tenant from the event, then rejects any lane whose tenant differs.
- Admin list needs selected tenant context; participant list derives tenant from `p_event_id` and checks membership before returning its minimal DTO.
- `register_for_event` binds actor, event tenant and inserted registration tenant; reserve/capacity logic remains atomic.
- Cancel/approve/payment/promotion derive through registration -> event and keep exactly one tenant-bound audit.
- Public list/availability need tenant resolution from trusted host/slug in 9E. Until then, the sole-active-CSK wrapper may remain only while `tenants_single_active_runtime_guard` prevents a second active tenant.
- Promotion and email claims persist tenant identity at preparation and verify the same tenant at completion.

## 6. Lane/configuration RPCs

- Block create derives from lane. Block update derives separately from existing block and proposed lane and rejects mismatch.
- Family configuration derives from root and verifies all payload resource IDs belong to that root and tenant before locking or mutation.
- Family creation has no trusted existing resource. Add a versioned contract with `p_tenant_id`, require tenant admin membership, and explicitly write tenant to root, positions, rules, durations and pricing relations through their lane ownership.
- Admin configuration list requires selected tenant context; public booking configuration is handled as a public selected-tenant contract in 9E.
- Internal snapshot/normalizer/validation functions retain internal-only grants and receive tenant-bound inputs only from the hardened parent writer.

## 7. Reports RPCs

- Add a versioned `p_tenant_id` to unfiltered report/list contracts; require active tenant admin membership.
- If `p_resource_id` is present, derive its tenant and require equality with `p_tenant_id`.
- Apply tenant predicate before aggregate, detail pagination, revenue and export limits so KPI and detail scope stay identical.
- CSV remains bounded to 5000 and PII-minimized; tenant ID does not need to be exposed in the DTO.
- v1/v2 legacy wrappers may resolve sole active CSK only during compatibility; remove after 9E call sites supply trusted context.

## 8. Profile/admin RPCs

- `admin_list_users_v1` must become tenant-contextual and return only members/operationally related customers permitted by the product rule. It must not restore global profile browsing.
- `admin_set_user_role_v1` must evolve into tenant-membership role management. It must not write a future tenant role into global `profiles.role`; the CSK sync bridge remains only during legacy cutover.
- note, identity, contact and verification operations require tenant admin/approved employee membership plus an explicit operational relationship between target user and tenant. Employee restrictions remain unchanged.
- self profile/export/anonymization stay caller-owned. They may operate over the user's rows across tenants only under an explicitly documented account-wide lifecycle contract; they must never use a selected tenant to access another user.
- `get_my_role` and `is_admin*` are removed from authorization only after all app and DB call sites use tenant membership. They are not rewritten to guess the sole tenant as a permanent solution.

## 9. Audit helpers

There is no standalone client audit-writer RPC in the 73-function inventory. Audit writes occur inside trusted business functions. Every hardened writer must:

- set audit `tenant_id` from the same locked resource used for authorization;
- preserve `tenant_id=NULL` only for approved global/account lifecycle actions;
- set actor from `auth.uid()` (or an explicitly documented server identity), timestamp in DB, and stable action/target values;
- create no audit on denied/no-change/idempotent repeat;
- reject mismatched event/registration/lane/reservation targets before an audit is written;
- never include PII, bearer tokens, JWTs, provider secrets or service-role keys.

The final 9D audit must compare the action/target classification map introduced in 9B-2 with every live audit-producing function.

## 10. `service_role` paths

RLS and membership helper grants do not protect a service-role client. Each path therefore needs authorization before the service client is created or used.

| Path | Current use | Current authentication | Tenant resolution target | 9D requirement |
|---|---|---|---|---|
| `app/api/account/delete/route.ts` | Auth Admin `deleteUser` after `anonymize_my_account_v1` | bearer JWT verified by anon client | user-owned account lifecycle; not selected tenant | keep service key only for Auth deletion; DB anonymization remains user-JWT RPC; verify no arbitrary user ID |
| `lib/server/confirmation-email-delivery.ts` plus three send-email routes | service client completes delivery claims and rate limits | each route verifies caller and uses user-JWT `prepare_confirmation_email` | derive at prepare from typed record; persist on delivery claim | completion must verify claim tenant/record and never accept recipient/tenant from browser |
| `lib/server/event-reserve-promotion.ts`, called by `app/api/send-event-reserve-promotion/route.ts` | service RPC prepares/completes reserve promotions | API route must authorize triggering event action | derive from event, bind every registration and claim | pass trusted actor/tenant proof into a hardened server contract; reject cross-tenant event IDs before service RPC |

Additionally, legacy DB grants to service_role (`admin_create_event`, `admin_set_event_active`, `admin_update_event`, `create_reservation`, and selected active functions) need zero-runtime-caller proof. Revoke obsolete grants; for necessary server completions keep only the exact claim-based function.

## 11. Tenant derivation strategy

| Input | Trusted chain | Required cross-check |
|---|---|---|
| `reservation_id` | `reservations.tenant_id` | lane tenant and any related audit/delivery row match |
| `check_in_token` | token -> reservation -> tenant | token validity/status/window before DTO |
| `lane_id` | `shooting_lanes.tenant_id` | family root and all conflict resources have same tenant |
| `block_id` | block -> lane/tenant | proposed lane tenant equals existing block tenant |
| `event_id` | `events.tenant_id` | all event lanes and registrations match |
| `registration_id` | registration -> event -> tenant | registration tenant equals event tenant |
| `claim_id` | delivery/promotion claim -> record -> tenant | caller-supplied record ID, when present, equals claim target |
| `target_user_id` | selected tenant membership or operational reservation/registration relationship | target relation belongs to selected tenant; global profile role is irrelevant |
| create/list/report without target | trusted `p_tenant_id` selected by server/app context | active tenant plus active membership/role; never rely on client assertion alone |
| public list without target | host/slug -> active tenant (9E) | public contract only; no membership or PII |

Any lookup returning zero or multiple tenants fails closed. Mixed-resource arrays are rejected, not partially processed.

## 12. Membership authorization strategy

- Admin: `has_tenant_role_v1(tenant, ['admin'])` for admin-only operations.
- Employee: include `employee` only where current product behavior allows it; never broaden admin-only config/reports/user-role operations.
- Instructor: include only current approved event/lane read scope. SEC-008 remains deferred and 9D must not invent an instructor-event assignment.
- User: owner action requires `auth.uid() = resource.user_id`; where the current RLS/product requires membership, also require active membership in the resource tenant.
- No membership, pending/suspended membership, inactive tenant or NULL actor: privileged operation denied.
- For server claim completion, authorization is the unforgeable claim created by an already-authorized prepare step, bound to tenant and target; it is not a generic service-role bypass.

Use the tenant helpers for authorization but still perform resource/tenant equality checks in the same transaction. Membership check alone is insufficient for IDOR protection.

## 13. `search_path`, owner and grants baseline

For every changed function:

1. `SECURITY DEFINER`, owner `postgres` only when definer privilege is genuinely required; otherwise convert to invoker/internal SQL where safe.
2. explicit `SET search_path = pg_catalog, public, pg_temp` and schema-qualified objects/functions;
3. `REVOKE ALL ... FROM PUBLIC, anon, authenticated, service_role` followed by the minimum exact grant;
4. no grant widening relative to the inventory;
5. internal triggers/helpers remain owner-only;
6. public PII-free readers get only anon/authenticated as required; token check-in stays anon only;
7. active browser RPCs get authenticated only; service-role claim completions get service_role only;
8. obsolete v1 functions lose non-owner EXECUTE after confirmed zero callers.

SP2/SP3 functions must be normalized when touched. The migration test must fail if any changed function has an unsafe/missing path, unexpected owner, PUBLIC execute or broader grant.

## 14. Application caller matrix

| File(s) | RPCs | Arguments today | Tenant context today | Target context | App change? | Phase |
|---|---|---|---|---|---:|---|
| `app/api/create-reservation/route.ts` | `create_reservation_v2` | lane/date/time/duration/count/request/note | none | derive from lane | no | 9D-1A |
| `app/booking/BookingForm.tsx` | `get_lane_booking_busy_ranges_v3` | lane/date | none | derive from lane | no | 9D-1B |
| `app/booking/page.tsx` | `get_public_booking_configuration_v1` | none | sole active CSK | host/slug tenant | yes, 9E | 9D-4E/9E |
| `app/my-reservations/page.tsx`, `app/api/calendar/reservations/[id]/route.ts` | `get_my_reservations_v2`, `cancel_reservation` | caller or reservation | none | selected tenant for list; derive for cancel | list yes in 9E; cancel no | 9D-1 |
| `lib/reservation-actions.ts`, admin reservation/check-in pages | attendance/payment/note/cancel | reservation/action | none | derive from reservation | no | 9D-1A |
| `app/admin/check-in/page.tsx` | check-in/profile batch/verification | token, reservation IDs, target user | global role | derive reservation tenant; relationship for profile | verification contract likely versioned | 9D-1B/4B |
| `app/check-in/[token]/page.tsx` | `get_public_check_in_status_v1` | token | bearer token | derive from reservation | no | 9D-1B |
| reservation email routes | rate-limit/prepare/complete | user/IP hash, type/record, claim result | authenticated prepare + service completion | record/claim-derived | internal helper change | 9D-2C |
| `app/events/page.tsx` | `get_public_event_list_v2` | search/scope/page | sole active CSK | host/slug tenant | yes, 9E | 9D-2B/9E |
| `app/my-events/page.tsx` | `get_my_event_registrations_v1` | scope/status/page | caller only | selected tenant | yes, 9E | 9D-2B/9E |
| event register/cancel/confirm APIs | register/cancel/confirm RPCs | event/registration/token | none | target-derived | no | 9D-2A |
| `app/admin/events/page.tsx` | list/create/update/active/participants/approve/payment | filters or target IDs | global role | explicit selected tenant for list/create; derive for targets | yes for list/create; target calls can stay | 9D-2 |
| reserve-promotion API/helper | prepare/complete promotion | event/registration/claim | service client | event/claim-derived | server helper change | 9D-2C |
| `app/admin/lane-blocks/page.tsx` | block create/update/active | lane/block | global role | resource-derived | no | 9D-3A |
| `app/admin/lane-configuration/page.tsx` | config list/family create/update | none, payload, root | global role | selected tenant for list/create; derive update | yes for list/create | 9D-3 |
| `app/admin/reports/page.tsx` | report v2/export | dates/filters/optional resource | global role | selected tenant | yes | 9D-4A/9E |
| `app/admin/users/page.tsx` | list/role/note/verification/identity/contact | filters/target user | global role | selected tenant + relationship | yes | 9D-4B/9E |
| `app/account/page.tsx`, account export/delete APIs | self update/export/anonymize | caller/self fields | caller UID | account-wide owner contract | no selected tenant required | 9D-4C |
| homepage/admin pages/calendar feed | `get_my_role` | none | global role | `get_my_tenant_role_v1(selected)` | yes | 9D-4D/9E |

No application source change belongs in the planning task. Calls marked 9E must not be broken by an earlier 9D migration.

## 15. Temporary CSK defaults retirement plan

Current default for all seven rows is fixed CSK UUID `c5c00000-0000-4000-8000-000000000001`.

| Table | Current writer(s) | Tenant-aware writer ready now? | Planned explicit/derived tenant | Remove in | Blocker if early? |
|---|---|---:|---|---|---:|
| `reservations` | `create_reservation_v2` (legacy v1 retained) | no | derive `p_lane_id`; explicit INSERT | 9D-5 after 9D-1 prod proof | yes, creates would fail |
| `shooting_lanes` | `admin_create_lane_booking_family_v1` | no | trusted selected tenant argument | 9D-5 after 9D-3 + app cutover | yes |
| `lane_blocks` | `admin_create_lane_block` | no | derive lane | 9D-5 after 9D-3 prod proof | yes |
| `events` | `admin_create_event_v2` | no | trusted selected tenant; lane cross-check | 9D-5 after 9D-2 + app cutover | yes |
| `event_lanes` | event create/update functions | no | inherit verified event tenant explicitly | 9D-5 after 9D-2 prod proof | yes |
| `event_registrations` | `register_for_event` and promotion flows | no | derive event/registration | 9D-5 after 9D-2 prod proof | yes |
| `email_deliveries` | `prepare_confirmation_email` | no | derive typed record and persist | 9D-5 after 9D-2C prod proof | yes |

Retirement is a separate fail-closed migration. Preflight enumerates every INSERT path and fails if any omits `tenant_id`. Postflight proves all seven defaults NULL, columns remain NOT NULL, no business row changed, and second tenant is still blocked.

## 16. Proposed 9D phases

### 9D-0 — frozen catalog and test harness

- Capture production definitions, grants, owners, paths, dependencies and normalized fingerprint.
- Add a manifest that accounts for all 73 functions and prevents unreviewed new definers.
- Add reusable two-tenant roles/fixtures locally only.

### 9D-1A — reservation writers

- Harden `create_reservation_v2`, cancel, attendance, payment and note.
- Explicit tenant INSERT/audit binding; keep active signatures.
- Retire legacy v1 only after zero-caller proof.

### 9D-1B — reservation readers/check-in/conflicts

- Harden check-in, profile batch, busy ranges and owner list.
- Preserve public token minimization and hierarchy semantics.

### 9D-2A — event writers

- Harden register/cancel/approve/payment/confirm and v2 event target writers.
- Introduce versioned tenant-aware event create contract; coordinated app switch required.

### 9D-2B — event lists/public reads

- Tenant-bound admin participant list; versioned selected-tenant admin list.
- Preserve sole-CSK public wrappers until 9E routing supplies tenant context.

### 9D-2C — delivery and promotion claims

- Persist/verify tenant in email and reserve-promotion claim lifecycle.
- Constrain service-role grants to exact completion paths.

### 9D-3 — lane/block/configuration

- 3A resource-derived block/family updates.
- 3B versioned selected-tenant family create and admin configuration list.
- Review internal validators and normalize touched function paths.

### 9D-4 — reports, profiles, account and legacy authorization

- 4A tenant-context reports/export.
- 4B tenant-related user/profile administration.
- 4C owner account lifecycle review.
- 4D remove authorization dependence on global helpers after app callers migrate.
- 4E prepare public selected-tenant contracts for 9E.

### 9D-5 — retirement and final definer audit

- Remove seven defaults only after all writers explicitly set tenant.
- Revoke obsolete v1/service-role grants and retire zero-caller functions.
- Retire CSK role sync/global role helpers only after 9E cutover/reconciliation; if roadmap ordering keeps 9E later, this substep becomes an explicit 9E completion gate rather than being forced prematurely.
- Re-inventory all definers and run the final cross-tenant suite.

Each subphase gets its own migration, focused SQL test, compatibility matrix, production preflight, explicit approval and post-deploy verification. No bulk 73-function migration.

## 17. Cross-tenant test matrix

Run for every RPC class, including positive single-tenant regression:

| Actor / attempt | Tenant A resource | Tenant B resource | Required result |
|---|---|---|---|
| `ADMIN_A` | exact admin operation | same operation | ALLOW A / DENY B |
| `EMPLOYEE_A` | currently allowed operation | same operation | ALLOW A / DENY B; admin-only stays denied |
| `INSTRUCTOR_A` | current approved scope only | same operation | current A behavior / DENY B; no SEC-008 expansion |
| `USER_A` | own A resource | User B or Tenant B resource | ALLOW own where canonical / DENY foreign |
| no membership | privileged A/B | — | DENY |
| pending membership | privileged A/B | — | DENY |
| suspended membership | privileged A/B | — | DENY |
| global `profiles.role=admin`, no membership | privileged A/B | — | DENY |
| caller supplies Tenant B but resource belongs A | resource A | tenant arg B | DENY before read/write/audit |
| mixed resource array A+B | batch/profile/lane IDs | — | fail whole call; no partial data or mutation |
| missing/orphan resource | random UUID | — | stable not-found; no tenant existence leak |
| concurrent writer A/B | independent resources | — | locks/capacity/idempotency remain tenant-bound |

Domain assertions additionally cover capacity/overbooking, reservation cutoffs, event waitlist promotion, email claim idempotency, hierarchy conflicts, pagination/filter totals, CSV PII/formula safety, owner lifecycle, audit actor/timestamp and safe error contracts. Test direct `anon`, `authenticated` and `service_role` EXECUTE matrices against the manifest.

## 18. Rollback strategy

- Before every phase, store exact `pg_get_functiondef`, owner, grants, path and dependency fingerprints.
- Function hardening is deployed with `CREATE OR REPLACE` only where the signature is unchanged. Versioned contracts are additive; old wrappers stay until app cutover.
- Rollback restores only the exact prior functions/grants from a reviewed forward migration; never use `migration repair` or edit applied history.
- If a versioned app/RPC cutover fails, route app calls back to the retained old wrapper while the second-active-tenant guard remains in place.
- Claim/audit schema additions, if proven necessary, use expand -> dual-compatible code -> validate -> contract; do not drop data during 9D.
- Default removal occurs last and has a forward rollback that restores the CSK default only while there is exactly one active CSK tenant. It is never a rollback mechanism after Tenant B.
- Production STOP conditions: unexpected catalog fingerprint, extra pending migration, orphan/mismatched tenant row, unclassified service caller, grant widening, cross-tenant allow, audit drift, runtime regression or second active tenant.

## 19. SEC-004 impact

9D closes the principal RLS-bypass gap by making privileged DB functions resource/tenant aware, restricting service claims and removing legacy definer authorization paths.

It does not close SEC-004. Remaining work:

- 9E: trusted application tenant resolution, routing and selected-tenant context;
- 9F: full reports/events/calendar/check-in cutover to selected tenant;
- 9G: cross-tenant application E2E, concurrency and IDOR proof;
- 9H: final catalog/runtime audit, default/bridge retirement confirmation and controlled second-tenant readiness decision.

SEC-004 may close only after 9H passes. A second tenant cannot be activated during 9D.

## 20. Blocking decisions

Decisions required before their affected later phases, but not before 9D-1A:

1. trusted application tenant selector and host/slug resolution contract (9E; blocks list/create/public cutovers);
2. whether account export/anonymization is account-wide across all memberships or tenant-scoped plus a separate global request;
3. exact tenant relationship that permits admin/employee profile note/identity/contact/verification access;
4. future instructor-event assignment remains deferred; current scope must not be broadened;
5. final sequencing of global-role/sync-bridge retirement: recommended after 9E caller cutover, even if tracked as a 9D-5 exit gate;
6. whether email/rate-limit records need an additional immutable tenant claim column beyond the existing `email_deliveries.tenant_id`, based on phase 9D-2C preflight.

No unresolved decision prevents local 9D-1A implementation because its tenant context is resource-derived and existing business semantics remain authoritative.

## 21. GO / NO-GO

Entry conditions for 9D-1A:

- start from clean `main` at this documentation checkpoint;
- perform a fresh read-only production catalog/fingerprint preflight immediately before implementation;
- freeze the exact current signatures and grants in focused tests;
- modify only reservation-domain functions in the first migration;
- prove Tenant A positive behavior and Tenant B/no-membership/global-role-only denial locally;
- do not remove defaults, activate Tenant B, close SEC-004 or deploy without a separate approval.

SAAS-9D TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-1 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

## 25. SAAS-9D-2B — EVENT MANAGEMENT RPC HARDENING FINAL PLAN

Planning baseline: checkpoint `b37386902b42c12f6902de27e172e516c69ed9d4` on `main`, identical to `origin/main` when this section was prepared. SAAS-9D-2A is closed with production PASS. This section is planning-only: it creates no migration, changes no application file, executes no production write and does not authorize a second tenant.

### 25.1 Exact function scope

SAAS-9D-2B contains exactly nine existing public functions. No 2A registration function and no 2C promotion/e-mail claim function belongs to this phase.

| Function | Signature | Current caller | SECURITY DEFINER | Current auth / global role | Resource argument | Planned tenant derivation | Required role / instructor scope | Cross-tenant risk | Severity |
|---|---|---|---|---|---|---|---|---|---|
| `admin_create_event` | `(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | none found; legacy | yes | `profiles.role` check; service-only EXECUTE | lane IDs only | no runtime derivation retained; retire client/service EXECUTE | owner-only; instructor DENY | service/global legacy entry point | CRITICAL |
| `admin_create_event_v2` | `(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik` | optional lane IDs; empty is valid | exact `active_single_tenant_id_v1()`, then every lane must match | active `admin` or `employee`; instructor DENY | global create and default-owned children | CRITICAL |
| `admin_list_events_v1` | `(text,text,text,integer,integer)` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik`/`instruktor` | none | exact active-single tenant bridge | active `admin`, `employee` or `instructor`; preserve instructor read | global event aggregation | HIGH |
| `admin_set_event_active` | `(uuid,boolean)` | none found; legacy | yes | `profiles.role` check; service-only EXECUTE | event ID | no runtime derivation retained; retire client/service EXECUTE | owner-only; instructor DENY | service/global legacy mutation | CRITICAL |
| `admin_set_event_active_v2` | `(uuid,boolean)` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik` | event ID | locked event -> `events.tenant_id` | active `admin` or `employee`; instructor DENY | foreign event activation/deactivation | CRITICAL |
| `admin_update_event` | `(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | none found; legacy | yes | `profiles.role` check; service-only EXECUTE | event ID and lane IDs | no runtime derivation retained; retire client/service EXECUTE | owner-only; instructor DENY | service/global legacy mutation | CRITICAL |
| `admin_update_event_v2` | `(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik` | event ID and lane IDs | locked event -> tenant; every old/new lane must match | active `admin` or `employee`; instructor DENY | foreign event mutation or mixed-tenant lane binding | CRITICAL |
| `get_public_event_availability_v1` | `()` | no current page caller; retained contract | yes | public, no role check | none | exact active-single tenant bridge | public read; no membership | cross-tenant aggregate mixing | HIGH |
| `get_public_event_list_v2` | `(text,text,integer,integer)` | `app/events/page.tsx` | yes | public, no role check | none | exact active-single tenant bridge | public read; no membership | cross-tenant list/count mixing | HIGH |

No additional participant-management RPC remains in 2B. Registration cancellation, approval, payment, owner reads and participant listing were completed in 2A. Promotion preparation/completion and shared confirmation delivery remain exclusively in 2C.

### 25.2 Risk classification and implementation boundary

The three active event writers are CRITICAL because they bypass RLS and can create or mutate event/lane state. The admin list and public readers are HIGH because an unscoped definer can aggregate foreign-tenant records, and admin list exposes operational event data. The three legacy service-only writers are CRITICAL exposed surface despite having no current caller; their correct treatment is grant retirement, not a new authorization path.

2B changes authorization, tenant predicates and explicit tenant writes only. It must not change validation messages, event dates/times, operating hours, active semantics, conflict-family locking, reservation/lane-block/event conflict rules, pagination, ordering, capacity display, waitlist accounting or DTO shape.

### 25.3 Tenant derivation

- `admin_create_event_v2`, `admin_list_events_v1`, `get_public_event_list_v2` and `get_public_event_availability_v1` have no pre-existing resource from which a tenant can be derived. They call the owner-only `active_single_tenant_id_v1()` bridge and fail closed unless it returns exactly one active tenant.
- `admin_update_event_v2` and `admin_set_event_active_v2` lock/read the target event first and derive authority only from `events.tenant_id`.
- `admin_update_event_v2` validates the persisted `event_lanes.tenant_id`, the event tenant and every requested `shooting_lanes.tenant_id` before deleting or inserting relationships.
- No public signature accepts `tenant_id`; no query, form or browser value becomes an authorization source.
- Event create writes `events.tenant_id` explicitly. Event create/update writes `event_lanes.tenant_id` explicitly from the already-authorized event tenant.
- All conflict reads are additionally constrained to the derived tenant while the existing composite tenant FKs remain the final integrity barrier.

The bridge is valid only while the partial unique active-tenant guard prevents a second active tenant. It is not the selected-tenant design and must be replaced during 9E before second-tenant activation.

### 25.4 Staff authorization and global-role negative contract

Every privileged active 2B function requires `auth.uid()`, an active membership in the derived/resolved tenant and an allowed membership role:

- `admin`: create, update, activate/deactivate and admin list;
- `employee`: same existing management scope as legacy `pracownik`;
- `instructor`: admin event list read only, exactly matching the existing contract;
- `user`, missing membership, pending membership and suspended membership: DENY.

`profiles.role` is not consulted as authority. The critical negative test sets `profiles.role=admin` while omitting an active membership in the target tenant; create, update, activation and admin list must return controlled `not_allowed` and produce no write. Admin/employee A may act on Tenant A and must be denied for Tenant B.

### 25.5 Instructor scope

Instructor access is neither expanded nor redesigned. An instructor with active membership may retain the current `admin_list_events_v1` read scope for that tenant. Instructor remains denied event creation, update, activation/deactivation and every legacy writer. Participant PII scope remains the deferred SEC-008 decision and is not modified by 2B.

### 25.6 Event creation

`admin_create_event_v2` keeps its public signature and caller payload. Its wrapper resolves the exact active tenant and requires active `admin`/`employee` membership before validation or conflict reads. The internal implementation receives that resolved tenant explicitly, rejects every lane outside it, permits an empty lane list only within that resolved tenant, and explicitly writes tenant ownership to event and event-lane rows.

The old application therefore remains compatible without 9E tenant UI. If the active-single invariant is absent or ambiguous, creation fails closed rather than falling back to a default or caller hint. No app-cutover is required for 2B; selected tenant creation remains a 9E dependency.

### 25.7 Event update, deactivation and activation

Update and status changes first lock the event, derive its tenant and authorize the actor in that tenant. Tenant B event IDs are denied to Tenant A staff without revealing the foreign record. Update locks the globally ordered union of old/new conflict families only after confirming that all referenced lanes belong to the event tenant. Cross-tenant lane arrays fail before relationship deletion or any event update.

There is no separate event-cancellation RPC: the product uses `admin_set_event_active_v2` for activation/deactivation. 2B does not invent a new status transition. Existing `no_change`, `created`, `updated`, `activated`, `deactivated`, conflict and validation codes remain stable.

### 25.8 Capacity and status semantics

Current event update validation requires a positive `max_participants` but does not enforce a separate lower bound against the current occupied count. 2B must characterize and preserve that existing contract; it must not silently add a new business rule. Registration capacity remains authoritative in the 2A registration/promotion locks. If local implementation reveals an undocumented capacity invariant rather than the observed behavior, implementation stops for a separate business decision.

Status changes preserve current event/lane conflict checks and do not alter registration, reserve or payment state. Deactivation does not delete event registrations or history.

### 25.9 Event/lane consistency

For every create/update lane assignment the invariant is:

`events.tenant_id = event_lanes.tenant_id = shooting_lanes.tenant_id`.

Event A plus Lane B is denied even for an admin of Tenant A. Mixed A+B arrays, missing lanes, inactive lanes/parents and invalid hierarchy remain atomic failures. Conflict queries for reservations, lane blocks and other events include the derived tenant and retain existing family-lock ordering, so a foreign-tenant row cannot become either an authorization channel or an accidental conflict result.

### 25.10 Participant admin actions

There is no new participant action in 2B. `admin_list_event_registrations_v1`, `approve_event_registration`, `mark_event_registration_paid` and staff cancellation are frozen 2A dependencies. Focused 2B regression must assert their post-2A fingerprints and cross-tenant behavior unchanged; 2B must not duplicate or replace their implementations.

### 25.11 Public contract

Both public readers remain anon/authenticated callable without membership. They resolve the exact active tenant internally, filter events and registration counts to that tenant, preserve `registered + approved` occupied semantics, keep reserve separate and clamp available spots at zero. The return columns/JSON keys, pagination limits and stable ordering remain unchanged and PII-free.

Public mutation permissions remain absent. `/events` continues to call only `get_public_event_list_v2`; `get_public_event_availability_v1` remains a compatible retained contract.

### 25.12 ACL, owner and search path

All nine functions remain owned by `postgres`; no grant is widened.

| Contract group | Target EXECUTE | Target path/definition |
|---|---|---|
| active staff wrappers: create V2, update V2, active V2, admin list | authenticated only | SECURITY DEFINER, SP1 |
| public list and availability wrappers | anon + authenticated only | SECURITY DEFINER, SP1 |
| six private `__saas9d2b_core` implementations | owner only | SECURITY INVOKER, SP1 |
| three legacy admin event functions | owner only | retain definition and SP2, revoke service-role EXECUTE only |

PUBLIC receives no implicit EXECUTE. Service role receives no 2B EXECUTE. The three legacy functions remain present for forward rollback compatibility but have no runtime caller. A frozen zero-caller search is a migration/test precondition.

### 25.13 Application callers

| File | RPC | Arguments | Current tenant/resource context | App change required in 2B |
|---|---|---|---|---|
| `app/admin/events/page.tsx` | `admin_list_events_v1` | search, scope, sort, page, page size | no resource; DB active-single bridge | no |
| `app/admin/events/page.tsx` | `admin_create_event_v2` | event fields and lane ID array | lane array optional; DB resolves tenant | no |
| `app/admin/events/page.tsx` | `admin_update_event_v2` | event ID, event fields, lane ID array | event ID is authoritative | no |
| `app/admin/events/page.tsx` | `admin_set_event_active_v2` | event ID, boolean | event ID is authoritative | no |
| `app/events/page.tsx` | `get_public_event_list_v2` | search, upcoming scope, page, page size | no resource; DB active-single bridge | no |
| none | `get_public_event_availability_v1` | none | no resource; DB active-single bridge | no |
| none | three legacy functions | none | deprecated service surface | no; revoke grant |

No caller currently supplies tenant context, and none will be added in 2B. Host/slug-selected context belongs to 9E.

### 25.14 Normalized production fingerprint baseline

Fingerprint normalization is exactly CRLF and lone CR to LF before MD5. The production baseline captured read-only after the 2A checkpoint is:

| Signature | Source fingerprint | Current path | Current effective grants |
|---|---|---|---|
| `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `26f51acb0a0f56677a86dbddec9974b2` | SP2 | service |
| `admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `6b8d29b11797a346ae9387a9bd3ec6b9` | SP1 | authenticated |
| `admin_list_events_v1(text,text,text,integer,integer)` | `7972f35024b6202a149afbe09f50d5a2` | SP1 | authenticated |
| `admin_set_event_active(uuid,boolean)` | `b547b0c8d2b056273b10fe57f78f89c0` | SP2 | service |
| `admin_set_event_active_v2(uuid,boolean)` | `ad56e445e74634f540425d92ff93acb1` | SP1 | authenticated |
| `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `60301f5e0b290117105bc9637f10d3ce` | SP2 | service |
| `admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `a525123389f3a646cd3da6f26e466ed5` | SP1 | authenticated |
| `get_public_event_availability_v1()` | `40adf74cb5adec5df3b4745fc7851433` | SP1 | anon + authenticated |
| `get_public_event_list_v2(text,text,integer,integer)` | `fe075d7057149b0a0bad0129419a3e99` | SP1 | anon + authenticated |

Every proposed migration fails closed unless all source fingerprints, signatures, owners, paths and grants match its phase baseline. Target fingerprints are calculated only after the reviewed local implementation exists, then frozen in focused tests and the production preflight report. The migration must also prove that 2A and 2C representative fingerprints are unchanged.

### 25.15 Temporary CSK defaults

| Table | 2B writer | Current default | Explicit after 2B | Default still required | Removal phase |
|---|---|---|---|---|---|
| `events` | `admin_create_event_v2` | bootstrap CSK tenant | yes, resolved tenant | yes for other legacy compatibility | 9D-5/9E cutover gate |
| `event_lanes` | create/update V2 | bootstrap CSK tenant | yes, event tenant | yes for other legacy compatibility | 9D-5/9E cutover gate |
| `event_registrations` | none in 2B | bootstrap CSK tenant | already explicit in 2A register path | yes pending all legacy writers | 9D-5 |
| `email_deliveries` | none in 2B | bootstrap CSK tenant | deferred to 2C | yes | after 2C production proof and 9D-5 gate |
| `audit_logs` | no 2B writer currently writes event-management audit | none | unchanged | not applicable | no change |

No default is removed in 2B. The explicit gate remains: remove compatibility defaults before selected-tenant writer cutover and before a second active tenant.

### 25.16 Concurrency test plan

Focused deterministic two-session tests must cover:

1. two overlapping creates on the same conflict family: exactly one create, one controlled conflict;
2. simultaneous independent Tenant A/Tenant B event operations: no cross-tenant conflict leak or deadlock;
3. update swapping old/new lane families in opposite order: global lock ordering, no deadlock;
4. simultaneous updates of one event: serialized existing behavior with no partial event-lane replacement;
5. activate versus overlapping reservation/lane block/event creation: existing conflict result remains deterministic;
6. update versus registration while capacity changes: observed current capacity contract remains stable and registration never overbooks;
7. mixed-tenant lane array under concurrent change: DENY before event or event-lane mutation;
8. no-change update/activation: no extra write and stable response;
9. public/admin list during a committed mutation: bounded consistent result and no PII/cross-tenant row.

Reuse the existing hierarchy event concurrency and final cross-writer harnesses. Add a focused 2B harness only where existing barriers cannot prove tenant separation. No production stress test is planned.

### 25.17 Cross-tenant and authorization matrix

- Admin A: create/list/update/activate Event A ALLOW; Event B DENY.
- Employee A: preserve create/list/update/activate scope in A; B DENY.
- Instructor A: admin list A ALLOW; every management mutation DENY; B list DENY.
- User, no membership, pending and suspended membership: all privileged calls DENY.
- Global legacy admin profile without active target membership: all active privileged 2B calls DENY.
- Event A plus Lane B, mixed A+B lane list and tenant-spoof attempt: DENY atomically.
- Public list/availability: anon and authenticated ALLOW for the exact active tenant, no membership required, no PII.
- Legacy service functions: service-role EXECUTE DENY after retirement.
- 2A participant operations and 2C claim functions: fingerprints and grants unchanged.

Every denial must leave event, event-lane, registration and audit counts unchanged. Fixture cleanup must equal zero.

### 25.18 Service-role analysis

Only the three legacy event management functions currently grant service-role EXECUTE; repository-wide caller search finds no TypeScript/JavaScript caller. Their internal reliance on `auth.uid()` plus global profile role is not a valid service business-authorization model. 2B revokes service EXECUTE and leaves them owner-only.

No active V2 writer, admin reader or public reader grants service-role EXECUTE today, and 2B preserves that. Service role is never treated as automatic business authorization. The service-only promotion/e-mail claims belong to 2C and are untouched.

### 25.19 Proposed migration split and local sequence

Implement locally in two separately reviewable migrations, without creating either during this planning task:

1. **9D-2B-1 — staff event management**: harden `admin_create_event_v2`, `admin_update_event_v2`, `admin_set_event_active_v2`, `admin_list_events_v1`; create four non-client invoker cores; retire service EXECUTE on the three zero-caller legacy functions while preserving their bodies, signatures, owners and SP2 paths. Add focused SQL, ACL/inventory updates and management concurrency coverage.
2. **9D-2B-2 — public event readers**: tenant-scope `get_public_event_list_v2` and `get_public_event_availability_v1` behind two non-client invoker cores while preserving exact public signatures/DTO/grants. Add PII-free, availability, pagination and public browser regressions.

Order is 2B-1 local PASS and review, then 2B-2 local PASS and review. Each phase gets its own production preflight, SHA, dry-run, explicit deployment approval and rollback-only postflight. Both are DB-first and old-app compatible because public signatures and result contracts remain unchanged.

### 25.20 Test and regression plan

For each subphase run focused 2B SQL and ACL tests, tenant A/B IDOR matrix, no-membership/pending/suspended/global-role negatives, event/lane composite-FK checks, RLS recursion checks, direct-DML denial and fixture cleanup. Run the existing event hierarchy/concurrency harnesses, 2A regression, full Supabase DB suite, all Node tests, TypeScript, production build, Events/Admin Events Playwright at mobile and desktop widths, `npm audit --omit=dev`, changed-files ESLint and `git diff --check`.

2B-2 additionally proves public anon/authenticated parity, PII-free keys, counts for registered/approved/reserve/cancelled, sold-out clamp, pagination <=50, stable order and no fetch-all/N+1 regression. All tests remain local until a separately approved production preflight.

### 25.21 Rollback plan

- Capture exact phase-specific definitions, owners, grants, paths and normalized fingerprints before implementation and again before deployment.
- Preserve every public signature and response contract so application rollback remains possible.
- Rollback is a reviewed forward migration restoring only the prior definitions/grants for the affected subphase; never edit an applied migration and never use migration repair.
- Do not remove tenant columns, memberships, composite FKs, the single-active guard or temporary defaults.
- STOP on baseline drift, unexpected caller, grant widening, mixed-tenant allow, public PII, changed business code, concurrency regression, nonzero fixture or unexpected pending migration.

### 25.22 SEC-004 impact, blockers and verdict

Already closed by 9D-2A: event registration owner/staff global-role bypasses for registration, cancellation, approval, payment, promotion confirmation, My Events and participant listing.

9D-2B will close: global staff authority in active event create/update/activate/list, unscoped event/public aggregation, mixed-tenant event-lane assignment through these writers, and the three unused legacy service event-management entry points.

Still open afterward: 9D-2C event promotion/e-mail claim boundaries; 9D-3 lane/block/configuration RPC; 9D-4 reports/profile/account helpers; 9D-5 compatibility retirement; 9E trusted tenant selection/routing; 9F module cutover; 9G full cross-tenant E2E/concurrency; and 9H final SEC-004/second-tenant audit.

No unresolved business decision blocks local 2B-1. The active-single bridge and current role mapping are already approved architecture. The absent capacity-floor rule is explicitly preserved rather than invented. A second tenant and selected-tenant UI remain prohibited.

SAAS-9D-2B TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2B LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 30. SAAS-9D-2C-1 local implementation result

SAAS-9D-2C-1 was implemented locally after checkpoint
`0b5188fdd9fbbd07b56c2ce2c0378ca0c82a4729`.

Exact scope:

- `prepare_confirmation_email(text,uuid)`: tenant/resource/membership body
  hardening, authenticated-only SECURITY DEFINER retained and normalized to
  SP1;
- `complete_confirmation_email(uuid,boolean,text,text)`: tenant/resource/
  recipient body hardening and service-only SECURITY INVOKER conversion;
- `check_confirmation_email_rate_limit(uuid,text)`: exact fingerprint,
  metadata, limits and service-only ACL preserved unchanged.

The two reserve-promotion functions remain untouched in 2C-2. No application
file changed.

Local verification:

- database reset: PASS;
- focused SQL: 44/44 PASS;
- real prepare/complete concurrency: PASS, with zero deadlocks, broken
  invariants or duplicate effects;
- 2A, 2B-1 and 2B-2 regressions: PASS;
- full DB suite: 31 files / 936 tests PASS;
- Node: 734/734 PASS;
- TypeScript and build: PASS;
- focused Events Playwright: 8/8 PASS;
- fixture cleanup: every tracked category 0;
- SECURITY DEFINER inventory: 73 -> 72 with zero unrelated drift;
- compatibility defaults: 7/7 retained.

Migration:

`20260914100000_harden_shared_confirmation_email_rpcs.sql`

SHA-256:

`C7CCEAD3B0A5ACE67AFE05D87EE6966B885C5BC1111926F01ACD970D7A31E0F1`

Detailed evidence is recorded in
`SAAS_9D_2C1_SHARED_RPC_HARDENING_REPORT.md`.

SAAS-9D-2C-1 LOCAL: **PASS**

READY FOR SAAS-9D-2C-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2C-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 29. SAAS-9D-2C — REMAINING EVENT / SHARED RPC HARDENING FINAL PLAN

This section is planning-only and is based on production after the completed
SAAS-9D-2A, 2B-1 and 2B-2 deployments. The reproducible 2B-2 checkpoint is
`0b5188fdd9fbbd07b56c2ce2c0378ca0c82a4729` on `main`, identical to
`origin/main` when this plan was prepared. No migration, SQL write,
application change or production deployment is authorized here.

### 29.1 Exact 2C function inventory

The exact 2C review boundary contains five existing functions. No function
from 9D-3, 9D-4 or 9D-5 is moved into this phase.

| Function | Current callers | Mode / owner / path | Current grants | Current authorization | Tenant/resource derivation | RLS bypass and cross-tenant risk | Severity |
|---|---|---|---|---|---|---|---|
| `check_confirmation_email_rate_limit(uuid,text)` | three mail API routes through a service client | DEFINER / postgres / `public, pg_temp` | service_role only | route verifies the user; function trusts supplied user UUID plus HMAC IP hash | global user/IP anti-abuse scope; no tenant-owned target | definer is required because service_role has no table ACL; no tenant data is read, but an arbitrary service call can affect another user's rate bucket | MEDIUM |
| `prepare_confirmation_email(text,uuid)` | event-registration confirmation, reservation confirmation and reservation cancellation routes, using caller JWT | DEFINER / postgres / `public, pg_temp` | authenticated only | owner checks for confirmation paths; cancellation staff fallback uses global `profiles.role` | message type + record ID -> reservation or registration -> event -> tenant | bypasses RLS and currently inserts `email_deliveries` using the CSK default rather than a proved tenant; staff branch is globally authorized | CRITICAL |
| `complete_confirmation_email(uuid,boolean,text,text)` | the same three routes through the service completion client | DEFINER / postgres / `public, pg_temp` | service_role only | opaque delivery claim ID | claim -> delivery -> typed record -> tenant | completion updates by claim only and does not re-prove delivery tenant, typed target tenant and recipient equality | HIGH |
| `prepare_event_reserve_promotions(uuid)` | `lib/server/event-reserve-promotion.ts`, called after cancellation and by the manual promotion API | DEFINER / postgres / `public, pg_temp` | service_role only | service credential; manual route currently checks global profile role | event ID -> event tenant; reserve registrations must match it | counts and claims registrations by global event ID without explicit tenant predicates; manual route can authorize a global role with no membership | CRITICAL |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `lib/server/event-reserve-promotion.ts` after provider outcome | DEFINER / postgres / `public, pg_temp` | service_role only | registration ID + claim ID | registration -> event -> tenant; claim is stored on the registration | exact claim equality is checked, but event/registration tenant equality is not explicitly re-proved | CRITICAL |

Production normalized fingerprints frozen for implementation preflight:

| Signature | Normalized MD5 |
|---|---|
| `check_confirmation_email_rate_limit(uuid,text)` | `e693411c3fc7f24510313e60a1d8e2a5` |
| `prepare_confirmation_email(text,uuid)` | `449dbd830a7ece7f0c5b8b046dc1ee2c` |
| `complete_confirmation_email(uuid,boolean,text,text)` | `8ca5430a2d7e625d10ebc61617a03dd5` |
| `prepare_event_reserve_promotions(uuid)` | `4e73ef1df59936a1a3f41a00e121f6e9` |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `dd5025876008d6eb9551497d84cef90e` |

All five exist exactly once, are currently SECURITY DEFINER, owned by
`postgres`, and have no PUBLIC or anon EXECUTE. `prepare_confirmation_email`
is authenticated-only; the other four are service-only.

### 29.2 Classification and target decision

| Function | Classification | Target decision |
|---|---|---|
| `prepare_confirmation_email` | A. BODY HARDENING REQUIRED | retain one authenticated SECURITY DEFINER signature, normalize to SP1, derive tenant from the typed resource, require owner or active same-tenant admin/employee membership, write tenant explicitly |
| `complete_confirmation_email` | A + C. BODY HARDENING AND DEFINER REMOVAL CANDIDATE | change to SECURITY INVOKER, SP1, service-only; service_role already has exact DML on `email_deliveries`; verify claim/delivery/typed-target/recipient tenant consistency before completion |
| `prepare_event_reserve_promotions` | A + C + E. BODY HARDENING, DEFINER REMOVAL, APP DEPENDENCY | change to SECURITY INVOKER, SP1, service-only; derive and filter the event tenant; complete manual-route membership cutover in the same 2C-2 release |
| `complete_event_reserve_promotion` | A + C. BODY HARDENING AND DEFINER REMOVAL CANDIDATE | change to SECURITY INVOKER, SP1, service-only; verify registration/event tenant consistency and exact current claim before completion |
| `check_confirmation_email_rate_limit` | D. SAFE / NO BODY CHANGE | preserve fingerprint, DEFINER and service-only ACL in 2C; this is intentionally global anti-abuse state and service_role has no direct table ACL, so converting it would require an unjustified table grant; path normalization is deferred to the final 9D-5 inventory review |

No ACL-only cleanup is required in 2C: current effective function grants are
already the narrow target. No grant is widened. The expected public-schema
SECURITY DEFINER count after both 2C slices is **70**, reduced from 73 by
converting the three service-only claim functions above to invoker. The rate
limit definer and authenticated prepare wrapper remain.

### 29.3 Production data preflight

The read-only production preflight found:

- 11 `email_deliveries`, all `reservation_confirmation`;
- zero unknown message types;
- zero null delivery tenants;
- zero reservation or event-registration target/tenant/recipient issues;
- zero active or expired delivery claims;
- zero active or expired promotion claims;
- zero promotion registration/event tenant issues.

No data migration or new tenant-claim column is required. `email_deliveries`
already has `tenant_id`; promotion claims live on the tenant-owned
`event_registrations` row. Implementation preflight must repeat these counts
and stop on an unknown type, orphan or mismatch.

### 29.4 Caller inventory

| Caller | Functions | Auth context | Tenant context | Resource context | Application change required |
|---|---|---|---|---|---|
| `app/api/send-event-registration-confirmation/route.ts` | rate limit, prepare confirmation, complete confirmation | verified user JWT for reads/prepare; service client only for rate-limit/completion | registration -> event tenant | owner registration ID | no signature change; DB enforcement only |
| `app/api/send-reservation-confirmation/route.ts` | rate limit, prepare confirmation, complete confirmation | verified owner JWT; service completion | reservation tenant | owner reservation ID | no signature change |
| `app/api/send-reservation-cancellation/route.ts` | rate limit, prepare confirmation, complete confirmation | verified JWT; current route also reads legacy profile role; service completion | reservation tenant | owner or staff cancellation reservation ID | no signature change; DB membership becomes authoritative even if legacy UI precheck remains temporarily |
| `app/api/cancel-event-registration/route.ts` | indirect promotion prepare/complete | cancellation RPC authenticates owner/staff; helper receives only the event ID returned by that successful RPC | hardened cancellation result -> event tenant | registration -> event | no request-contract change |
| `app/api/send-event-reserve-promotion/route.ts` | indirect promotion prepare/complete | verified user JWT, but current authorization uses global `profiles.role` | currently absent before service call | browser event ID | **yes in 2C-2**: derive event tenant through authenticated DB context and require active admin/employee membership before service invocation |
| `lib/server/event-reserve-promotion.ts` | promotion prepare/complete and service table reads | server-only service credential | derived inside hardened DB prepare; registration IDs returned by that claim | event ID plus exact prepared registration/claim pairs | retain server-only boundary and signatures; do not accept browser tenant ID |

There is no SQL-to-SQL, cron or background caller for these five functions.
Tests and security reports call them only as regression surfaces. Direct
service helper invocation remains an infrastructure boundary; it is not by
itself business authorization.

### 29.5 Tenant derivation and authorization

`prepare_confirmation_email` must use a message-type allowlist and derive the
tenant as follows:

- `reservation_confirmation` and `reservation_cancellation`: lock the
  reservation and take `reservations.tenant_id`;
- `event_registration_confirmation`: lock the registration, require its
  non-null `event_id`, load the event, and prove
  `registration.tenant_id = event.tenant_id`;
- derive `recipient_user_id` only from that resource, never from request data;
- insert `email_deliveries.tenant_id` explicitly and reject an existing
  delivery whose tenant, record type, record ID or recipient differs.

Owner confirmation requires `auth.uid() = resource.user_id` plus an active
membership in the resource tenant. Cancellation email preparation permits the
same owner or active tenant membership role `admin`/`employee`. Global
`profiles.role`, pending membership, suspended membership, no membership,
user/instructor membership for staff actions and cross-user/cross-tenant IDs
all deny. Existing status eligibility remains unchanged.

`prepare_event_reserve_promotions` locks the event, derives its tenant, counts
only registrations with both matching `tenant_id` and `event_id`, and claims
only reserve registrations in that same tenant. `complete_event_reserve_promotion`
locks the supplied registration, loads its event, proves equal tenants and
then requires the exact current claim ID. Neither accepts tenant ID.

The manual promotion route must replace the global profile-role decision with:

1. authenticated event lookup to derive its stored tenant;
2. `has_tenant_role_v1(derived_tenant_id, ['admin','employee'])` under the
   caller JWT;
3. fail-closed not-found/forbidden behavior before creating a service client;
4. invoke the service helper only with the already-checked event ID.

The tenant UUID is not accepted from the browser. The event tenant is
immutable through client paths, so the lookup plus membership check does not
create a tenant-switch TOCTOU window.

### 29.6 Service-role model

The three completion/promotion functions remain callable only by
`service_role`, but service possession is not treated as business authority:

- mail routes authenticate the actor before creating a delivery claim;
- completion can touch only the exact claim produced by authenticated
  prepare and must re-prove the typed target tenant;
- owner cancellation may promote only the event ID returned by the successful
  hardened cancellation RPC;
- manual promotion must pass the event-derived membership precheck;
- provider recipient reads use only registration IDs returned by the
  tenant-filtered prepare function;
- no browser receives a service credential, claim tenant or arbitrary
  recipient selector.

Production ACL confirms service_role has the table privileges required for
the three proposed invoker functions on `email_deliveries`, `events` and
`event_registrations`. It has no table privilege on
`confirmation_email_rate_limits`, which is why that one narrow definer is
retained rather than widening table ACL.

### 29.7 Public, token, owner, staff and server paths

- **Public read:** none of the five functions is public; public Events readers
  remain the completed 2B-2 contracts and receive no membership requirement.
- **Public token action:** reserve-promotion confirmation is already hardened
  in 2A and remains outside 2C. Token -> registration -> event tenant,
  expiration, owner binding and single-use semantics must regress PASS.
- **Owner action:** confirmation/cancellation delivery prepare is actor JWT +
  owned resource + active membership + resource tenant.
- **Staff action:** cancellation preparation and manual promotion require
  active same-tenant admin/employee membership.
- **Server action:** only rate limiting and exact prepared-claim completion or
  promotion use service_role.

No token alone authorizes a 2C mutation. Promotion token generation is bound
to a tenant-filtered reserve registration. Tokens remain UUIDs, expire after
24 hours, and confirmation remains single-use/idempotent under the completed
2A contract. Full tokens, claims, recipient PII and provider errors remain
absent from logs and public responses.

### 29.8 ACL, owner and search path target

| Function | Target mode | Owner | Target search path | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---:|---:|---:|---:|
| rate limit | DEFINER | postgres | retain current SP2 in 2C | no | no | no | EXECUTE |
| prepare confirmation | DEFINER | postgres | SP1 | no | no | EXECUTE | no |
| complete confirmation | INVOKER | postgres | SP1 | no | no | no | EXECUTE |
| prepare promotions | INVOKER | postgres | SP1 | no | no | no | EXECUTE |
| complete promotion | INVOKER | postgres | SP1 | no | no | no | EXECUTE |

SP1 means `pg_catalog, public, pg_temp`. All touched identifiers are schema
qualified. The migration must revoke from all four application roles before
granting back only the exact target role. The unchanged rate-limit function
is fingerprint-frozen in both preflight and postflight.

### 29.9 Signature and response compatibility

All five signatures, parameter defaults, return shapes and stable business
codes remain unchanged. No tenant argument is added. Existing callers continue
to pass record, event, registration and claim IDs in the same order.

Compatibility by slice:

| State | 2C-1 shared delivery | 2C-2 promotion |
|---|---|---|
| old app + old DB | current behavior | current behavior |
| old app + new DB | safe for single-active CSK; DB enforcement is stricter and signatures unchanged | safe while second tenant remains blocked; manual route still has legacy precheck until app release |
| new app + old DB | no app change in 2C-1 | membership precheck improves authorization but service RPC bodies remain globally scoped |
| new app + new DB | tenant-bound | tenant-bound |

Recommended rollout for 2C-2 is **DB first followed immediately by APP in one
controlled low-traffic release window**, with the second-active-tenant guard
unchanged. The phase is not complete until both sides pass production smoke.

### 29.10 Concurrency and idempotency

The implementation must preserve and test:

1. two parallel delivery prepares for one typed record: exactly one `ready`,
   the other `in_progress` or `already_sent`;
2. completion with the exact current claim only; foreign and superseded claim
   IDs deny;
3. repeated successful completion returns no second mutation or send state;
4. provider failure clears only its claim, stores a bounded technical code and
   retains the existing three-attempt/24-hour bound;
5. a delayed completion may succeed only while its claim remains the current
   claim; a re-claimed record makes the old completion fail;
6. two parallel promotion prepares serialize on the event and cannot claim or
   email the same reserve registration twice;
7. reserve ordering remains `created_at,id`, capacity uses only registered and
   approved statuses, and reserve does not occupy capacity;
8. cancellation and manual promotion races do not exceed capacity or create
   duplicate active claims;
9. success/failure promotion completion remains idempotent for the same exact
   registration/claim pair;
10. rate-limit user and HMAC-IP scopes retain their current atomic behavior.

### 29.11 Cross-tenant test matrix

Minimum focused tests for each applicable path:

| Scenario | Expected |
|---|---|
| Tenant A resource + active authorized Tenant A caller | ALLOW |
| Tenant B resource + Tenant A caller | DENY |
| global `profiles.role=admin/pracownik` without membership | DENY |
| pending membership | DENY |
| suspended membership | DENY |
| no membership | DENY |
| instructor/user attempting staff action | DENY |
| owner A on another user's resource | DENY |
| browser-supplied tenant spoof | impossible by request contract / DENY |
| delivery tenant differs from typed target tenant | DENY, no state change |
| delivery recipient differs from target owner | DENY, no state change |
| promotion registration tenant differs from event tenant | DENY |
| claim from Tenant B paired with Tenant A registration/event | DENY |
| claim/token replay after successful completion | controlled no-change |
| service direct call without a valid current claim | DENY |

Tests must also prove the legal owner, admin and employee paths, public Events
2B-2 regression, event registration 2A regression, reservation 9D-1
regression, SEC-006 HTML escaping, SEC-015 cancellation delivery, safe errors,
PII minimization and zero fixture.

### 29.12 Full SECURITY DEFINER inventory after 2B-2

Production contains exactly 73 SECURITY DEFINER functions. Every signature is
accounted for below; there is no UNKNOWN classification.

**Already hardened or safe retained (29):**

`admin_create_event_v2`, `admin_list_event_registrations_v1`,
`admin_list_events_v1`, `admin_set_event_active_v2`, `admin_update_event_v2`,
`approve_event_registration`, `cancel_event_registration`,
`cancel_reservation`, `confirm_event_reserve_promotion`,
`create_reservation_v2`, `get_check_in_reservation_v1`,
`get_lane_booking_busy_ranges`, `get_lane_booking_busy_ranges_v2`,
`get_lane_booking_busy_ranges_v3`, `get_my_event_registrations_v1`,
`get_my_reservations_v2`, `get_public_check_in_status_v1`,
`get_public_event_availability_v1`, `get_public_event_list_v2`,
`get_reservation_customer_profiles_v1`, `mark_event_registration_paid`,
`register_for_event`, `update_reservation_admin_note`,
`update_reservation_attendance`, `update_reservation_payment`,
`get_my_tenant_role_v1`, `has_tenant_role_v1`,
`is_active_public_tenant_v1`, `is_tenant_member_v1`.

**9D-2C (5):** the five exact signatures in section 29.1.

**9D-3 lane/block/configuration (13):**

`admin_create_lane_block`, `admin_create_lane_booking_family_v1`,
`admin_get_lane_booking_configuration_v1`,
`admin_get_lane_booking_configuration_v2`,
`admin_set_lane_block_active`, `admin_set_lane_booking_configuration`,
`admin_set_lane_booking_family_configuration_v2`, `admin_update_lane_block`,
`lane_booking_family_business_snapshot_v2`,
`normalize_lane_booking_family_payload_v2`,
`validate_lane_booking_rule_capacity`,
`validate_shooting_lane_capacity_change`,
`validate_shooting_lane_hierarchy`.

**9D-4 / 9E reports, profiles, lifecycle and authorization (19):**

`admin_get_reservation_report_export_v1`,
`admin_get_reservation_report_v1`, `admin_get_reservation_report_v2`,
`admin_list_users_v1`, `admin_set_user_note_v1`, `admin_set_user_role_v1`,
`anonymize_my_account_v1`, `export_my_data_v1`, `get_my_role`,
`get_public_booking_configuration_v1`, `handle_new_user`, `is_admin`,
`is_admin_or_employee`, `is_admin_or_staff`,
`prevent_non_admin_profile_privilege_changes`, `update_my_profile_v1`,
`update_profile_contact_details`, `update_profile_identity`,
`update_profile_verification`.

**9D-5 / 9E retirement or bridge gate (7):**

`active_single_tenant_id_v1`, the owner-only legacy
`admin_create_event`, `admin_set_event_active`, `admin_update_event` and
`create_reservation`, plus `sync_csk_membership_role_to_profile` and
`sync_profile_role_to_csk_membership`.

After converting three 2C service functions to invoker, the projected count
is 70. Later counts may change only in their assigned reviewed phase.

### 29.13 Temporary CSK defaults

All 7/7 compatibility defaults remain and are not removed in 2C planning.

| Table | Current active writers | Tenant-aware now? | Still depends on default? | Target removal gate |
|---|---|---:|---:|---|
| `shooting_lanes` | lane-family/configuration writers | no; 9D-3 pending | yes | 9D-5 after 9D-3 production proof |
| `reservations` | hardened `create_reservation_v2` | yes, explicit tenant | no active V2 dependency | 9D-5 after legacy retirement verification |
| `lane_blocks` | lane-block writers | no; 9D-3 pending | yes | 9D-5 after 9D-3 production proof |
| `events` | hardened event V2 create/update | yes, explicit tenant | no active V2 dependency | 9D-5 after 2C and 9D-3/4 gates |
| `event_lanes` | hardened event V2 create/update | yes, explicit event tenant | no active V2 dependency | 9D-5 |
| `event_registrations` | hardened register/promotion contracts | registration owner writers are explicit; promotion updates existing rows | no new-row 2C dependency | 9D-5 after event domain proof |
| `email_deliveries` | `prepare_confirmation_email` | **not yet** | **yes** | 9D-5 only after 2C-1 production proof |

The mandatory gate remains: **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER
CUTOVER AND BEFORE SECOND TENANT**.

### 29.14 Proposed split, implementation order and tests

#### SAAS-9D-2C-1 — shared confirmation delivery

1. freeze all three shared function definitions/ACL plus delivery constraints;
2. fail preflight on any unknown/orphan/mismatched delivery;
3. harden `prepare_confirmation_email` with resource tenant, membership and
   explicit delivery tenant;
4. convert/harden `complete_confirmation_email` as service-only invoker;
5. preserve `check_confirmation_email_rate_limit` exactly;
6. add focused owner/staff/cross-tenant/claim/concurrency tests;
7. run every reservation/event email, SEC-006, SEC-009 and SEC-015 regression;
8. run full DB, Node, TypeScript, build, focused Playwright and diff checks.

Expected migration: one new 2C-1 SQL migration and one focused SQL test. No
application change is expected.

#### SAAS-9D-2C-2 — reserve promotion claims

1. freeze both promotion functions, event/registration constraints and the
   manual/cancellation caller contracts;
2. harden both functions with explicit tenant consistency and convert them to
   service-only invokers;
3. replace the manual route's global role lookup with event-derived active
   admin/employee membership;
4. keep the cancellation path bound to the event ID returned by the hardened
   cancellation RPC;
5. add deterministic parallel prepare/complete/cancellation tests and IDOR
   tests;
6. run all 2A/2B/event availability/public DTO, email, reservation and
   operational Playwright regressions;
7. deploy DB first and APP immediately afterward under a separate approved
   coordinated rollout, then run postflight.

Expected files: one 2C-2 SQL migration, focused SQL test,
`app/api/send-event-reserve-promotion/route.ts` and its focused Node tests.
`lib/server/event-reserve-promotion.ts` should change only if tests prove an
additional server-side tenant assertion is required; its public helper
signature should otherwise remain stable.

### 29.15 Rollback

- Every migration freezes normalized production fingerprints, exact overload
  count, owner, search path and grants and aborts on drift.
- Database rollback is a reviewed forward migration restoring only the
  previous bodies/security modes/paths/grants for that slice; never use
  migration repair or edit an applied migration.
- 2C-1 signatures are backward-compatible, so application rollback is not
  required.
- After 2C-2 DB-first deployment, the old app remains functional while the
  single-active guard is enforced. If the app deployment fails, keep Tenant B
  blocked and either retry the app or deploy the reviewed forward DB rollback.
- The new manual-route precheck is compatible with the old DB; rolling the app
  back after the new DB does not break signatures but reopens the route-level
  authorization gap until restored.
- Never roll back tenant columns, memberships, composite FKs, the active
  tenant guard or completed 9D-1/2A/2B work.

STOP conditions are fingerprint/ACL drift, unknown delivery type, orphan or
tenant mismatch, active claim that cannot be reconciled, global-role-only
authorization, widened grant, cross-tenant allow, duplicate send/promotion,
capacity regression, PII/secret leak, nonzero fixture or any extra pending
migration.

### 29.16 SEC-004 impact and residual work

2C closes the remaining event-domain service claim boundaries: typed email
delivery tenant ownership, exact delivery completion, tenant-filtered reserve
claim creation/completion and manual promotion authorization. It completes
the planned 9D-2 event/shared scope.

It does not close SEC-004. Remaining work stays assigned to:

- 9D-3: lane, block and lane-configuration definers;
- 9D-4: reports, users/profiles, account lifecycle and global role helpers;
- 9D-5: legacy function/default/CSK bridge retirement and final definer audit;
- 9E: trusted selected-tenant application context and routing;
- 9F: reports/events/calendar/check-in selected-tenant cutover;
- 9G: full application cross-tenant IDOR and concurrency suite;
- 9H: SEC-004 closure and second-tenant readiness decision.

### 29.17 Blocking decisions and final gate

No unresolved business decision blocks local 2C-1. Its tenant derivation,
owner/staff roles, delivery types and compatibility contract are explicit.

Local 2C-2 is also implementation-ready provided its approved scope includes
the narrowly required manual-route authorization change described above. No
new RPC, tenant selector or browser tenant argument is needed. Production
deployment remains separately gated per slice and 2C-2 requires coordinated
DB/application approval.

SAAS-9D-2C TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2C LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 28. SAAS-9D-2B-2 local implementation result

SAAS-9D-2B-2 was implemented locally in the single migration
`20260913150000_harden_public_event_readers.sql`. The approved wrapper/core
design is now concrete:

- `get_public_event_availability_v1()` and
  `get_public_event_list_v2(text,text,integer,integer)` retain their exact
  signatures, defaults, stable 13-field public DTO and anon/authenticated
  grants;
- each wrapper resolves only `active_single_tenant_id_v1()` and calls one
  owner-only `SECURITY INVOKER` core;
- both cores independently filter `events` and `event_registrations` by the
  resolved tenant and join counts on both tenant and event ID;
- zero or multiple active tenants return a safe empty public result, while
  invalid list input still returns `invalid_input`;
- no application caller, route, parser, writer, RLS policy, temporary CSK
  default or unrelated RPC changed.

The focused rollback-only SQL suite passed 40/40 checks across Tenant A and
Tenant B, including one-active A, one-active B, zero-active, two-active,
Event A plus Registration B, Event A plus Lane B, canonical count semantics,
anon parity, exact DTO/PII allowlisting, pagination, filters and stable sort.
The full database suite passed 892/892 checks after updating three historical
test assertions that intentionally described the pre-2B-2 function inventory,
global-reader boundary and wrapper fingerprints. All 734 Node tests,
TypeScript, the production build, Events Playwright 8/8 and lane-family/admin
Playwright 5/5 passed. Local fixture post-check was zero for tenants, events,
registrations, lanes and memberships.

Migration SHA-256:
`9E2E1A8530CCFB1A17AC5926F22E885033D0957788B0A27776637A82B35293DD`.

SAAS-9D-2B-2 LOCAL: **PASS**

READY FOR SAAS-9D-2B-2 PRODUCTION PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR SAAS-9D-2C: **NO-GO until review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 24. SAAS-9D-2A local implementation result

SAAS-9D-2A was implemented locally in `20260912100000_harden_event_registration_rpcs.sql` for exactly the seven approved event-registration contracts. The public signatures and response shapes remain unchanged. Each reviewed business implementation is retained as a non-client `SECURITY INVOKER` core behind a postgres-owned, SP1 `SECURITY DEFINER` wrapper that derives tenant ownership from the event, registration or promotion token target.

The registration core now writes `v_event.tenant_id` explicitly. Approval, cancellation and payment audits write the registration tenant explicitly. My Events joins active membership and active tenant state to each returned registration. Owner cancellation and promotion confirmation require both `auth.uid()` ownership and active target-tenant membership; staff operations use the active membership role and never trust `profiles.role` alone. Instructor participant access remains at its pre-existing, deferred SEC-008 scope.

All seven wrappers are `authenticated`-only; `PUBLIC`, `anon` and `service_role` have no EXECUTE. All seven cores have no client/service EXECUTE. The total public-schema `SECURITY DEFINER` inventory remains 73. Preflight fingerprints, owner and ACL guards fail closed, and the migration is fully transactional. Representative 2B/2C fingerprints are frozen in focused tests and remain unchanged.

Local evidence:

- clean `supabase db reset`: PASS;
- focused SAAS-9D-2A SQL: 32/32 PASS;
- full Supabase DB suite: 28 files / 820 tests PASS;
- real two-session registration race at capacity 1: exactly one `registered`, one `reserve`, cleanup 0;
- Node: 734/734 PASS;
- TypeScript and production build: PASS;
- focused Events/My Events/Admin Events/Booking/Admin Playwright: 14/14 PASS;
- synthetic fixture post-check: zero auth users, profiles, events, registrations and audits.

SAAS-9D-2A LOCAL: **PASS**

EVENT RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED for the seven 2A contracts**

READY FOR SAAS-9D-2A PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2B: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 22. SAAS-9D-2 — EVENTS RPC HARDENING FINAL PLAN

Planning baseline: `d8fe265ccd00b607b3dc99cc53f5c2320c40cc08` on `main`, after the reproducible SAAS-9D-1 checkpoint and production PASS. This section is planning-only. It does not create a migration, change an application caller, authorize a production write or permit a second active tenant.

### 22.1 Exact function inventory and severity

The local catalog reconstructed from the production migration history still contains 73 `SECURITY DEFINER` functions. The 9D-2 boundary contains 20 of them: 19 event-named/event-target functions plus the shared `complete_confirmation_email` claim finalizer. All 20 are owned by `postgres` and bypass table RLS by design.

`SP1` means `pg_catalog, public, pg_temp`; `SP2` means `public, pg_temp`. Grants below are the effective client/service grants in the current catalog, excluding owner `postgres`.

| Function and exact identity arguments | Caller | Path / grants | Current authorization | Resource / tenant derivation | Operation | Current cross-tenant risk | Severity | Planned phase |
|---|---|---|---|---|---|---|---|---|
| `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | no TypeScript caller; legacy | SP2 / service | global `profiles.role` | lane array is insufficient when empty | staff write, RLS bypass | service can create globally | CRITICAL | 2B retire EXECUTE |
| `admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | single-active tenant bridge; cross-check every lane | staff write | global create and default-owned children | CRITICAL | 2B |
| `admin_list_event_registrations_v1(uuid,text,text,integer,integer)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik/instruktor | event -> tenant | staff/instructor PII read | foreign-tenant participant PII | HIGH | 2A |
| `admin_list_events_v1(text,text,text,integer,integer)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik/instruktor | no resource; single-active tenant bridge | staff/instructor read | aggregates all tenants | HIGH | 2B |
| `admin_set_event_active(uuid,boolean)` | no TypeScript caller; legacy | SP2 / service | global `profiles.role` | event -> tenant | staff write, RLS bypass | service/global mutation | CRITICAL | 2B retire EXECUTE |
| `admin_set_event_active_v2(uuid,boolean)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | event -> tenant | staff write | foreign event mutation | CRITICAL | 2B |
| `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | no TypeScript caller; legacy | SP2 / service | global `profiles.role` | event -> tenant, then lanes | staff write, RLS bypass | service/global mutation | CRITICAL | 2B retire EXECUTE |
| `admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | event -> tenant; every lane must match | staff write | foreign event/lane binding | CRITICAL | 2B |
| `approve_event_registration(uuid)` | `app/admin/events/page.tsx` | SP2 / authenticated | global admin/pracownik | registration -> event -> tenant | staff write/audit | foreign participant mutation | CRITICAL | 2A |
| `cancel_event_registration(uuid)` | register/my/admin flows through `app/api/cancel-event-registration/route.ts` | SP2 / authenticated + service | owner for user/instruktor, otherwise global admin/pracownik | registration -> event -> tenant | owner or staff write/audit | staff global bypass; unnecessary service grant | CRITICAL | 2A |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `lib/server/event-reserve-promotion.ts` | SP2 / service | claim pair only | registration -> event -> tenant; claim must match | service claim completion | completion is not tenant-bound | CRITICAL | 2C |
| `confirm_event_reserve_promotion(text)` | `app/api/confirm-event-reserve-promotion/route.ts` | SP2 / authenticated | `auth.uid()` owns token registration | token -> registration -> event -> tenant | owner promotion write | no membership/tenant equality check | CRITICAL | 2A |
| `get_my_event_registrations_v1(text,text,integer,integer)` | `app/my-events/page.tsx` | SP1 / authenticated | `auth.uid()` row ownership | actor rows plus single-active tenant bridge until 9E | owner read | future account can aggregate tenants | MEDIUM | 2A |
| `get_public_event_availability_v1()` | no current page caller; retained public contract | SP1 / anon + authenticated | public | single-active public tenant | PII-free public read | aggregates all tenants | HIGH | 2B |
| `get_public_event_list_v2(text,text,integer,integer)` | `app/events/page.tsx` | SP1 / anon + authenticated | public | single-active public tenant | PII-free public read | mixes event counts across tenants | HIGH | 2B |
| `mark_event_registration_paid(uuid)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | registration -> event -> tenant | staff write/audit | foreign payment mutation | CRITICAL | 2A |
| `prepare_confirmation_email(text,uuid)` | event registration confirmation API plus reservation mail APIs | SP2 / authenticated | owner for event branch; mixed legacy staff branch for reservation cancellation | typed record -> registration/event or reservation -> tenant | owner/staff email claim | delivery tenant is defaulted, not proven | CRITICAL | 2C shared boundary |
| `complete_confirmation_email(uuid,boolean,text,text)` | three mail APIs through the service completion client | SP2 / service | claim ID only | claim -> delivery -> typed record tenant | service claim completion | claim target/tenant equality not enforced | CRITICAL | 2C shared boundary |
| `prepare_event_reserve_promotions(uuid)` | `lib/server/event-reserve-promotion.ts` from cancellation and manual promotion APIs | SP2 / service | trusted server only; route manual path uses global profile role | event -> tenant, registrations must match | service claim/token creation | arbitrary tenant event accepted by service | CRITICAL | 2C |
| `register_for_event(uuid,boolean)` | `app/api/register-event/route.ts` | SP2 / authenticated | `auth.uid()`, profile completeness | event -> tenant; actor active membership | owner create | inserted tenant currently comes from CSK default | CRITICAL | 2A |

No separate event-rejection or event-lane RPC exists. Rejection uses the existing cancellation transition, and event-lane writes are embedded in event create/update. Event reads performed through table RLS by the calendar `.ics` route are outside this `SECURITY DEFINER` inventory and remain covered by SAAS-9C.

### 22.2 Tenant derivation and write invariant

For every target-bound call, the function must lock or read the target, derive its tenant, and authorize against that derived tenant before reading PII, mutating state or writing audit:

- `event_id` -> `events.tenant_id`;
- `registration_id` -> `event_registrations.tenant_id`, with equality to the referenced `events.tenant_id`;
- promotion token -> registration -> event, with token owner equal to `auth.uid()`;
- promotion claim -> registration -> event, with claim ID and tenant bound to that same registration;
- delivery claim -> `email_deliveries.tenant_id` -> typed record, with record tenant, recipient and claim all equal;
- event lane -> both composite FKs must prove `event_lanes.tenant_id = events.tenant_id = shooting_lanes.tenant_id`.

Caller-supplied tenant is never the only authority. No active 9D-2 signature currently accepts tenant. Target-bound signatures can therefore remain stable.

`admin_create_event_v2`, `admin_list_events_v1`, `get_public_event_availability_v1` and `get_public_event_list_v2` lack an existing resource. Before 9E they resolve exactly one active tenant with `active_single_tenant_id_v1()`. They fail closed if that invariant is not exact. Admin create/list additionally require an active membership in that tenant; public reads do not require membership and return only that active tenant's public events. This is a CSK compatibility bridge, not a multi-tenant routing design.

Every new insert must set tenant explicitly:

- `events.tenant_id` from the resolved single-active tenant during the bridge;
- `event_lanes.tenant_id` from the already-authorized event tenant;
- `event_registrations.tenant_id` from the locked event;
- `email_deliveries.tenant_id` from the typed source record;
- event-related `audit_logs.tenant_id` from the target event/registration.

Any null/missing target, tenant mismatch, mixed-tenant lane array or orphan relationship fails before partial writes and before audit.

### 22.3 Owner event-registration operations

`register_for_event`, `cancel_event_registration`, `confirm_event_reserve_promotion` and `get_my_event_registrations_v1` retain their existing business statuses and response contracts.

- Registration requires `auth.uid()`, an active `user` or `instructor`/staff membership in the event tenant as permitted by the current single-tenant product, a complete owner profile, and an active future event. The insert uses the event tenant explicitly.
- Self-cancellation requires the registration owner, active membership in its tenant and the existing Europe/Warsaw 72-hour rule. Exactly 72 hours remains allowed; less than 72 hours remains denied.
- An instructor can cancel only their own registration. This does not create instructor-to-event assignment and does not expand SEC-008.
- Promotion confirmation requires the token registration owner, active membership in the event tenant, unexpired token and capacity under the locked event.
- My-events remains owner-only and is filtered to the sole active tenant until 9E supplies selected tenant context. A caller cannot pass a user ID or tenant ID.

Required proof: User A own Tenant A operation ALLOW; User A foreign user in A DENY; User A Tenant B IDOR DENY; missing/pending/suspended membership DENY; no partial registration/audit/email row.

### 22.4 Staff and instructor operations

For create/update/activate/approve/payment/staff cancellation, global `profiles.role` is replaced by an active tenant membership role:

- `admin` and `employee` preserve current management permissions;
- `instructor` remains read-only for the currently exposed event and participant lists, scoped to the event tenant/single active tenant;
- `instructor` does not gain approval, payment, event management or foreign cancellation;
- no membership, pending membership, suspended membership and global `profiles.role=admin` without membership all fail closed.

Participant-list authorization derives tenant from `p_event_id` before returning PII. Event update and activation lock the event first. Update cross-checks every requested lane tenant before any conflict query or relationship replacement. Create resolves the compatibility tenant first and rejects every lane outside it. Empty-lane creation is allowed only inside that resolved tenant.

### 22.5 Event management, lanes and audit

Existing validation, operating hours, hierarchy conflict locks, reservation conflicts, lane-block conflicts and event conflicts remain unchanged. The hardening adds tenant predicates to each conflict read and writes event/event-lane tenant explicitly. It does not alter capacity, dates, prices, active semantics or UI responses.

Changed staff actions continue to create exactly one tenant-bound audit with DB actor/time. `no_change`, invalid transitions, authorization denial and not-found paths create no audit. Audit details must not contain promotion tokens, email claims or participant contact fields.

The three legacy service-only event management signatures have no current TypeScript caller. 9D-2B freezes a zero-caller test and revokes `service_role` EXECUTE, leaving owner-only access. It does not drop the functions in the same migration, allowing a forward rollback without reconstructing definitions.

### 22.6 Waitlist, promotion and confirmation claims

The existing order and state machine remain authoritative:

- occupied statuses are `registered` and `approved`;
- `reserve` does not occupy capacity;
- reserve ordering remains `created_at, id`;
- event row lock precedes participant counting and promotion/confirmation;
- registration row locks, unique active registration constraint, promotion claim ID/expiry and email delivery claim ID/expiry remain intact;
- repeated completion remains idempotent and cannot create a second state transition or audit.

The service-only prepare/complete functions retain exact service grants because they are server delivery state machines. They must derive tenant from the event/registration/claim and reject mismatched claims or typed targets. They may not accept a browser-supplied tenant.

The manual `/api/send-event-reserve-promotion` path must replace its global profile-role check with an authenticated, event-target membership check before invoking the service helper. The owner-cancellation path may invoke the helper only with the `event_id` returned by the successfully hardened cancellation RPC; it must not accept a second event ID from the request. The service helper continues to send only after a successful claim and completes only that exact registration/claim pair.

`prepare_confirmation_email` must derive `email_deliveries.tenant_id` for each supported message type. `complete_confirmation_email` must verify that the delivery tenant still equals its typed reservation/event-registration target before completion. This shared change must run all reservation email regressions from SEC-006/SEC-015 as well as event confirmation tests.

### 22.7 Public availability and public list

`get_public_event_list_v2` remains the active `/events` contract. `get_public_event_availability_v1` remains a compatible PII-free contract although no page currently calls it. Both:

- resolve the exact single active tenant;
- filter events and registration counts by that tenant;
- preserve `registered + approved` occupied semantics, reserve count and `available_spots >= 0`;
- remain executable by anon and authenticated only;
- return no registration ID, user ID, contact data, tokens or notes;
- fail closed if the single-active invariant is not exact.

They must not require membership while public CSK routing remains unchanged. Before a second tenant, 9E must replace the implicit single-active selection with a trusted host/slug-selected contract.

### 22.8 Owners, grants and search path

All touched functions remain owned by `postgres`. Every body-redefined function uses explicit `SET search_path = pg_catalog, public, pg_temp` and schema-qualified objects/functions. The three legacy admin event functions are ACL-only in 9D-2B-1 and retain their production baseline `search_path = public, pg_temp`; any future path hardening requires a separate reviewed change. No EXECUTE grant is widened.

- public readers: `anon`, `authenticated` only;
- owner/staff client RPCs: `authenticated` only;
- service claim prepare/complete functions: `service_role` only;
- legacy admin event v1 functions: owner-only after service grant revocation;
- `PUBLIC`: no EXECUTE for every non-public contract and no implicit grant drift.

Focused ACL tests must assert effective privileges, owner and search path for all 20 signatures and keep the total `SECURITY DEFINER` inventory explicitly accounted for.

### 22.9 Application caller impact

| File | Current RPC | Current arguments/context | Planned caller impact |
|---|---|---|---|
| `app/events/page.tsx` | `get_public_event_list_v2` | search/scope/page; no tenant | none in 9D-2; compatibility bridge filters CSK |
| `app/my-events/page.tsx` | `get_my_event_registrations_v1` | scope/status/page; actor JWT | none; DB adds tenant membership/filter |
| `app/api/register-event/route.ts` | `register_for_event` | event ID/reserve flag; actor JWT | none |
| `app/api/cancel-event-registration/route.ts` | `cancel_event_registration` | registration ID; actor JWT | preserve call; promotion helper must use only returned event ID |
| `app/api/confirm-event-reserve-promotion/route.ts` | `confirm_event_reserve_promotion` | token; actor JWT | none |
| `app/admin/events/page.tsx` | admin lists/create/update/active/approve/payment | filters or target IDs; browser JWT | active signatures remain; no selected tenant UI yet |
| `app/api/send-event-registration-confirmation/route.ts` | `prepare_confirmation_email`, `complete_confirmation_email` | owner registration claim + server completion | no public contract change; shared claim gets tenant proof |
| `app/api/send-event-reserve-promotion/route.ts` | server helper -> promotion prepare/complete | event ID; currently global profile-role precheck | change server precheck to event-derived active membership |
| `lib/server/event-reserve-promotion.ts` | `prepare_event_reserve_promotions`, `complete_event_reserve_promotion` | service client, event/registration/claim | preserve service-only DB signatures; accept only already-authorized event context from route/cancellation result |

No 9D-2 caller sends tenant ID. Selected-tenant arguments, hostname routing and multi-tenant URL state belong to 9E. If implementation discovers that preserving a signature would require trusting client tenant input, that subphase stops rather than silently changing the caller contract.

### 22.10 Concurrency and business-regression contract

Tests must prove, under deterministic barriers and repeated stress where the current harness supports it:

1. one active registration per user/event remains enforced;
2. event row locking prevents overbooking and preserves reserve fallback;
3. exactly one reserve claimant is promoted for one released place;
4. confirmation cannot exceed capacity under simultaneous tokens;
5. event create/update/activate retains canonical lane-family conflict locks and cannot bind mixed-tenant lanes;
6. claim prepare/complete permits one active delivery/promotion claim, rejects a foreign claim and remains retry-safe;
7. cancellation plus promotion retains the current controlled-warning contract when email delivery fails;
8. changed staff actions write one audit, while no-change/retry writes none;
9. Tenant A and Tenant B operations on independent resources do not deadlock or leak rows.

### 22.11 Required cross-tenant and regression tests

Focused SQL coverage for every phase includes:

- anon public list/availability ALLOW and PII-free; anon mutations DENY;
- User A own registration/register/cancel/confirm in Tenant A ALLOW;
- User A foreign registration and Tenant B event/registration/token DENY;
- Admin A and Employee A allowed Tenant A operations ALLOW, Tenant B DENY;
- Instructor A retains current reads and own cancellation only; management DENY;
- missing, pending and suspended membership DENY privileged/owner tenant operations;
- global legacy admin/pracownik profile without active target membership DENY;
- caller/resource mismatch and mixed A+B lane arrays DENY atomically;
- event registration and event-lane composite tenant constraints remain valid;
- public counts, sold-out, reserve, cancellation and promotion semantics remain exact;
- no cross-tenant PII from admin participant list or my-events;
- service prepare/complete claims cannot cross registration/delivery tenants;
- exact grants/search paths/owners and zero legacy runtime callers;
- no RLS recursion and no direct DML grant regression;
- fixture cleanup equals zero.

Regression gates: focused event SQL, event concurrency harness, full Supabase DB suite, full Node suite, TypeScript, production build, event Playwright/mobile flows, confirmation/reserve email tests, `npm audit --omit=dev`, changed-files ESLint and `git diff --check`.

### 22.12 Temporary CSK defaults

Current catalog evidence:

| Table | Current `tenant_id` default | 9D-2 writer behavior | Removal |
|---|---|---|---|
| `events` | CSK UUID | create writes resolved tenant explicitly | retain until 9D-5/9E gate |
| `event_lanes` | CSK UUID | create/update write event tenant explicitly | retain until 9D-5/9E gate |
| `event_registrations` | CSK UUID | register/promotion paths write/retain event tenant explicitly | retain until 9D-5/9E gate |
| `email_deliveries` | CSK UUID | prepare writes typed-record tenant explicitly | retain until all reservation/event mail writers pass production proof |
| `audit_logs` | no default | every event audit writes derived tenant explicitly | no change |

The explicit gate remains: **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER CUTOVER AND BEFORE SECOND TENANT**. 9D-2 does not remove any default.

### 22.13 Proposed migration split and rollout

Do not deploy this domain as one migration.

1. **9D-2A — event registration owner/staff contracts**: `register_for_event`, `cancel_event_registration`, `approve_event_registration`, `mark_event_registration_paid`, `confirm_event_reserve_promotion`, `get_my_event_registrations_v1`, `admin_list_event_registrations_v1`; explicit registration/audit tenant, membership enforcement, SP1 normalization, concurrency tests. Active signatures stay unchanged.
2. **9D-2B — event management and public reads**: active admin create/update/activate/list and both public readers; single-active bridge for contextless calls, mixed-lane rejection, explicit event/event-lane tenant; revoke service EXECUTE from the three zero-caller legacy admin functions. Active signatures stay unchanged.
3. **9D-2C — event delivery and promotion claims**: promotion prepare/complete, shared confirmation prepare/complete, tenant-bound claim state; replace the manual promotion route's global role precheck with event-target membership. Run reservation e-mail regressions because the confirmation functions are shared.

Each migration is independently additive/`CREATE OR REPLACE` plus grant hardening, has a frozen preflight fingerprint, focused test, compatibility matrix, local PASS, production dry-run, explicit production approval and rollback-only postflight. Complete 2A production proof before 2B; complete 2B before 2C.

Compatibility target for every subphase:

- old app + old DB: current behavior;
- old app + new DB: safe because active signatures and response codes remain, subject to correct membership backfill already proven in 9C-1;
- new app + old DB: only 2C's route membership precheck dependency requires coordinated ordering; deploy its DB authorization contract before the route change;
- new app + new DB: tenant-bounded CSK behavior, still not second-tenant ready.

### 22.14 Rollback

- Capture exact preflight function definitions, owners, grants, paths and normalized fingerprints for all 20 signatures.
- Rollback is a reviewed forward migration restoring only the previous definitions/grants for the affected subphase; never edit applied migrations or use `migration repair`.
- Keep active signatures stable so application rollback remains possible.
- If 2C application deployment fails, roll back the route/helper to the prior version while the new DB functions remain backward-compatible; do not re-grant legacy browser access.
- Never roll back by removing tenant columns, composite FKs, memberships or the single-active guard.
- STOP on catalog drift, unexpected caller, membership/backfill mismatch, cross-tenant allow, grant widening, capacity/waitlist race regression, audit drift, public PII, nonzero fixture or additional pending migration.

### 22.15 SEC-004 impact and residual work

9D-2 removes global-role authorization and unscoped event/event-registration access from active event RPCs, filters public/admin reads to CSK, explicitly binds event children/audits/deliveries, and constrains service claims to exact tenant-owned targets.

SEC-004 remains OPEN because:

- 9D-3 still must harden lane/block/configuration definers;
- 9D-4 still must harden reports, profile/account and remaining global authorization helpers;
- 9D-5 must retire compatibility grants/default dependencies after all writers are proven;
- 9E must introduce trusted tenant selection/routing and replace single-active wrappers;
- 9F must cut over reports/events/calendar/check-in to selected tenant context;
- 9G must prove application-level cross-tenant IDOR and concurrency;
- 9H alone may authorize SEC-004 closure and second-tenant readiness.

### 22.16 Blocking decisions and GO / NO-GO

No unresolved architecture decision blocks **local 9D-2A**: all its tenant contexts derive from event/registration/token resources, membership role mapping is already approved, and the existing concurrency semantics are explicit.

9D-2B may proceed locally with the already established single-active-CSK compatibility bridge. It must not invent selected-tenant routing. 9D-2C may proceed only after its local preflight freezes the exact server callers and proves the manual promotion endpoint checks membership in the derived event tenant before service execution; this is an implementation gate, not a business decision.

Production remains separately gated per subphase. No 9D-2 work enables Tenant B or closes SEC-004.

SAAS-9D-2 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 23. SAAS-9D-1 closure record

The approved first phase was implemented locally in `20260911140000_harden_reservation_checkin_rpcs.sql`. It preserves all public function signatures and the 73-function `SECURITY DEFINER` count while separating 12 reviewed business implementations into non-client `SECURITY INVOKER` cores behind tenant-authorizing wrappers.

Hardened active signatures:

1. `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)`
2. `cancel_reservation(uuid)`
3. `update_reservation_admin_note(uuid,text)`
4. `update_reservation_attendance(uuid,text)`
5. `update_reservation_payment(uuid,text)`
6. `get_check_in_reservation_v1(uuid)`
7. `get_public_check_in_status_v1(uuid)`
8. `get_my_reservations_v2()`
9. `get_reservation_customer_profiles_v1(uuid[])`
10. `get_lane_booking_busy_ranges(uuid,date)`
11. `get_lane_booking_busy_ranges_v2(uuid,date)`
12. `get_lane_booking_busy_ranges_v3(uuid,date)`

The retained legacy `create_reservation(uuid,date,time,integer,integer,uuid,text)` is now owner-only; its prior `service_role` EXECUTE grant was removed. Broad `service_role` grants were also removed from the hardened reservation/busy-range paths. Client-facing grants were not widened.

Tenant derivation is resource-based: lane for create/busy-range, reservation for owner/staff operations and customer profile batches, and check-in token to reservation. The V2 create core now writes `v_lane.tenant_id` explicitly while the existing composite tenant/lane FK continues to reject mismatches. The seven temporary CSK defaults remain because their global removal is deferred to a later approved 9D gate; the reservation writer no longer relies on its default as a security mechanism.

Authorization now requires `auth.uid()`, an active membership in the derived tenant and the allowed membership role. Owner cancellation additionally requires the reservation owner. Global `profiles.role` alone, missing membership, pending membership, instructor role and cross-tenant IDs fail closed.

Local verification outcome:

- fresh local reset: PASS;
- focused SAAS-9D-1 SQL: 32/32 PASS;
- full Supabase DB suite: 27 files / 784 tests PASS;
- cross-writer concurrency: 52/52 deterministic and 50/50 stress PASS, zero deadlock/lock-timeout/serialization failures;
- Node: 734/734 PASS;
- TypeScript and production build: PASS;
- focused Playwright: 11/11 PASS;
- synthetic fixture remaining: 0;
- `SECURITY DEFINER`: 73; protected 9D-1 cores: 12; temporary defaults: 7.

The detailed implementation evidence is recorded in `SAAS_9D_1_RESERVATION_CHECKIN_RPC_HARDENING_REPORT.md`.

SAAS-9D-1: **CLOSED / PROD PASS**

REPOSITORY REPRODUCIBLE: **YES**

GLOBAL ROLE BYPASS — RESERVATION/CHECK-IN: **REMOVED**

READY FOR SAAS-9D-2 PLANNING: **GO; section 22 is authoritative**

READY FOR PRODUCTION WRITE: **NO**

## 26. SAAS-9D-2B-1 local implementation record

SAAS-9D-2B-1 was implemented locally on 2026-09-13. The active, signature-compatible wrappers are `admin_create_event_v2`, `admin_update_event_v2`, `admin_set_event_active_v2` and `admin_list_events_v1`. They now require active tenant membership roles, derive tenant from the event where available, use the approved exact-single-active bridge only for contextless create/list, reject mixed-tenant lanes and keep the frozen business implementations in inaccessible `SECURITY INVOKER` cores.

The zero-caller legacy `admin_create_event`, `admin_update_event` and `admin_set_event_active` signatures are owner-only after service-role grant cleanup. This cleanup is ACL-only: their bodies, signatures, owners and production `search_path = public, pg_temp` remain unchanged. Public availability/list readers are unchanged and explicitly deferred to 2B-2.

Verification: focused SQL 32/32, full DB 29 files/852 tests, cross-writer 52/52 deterministic plus 50/50 stress with zero concurrency errors, Node 734/734, TypeScript/build PASS and focused Playwright 14/14. Fixture remaining is zero. Full evidence is in `SAAS_9D_2B1_EVENT_MANAGEMENT_RPC_HARDENING_REPORT.md`.

SAAS-9D-2B-1 LOCAL: **PASS**

READY FOR SAAS-9D-2B-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2B-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 27. SAAS-9D-2B-2 — PUBLIC EVENT READERS FINAL PLAN

This section is the implementation-ready technical plan only. It creates no migration, changes no application code and authorizes no database write. SAAS-9D-2B-1 is closed in production at checkpoint `6cd29ab` before this plan begins.

### 27.1 Exact scope

Only these public read contracts are in scope:

1. `public.get_public_event_availability_v1()`
2. `public.get_public_event_list_v2(text,text,integer,integer)`

The local implementation should introduce an inaccessible `SECURITY INVOKER` core for each contract and recreate the exact public signature as a small tenant-resolving `SECURITY DEFINER` wrapper. No event writer, registration writer, admin reader, UI component, RLS policy, table ACL, compatibility default or tenant-routing mechanism is changed in 2B-2.

### 27.2 Current function inventory

| Function | Exact signature | Return contract | SECURITY DEFINER | Current tenant source | Current tenant filtering | Owner | Search path |
|---|---|---|---|---|---|---|---|
| availability | `public.get_public_event_availability_v1()` | 13-column table | yes, stable | none | none; all active events are eligible | `postgres` | `pg_catalog, public, pg_temp` |
| list | `public.get_public_event_list_v2(text,text,integer,integer)` | JSONB contract v2 | yes, stable | none | none; filters only active/search/scope | `postgres` | `pg_catalog, public, pg_temp` |

Current grants for both signatures are identical:

- `PUBLIC`: no `EXECUTE`;
- `anon`: `EXECUTE`;
- `authenticated`: `EXECUTE`;
- `service_role`: no `EXECUTE`.

These grants must remain exact. No direct table grant or RLS policy is widened.

### 27.3 Caller inventory and compatibility

Runtime callers:

- `app/events/page.tsx` calls `get_public_event_list_v2` with `p_search`, `p_scope='upcoming'`, `p_page` and `p_page_size=20`.
- `lib/event-read-contracts.ts` parses the outer v2 JSONB envelope and pagination.
- `lib/public-event-availability.ts` enforces the exact 13-key item DTO and capacity invariants.
- There is no direct application/runtime caller of `get_public_event_availability_v1()` at current HEAD. It remains an externally callable public contract and an authoritative regression surface.

Test and contract callers include:

- `supabase/tests/20260905120000_add_public_event_availability_v1_test.sql`;
- `supabase/tests/20260905190000_add_scalable_event_read_contracts_test.sql`;
- `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`;
- `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`;
- `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`;
- `lib/public-event-availability.test.mjs`, `lib/event-read-contracts.test.mjs`, `app/events/events-ux.test.mjs` and `tests/e2e/events-responsive.spec.ts`.

Both public signatures, parameter defaults, item keys, list envelope, pagination/filter behavior and status/capacity semantics remain unchanged. No `tenant_id` argument is added, so no UI change is required. Until 9E provides trusted routing, the active-single-tenant bridge is the compatibility mechanism.

Compatibility matrix:

| State | Result |
|---|---|
| old app + old DB | current behavior |
| old app + new DB | safe; identical signatures and DTOs, tenant-bounded result |
| new app + old DB | not applicable to this DB-only phase; current app requires no change |
| current app + new DB | safe for exact-one-active CSK runtime |

Deployment model after local and production preflight PASS: **DB FIRST / DB ONLY**.

### 27.4 Current data paths and risk

`get_public_event_availability_v1()` currently:

- aggregates every non-null `event_registrations.event_id`;
- counts `registered` and `approved` as occupied;
- counts `reserve` separately;
- joins counts to every active event by global `event_id`;
- clamps `available_spots` to zero and derives `sold_out`.

`get_public_event_list_v2(...)` currently:

- builds the active/search/scope-filtered event set globally;
- paginates before counting registrations;
- counts `registered` and `approved` as occupied and `reserve` separately for page event IDs;
- returns a bounded v2 JSONB envelope with maximum page size 50.

Neither function currently reads `event_lanes` or `shooting_lanes`, so lane data is not part of the public DTO. The database already enforces `(tenant_id,event_id)` consistency for `event_registrations` and `(tenant_id,event_id)/(tenant_id,lane_id)` consistency for `event_lanes`; nevertheless, the new cores must include explicit tenant predicates rather than rely only on globally unique IDs or composite FKs.

Current cross-tenant exposure risk is **HIGH once another tenant becomes active**: both definers bypass caller RLS and currently select globally. Current single-active CSK exploitability remains bounded by the second-active-tenant guard, but this is not sufficient for 9E/second-tenant readiness.

### 27.5 Tenant resolution and bridge behavior

The wrappers resolve tenant only through:

```text
public.active_single_tenant_id_v1()
```

The helper already returns an ID only when exactly one tenant has `status='active'`; otherwise it returns `NULL`. It is owner-only, `postgres`-owned, stable, SP1 and must not receive a public grant.

Required public behavior:

| Active tenants | Availability | List v2 |
|---|---|---|
| exactly one A | rows for A only | `ok=true`, items/total for A only |
| exactly one B | rows for B only | `ok=true`, items/total for B only |
| zero | empty result set | contract-compatible `ok=true`, `items=[]`, `pagination.total=0` |
| more than one | empty result set | contract-compatible `ok=true`, `items=[]`, `pagination.total=0` |

Invalid list inputs continue to return `{"ok":false,"code":"invalid_input"}` before any empty-result success is produced. No arbitrary `LIMIT 1`, oldest/newest tenant selection, CSK constant fallback, membership requirement or browser-supplied tenant ID is allowed.

The production partial unique index normally prevents two active tenants. The `>1` path is still tested locally inside a rollback-only fixture that temporarily exercises the resolver invariant and restores the guard before rollback; it is never tested by weakening production.

### 27.6 Proposed wrapper/core design

Availability:

- public wrapper retains signature `()` and exact table return columns;
- wrapper resolves `v_tenant_id` and returns zero rows when it is null;
- inaccessible core accepts one internal UUID tenant argument;
- core filters `events.tenant_id = p_tenant_id`;
- registration aggregation filters `event_registrations.tenant_id = p_tenant_id` and joins on the tenant-consistent event.

List:

- public wrapper retains `(text,text,integer,integer)` and all defaults;
- wrapper resolves one active tenant and calls an inaccessible core with the tenant UUID plus the four existing arguments;
- core preserves validation, search, scope, Warsaw-time comparison, stable ordering, page bounds and outer JSONB contract;
- `filtered` includes `events.tenant_id = p_tenant_id`;
- page registration counts include both `registration.tenant_id = p_tenant_id` and page event IDs;
- valid requests with a null resolved tenant return the exact empty v2 envelope rather than leaking an internal error.

Both cores must be `SECURITY INVOKER`, `postgres`-owned, SP1 and have no `EXECUTE` for `PUBLIC`, `anon`, `authenticated` or `service_role`. Both public wrappers remain stable `SECURITY DEFINER`, `postgres`-owned and SP1 with the existing anon/authenticated-only grants. The total public-schema `SECURITY DEFINER` count therefore remains unchanged.

Direct conversion of the public functions to `SECURITY INVOKER` is not recommended in 2B-2: anon does not have the protected table access needed to count registrations, and granting it would expand the trust boundary. It can be reconsidered only with a separate PII-free view/read-model design.

### 27.7 Public DTO and PII inventory

The exact availability row and each list item remain:

1. `event_id`
2. `title`
3. `description`
4. `event_date`
5. `start_time`
6. `end_time`
7. `location`
8. `price`
9. `max_participants`
10. `registered_count`
11. `reserve_count`
12. `available_spots`
13. `sold_out`

The list envelope additionally contains only `ok`, `code`, `contract_version`, public filters, pagination and `items`.

Forbidden output remains: registration IDs, user IDs, membership IDs/roles, profile data, names of participants, email, phone, address, permit/declaration data, payment/customer fields, registration tokens, promotion/confirmation/check-in tokens, admin notes, audit data and tenant membership internals. `event_id` is intentionally public because registration and event selection require it; `tenant_id` is not added to the DTO in this bridge phase.

### 27.8 Join consistency and authoritative semantics

The tenant predicate must appear independently on the event base and registration aggregate. Registration status semantics remain exact:

- `registered`, `approved`: occupy capacity;
- `reserve`: counted separately and does not occupy capacity;
- `cancelled` and every other non-occupying state: excluded from both counts.

`available_spots = greatest(max_participants - registered_count, 0)` and `sold_out = registered_count >= max_participants` remain unchanged.

`event_lanes` and `shooting_lanes` remain outside both reader queries and DTOs. Tests must nevertheless create Event A with Lane A and a Tenant B lane/relation to prove that no lane relationship introduces a cross-tenant public row. An attempted Event A + Lane B relation must continue to fail under the existing composite tenant FK.

### 27.9 Fingerprint baseline and migration guards

Normalized production fingerprints use `CRLF / CR -> LF` before MD5:

| Function | Production normalized full-definition MD5 |
|---|---|
| `public.get_public_event_availability_v1()` | `40adf74cb5adec5df3b4745fc7851433` |
| `public.get_public_event_list_v2(text,text,integer,integer)` | `fe075d7057149b0a0bad0129419a3e99` |

Implementation preconditions must fail closed unless:

- both exact signatures exist once and match these fingerprints;
- both are stable `SECURITY DEFINER`, owned by `postgres`, with SP1;
- grants are exactly anon/authenticated `EXECUTE`, with none for `PUBLIC` or `service_role`;
- `active_single_tenant_id_v1()` exists with its reviewed owner/path/ACL;
- `events.tenant_id` and `event_registrations.tenant_id` are non-null;
- validated composite tenant/event FKs and the single-active guard exist;
- 2B-1 active/legacy event RPC fingerprints and ACLs have not drifted;
- no unexpected pending migration or function overload exists.

Postflight repeats the catalog, ACL, path, owner, signature, definer-count, core-isolation and public DTO checks. Any mismatch aborts the migration transaction.

### 27.10 Cross-tenant and public test matrix

Focused SQL tests use Tenant A and dormant Tenant B with synthetic events, lanes and registrations:

1. one active Tenant A: anon and authenticated list return only A;
2. one active Tenant A: availability returns only A;
3. switch the exact active tenant to B: both contracts return only B;
4. zero active tenants: availability is empty; valid list is a successful empty envelope;
5. two active tenants in a local rollback-only guard fixture: both contracts fail closed as empty;
6. Event A plus Lane B is rejected and cannot create a public row;
7. Tenant B registrations do not affect Event A counts;
8. A and B may use identical-looking titles/dates without count bleed;
9. anon and authenticated receive identical public results;
10. no-auth REST/RPC access remains allowed;
11. `registered` and `approved` occupy capacity; `reserve` is separate; `cancelled` does not occupy;
12. sold-out clamps at zero and never becomes negative;
13. search, upcoming/all scope, Warsaw time, stable ordering, page 1/page 2, beyond-last page and max page size 50 remain exact;
14. invalid page/scope/search remain `invalid_input`;
15. all response keys match the PII-free allowlist and forbidden strings/values are absent;
16. wrapper cores cannot be called by any client role;
17. `PUBLIC`, `anon`, `authenticated`, `service_role` grants remain exact;
18. 2A registration, cancellation and promotion update availability without cross-tenant effects;
19. 2B-1 create/edit/activate/list regression remains PASS;
20. overbooking remains prevented by the authoritative writer, not by the display reader.

### 27.11 Regression and operational verification

Required local verification after a separately approved implementation:

- fresh local database reset;
- focused 2B-2 SQL suite;
- tenant-aware Events RLS and event-registration privacy suites;
- 2A and 2B-1 focused regression suites;
- full Supabase DB suite;
- all Node tests;
- TypeScript and production build;
- focused `/events` Playwright tests for public list, search, pagination, empty/error/retry and mobile layouts;
- anon/authenticated REST contract smoke;
- `git diff --check` and zero synthetic fixture.

Production preflight remains separate: exact migration SHA, LOCAL/REMOTE history, only-one-pending dry-run, frozen production fingerprints, tenant/data invariants, lock check and explicit deployment approval. Production postflight uses read-only catalog checks plus a rollback-only two-tenant fixture; it performs no persistent second-tenant activation.

No new index is planned initially. The existing tenant/event integrity, `events_tenant_active_schedule_idx`, event registration indexes and bounded page query are retained. Local `EXPLAIN` must confirm no material regression; any proposed additional index is a scope change requiring review before implementation.

### 27.12 Temporary defaults and application scope

2B-2 is read-only and does not use, add or remove any of the seven temporary CSK `tenant_id` defaults. Default removal remains gated before tenant-aware writer cutover and before a second tenant. No route, UI, parser or generated client type change is expected because signatures and DTOs remain stable.

### 27.13 Rollback

Rollback is a reviewed forward migration that restores the two exact pre-2B-2 production function definitions, owners, SP1 paths and grants from the frozen baselines. It removes only the new inaccessible cores after restoring the public functions. It must not remove tenant columns, constraints, indexes, memberships, the single-active guard or any 2A/2B-1 work.

Because the phase is DB-only and signature-compatible, an application rollback is not required. STOP conditions are fingerprint drift, unexpected caller/overload, public PII, tenant bleed, changed status/capacity semantics, widened ACL, changed `SECURITY DEFINER` inventory, nonzero fixture or any additional pending migration.

### 27.14 SEC-004 impact and final gate

2B-2 removes the remaining global public event-read path for the two named readers and makes them fail closed when the bridge cannot resolve exactly one tenant. It does not close SEC-004 because selected tenant routing, remaining RPC families, application context, operational cutover and full cross-tenant verification remain in 9D-2C through 9H.

No unresolved business decision blocks local implementation. The bridge behavior, unchanged signatures/DTOs/grants, explicit tenant predicates and zero/one/many behavior are fully specified. Implementation still requires a separate explicit approval.

SAAS-9D-2B-2 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2B-2 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 31. SAAS-9D-2C-2 — EVENT RESERVE PROMOTION RPC HARDENING FINAL PLAN

This section supersedes the preliminary 2C-2 rollout notes in sections 29.9,
29.14 and 29.15 where they conflict with this final plan. It is planning-only
and is based on the production state after the successful 2C-1 deployment and
the reproducible checkpoint `8c781b2c67233f865407abe1318534f57ef86040`.
No migration, application change, SQL write or deployment is authorized by
this section.

### 31.1 Exact scope and production inventory

The implementation boundary contains exactly two existing database functions
and one mandatory server-route authorization correction. It does not include
the public confirmation RPC, event registration writers, public event readers,
shared confirmation-email functions or any 9D-3/4/5 function.

| Function | Exact signature and result | Current callers | SQL-to-SQL callers | Current security metadata | Current arguments / token | Current tenant and authorization model | RLS bypass / risk |
|---|---|---|---|---|---|---|---|
| `prepare_event_reserve_promotions` | `(p_event_id uuid) RETURNS TABLE(registration_id uuid, claim_id uuid, promotion_token text, promotion_token_expires_at timestamptz, token_reused boolean)` | `lib/server/event-reserve-promotion.ts`; indirectly the manual promotion route and the successful cancellation route | none | volatile, SECURITY DEFINER, owner `postgres`, SP2 `public, pg_temp`; only `service_role` EXECUTE | event argument yes; generated token and claim returned; no registration argument | service credential is the present execution gate; event tenant can be derived from `events.tenant_id`; the manual route still uses global `profiles.role` | bypasses RLS and currently filters by global event ID without explicit tenant predicates; CRITICAL |
| `complete_event_reserve_promotion` | `(p_registration_id uuid, p_claim_id uuid, p_success boolean, p_error_code text DEFAULT NULL) RETURNS jsonb` | `lib/server/event-reserve-promotion.ts` after each provider outcome | none | volatile, SECURITY DEFINER, owner `postgres`, SP2 `public, pg_temp`; only `service_role` EXECUTE | registration and claim arguments yes; no token/event/tenant argument | exact claim is checked on the supplied registration; tenant is only implicit in registration/event rows; service credential is not business authorization | bypasses RLS and does not explicitly re-prove registration/event tenant equality; CRITICAL |

Effective EXECUTE is currently and must remain: PUBLIC **no**, anon **no**,
authenticated **no**, service_role **yes**. Both functions exist exactly once.
The service path uses `NEXT_PUBLIC_SUPABASE_URL` plus the server-only
`SUPABASE_SERVICE_ROLE_KEY`; it does not persist or refresh a browser session.
Neither function accepts a caller-controlled tenant ID.

### 31.2 Caller and authorization inventory

| File / caller | Caller type | Auth context | Tenant context | Resource context and current arguments | Application change required |
|---|---|---|---|---|---|
| `app/api/send-event-reserve-promotion/route.ts` | manual authenticated POST | bearer JWT is verified with `getUser`; authorization then reads global `profiles.role` and accepts `admin`/`pracownik` | absent before the service call | browser supplies only `eventId`; route calls `promoteEventReserve(eventId)` | **yes**: use authenticated DB context to resolve the event tenant and require an active membership role `admin` or `employee`; global profile role alone must deny |
| `app/api/cancel-event-registration/route.ts` | owner/staff cancellation POST with automatic follow-on | the hardened `cancel_event_registration` RPC authenticates and authorizes the actor | the successful RPC derives registration -> event -> tenant | promotion is attempted only when the controlled result says `changed=true` and `freed_participant_place=true`; helper receives the returned `event_id`, not authority supplied separately by the browser | no request-contract change; retain this provenance and add regression assertions |
| `lib/server/event-reserve-promotion.ts` | server-only orchestrator | service client only after a caller boundary has authorized the operation | prepare must derive tenant from event; returned registration/claim pairs remain the completion capability | calls prepare with `p_event_id`; calls complete with registration ID, claim ID, success and bounded error code; reads event and recipient fields from DB and sends via Resend | preserve exported helper and RPC signatures; add tenant assertions only if focused tests show the server read step cannot remain bound to the prepared IDs |

There is no cron, background worker or SQL-to-SQL caller. Test and report
references are not runtime callers. The service helper is an infrastructure
boundary, not proof that the initiating user may operate on the event.

The manual route target authorization sequence is:

1. verify the bearer JWT and derive `auth.uid()`;
2. resolve the event and its `tenant_id` through the authenticated client;
3. require an active membership in that exact tenant;
4. allow only tenant roles `admin` or `employee`;
5. pass only the already-authorized event ID into the server helper.

`ADMIN_A` and `EMPLOYEE_A` may trigger Event A. They must be denied for Event
B. A global legacy admin/pracownik without an active Event-B membership,
pending or suspended membership, no membership, user and instructor all deny.
No query string, request body, profile role or service credential may replace
the membership check.

### 31.3 Flow state machine and state transitions

The current business flow, which tenant hardening must preserve, is:

1. **Prepare starts:** validate non-null event ID; lock the event row.
2. **Capacity gate:** count `registered` + `approved`; if the count is at or
   above `max_participants`, return an empty set without claim or email work.
3. **Candidate scan:** select `reserve` rows in `created_at,id` FIFO order,
   excluding a still-active claim and excluding a valid token whose email has
   already been recorded as sent.
4. **Token decision:** reuse a still-valid, unsent token or generate a new UUID
   token valid for 24 hours.
5. **Claim:** generate a claim UUID valid for 10 minutes, increment attempt
   count, set last-attempt time, clear the previous bounded error, and return
   the registration/claim/token tuple.
6. **Recipient and template:** the server reads event data and each claimed
   registration's stored recipient/name, escapes dynamic HTML and constructs
   the public confirmation link. The browser cannot supply recipient, name,
   token or content.
7. **Provider failure:** complete with `success=false`; exact claim is cleared,
   the bounded technical error code is stored and no sent timestamp is added.
8. **Provider success:** complete with `success=true`; `promotion_email_sent_at`
   is set once and the exact claim/error state is cleared.
9. **Retry:** a completion retry after the claim was cleared is a no-change
   controlled result when the requested outcome is already represented;
   mismatched or inactive success claims fail closed.
10. **Public confirmation is separate:**
    `confirm_event_reserve_promotion(text)` authenticates the owner and
    atomically locks/rechecks event capacity before changing `reserve` to
    `registered`. It remains outside this migration and must retain its 9D-2A
    fingerprint and behavior.

Prepare intentionally may notify multiple FIFO reserve candidates while at
least one place is free. Email copy and the existing product rule are
first-successful-confirmation wins. 2C-2 must **not** reinterpret this as one
exclusive prepared claim per free slot. Capacity is protected by the final
confirmation RPC, not by the number of emails prepared.

### 31.4 Tenant derivation and database target bodies

Tenant authority is always resource-derived:

- prepare: `p_event_id -> events.tenant_id`;
- completion: `p_registration_id -> event_registrations.tenant_id` and
  `event_registrations.event_id -> events.tenant_id`;
- claim/token: claim is stored on the registration, which must join its event
  on both event ID and tenant ID.

Target `prepare_event_reserve_promotions` behavior:

- lock the event and capture its non-null tenant;
- apply both `event_id` and `tenant_id` to occupied-count and reserve-candidate
  queries;
- keep the existing statuses, capacity gate, FIFO ordering, token reuse,
  24-hour token TTL, 10-minute claim TTL and response columns unchanged;
- update each candidate by registration ID + event ID + tenant ID and fail
  closed if the locked candidate no longer matches;
- remain service-only, become SECURITY INVOKER and use SP1
  `pg_catalog, public, pg_temp`.

Target `complete_event_reserve_promotion` behavior:

- lock the registration and its event with an exact
  `(event_id, tenant_id)` relationship;
- require non-null, equal registration/event tenants and the exact current
  claim before any changed update;
- update by registration ID + event ID + tenant ID + claim ID;
- preserve validation of `p_success` and the bounded lower-case error-code
  contract, the JSON keys/types, no-change retry behavior and sent timestamp
  idempotency;
- remain service-only, become SECURITY INVOKER and use SP1.

The completion RPC does not receive the email address and therefore cannot
prove the provider recipient independently. Recipient binding remains the
server data-flow invariant: the address is read from the same claimed
registration ID returned by prepare, is never accepted from the request, and
completion binds the outcome to that registration and exact claim. No API
response adds email, user ID, token, claim metadata or participant PII.

### 31.5 Token, claim, status and replay security

The focused contract must deny or return a controlled no-change result for:

- null/invalid registration or claim IDs;
- claim from another registration, event or tenant;
- expired/stale/replaced claim;
- inactive claim that does not match an already-recorded idempotent outcome;
- a token/claim replay after successful completion;
- a claimed row whose event relationship or tenant equality is broken;
- a registration outside the canonical `reserve` candidate set during
  prepare.

Token lookup and public confirmation continue to return stable business
codes without enumeration or extra PII. Tenant hardening does not change
token format, expiry, recipient, email copy, registration statuses or public
confirmation response.

Completion records delivery outcome; it does not promote a participant or
consume capacity. If completion races with event/registration cancellation,
row locks must serialize the writes, record an actual provider success at
most once, clear only the matching claim and never restore an eligible status.
The already-hardened confirmation RPC remains the sole capacity-changing
transition, so cancellation winning the race leaves the token unusable and
capacity uncorrupted. This preserves current business semantics rather than
inventing a new cancellation transition in 2C-2.

### 31.6 Capacity, ordering and concurrency tests

Required deterministic database/concurrency coverage:

| Race / invariant | Expected result |
|---|---|
| two prepare calls for one event | event/registration row locks serialize; a candidate has at most one active claim; duplicate claims for one registration = 0 |
| two reserve candidates and one free place | candidates are prepared in stable FIFO order as today; final public confirmations still allow only capacity-valid transitions |
| same claim completed twice with success | sent timestamp is recorded once; second completion is controlled no-change; duplicate provider effect is prevented by the server claim protocol |
| success and failure completion for one claim | exact row lock/claim predicate permits one changed completion; the loser cannot overwrite the recorded outcome |
| complete versus event cancellation/deactivation | no cross-tenant write, no status restoration, no broken event capacity; existing event-management semantics remain authoritative |
| complete versus registration cancellation | serialized, no status restoration, at most one sent record, cancelled token cannot promote |
| retry after provider/partial failure | claim is safely cleared or remains bounded by expiry; retry creates no duplicate active claim and cannot complete a stale claim |
| Event A with Registration/Claim B | deny; zero changed rows in both tenants |

All tests must assert deadlocks = 0, duplicate changed completions = 0,
cross-tenant promotions = 0, negative availability = 0 and fixture remaining
= 0. Provider calls are mocked locally; production preflight/postflight must
not send real email unless separately authorized.

### 31.7 Email side effects and PII

This promotion flow does **not** insert `email_deliveries`. Its outbound intent
and retry state are the token, claim, attempt, error and sent columns on the
existing tenant-owned `event_registrations` row. Consequently:

- `event_registrations.tenant_id` is derived and checked explicitly;
- no compatibility default is used as the security mechanism;
- event/recipient reads must be limited to the exact prepared event and IDs;
- request/API responses keep the current aggregate counts only;
- logs keep operation/stage and bounded safe error metadata only;
- JWT, service key, full token, claim UUID, provider body, email and other PII
  must not be logged or returned.

Existing `escapeHtml`/`escapeEmailHref` use, plain-text behavior, Resend error
normalization and SEC-006 tests remain mandatory regressions.

### 31.8 ACL, owner, search path and invoker decision

| Function | Target mode | Owner | Target search path | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---:|---:|---:|---:|
| `prepare_event_reserve_promotions(uuid)` | SECURITY INVOKER | postgres | SP1 `pg_catalog, public, pg_temp` | no | no | no | EXECUTE |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | SECURITY INVOKER | postgres | SP1 `pg_catalog, public, pg_temp` | no | no | no | EXECUTE |

Invoker is viable because production confirms service_role already has the
required SELECT/UPDATE table privileges on `events` and
`event_registrations`. The migration must neither widen table ACL nor grant
function EXECUTE to a client role. Owner remains postgres. All object names
and built-ins are schema-qualified.

### 31.9 Fingerprints and mandatory preconditions

Production `pg_get_functiondef` is normalized CRLF/CR -> LF before hashing:

| Signature | Current normalized MD5 |
|---|---|
| `prepare_event_reserve_promotions(uuid)` | `4e73ef1df59936a1a3f41a00e121f6e9` |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `dd5025876008d6eb9551497d84cef90e` |

The implementation migration must abort before DDL unless both overload
counts, signatures, result types, fingerprints, owner, SP2 path and exact
service-only ACL match this baseline. It must also freeze the 2A, 2B-1,
2B-2 and 2C-1 function fingerprints and the remaining-definer aggregate.

Repeat the production data preflight immediately before deployment and stop
unless: registration/event tenant mismatches = 0, claims outside reserve = 0,
duplicate non-null claim IDs = 0, duplicate non-null tokens = 0, active claims
= 0, stale claims = 0 and all seven compatibility defaults are present.
The verified planning baseline was 25 registrations, one reserve row, zero
active/stale claims, four token rows, four sent rows, two confirmed rows and
zero tenant/claim/token anomalies. These counts are evidence, not hard-coded
migration assertions except for the zero-invariant checks.

Local clean-baseline definitions match the captured production bodies
semantically. Any new drift before implementation is a STOP condition and
requires plan review; it must not be overwritten by a broad `CREATE OR
REPLACE`.

### 31.10 Cross-tenant and authorization matrix

Minimum local SQL/Node coverage:

- Event A + Registration A + Claim A: prepare/complete valid path;
- Event A + Registration B: deny and both tenants unchanged;
- Claim B with Registration A: deny;
- Claim A cannot be used for Event B or a registration whose tenant/event
  pair differs;
- admin A and employee A manual prepare for Event A: allow;
- admin A / employee A manual prepare for Event B: deny;
- global legacy admin/pracownik without active Event-B membership: deny;
- pending, suspended, no-membership, user and instructor: deny privileged
  manual prepare;
- service caller derives Event A tenant and cannot cause a Registration-B
  claim/update through Event A;
- invalid, expired, replaced, replayed and already-completed claim cases are
  fail closed/idempotent as defined above;
- public token confirmation remains owner-bound, PII-free and capacity-safe.

Direct anon/authenticated calls to both service functions must fail at ACL.
Tests must separately show that a service credential can execute only the
resource-bound semantics; service access itself is not counted as business
authorization.

### 31.11 Compatibility and rollout

Function signatures, argument names/default, return table/JSON fields and
server helper calls remain unchanged.

| Combination | Result |
|---|---|
| old app + old DB | current single-tenant behavior; manual global-role gap remains |
| **new app + old DB** | **safe compatibility step**: manual route enforces event-derived membership before invoking unchanged service RPCs; automatic cancellation provenance unchanged |
| old app + new DB | function calls still work, but the old manual route can authorize a global role for another tenant; therefore this state is operationally compatible but **not an accepted completed security state** |
| new app + new DB | target tenant-bound route and tenant-bound invoker functions |

The final rollout recommendation is **APP FIRST, then DB in one controlled
low-traffic release**, not DB-first. Verify the app deployment's membership
gate before applying the migration. Keep the second-active-tenant guard in
force throughout. The phase is complete only after both deployments and
postflight pass.

Expected implementation files:

- one new 2C-2 SQL migration;
- one focused SQL test and one deterministic concurrency harness;
- `app/api/send-event-reserve-promotion/route.ts`;
- a new focused route/server authorization Node test;
- this plan and a 2C-2 implementation report.

`lib/server/event-reserve-promotion.ts` should remain unchanged unless a
focused test proves that an additional exact-ID assertion is required. No
browser contract, UI, selected-tenant routing or public API signature changes.

### 31.12 Regression plan

Run, in order:

1. local database reset from the clean migration chain;
2. focused 2C-2 SQL authorization, tenant, token/claim and state tests;
3. deterministic parallel prepare/complete/cancellation tests;
4. focused Node tests for missing/invalid auth, auth upstream failure,
   admin/employee A allow, foreign tenant/global role/pending/suspended/no
   membership deny and safe responses;
5. all 9D-2A, 2B-1, 2B-2 and 2C-1 SQL tests;
6. reserve registration, cancellation, public confirmation, public event
   availability/list, event management and shared email delivery regressions;
7. full Supabase DB suite and all Node tests;
8. TypeScript, production build, focused Events/operational Playwright,
   changed-files ESLint, `npm audit --omit=dev` and `git diff --check`.

Production preflight must verify the same fingerprint/data/ACL guards and
show only the approved migration pending. Postflight must prove final dry-run
up to date, target fingerprints, SECURITY DEFINER count, no drift, route/runtime
smoke, zero real email unless authorized and zero fixture.

### 31.13 SECURITY DEFINER impact and remaining inventory

Current production count after 2C-1 is **72**. Converting these exact two
functions to SECURITY INVOKER produces an expected count of **70**. No new
wrapper or definer is added. Every remaining definer has an assigned bucket;
there is no UNKNOWN.

**Safe/already hardened or deliberate no-change in 2C-2 (31):**

`admin_create_event_v2`, `admin_list_event_registrations_v1`,
`admin_list_events_v1`, `admin_set_event_active_v2`, `admin_update_event_v2`,
`approve_event_registration`, `cancel_event_registration`,
`cancel_reservation`, `confirm_event_reserve_promotion`,
`create_reservation_v2`, `get_check_in_reservation_v1`,
`get_lane_booking_busy_ranges`, `get_lane_booking_busy_ranges_v2`,
`get_lane_booking_busy_ranges_v3`, `get_my_event_registrations_v1`,
`get_my_reservations_v2`, `get_public_check_in_status_v1`,
`get_public_event_availability_v1`, `get_public_event_list_v2`,
`get_reservation_customer_profiles_v1`, `mark_event_registration_paid`,
`register_for_event`, `update_reservation_admin_note`,
`update_reservation_attendance`, `update_reservation_payment`,
`get_my_tenant_role_v1`, `has_tenant_role_v1`,
`is_active_public_tenant_v1`, `is_tenant_member_v1`,
`prepare_confirmation_email`, `check_confirmation_email_rate_limit`.

**9D-3 lane/block/configuration (13):**

`admin_create_lane_block`, `admin_create_lane_booking_family_v1`,
`admin_get_lane_booking_configuration_v1`,
`admin_get_lane_booking_configuration_v2`,
`admin_set_lane_block_active`, `admin_set_lane_booking_configuration`,
`admin_set_lane_booking_family_configuration_v2`, `admin_update_lane_block`,
`lane_booking_family_business_snapshot_v2`,
`normalize_lane_booking_family_payload_v2`,
`validate_lane_booking_rule_capacity`,
`validate_shooting_lane_capacity_change`,
`validate_shooting_lane_hierarchy`.

**9D-4 / 9E reports, profiles, lifecycle and authorization (19):**

`admin_get_reservation_report_export_v1`,
`admin_get_reservation_report_v1`, `admin_get_reservation_report_v2`,
`admin_list_users_v1`, `admin_set_user_note_v1`, `admin_set_user_role_v1`,
`anonymize_my_account_v1`, `export_my_data_v1`, `get_my_role`,
`get_public_booking_configuration_v1`, `handle_new_user`, `is_admin`,
`is_admin_or_employee`, `is_admin_or_staff`,
`prevent_non_admin_profile_privilege_changes`, `update_my_profile_v1`,
`update_profile_contact_details`, `update_profile_identity`,
`update_profile_verification`.

**9D-5 / 9E retirement and bridge gate (7):**

`active_single_tenant_id_v1`, legacy `admin_create_event`,
`admin_set_event_active`, `admin_update_event`, `create_reservation`,
`sync_csk_membership_role_to_profile`,
`sync_profile_role_to_csk_membership`.

### 31.14 Temporary CSK defaults

All 7/7 defaults stay present. 2C-2 neither consumes nor removes one as an
authorization mechanism.

| Table | Promotion writer/read | Tenant explicitly derived/set? | Default used by this flow? | Removal phase |
|---|---|---:|---:|---|
| `events` | prepare locks/reads event; helper reads event | derived from the existing event row; no insert | no | 9D-5 after all writer/caller gates |
| `event_registrations` | prepare/complete update existing registrations | explicit event + registration tenant equality | no | 9D-5 after event-domain proof |
| `email_deliveries` | none; promotion state is stored on registration | not applicable | no | 9D-5 after 2C-1 proof |
| `shooting_lanes`, `reservations`, `lane_blocks`, `event_lanes` | no 2C-2 writer | unchanged | unchanged | their assigned 9D-3/5 gates |

The mandatory global gate remains: remove compatibility defaults only after
tenant-aware writer cutover and before a second tenant can be activated.

### 31.15 Rollback and STOP conditions

Database rollback is a reviewed **forward migration** restoring only the two
captured function bodies, SECURITY DEFINER modes, SP2 paths, postgres owner
and exact service-only ACL. Never edit an applied migration or use migration
repair. Application rollback before the DB migration returns to the known
old state; after the DB migration it would reopen the manual-route business
authorization gap, so do not roll back the app alone. Prefer forward-fixing
the app or coordinate app + DB rollback while Tenant B remains blocked.

STOP on fingerprint/ACL/owner/path drift, any unexpected overload, tenant
mismatch, claim outside reserve, duplicate claim/token, active or stale claim
at deployment, widened grant/table ACL, service key in client output,
cross-tenant allow, duplicate provider/completion effect, FIFO/capacity/status
regression, PII/token leak, unexpected SECURITY DEFINER drift, nonzero fixture
or any additional pending migration.

### 31.16 SEC-004 impact and final gate

After a future local, production preflight, APP-FIRST deployment, DB deployment
and postflight PASS, SAAS-9D-2C can be marked **CLOSED / PROD PASS**. It will
close the remaining event reserve-promotion service claim boundaries and the
manual route's global-role authorization gap.

It will not close SEC-004. Exact remaining scope is:

- 9D-3: lane, block and lane-configuration functions;
- 9D-4: reports, users/profiles, account lifecycle and legacy authorization;
- 9D-5: legacy functions, seven defaults, CSK sync bridges and final definer
  disposition;
- 9E+: trusted selected-tenant application context and routing, then module
  cutovers;
- 9G: full cross-tenant application IDOR/concurrency proof;
- 9H: SEC-004 closure and second-tenant readiness audit.

There is no unresolved product-semantic decision for local implementation:
existing multi-recipient notification, first-confirmed-wins capacity rule,
FIFO iteration, token TTL, claim TTL, retry responses and cancellation status
behavior are all preserved. The required manual-route membership correction
is explicitly part of the approved implementation boundary.

SAAS-9D-2C-2 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2C-2 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 32. SAAS-9D-2C-2 local implementation result (2026-09-14)

The approved event reserve-promotion slice has been implemented and verified locally.

- `POST /api/send-event-reserve-promotion` now derives `events.tenant_id` through the authenticated caller and requires an active tenant membership with role `admin` or `employee` before the existing service helper is invoked. The legacy global `profiles.role` authorization path is removed.
- `prepare_event_reserve_promotions(uuid)` and `complete_event_reserve_promotion(uuid,uuid,boolean,text)` retain their signatures and response contracts, use explicit event/registration/tenant predicates, and have moved from SECURITY DEFINER/SP2 to SECURITY INVOKER/SP1 with exact service-only EXECUTE.
- APP-FIRST compatibility was proven with real local HTTP calls against both the old DB baseline and the migrated DB: valid Tenant-A admin `200`, membership-less legacy admin `403`, cross-tenant/inaccessible event `404`, malformed `400`, unknown `404`.
- Focused SQL passed 36/36; deterministic concurrency passed all six scenarios with zero deadlocks, duplicate final effects, broken invariants, or fixture; full DB passed 972/972; Node passed 739/739; focused Playwright Events passed 8/8 and the full Playwright suite passed 30/30; TypeScript, build, changed-files ESLint, and fixture cleanup passed.
- The expected SECURITY DEFINER inventory is 70, non-target drift is zero, and all 7/7 compatibility defaults remain present.
- Migration SHA-256: `A9373F9BCFBB456624720FB2AFFB94A416C428454B7881E6FB2649F21ED39759`.
- `npm audit --omit=dev` reports one unrelated MODERATE transitive `baseline-browser-mapping` advisory; it is outside this RPC-hardening scope.

Detailed evidence is recorded in `SAAS_9D_2C2_RESERVE_PROMOTION_RPC_HARDENING_REPORT.md`.

SAAS-9D-2C-2 LOCAL: **PASS**

READY FOR SAAS-9D-2C-2 PRODUCTION APP PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR SAAS-9D-3: **NO-GO until 2C-2 full production rollout/checkpoint**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
