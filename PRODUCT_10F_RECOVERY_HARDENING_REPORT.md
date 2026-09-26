# PRODUCT-10F recovery hardening — LOCAL REVIEW ONLY

## Current gate — 2026-09-26 ONE-TIME RECOVERY GRANT: LOCAL PASS / SECURITY REVIEW REQUIRED

This section supersedes all historical stateless/HMAC evidence below. No staging,
commit, push, deployment, production DB/configuration/template/sender write was
performed. The new migration was applied ONLY to the local Docker DB on 54322.

### Architecture and trust boundary

- Forward-only migration: `supabase/migrations/20261012100000_add_one_time_recovery_grants.sql`.
- SHA-256: `A3E02BE30BE5D9A2DD6E8C3864988DE078CB694324C6EDD16E6054E7B1C4F7A2`.
- Public SECURITY DEFINER inventory: **104 -> 107**, exactly three new contracts.
- `public.recovery_grants` is global auth infrastructure, not tenant-owned data.
  No existing application private schema was available. RLS enabled, zero
  policies, zero direct privileges for PUBLIC/anon/authenticated/service_role.
- Columns: grant_hash, user_id, session_id, created_at, expires_at, consumed_at.
  No email/password/mail TokenHash/access token/refresh token/raw grant stored.
- Raw grant: 32 cryptographically random bytes, base64url cookie encoding. DB
  stores SHA-256 of the decoded 32 bytes, lowercase hexadecimal, unique PK.
- `RECOVERY_CONTEXT_SECRET` and HMAC are removed from executable code/config.
- `create_recovery_grant_v1(uuid,text)` accepts session ID/hash only. EXECUTE:
  **service_role only among application roles**; postgres owner retains inherent
  owner privileges. No user_id or TTL parameter. User derives from auth.sessions;
  missing/expired session and deleted/banned/anonymous users are rejected.
  DB creates both timestamps with expiry exactly 10 minutes later.
- `lib/server/recovery-grant-mint.ts` imports `server-only`, uses only the private
  `SUPABASE_SERVICE_ROLE_KEY`, disables SDK persistence/refresh, never logs it.
  The same minter is called immediately after successful proof in both handlers.
  There is no browser mint endpoint. Configuration is checked before token exchange.
- LEGACY: exactly one server PKCE exchange, server-returned JWT AMR `recovery`,
  subject matches returned user and a session_id exists. SDK redirectType is not trusted.
- NEW: successful `verifyOtp({token_hash,type:'recovery'})` is the proof. Actual
  local server-issued AMR is `otp`, not `recovery`; `otp` alone is never accepted
  as proof. The privileged mint contract deliberately trusts this narrow server
  caller, NOT an authenticated user's claimed recovery type.
- `check_recovery_grant_v1(text)` and `consume_recovery_grant_v1(text)` EXECUTE:
  authenticated only among app roles. PUBLIC/anon/service_role denied. Both
  derive auth.uid and logical JWT session_id, require same user/session, live
  auth session/account, unexpired grant and consumed_at IS NULL.
- Consume is one conditional UPDATE/RETURNING. Only a true result permits
  updateUser. Password validation precedes consume. A failed/uncertain mutation
  after claim does not restore the grant; cookie cleared, fresh link required.
- Successful update + failed signOut: explicit partial-success response, cookie
  cleared, DB grant remains consumed even while the Auth session is still valid.
- This governs the recovery flow; it does not redefine Supabase's existing
  authenticated account/password-change API or make a stolen Auth session harmless.

### Cookie, privacy and retention

Cookie: `st-recovery-context`; raw opaque token only; HttpOnly; Secure on HTTPS;
SameSite=Lax; Path=/auth; host-only (no Domain); Max-Age=600. Canonical production
host remains StrzelajTu.pl. No secret sent to client JS; 93 built client chunks
scanned for the actual local service key and private env key name: **0 matches**.

Application token logging: none introduced. Token-bearing entry URLs are cleaned
by redirect; responses no-store/no-referrer/noindex. **Infrastructure query-log
retention/redaction is NOT verified locally** and remains a rollout review item.
No claim that referrer policy removes an initial URL from infrastructure logs.

Retention: session/user deletion cascades. Every successful mint opportunistically
removes up to 1000 rows with expiry older than 24 hours using SKIP LOCKED. Idle
systems retain expired records until the next mint or operator maintenance; this
is not a guaranteed wall-clock purge SLA. For a sustained backlog, operator-only
maintenance should repeat the same bounded expiry deletion. No scheduler added.

### Test evidence on exact local implementation

| Gate | Result |
| --- | --- |
| Focused SQL | **39/39 PASS**, rollback, fixture cleanup 0 |
| Fresh historical replay/full DB | **2052/2052 PASS**, 66 SQL files |
| Real DB concurrency | **1 winner / 7 denied**, deadlocks 0 |
| Real Auth + DB fault matrix | **3/3 PASS**: signOut failure replay, mutation failure, concurrent handlers |
| Targeted Node | **16/16 PASS** |
| Full Node | **859/859 PASS** |
| Playwright recovery/auth | **5/5 PASS**, 1440 and 375; real local GoTrue/Mailpit |
| TypeScript | PASS |
| Production Build (`--webpack`) | PASS |
| ESLint changed recovery files/scripts | PASS, 0 errors |
| `git diff --check` | PASS |
| Replay vs local schema | identical after newline normalization, diff 0 |
| Post-test schema | diff 0 |
| Cleanup | scratch DB 0, recovery grants 0, synthetic recovery users 0 |

Browser coverage: independent-browser TokenHash recovery; legacy same-browser
recovery with exactly one server exchange; legacy cross-device fails closed;
ordinary login/direct reset denied; malformed/expired/reused token denied;
external next and forged Origin denied; actual access-token refresh preserves
logical session and grant; restored captured grant/session cookies deny replay.
No production email sent. Physical phone/Gmail testing remains pending.

The fault matrix transpiles the actual handler and uses real local GoTrue and
PostgREST RPC calls. Only updateUser/signOut failures are injected, not DB
consumption. After failed signOut, getUser confirms the original session still
valid and a second POST still returns DENY with exactly one mutation total.
There is no production runtime fault-injection flag.

Historical regression updates are narrow: exact SD counts 104->107, function
inventory 166->169, authenticated execute 89->91, service execute 5->6, table
inventory 28->29 with no privileges. Two old raw fingerprint assertions now
normalize CRLF/CR to LF with authoritative corresponding normalized hashes.
Their underlying four function definitions were not changed. Historical
migrations have **zero diff**. No broader ACL expectation was relaxed.

Evidence logs outside candidate: `../recovery-grant-db.log`,
`../recovery-grant-node.log`, `../recovery-grant-build.log`,
`../recovery-grant-playwright.log`. Reproducible local scripts:
`scripts/recovery-grant-local-replay.mjs`, `scripts/recovery-grant-concurrency.mjs`,
`scripts/recovery-grant-live-check.mjs`.

### Frozen scope and rollout gate

Account Header frozen SHA unchanged:

- app/dashboard/page.tsx: `9AE5B1DAAFBABF68AED2863B888F6C18BE97B190D73D20904B2A344624C4C800`
- tests/e2e/global-account-header.spec.ts: `BB92288C7C6D80196C0BB1F83EE09EBF7D70C7BD6E388F53F2BA9342458E12EE`

CSK visual impact NONE. PLATFORM_BASE_URL/canonical host and tenant authority
unchanged. Account Header changes already present in worktree remain separate.
Supabase email template/subject/sender and the proposal are untouched this turn.

READY FOR SECURITY REVIEW: **YES**.
READY FOR PRODUCTION: **NO** — separate review/preflight/approval required. Future
rollout must apply DB contracts before the new app, verify private server env,
then separately review email-template cutover and real cross-device flow.

## Historical gate — 2026-09-26 DUAL-FLOW: BLOCKED (superseded)

This section supersedes the earlier local-review gate below. No production changes, commits, pushes, deployment, DB migration or state store were made.

Implemented and tested:

- `middleware.ts` intercepts legacy `/reset-password?code=...` on the canonical/local host and rewrites to `/auth/recovery/legacy` before browser components or SDK initialization.
- The legacy server handler performs exactly one exchange with the SSR verifier cookie. It requires the server-issued JWT AMR method `recovery`, exact subject and session ID. It does NOT trust SDK `redirectType`, which is derived from a writable verifier-cookie suffix.
- Real local ConfirmationURL email tests pass at desktop/mobile viewport sizes; a separate browser without the verifier fails closed. Local Mailpit messages are read only for the exact synthetic recipient and deleted by exact ID after testing. No production email is sent.
- New TokenHash flow continues to pass in an independent browser.
- `RECOVERY_CONTEXT_SECRET` now requires exactly 64 hexadecimal characters, decodes to 32 bytes and uses those decoded bytes as HMAC key. Entropy must come from secure random generation; syntax validation cannot measure entropy. No production secret generated.
- Recovery cookie Path is now `/auth`, HttpOnly, Secure on production HTTPS, SameSite=Lax, host-only, TTL 600 seconds.
- Password-change success followed by signOut error/exception returns HTTP 503 with `password_changed_session_cleanup_failed`, expires recovery cookie and displays the explicit partial-success message. No false claim that the password mutation was rolled back.
- Actual local refresh preserves logical `session_id`; the receipt remains accepted after refresh.
- Captured recovery AND session cookies replayed after successful signOut are denied by the local integration test.

### Architectural blocker: replay when session cleanup fails

The receipt is stateless. Deleting it from the browser does not invalidate a previously captured signed value. If password update succeeds but signOut fails and Supabase still accepts the session, the same signed receipt remains valid until its original expiry. A deterministic handler test reproduces two password-update calls using the same receipt under simulated signOut failure. This diagnostic passing is evidence of the limitation, NOT a security PASS.

There is also no atomic consumption/lock before the password update to guarantee one-time behavior for concurrent requests. Successful signOut is not an adequate substitute for atomic one-time consumption.

Recommended next decision: authorize a minimal server-side one-time recovery-grant store with atomic consumption, binding to user/session/nonce and bounded TTL. Consume before password mutation, fail closed if consumption fails; unsuccessful password attempts after consumption require a fresh recovery link. Store choice and schema require separate approval. No in-process map, browser flag, or silent DB addition used here.

Current tests: targeted Node **8/8 PASS** (includes blocker reproduction), full Node **858/858 PASS**, Playwright **5/5 PASS**; TypeScript, production Build, ESLint changed files, diff check **PASS**. Physical phone/Gmail testing remains pending; viewport tests do not claim physical-device coverage.

Application token logging: none found. Infrastructure query logging: NOT VERIFIED. No analytics or logs receive tokens from application code; clean redirects and no-referrer remain. Production template/subject/sender and local proposal are unchanged in this task.

Account Header SHA values below unchanged. CSK, DB, canonical base URL, signup/login and tenant authority unchanged. Ready for clean deploy candidate: **NO**. Ready for TokenHash template cutover: **NO**.

Base: `541e195e45a2c2fb5b190506a820be1cafd3cab4`.
No staging, commit, push, deployment, production configuration or DB schema changes.

## Cause and scope

The reported request originated on desktop and the email was opened in Chrome on a phone. The phone lacked the initiating browser's PKCE verifier. Separately, the old reset page explicitly exchanged a code already automatically processed by the installed browser SDK. A local SDK diagnostic reproduced that false failure.

Recovery-only implementation:

- `app/auth/confirm/route.ts`: exact recovery token-hash verification using installed Supabase `verifyOtp({ token_hash, type: "recovery" })`; success redirects to `/reset-password`, failure to `/reset-password?recoveryError=1`.
- `lib/server/recovery-context.ts`: signed 10-minute recovery receipt bound to the verified user and Supabase session ID. HMAC comparison is constant-time. No bearer token is stored in the receipt.
- `lib/server/recovery-http.ts`: existing SSR cookie adapter pattern, canonical host validation, host-only HttpOnly/SameSite=Lax receipt (Secure on HTTPS), no-store and no-referrer responses.
- `app/auth/recovery/route.ts`: validates Supabase session with `getUser(access_token)` AND signed recovery receipt before status or password update. POST requires exact same-origin and JSON, validates the password policy, calls `updateUser`, clears recovery context and signs out the local recovery session.
- `app/reset-password/page.tsx`: no manual PKCE exchange and no generic authenticated-session fallback. Server checks gate the form and the mutation. Normal login alone is insufficient. Invalid/old URL flows fail closed and offer a fresh reset link.
- `lib/password-policy.test.mjs`: regression assertion follows the moved server-side password mutation and verifies policy enforcement on client and server; no weakened password policy.
- `lib/server/recovery-context.test.mjs`, `tests/e2e/recovery-hardening.spec.ts`, `playwright.recovery.config.ts`: targeted tests.
- `auth-email-proposals/recovery.html`: proposal only, not wired into production or local Supabase configuration.

Login/signup PKCE configuration, canonical `PLATFORM_BASE_URL`, callback, forgot-password, tenant return context, authority, CSK visuals and DB migrations are unchanged. This adds a recovery-specific server gate; it does not claim to disable Supabase's separate normal account password-change capability.

## Deployment prerequisite (NOT performed)

Add a dedicated server-only `RECOVERY_CONTEXT_SECRET` containing exactly 32 random bytes encoded as 64 hexadecimal characters. Never prefix it with NEXT_PUBLIC, never reuse anon/service-role keys, never log or commit its value. Invalid format fails closed BEFORE consuming a recovery token. Rotation invalidates outstanding recovery receipts. Local tests generate an ephemeral secret in memory for the test server.

The future deployment must coordinate app availability, the server secret and the recovery email template. Legacy same-browser PKCE recovery is now supported by the server bridge; new TokenHash supports independent browsers. No production switch is authorized by this local result, and one-time context protection remains BLOCKED as described above.

## Email proposal

Subject: `Reset hasła — StrzelajTu.pl`

Sender display name: `StrzelajTu.pl` (SMTP display-name setting, no SMTP credentials/address changes proposed).

Exact body: `auth-email-proposals/recovery.html`.

Exact template href:

```html
https://strzelajtu.pl/auth/confirm?token_hash={{ .TokenHash }}&amp;type=recovery&amp;next=/reset-password
```

This uses Supabase's documented `.TokenHash` variable, not `.ConfirmationURL`, not arbitrary `.RedirectTo`. The confirmation handler accepts only recovery and the fixed reset destination. No wildcard is proposed.

Documentation checked: https://supabase.com/docs/guides/auth/auth-email-templates and https://supabase.com/docs/reference/javascript/auth-verifyotp . Installed SDK: @supabase/ssr 0.10.3, auth-js 2.105.4.

Signup/confirmation, email change, invitations, magic links, reauthentication and account security notifications are separate future global-branding inventory, not edited here. LEGAL/GDPR remains separate.

## Earlier TokenHash-only evidence (superseded by current gate above)

- Targeted Node: **5/5 PASS** (signature/user/session binding, expiry, missing configuration, strict next/type/query, no duplicate exchange, Supabase `otp_expired` and transport-error rejection).
- Full Node: **855/855 PASS**.
- Playwright recovery/auth: **3/3 PASS** against loopback Supabase and a production build at 127.0.0.1:3101.
- Real local Supabase tokens issued via local admin `generateLink`, opened in fresh browser contexts with no originating cookies or PKCE verifier. Desktop 1440 and mobile viewport 375: verify, cookie establishment, actual password update, fresh login with new password, session end and reuse denial PASS.
- Direct reset and unrelated normal login denied; malformed/missing/unknown token, wrong type, external next and cross-origin POST denied.
- Expired-token response is a deterministic SDK-error simulation; receipt expiry is a clock-controlled test. No claim of waiting for a real production token to expire.
- TypeScript, production webpack Build, ESLint changed scope and git diff --check: **PASS**.
- Temporary local auth users cleaned up; no production emails/password mutations.

Desktop→desktop, phone→phone, desktop→phone and phone→desktop are supported by the same verifier-independent token-hash contract. Actual phone Chrome/Gmail/webview and email-delivery end-to-end tests remain required after an explicitly approved production cutover. A mobile viewport is not a physical phone test. Mail clients that consume links before the user or reject cookies remain a live-test consideration; no bypass is implemented.

## Frozen Account Header scope

Neither approved file changed during recovery work:

- `app/dashboard/page.tsx`: SHA-256 `9AE5B1DAAFBABF68AED2863B888F6C18BE97B190D73D20904B2A344624C4C800`.
- `tests/e2e/global-account-header.spec.ts`: SHA-256 `BB92288C7C6D80196C0BB1F83EE09EBF7D70C7BD6E388F53F2BA9342458E12EE`.

Other existing Account Header changes remain untouched and separate from recovery scope.

## Earlier review gates (superseded; current candidate is BLOCKED)

Ready for code review: YES.
Recovery template proposal prepared for review: YES.
Ready to apply production template now: NO — code/secret deployment and explicit authorization required.
Ready for deploy: NO.
