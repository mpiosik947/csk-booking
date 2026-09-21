# SAAS FINAL MIGRATION MASTER REPORT

Updated: 2026-09-21 (Europe/Warsaw)

## Current stage

**Stage A — SAAS-9E-C C3 final reproducibility checkpoint.** C3 database and application production deployments are PASS. The remaining action is the explicit checkpoint for the canonical migration, SQL/regression tests and C3 documentation. Stage B (4D-2) starts only after that checkpoint is pushed and verified.

## Completed stages

- SAAS-9A through SAAS-9E-B: closed according to the authoritative prior reports/checkpoints.
- SAAS-9E-C Phase 1: CLOSED / PROD PASS.
- SAAS-9E-C Phase 2: CLOSED / PROD PASS; checkpoint `634ca40c8684292681e83855b87f4a09a3fc3dce`.
- SAAS-9E-C Phase 3 DB: production migration `20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql`, SHA-256 `012A0472EA74CF17FD912C37B78A63B3BA68DF50144A46B35A0EAD5C2CAD6D0D`; history 107/107 and pending 0; rollback-only 16/16; fixture residue 0.
- SAAS-9E-C Phase 3 app: commit `b3a85bba9797f4ea056fbd41d6b3e990af59b2cc`, pushed to `origin/main` by fast-forward; authenticated production screen smoke PASS with stated ICS/mutating limitations.

## Current production state

- Application: C3 target live on `csk-booking-5nwh.vercel.app`.
- Database: C3 contract live; SECURITY DEFINER 96; bridge definitions 22; compatibility defaults 7/7.
- Migration history: LOCAL = REMOTE through `20260928100000`; pending 0.
- Runtime callers at deployed source: legacy operational 0; `get_my_role()` 0; direct `is_admin*` application helper callers 0.
- Active production tenants: exactly one active CSK tenant. Second production tenant remains NO-GO.
- SEC-004 remains OPEN pending Stages B–F.

## Latest test counts

- Clean local replay: PASS.
- Full DB: 51 files, 1543/1543 PASS (repeated after final cleanup).
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

## Blockers and exclusions

- 4D-2 is not yet implemented; entry review follows the C3 final checkpoint.
- 9D-5 is not yet implemented; bridge/default removal requires per-object dependency proof.
- Second production tenant remains blocked until Stage G readiness verdict.
- SEC-004 remains OPEN.
- `AGENTS.md` is unrelated and always excluded. `supabase/drafts/*` is non-deployable and always excluded.
- Production owner ICS download was not exercised after app deployment because the authenticated account had no active reservation. No production mutating E2E or two-active-tenant UI test was performed.
- Legal/GDPR public-launch gate remains separate and incomplete until the final legal/tracker/consent review.

## Next stage

Complete and push the C3 final reproducibility checkpoint, then perform the exact 4D-2 zero-caller entry audit from `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`. No second tenant activation.
