# PRODUCT-10F — LOCAL IMPLEMENTATION / ACL RECOVERY

## Authoritative clean cutover preflight — 2026-09-25: PASS

This supersedes all earlier grace-period and infrastructure blocker sections below.
Approved business decision: NO grace period. Canonical Auth is https://strzelajtu.pl;
legacy host initiation/completion redirects without token, cookie or PKCE transfer.
Exact target allowlist: /auth/callback and /reset-password on canonical only.
Five current Krutla entries (including wildcard) are removed only at future cutover.
No Vercel Auth entries exist to remove.

Fresh evidence: focused SQL43/43, full DB2013/2013, concurrency3/3 (deadlocks0),
Node839/839, isolated production-build Playwright59/59, TypeScript/build PASS,
ESLint0 errors/1 existing warning, schema/diff PASS, fixture cleanup0.
Candidate manifest68 files: extra test configuration isolates port3100 with
reuseExistingServer=false. Main mixed port3000 is never accepted as candidate evidence.
First accidental mixed-server run and Turbopack junction startup failure are recorded
in the full report; final tests run against exact rebuilt candidate.

Live production: remote20261010100000, 126 matching versions, exactly one pending10F,
dry-run exactly20261011100000, existing161 normalized function/metadata/ACL drift0.
Migration SHA unchanged: 737ED1F7CB4D7CC3D009ACD17D456424B2F048CDA8ABE0FA74D5CEA69D9086BB.
Vercel csk-booking-5nwh: both names Valid Configuration; apex HTTPS200, www HTTPS308
to apex, certificate verification PASS. DNS matches exact Vercel targets.
Auth Site URL/allowlist remain unchanged; no production writes in this task.

PREFLIGHT PASS; ready for precise staging and ordered DB/app/Auth deployment.
Execution still requires separate authorization. Live email completion is verified
after canonical Auth configuration is saved, not under the old allowlist.
Full handoff: C:/Users/Mpios/Desktop/APP Krutla/PRODUCT_10F_CLEAN_CUTOVER_PREFLIGHT_REPORT.md.

## Latest production preflight retry — 2026-09-25

Supersedes the earlier Auth-transition blocker below. The isolated clean candidate
now supports exactly seven days of completion-only grace for krutla.pl,
www.krutla.pl and csk-booking-5nwh.vercel.app. New auth flows redirect to canonical
https://strzelajtu.pl; no cookie/token/PKCE sharing. Exact Day-0 and Day-7 allowlists
are documented in the runbook. No production configuration was changed.

Fresh results: focused SQL 43/43; full DB 2013/2013; concurrency 3/3; Node 838/838;
Playwright 59/59 plus separate expired-grace HTTP test 1/1; TypeScript/build PASS;
ESLint 0 errors (1 existing warning); diff/schema checks PASS; fixtures 0.
Live history matches all 126 deployed migrations through 20261010100000; exactly
20261011100000 pending and dry-run confirmed. Existing 161 normalized function
definitions/metadata/ACL show no drift. Migration SHA remains unchanged.

Overall preflight remains BLOCKED solely because Vercel is at its login page:
current project/domain binding and exact project-specific A/CNAME/TXT/TLS
recommendations cannot be verified. No DNS targets are guessed.
READY FOR STAGING / APP-DB DEPLOYMENT / DOMAIN CUTOVER: NO.

Full retry evidence:
`C:/Users/Mpios/Desktop/APP Krutla/PRODUCT_10F_PRODUCTION_PREFLIGHT_RETRY_REPORT.md`.

## Latest ACL recovery — 2026-09-25

Production project `yuyxfodozzpzrdzkmolu` was queried read-only through SQL Editor
using `pg_class` and `aclexplode`. Both technical tables have service_role `{}`.
Fresh canonical replay also has `{}`; before recovery the local application DB
had `{MAINTAIN,REFERENCES,TRIGGER,TRUNCATE}` on both tables.

Provenance: the prior PRODUCT-10E ACL audit explicitly left the application DB
untouched. Its migration ledger still ended at `20261007100000` despite later
schema objects. Container creation is `2026-09-24T06:52:02.730613425Z`, but this
does not establish its last reset time. The precise historical operation that
introduced the four grants is not recorded; no such origin is inferred.

The authorized local recovery rebuilt public schema and its schema-scoped defaults
from all 127 unchanged migrations through `20261011100000`, in historical order.
Managed schemas were preserved; auth users/storage objects were empty before recovery.
Target: `supabase_db_csk-booking`, published DB port 54322 only. The initial attempt
to run everything under a managed-operator session failed a historical guard and
rolled back. Successful recovery used the proven replay connection model: managed
operator recreates the schema, postgres executes each original migration transaction.
No individual ACL REVOKE, assertion change, migration repair or migration edit occurred.
Recovery script requires explicit `--rebuild-local` and fails on nonempty managed data.

Post-rebuild: both service_role ACLs `{}`, migration head `20261011100000`,
SECURITY DEFINER 104. Complete public schema equals fresh replay, including ACLs;
normalization removes only CR-at-EOL and pg_dump session restriction tokens.

Fresh verification: focused SQL **43/43**, full DB **2013/2013** (65 files),
concurrency **3/3**, deadlocks **0**, Node **836/836**, Playwright **58/58**,
TypeScript PASS, production webpack build PASS, ESLint **0 errors / 1 pre-existing
register warning**, candidate diff check PASS. Domain tests cover resolver,
forged host, duplicate domain, status gating, cache isolation, open redirect,
platform-admin mutations and tenant-admin denial. Browser run logs retain the
previous aborted-stream diagnostic during navigation; all 58 assertions pass.
Cleanup after E2E: auth users, profiles, memberships, domains and non-CSK tenants
all **0**; technical ACLs remain `{}`. Scratch databases are removed after replay.

Migration SHA unchanged:
`737ED1F7CB4D7CC3D009ACD17D456424B2F048CDA8ABE0FA74D5CEA69D9086BB`.
No staging/commit/push/deploy, production SQL write, DNS/Vercel domain write or
Supabase production Auth change. Main mixed worktree was preserved.

**PRODUCT-10F LOCAL = PASS. READY FOR PRODUCTION PREFLIGHT = YES.**
This does not authorize or perform production preflight/deployment.

## Historical pre-recovery evidence (superseded by the section above)

Date: 2026-09-25. Base HEAD: `cc54cdfae90bd237d3f7bcde3c1f9b995354c63c`.

## Authoritative status

The auth-transition architectural decision is APPROVED and implemented locally.
Implementation is isolated in `C:/Users/Mpios/Desktop/APP Krutla/product10f-local`.
The mixed main worktree is NOT the tested candidate. No CSK visual changes were copied.
No staging, commit, push, deployment, production query/write, DNS/provider write,
Supabase production auth change, or second production tenant activation occurred.

**PRODUCT-10F LOCAL = BLOCKED. READY FOR PRODUCTION PREFLIGHT = NO.**

## New blocker: local DB baseline ACL does not match clean replay

Severity: local security-baseline/integrity blocker; production impact NOT CONFIRMED.
The full historical replay and the local API database differ on technical-table ACLs:

| Object | Fresh replay service_role | Local API DB service_role |
|---|---|---|
| confirmation_email_rate_limits | none | MAINTAIN, REFERENCES, TRIGGER, TRUNCATE |
| lane_booking_family_configuration_versions | none | MAINTAIN, REFERENCES, TRIGGER, TRUNCATE |

Read directly using `pg_class` + `aclexplode`, filtering the exact role and tables.
This is not merely CRLF or a count assertion. No grants were changed to force PASS.
The new migration does not touch either table. The discrepancy prevents claiming
that full replay and browser tests used an identical security baseline.

Recommended next action: establish provenance of those four local grants and reconcile
the local API test environment with the accepted replay baseline, or attach Auth/REST and
all E2E fixtures to an isolated historical replay. Do not add grants to production or
weaken expected ACLs. Then repeat schema comparison and the entire final suite together.

The replay harness also exposed an initialization difference: recreating `public` with
`CREATE SCHEMA` omits PostgreSQL's initial PUBLIC USAGE. The harness now restores that
managed-schema baseline ONLY in its own disposable database. It does not pre-seed current
TABLE/FUNCTION default ACLs. Namespace ACLs now match; technical table grants above do not.

## Candidate scope / identity

Migration: `supabase/migrations/20261011100000_add_verified_tenant_domains.sql`.
SHA-256: `737ED1F7CB4D7CC3D009ACD17D456424B2F048CDA8ABE0FA74D5CEA69D9086BB`.
Forward-only new table and five functions; SECURITY DEFINER target **104** (100 + 4).
Operator verifier is SECURITY INVOKER, postgres-only, with all client/service EXECUTE revoked.

`scripts/product10f-scope.mjs` compares against the archived exact base HEAD and reports
the complete SHA manifest. Before this report: 65 candidate files (including regression
inventory updates); this report adds one. Runtime `.env.local`, node_modules junction,
build/test outputs and logs are excluded. Historical migrations were copied byte-preserving
after verifying normalized content against the archived HEAD. No historical SQL was edited.
`AGENTS.md`, drafts, mixed account changes and CSK visual work remain excluded.

## Implemented contracts

- Canonical platform: `https://strzelajtu.pl`; www redirects permanently to apex.
- Host selector: strict ASCII DNS normalization, unique exact binding, no ports/path/scheme,
  no first-active/CSK fallback for a custom domain; platform/technical hosts reserved.
- Status: pending → operator-verified → active → disabled; active primary unique per tenant.
- Verification: random TXT challenge, stored SHA-256 only, version and 24-hour expiry;
  active Platform Admin requester; independent controlled operator DNS + provider/TLS review.
  Browser cannot set verified. Raw challenge is excluded from audit/list/public DTO.
- Platform Admin add/start/activate/disable/primary only; tenant roles denied by DB contract.
- Domain mutation and audit atomic; tenant-row locking plus unique indexes for concurrency.
- Public resolver DTO is exactly tenant_slug/public_slug. No tenant UUID, status or secrets.
- Custom host public routes: `/`, `/cennik`, `/o-obiekcie`, `/kontakt`.
- Operational/auth routes redirect to fixed canonical platform, preserving resolved technical
  tenant slug for booking/events/admin. Unknown paths and POST APIs on custom hosts deny.
- Public rendering forwards neither cookies nor Authorization. Forwarded/X-Forwarded-Host
  are ignored for selection; forged forwarded-host requests cannot switch content.
- Host itself is public selection, NEVER membership/platform authority. Verified Vercel
  domain binding remains the production ingress prerequisite, not a client header assertion.
- Auth: no cross-domain session bridge, no cookie Domain sharing, explicit re-login.
  New signup/reset redirect URLs use the canonical constant. Existing account email-change
  flow is absent; hosted confirmation configuration is documented for later authorized cutover.
- Exact old host callback/reset grace uses explicit `PLATFORM_AUTH_CUTOVER_AT`, seven days;
  no new old-host auth flow and no callback tokens forwarded after expiry.
- SEO model B: platform paths remain available, canonical points to active primary custom
  host or platform public slug. Same rule on public subpages and secondary custom domains.
- Cache: host-specific pages force-dynamic/no-store; domain RPC reads no-store; no shared CDN
  page cache in V1. Visibility/entitlement gates remain the existing DB and route contracts.
- Existing production-approved visual classes/layout preserved; only functional URLs/props.
- PRODUCT-10G transactional email changes intentionally not implemented.

## Test evidence (do not merge separate runs into an invented final PASS)

| Gate | Evidence |
|---|---|
| Focused SQL | 43/43 PASS on fresh replay; rollback + fixtures 0 |
| Full DB | 2013/2013 PASS, 65 files, before final strict local-schema equivalence gate was added |
| Concurrency | 3/3 PASS: duplicate host, same-domain activation, eight competing primary switches; deadlocks 0 |
| Node | 836/836 PASS |
| Playwright full first run | 57 PASS / 1 FAIL in new domain rewrite test |
| Focused domain Playwright after fix | 1/1 PASS, real alternating A/B HTTP, 4 public routes, canonical, privacy, forwarded-host spoof, redirects, disable and visibility |
| Final combined Playwright | NOT RERUN after rewrite fix because baseline integrity gate is blocked |
| TypeScript | PASS |
| Production build | PASS on latest app code |
| ESLint changed implementation | 0 errors, one pre-existing unused `message` parameter warning in register page |
| Candidate diff check | PASS, CR-at-EOL neutralized only; no broad whitespace suppression |
| Post-SQL schema stability | PASS on successful complete replay run |
| Replay vs local API schema | FAIL — technical table ACL discrepancy above |
| Cleanup | Disposable replay DB removed; domain concurrency fixtures 0; E2E tenant/domain fixtures 0 |

New host test initially caught a genuine local rewrite defect: Next normalized 127.0.0.1
to localhost, turning the rewrite into an outbound proxy request. Fixed with documented
`skipProxyUrlNormalize` and the original framework server URL (not forwarded host). The
internal path is under `domain-view.internal`, outside valid tenant slug syntax; direct
requests are denied. The fixed focused test is green. No assertion was weakened.

Full browser run also logged two aborted-response `destination stream closed early`
messages while navigating; those existing tests passed. This is recorded, not claimed
as a verified zero-console-error final run.

## DNS / Vercel / Supabase Auth plan

See `docs/product10f-domain-runbook.md` for exact sequencing and operator boundaries.
Use **csk-booking-5nwh** only. Get apex A and project-specific CNAME targets from its
Domain Settings at the authorized cutover; do not guess historical provider addresses.
Keep dhosting nameservers and unrelated MX/TXT. Add apex/www separately; verify TLS.
Tenant domains require both TXT proof and correct provider-project/TLS binding.
Supabase Site URL/callback allowlist changes and the old-host expiry removal are later,
explicit production operations. None were performed here.

References: https://vercel.com/docs/domains/working-with-domains/add-a-domain,
https://vercel.com/kb/guide/a-record-and-caa-with-vercel,
https://supabase.com/docs/guides/auth/redirect-urls .

## Final local handoff

PLATFORM / AUTH MODEL: implemented; no cross-domain sharing.
DOMAIN / AUTHORITY / DTO SQL MATRIX: PASS.
CUSTOM ROUTES / FORGED HOST / CACHE A/B: focused PASS after rewrite correction.
TENANT ISOLATION / PRIVILEGE EXPANSION: domain matrix PASS; no authority expansion observed.
PRODUCTION WRITE / DNS WRITE / VERCEL WRITE / AUTH PROD CHANGE: NO.
SECOND PROD TENANT: UNTOUCHED / NOT ACTIVATED BY THIS TASK.
PRODUCT-10F LOCAL: BLOCKED (not PASS).
READY FOR PRODUCTION PREFLIGHT: NO.
OPEN ITEMS: reconcile local ACL baseline, rerun exact complete gate, then review manifest.
