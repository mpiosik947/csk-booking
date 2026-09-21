# SAAS FINAL MIGRATION MASTER REPORT

Updated: 2026-09-21 (Europe/Warsaw)

## Current stage

**Stage B — SAAS-9D-4D-2 final reproducibility checkpoint.** C3 is closed and reproducible. The four legacy global-role helpers have zero runtime/DB dependencies and their client EXECUTE path is closed in production. Stage C (9D-5) starts after this exact checkpoint is pushed and verified.

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
- Full DB: 52 files, 1555/1555 PASS (repeated after final cleanup).
- Node: 777/777 PASS.
- TypeScript: PASS.
- Production build: PASS (known middleware→proxy deprecation warning).
- Changed-file ESLint: 0 errors, 3 existing hook warnings.
- Playwright: 38/38 PASS.
- Local fixture cleanup: 0 test users/profiles/lanes/events; one active tenant; 96 definers.
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

Create and push the exact 4D-2 reproducibility checkpoint, then perform the per-object 9D-5 bridge/default zero-dependency audit. No second tenant activation.
