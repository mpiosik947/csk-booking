# CSK Booking — Final Clean Confirmation 2026-09

## Scope

This is a short, read-only post-remediation confirmation at:

- HEAD: `40f30bb — docs: record CLEAN-005 production smoke pass`
- CLEAN-004: `7e0d05f — security: block direct reservation deletes`
- CLEAN-005: `fe1783b — security: harden profile updates`

No application code, SQL, configuration, local or production database state was
changed by this review. The only workspace change is this report.

## CLEAN-004 confirmation

**Status: confirmed remediated, no regression found.**

- `authenticated` has no direct `DELETE` on `public.reservations`.
- The broad administrator reservation DELETE policy is absent.
- Anonymous, ordinary user, instructor, employee and administrator direct
  deletion is covered by the current regression test and remains denied.
- Supported owner, employee and administrator cancellation paths remain
  controlled RPC operations.
- Cancellation retains the reservation record and operational history.
- Successful controlled state change remains audited; idempotent/no-change
  behavior does not create a false duplicate audit.
- The full local DB suite reran the dedicated CLEAN-004 contract successfully.

## CLEAN-005 confirmation

**Status: confirmed remediated, no regression found.**

- `authenticated` has no direct `UPDATE` on `public.profiles`.
- No broad profile UPDATE policy remains.
- Anonymous, ordinary-user foreign/self, instructor, employee and administrator
  direct profile updates remain denied by the database contract.
- `update_my_profile_v1(...)` is owner-scoped through `auth.uid()` and exposes
  only the approved contact/address and declaration parameters. It has no
  arbitrary target-user, role, verification, admin-note or internal-field
  parameter.
- `/account` uses `update_my_profile_v1` and has no direct
  `.from("profiles").update(...)` fallback.
- Dedicated administrator and employee RPCs remain available for their
  authorized role, verification, note, identity and contact operations.
- Controlled changes retain database-attributed actor/timestamp audit behavior;
  no-change operations remain idempotent.
- `anonymize_my_account_v1()` remains compatible with the hardened profile ACL,
  so SEC-009 lifecycle behavior is not regressed.
- The full local DB suite reran the dedicated CLEAN-005 contract successfully.

## Fast trust-boundary regression review

The two remediation migrations are fail-closed hardening changes: CLEAN-004
removes authenticated reservation DELETE and its administrator policy;
CLEAN-005 removes authenticated profile UPDATE and both direct UPDATE policies.
Neither introduces a broader grant, a new client-side destructive path or a new
service-role call site.

Current application source contains no PostgREST `.delete()`/`.update()` call
against `reservations` or `profiles`; matching `.delete()` occurrences are local
JavaScript collection cleanup only. Existing service-role usage remains confined
to previously reviewed server-only delivery, reserve-promotion and account Auth
Admin lifecycle boundaries. CLEAN-004 and CLEAN-005 add no browser exposure of
that credential and no new elevated runtime path.

Updated ACL regression tests continue to guard public-function, table and
sequence privileges after both migrations. The current full database suite also
passes cross-writer invariants and the remote-baseline contract.

## Verification results

| Check | Result | Evidence |
|---|---|---|
| Node tests | PASS | `node --test`: 614 passed, 0 failed, 0 skipped. |
| Supabase DB tests | PASS | `npx.cmd supabase test db --local`, explicitly targeting local `127.0.0.1:54322`: 14 files, 269 tests, all successful. No linked/remote operation was used. |
| TypeScript | PASS | `npx.cmd tsc --noEmit`: exit code 0. |
| Next.js build | PASS | Next.js 16.3.4 production build completed, including all 37 static pages and dynamic routes. The existing middleware-to-proxy deprecation notice is maintenance, not a new security regression. |
| Production dependency audit | PASS | `npm.cmd audit --omit=dev`: 0 vulnerabilities. |
| ESLint | KNOWN BASELINE | `npx.cmd eslint .`: exactly 14 errors and 6 warnings. New CLEAN-004/CLEAN-005 confirmation regressions: 0. No lint remediation was performed. |
| Whitespace validation | PASS | `git diff --check`: no whitespace errors. |

## New findings

No new finding met the requested threshold. In particular, this confirmation
found:

- new Critical: 0
- new High: 0
- new Medium P1: 0
- P0: none
- P1 before feature work: none

No `CONFIRM-*` identifier is assigned because there is no new confirmed issue.

## Known accepted or deferred security debt

These are pre-existing decisions or residuals, not new findings:

| Residual | Current severity/status | Required timing |
|---|---|---|
| SEC-004 / CLEAN-001 tenant isolation | HIGH before SaaS; no demonstrated second-tenant boundary in the current installation | Mandatory architecture work before tenant two. |
| SEC-008 / CLEAN-002 instructor event access | MEDIUM, deferred pending authoritative instructor-to-event assignment model | Resolve before enabling the scoped instructor participant model and before SaaS. |
| SEC-009 10B time-based retention | LOW privacy/compliance debt, deferred pending retention-period decisions | Approve periods before scheduled retention implementation. |
| SEC-010 leaked-password protection | LOW accepted residual caused by current plan limitation | Enable when the platform plan/capability permits. |
| SEC-016 owner/legal data | INFO deferred business/legal completion | Complete before formal commercial launch. |
| Managed Supabase ACL defaults / CLEAN-007 | LOW accepted platform residual, guarded by ownership/default-ACL tests | Continue explicit ACL review for every new public object. |
| CLEAN-003 lane-block reason visibility | LOW pre-existing data-minimization residual | Fix before sensitive free text or multi-tenant use. |
| Nonce/hash CSP hardening | INFO defense-in-depth residual | Separate compatible Next.js rollout; not a current feature-work blocker. |

## Readiness

The current single-tenant installation is ready to continue feature work with
the documented accepted/deferred residuals. CLEAN-004 and CLEAN-005 no longer
remain P1 blockers.

SaaS or a second tenant is not ready. Before that boundary exists, the system
needs authoritative tenant/membership ownership propagated through tables,
RLS, RPCs, server routes, audit and operational jobs. Instructor/event access,
lane-block visibility and retention governance must also be tenant-safe. Final
legal controller/contact data must be completed before commercial launch.

```text
FINAL CLEAN CONFIRMATION:
PASS

NEW CRITICAL:
0

NEW HIGH:
0

NEW MEDIUM P1:
0

P0:
NONE

P1:
NONE

CURRENT SINGLE-TENANT:
READY WITH ACCEPTED RESIDUALS

BLOCKERS BEFORE FEATURE WORK:
NONE

SAAS / SECOND TENANT:
NOT READY

BLOCKERS BEFORE SAAS:
End-to-end tenant/membership isolation; authoritative instructor-to-event
assignment and scoped registration access; tenant-safe lane-block visibility;
approved time-based retention; final legal controller/contact data.
```
