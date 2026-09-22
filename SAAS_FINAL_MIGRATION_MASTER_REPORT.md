# SAAS FINAL MIGRATION MASTER REPORT

Updated: 2026-09-22 (Europe/Warsaw)

## Current stage

**Stage C — SAAS-9D-5A tenant-aware onboarding cutover, local gate PASS.** The architectural blocker in implicit CSK onboarding has a forward-only replacement and retirement sequence that passed clean local replay and the full regression gate. Production remains unchanged pending the staged DB → app → DB preflight and rollout.

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
- Database: 4D-2 ACL closure live; SECURITY DEFINER 96; bridge definitions 22; compatibility defaults 7/7.
- Migration history: LOCAL = REMOTE through `20260929100000`; pending 0.
- Runtime callers at deployed source: legacy operational 0; `get_my_role()` 0; direct `is_admin*` application helper callers 0.
- Legacy global-role helper ACL: PUBLIC/anon/authenticated/service_role EXECUTE denied on all four; bodies retained owner-only for 9D-5.
- Active production tenants: exactly one active CSK tenant. Second production tenant remains NO-GO.
- SEC-004 remains OPEN pending Stages B–F.

## Latest test counts

- Clean local replay: PASS.
- Full DB after 9D-5A: 52 files, 1499/1499 PASS.
- Focused 9D-5A onboarding/cutover SQL: 24/24 PASS.
- Node: 782/782 PASS.
- TypeScript: PASS.
- Production build: PASS (known middleware→proxy deprecation warning).
- Changed-file ESLint: PASS, 0 new errors/warnings.
- Playwright: 38/38 PASS.
- Local fixture cleanup: 0 test users/profiles/lanes/events; one active tenant; 95 definers.
- `npm audit --omit=dev`: one moderate transitive `baseline-browser-mapping` advisory remains; no production-code regression was introduced and no unrelated dependency rewrite was performed.
- Production C3 rollback-only DB matrix: 16/16 PASS; persisted fixture 0.

## Security and compatibility counters

| Counter | Current |
|---|---:|
| SECURITY DEFINER | 96 |
| Unexpected C3 DEFINER drift | 0 |
| Bridge definitions | 22 |
| Compatibility defaults | 7/7 |
| Legacy operational app callers | 0 |
| `get_my_role()` app/API callers | 0 |
| Cross-tenant anomalies in C3 production integrity checks | 0 |
| Closed legacy global-role helper ACLs | 4/4 |
| Active RLS/routine/trigger dependencies on those helpers | 0/0/0 |

## Blockers and exclusions

- 4D-2 is deployed and verified; only its reproducibility checkpoint remains.
- 9D-5 is not yet implemented; bridge/default removal requires per-object dependency proof and begins only after the 4D-2 checkpoint.
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
3. `20260930110000_retire_implicit_csk_onboarding.sql` — SHA-256 `E4C4292F3F3CE4EFA3F49D7D2EF4A41B8A8473671AB1EEDEE237975CF03D5E28`.
   Retires both role-sync triggers/functions, replaces auth signup handling with profile-only creation, and rewrites the profile privilege guard without exact-single-tenant or global-role authority. The existing identity/contact writers pass an explicit validated tenant context for their narrow protected-field workflow. Local final SECURITY DEFINER count: 95.

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
- Full Supabase DB suite: 52 files, 1499/1499 PASS.
- Node: 782/782 PASS; TypeScript: PASS; production build: PASS.
- Changed-file ESLint: PASS; Playwright: 38/38 PASS.
- Local fixture cleanup: users 0, profiles 0, lanes 0, events 0; active tenants 1.
- Trigger inventory: legacy sync triggers 0. Exact-single dependencies: 0. Final local SECURITY DEFINER count: 95.
- `git diff --check`: PASS (Windows line-ending notices only).

### Compatibility and production state

| Combination | Status |
|---|---|
| Current app + current DB | Existing production baseline; PASS |
| Current app + onboarding-capability DB | Compatible; new RPC is additive and old implicit onboarding remains until retirement migration |
| New app + onboarding-capability DB | Target transition state; explicit onboarding available while legacy behavior remains compatible |
| New app + final 9D-5A DB | Local PASS; legacy sync and exact-single profile-guard dependency removed |
| Current app + final 9D-5A DB | Not an approved rollback target because old callers can still assume implicit membership |

Production state is **NOT YET DEPLOYED** for 9D-5A. Required rollout is strictly DB capability first, application second, retirement DB migration last. Production preflight must prove exact SHAs, migration history, fingerprints, tenant/membership integrity, clean dry-run and the same compatibility order before any write.

### Final residual inventory

- Obsolete bridge/default retirement remains normal SAAS-9D-5 work after 9D-5A production PASS.
- Compatibility defaults: 7/7 retained.
- Second production tenant: NO-GO.
- SEC-004: OPEN until SAAS-9H.
- `AGENTS.md`, `supabase/drafts/*` and the pre-existing C3-only plan diff remain unrelated/excluded.
