# SAAS FINAL MIGRATION MASTER REPORT

Updated: 2026-09-22 (Europe/Warsaw)

## Current stage

**Stage C — SAAS-9D-5A CLOSED / PROD PASS.** Additive onboarding DB capability, application deployment `dd02b3138a591966697d89cce7d72c2a3b3b054d`, and corrected forward-only A2 retirement are live on the primary `csk-booking-5nwh` project. The discovered `auth.users.on_auth_user_created -> public.handle_new_user()` path is preserved as the canonical global-profile-only trigger. Both legacy CSK role-sync directions are removed, and the profile privilege guard no longer depends on the exact-single-tenant or profile-role bridge.

## Completed stages

- SAAS-9A through SAAS-9E-B: closed according to the authoritative prior reports/checkpoints.
- SAAS-9E-C Phase 1: CLOSED / PROD PASS.
- SAAS-9E-C Phase 2: CLOSED / PROD PASS; checkpoint `634ca40c8684292681e83855b87f4a09a3fc3dce`.
- SAAS-9E-C Phase 3 DB: production migration `20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql`, SHA-256 `012A0472EA74CF17FD912C37B78A63B3BA68DF50144A46B35A0EAD5C2CAD6D0D`; history 107/107 and pending 0; rollback-only 16/16; fixture residue 0.
- SAAS-9E-C Phase 3 app: commit `b3a85bba9797f4ea056fbd41d6b3e990af59b2cc`, pushed to `origin/main` by fast-forward; authenticated production screen smoke PASS with stated ICS/mutating limitations.
- SAAS-9E-C Phase 3 final checkpoint: `9d8c893b401436a1ac2fb122eeeae179bd165f16`, pushed to `origin/main`; repository reproducible.
- SAAS-9D-4D-2: production migration `20260929100000_close_global_role_helper_execute.sql`, SHA-256 `4086E195BCE1F3A1CB0C107AC5231923BCBAED24132083990A3763BDC335D7AE`; deploy and post-deploy PASS.

## Current production state

- Application: C3 target live on `csk-booking-5nwh.vercel.app`.
- Database: corrected A2 live; SECURITY DEFINER 95; canonical auth-to-profile trigger present; legacy role-sync triggers/functions 0/0; compatibility defaults 7/7.
- Migration history: LOCAL = REMOTE through `20260930110000`; pending 0; final linked dry-run reports the remote database is up to date.
- Runtime callers at deployed source: legacy operational 0; `get_my_role()` 0; direct `is_admin*` application helper callers 0.
- Legacy global-role helper ACL: PUBLIC/anon/authenticated/service_role EXECUTE denied on all four; bodies retained owner-only for 9D-5.
- Active production tenants: exactly one active CSK tenant. Second production tenant remains NO-GO.
- SEC-004 remains OPEN pending Stages B–F.

## Latest test counts

- Clean local replay: PASS.
- Full DB after the corrected A2 clean replay: 53 files, 1579/1579 PASS.
- Focused 9D-5A onboarding/cutover SQL: 24/24 PASS.
- Node: 782/782 PASS.
- TypeScript: PASS.
- Production build: PASS (known middleware→proxy deprecation warning).
- Changed-file ESLint: PASS, 0 new errors/warnings.
- Playwright: 38/38 PASS.
- Local fixture cleanup: 0 test users/profiles/lanes/events; one active tenant; 95 definers.
- `npm audit --omit=dev`: not rerun during the A2 blocker correction because the environment did not authorize the registry metadata request; no dependency files changed.
- Production C3 rollback-only DB matrix: 16/16 PASS; persisted fixture 0.

## Security and compatibility counters

| Counter | Current |
|---|---:|
| SECURITY DEFINER | 95 |
| Unexpected C3 DEFINER drift | 0 |
| Bridge definitions | 22 |
| Compatibility defaults | 7/7 |
| Legacy operational app callers | 0 |
| `get_my_role()` app/API callers | 0 |
| Cross-tenant anomalies in C3 production integrity checks | 0 |
| Closed legacy global-role helper ACLs | 4/4 |
| Active RLS/routine/trigger dependencies on those helpers | 0/0/0 |

## Blockers and exclusions

- SAAS-9D-5A is deployed and verified; only its reproducibility checkpoint remains.
- Normal 9D-5 bridge/default retirement requires a fresh per-object dependency audit after this checkpoint.
- Second production tenant remains blocked until Stage G readiness verdict.
- SEC-004 remains OPEN.
- `AGENTS.md` is unrelated and always excluded. `supabase/drafts/*` is non-deployable and always excluded.
- Production owner ICS download was not exercised after app deployment because the authenticated account had no active reservation. No production mutating E2E or two-active-tenant UI test was performed.
- Legal/GDPR public-launch gate remains separate and incomplete until the final legal/tracker/consent review.

## Next stage

Run the fail-closed 9D-5A production preflight, then deploy in the frozen compatibility order: onboarding DB capability (`20260930100000`) → application callers → legacy trigger/guard retirement (`20260930110000`). Only after 9D-5A PROD PASS may normal 9D-5 bridge/default retirement resume. No second tenant activation.

## SAAS-9D-5A TENANT-AWARE ONBOARDING CUTOVER

### Legacy trigger problem

The pre-9D-5A model coupled global identity and tenant authority. Creating/updating a global profile could select the exact single active tenant and mirror `profiles.role` into `tenant_memberships`; the inverse membership trigger mirrored the tenant role back to the global profile. `prevent_non_admin_profile_privilege_changes()` also depended on the exact-single-tenant helper. This made the current one-tenant deployment an implicit authority source and blocked safe continuation of 9D-5.

### Chosen architecture and onboarding flow

- `auth.users` plus `profiles` creates a global account only; no tenant, membership, role or verification is inferred.
- Membership is created only when an authenticated user enters a validated tenant-scoped booking or event-registration write flow.
- The application validates the target resource and its tenant first, invokes self-onboarding second, and performs the business write third.
- The DB resolves an active tenant from the canonical server-validated slug. It never trusts a supplied `tenant_id`, `profiles.role`, an exact-single-active-tenant assumption or a hidden CSK fallback.
- Self-onboarding can create only the caller's own `role=user,status=active` membership. It is idempotent under the existing `(tenant_id,user_id)` key and preserves every existing membership, including privileged or non-active state.
- `/account` and `/dashboard` remain global and do not create membership.

### Migrations and contracts

1. `20260930100000_add_tenant_self_onboarding.sql` — SHA-256 `3B774502775B56DD0A76A33ED4DD213878B8926438D9297714E9D3620AFA3B58`.
   Adds `self_onboard_tenant_v1(text)` as an authenticated-only, fixed-search-path, owner-`postgres` contract. It validates the active tenant slug and authenticated user, inserts only an own user membership, returns a minimal relationship DTO and writes a tenant-bound PII-free audit record only for a new relationship. Local intermediate SECURITY DEFINER count: 97.
2. Application cutover — `create-reservation` and `register-event` call the server-only onboarding helper only after resource/tenant validation. No browser service-role use and no client tenant authority were introduced.
3. `20260930110000_retire_implicit_csk_onboarding.sql` — corrected forward-only SHA-256 `D30EF39EB5331A6CD7E4F60EA6B38E5206B3F86C315461B37B7300779F299B4E`.
   Preserves the canonical auth-signup profile trigger, positively verifies its exact trigger metadata and global-profile-only function semantics, conditionally creates it only for canonical clean replays where the public-schema baseline could not contain an `auth.users` trigger, retires both role-sync triggers/functions, and rewrites the profile privilege guard without exact-single-tenant or global-role authority. The existing identity/contact writers pass an explicit validated tenant context for their narrow protected-field workflow. Local final SECURITY DEFINER count: 95.

### Retired and retained state

- `sync_profile_role_to_csk_membership`: removed locally.
- `sync_csk_membership_role_to_profile`: removed locally.
- `profiles.role`: retained physically as **LEGACY / NON-AUTHORITATIVE / SYSTEM-ONLY** and frozen against operational owner mutation.
- Profile privilege guard exact-single dependency: removed locally.
- Exact-single helper runtime/dependency inventory after the cutover: 0 local dependencies.
- Existing staff membership/role/status management and last-admin protections remain authoritative and unchanged in scope.
- Compatibility defaults remain 7/7 until normal 9D-5; 9D-5A does not remove them.

### Local verification

- Clean migration replay against `127.0.0.1:54322`: PASS.
- Focused onboarding matrix: 24/24 PASS, including no signup membership, user-only self-onboarding, idempotency, inactive/invalid/anonymous denial, two-tenant isolation, existing membership preservation, role-escalation denial, frozen profile role and trigger retirement.
- Full Supabase DB suite: 53 files, 1579/1579 PASS.
- Node: 782/782 PASS; TypeScript: PASS; production build: PASS.
- Changed-file ESLint: PASS; Playwright: 38/38 PASS.
- Local fixture cleanup: users 0, profiles 0, lanes 0, events 0; active tenants 1.
- Trigger inventory: legacy sync triggers 0. Exact-single dependencies: 0. Final local SECURITY DEFINER count: 95.
- `git diff --check`: PASS (Windows line-ending notices only).

### A2 auth-profile trigger blocker review

Production contains exactly one enabled non-internal trigger on `auth.users`:

`CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user()`

`public.handle_new_user()` has an empty signature, owner `postgres`, `SECURITY DEFINER`, fixed `search_path=public, pg_temp`, and no direct EXECUTE for PUBLIC, anon, authenticated or service_role. Its production normalized `pg_get_functiondef` fingerprint is `10a0141f56f2baf69aa3e767d58338c0`; its normalized-EOL `prosrc` fingerprint is `9765e3a659e1e3f6395848dd52f74fb6`; and the cross-environment semantic whitespace-normalized body fingerprint is `1de0460e8b4298219dd8be7d953bb0f5`. Clean local replay produces the same semantic fingerprint (the raw definition differs only because the baseline dump formats the function body differently).

The function reads identity/contact metadata from the new auth user and inserts/upserts only `public.profiles`, initializing the legacy global defaults `role='user'` and `verification_status='pending'`. It does not read or write `tenant_memberships`, resolve CSK or an exact-single-active tenant, assign tenant role/status/verification/admin-note state, invoke onboarding, invoke a role-sync helper, or call a bridge RPC.

- AUTH PROFILE TRIGGER PURPOSE: **GLOBAL PROFILE ONLY**
- IMPLICIT MEMBERSHIP CREATION: **NO**
- IMPLICIT CSK: **NO**
- LEGACY ROLE MIRROR: **NO**

Root cause classification: **A (stale) + B (incorrect) + D (canonical migration boundary)**. The remote public-schema baseline contains `handle_new_user()` but cannot faithfully carry an `auth.users` trigger. The later trigger-preservation migration explicitly accepted zero or one canonical trigger. A2 incorrectly converted that dump limitation into a zero-trigger production invariant; production was not unsafe and showed no semantic drift.

The forward-only correction therefore does not edit historical migrations and does not drop/recreate a correct production trigger. It verifies the function metadata, ACL, semantic fingerprint and forbidden tenant side effects; accepts exactly one matching canonical trigger; creates that trigger only when clean replay has zero; and fails closed on missing function, alternate target, extra trigger, unexpected WHEN clause, fingerprint drift or tenant behavior. The focused test still contains 24 semantic assertions. Legacy SQL fixtures were updated only to tolerate the now-canonical profile auto-creation, and local Playwright fixture writes were moved to the existing local-postgres setup so the production profile guard remains unchanged.

### Compatibility and production state

| Combination | Status |
|---|---|
| Current app + current DB | Existing production baseline; PASS |
| Current app + onboarding-capability DB | Compatible; new RPC is additive and old implicit onboarding remains until retirement migration |
| New app + onboarding-capability DB | Target transition state; explicit onboarding available while legacy behavior remains compatible |
| New app + final 9D-5A DB | Local PASS; legacy sync and exact-single profile-guard dependency removed |
| Current app + final 9D-5A DB | Not an approved rollback target because old callers can still assume implicit membership |

Production staged state:

- `20260930100000_add_tenant_self_onboarding.sql`: **PROD PASS**; migration history LOCAL=REMOTE for A1, normalized RPC fingerprint `2b3e722279bfe2372cbe951e16f8d315`, ACL/owner/search_path PASS, SECURITY DEFINER 97, sync triggers still 2, defaults 7/7.
- Application checkpoint `dd02b3138a591966697d89cce7d72c2a3b3b054d`: pushed fast-forward and deployed successfully to the authoritative `csk-booking-5nwh` Vercel project. Public runtime smoke: 12/12 routes without 5xx; the write endpoint rejects an unsupported method with 405 and `private, no-store`.
- A second legacy/parallel Vercel project named `csk-booking` failed its duplicate deployment, while the authoritative `csk-booking-5nwh` deployment succeeded. No production alias failure was observed.
- `20260930110000_retire_implicit_csk_onboarding.sql`: **NOT DEPLOYED**. The migration transaction aborted at its first preflight block; migration history still shows it as the sole pending migration and dry-run still lists exactly A2.
- Drift evidence: production trigger `on_auth_user_created` is enabled on `auth.users` and executes `public.handle_new_user()`; normalized function fingerprint `10a0141f56f2baf69aa3e767d58338c0`. The pending migration expected zero such triggers. Existing frozen guard fingerprint remains `8a3cb4dc2d663cbf3c866fc3d9c8dac7`, SECURITY DEFINER remains 97, and both legacy sync triggers remain enabled. Therefore no partial A2 change persisted.

The required order DB capability → application → retirement DB migration completed successfully. The corrected A2 production preflight verified project `yuyxfodozzpzrdzkmolu`, final SHA-256 `D30EF39EB5331A6CD7E4F60EA6B38E5206B3F86C315461B37B7300779F299B4E`, LOCAL=REMOTE through A1, A2 as the sole pending migration, canonical trigger/function semantics, legacy sync baseline 2/2, SECURITY DEFINER 97, compatibility defaults 7/7, one active tenant and zero checked integrity anomalies. The dry-run listed exactly A2.

Production deployment and post-deploy verification:

- `20260930110000_retire_implicit_csk_onboarding.sql`: **PROD PASS**.
- Migration history: LOCAL=REMOTE through A2; pending 0; final dry-run: remote database is up to date.
- Canonical `auth.users.on_auth_user_created -> public.handle_new_user()`: present exactly once, enabled, AFTER INSERT/FOR EACH ROW/no WHEN; semantic fingerprint remains `1de0460e8b4298219dd8be7d953bb0f5`.
- Legacy sync triggers/functions: 0/0.
- Profile guard forbidden bridge references (`active_single_tenant_id_v1`, `profile_role_rpc`): 0. Tenant-membership checks retained inside explicitly tenant-bound identity/contact workflows are operational-relationship validation, not global role mirroring.
- SECURITY DEFINER: 95; compatibility defaults: 7/7; active tenants: 1; checked membership/reservation/event integrity anomalies: 0.
- Production rollback-only A2 matrix: 24/24 PASS. It covered canonical profile-only signup, no implicit membership, explicit onboarding, idempotency, inactive/invalid/anonymous denial, two-tenant independence, role escalation denial, no role mirroring, controlled profile updates, defaults and inventory. Final `ROLLBACK` executed.
- Persistent fixture residue after rollback: tenants 0, auth users 0, profiles 0, memberships 0, audits 0; active tenants restored to exactly 1.
- Runtime HTTP smoke: `/`, `/booking`, `/events`, `/login`, `/account`, `/admin`, `/admin/reservations`, `/admin/calendar`, `/admin/reports`, `/admin/check-in` all returned 200; no 5xx.

### Final residual inventory

- Obsolete bridge/default retirement remains normal SAAS-9D-5 work after 9D-5A production PASS.
- Compatibility defaults: 7/7 retained.
- Second production tenant: NO-GO.
- SEC-004: OPEN until SAAS-9H.
- `AGENTS.md`, `supabase/drafts/*` and the pre-existing C3-only plan diff remain unrelated/excluded.
