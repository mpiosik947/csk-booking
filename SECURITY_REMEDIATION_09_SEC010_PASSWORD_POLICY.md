# CSK Booking — Security Remediation 09

## SEC-010 — Password Policy / Supabase Auth

**Date:** 2026-09-04  
**Base HEAD:** `c072fff — docs: record SEC-006 production smoke pass`  
**Original severity:** `MEDIUM`

This remediation changed only the local application and its tests. It did not
change Supabase Auth settings, SQL, migrations, production data, MFA, or any
other security finding.

## Before

| Layer / flow | Effective policy before this change |
|---|---|
| Production Supabase Auth | Minimum 6, maximum 72, no required character classes, leaked-password protection off |
| Local Supabase Auth | Effective minimum 6, no required character classes; the repository has no `supabase/config.toml` |
| `/register` | Hardcoded minimum 6, no application maximum |
| `/reset-password` | Hardcoded minimum 8, no application maximum |
| `/account` password change | Hardcoded minimum 8, no application maximum |
| `/login` | Non-empty credentials only, as expected for an existing password |

The three new-password flows therefore exposed inconsistent rules and allowed
the registration UI to submit a six-character password.

## Approved target

```text
minimum length: 12
maximum length: 72
required character classes: none
leaked-password protection: enabled
MFA: outside SEC-010 scope
```

## Application policy after this change

`lib/password-policy.ts` is now the single application source of truth:

```text
PASSWORD_MIN_LENGTH = 12
PASSWORD_MAX_LENGTH = 72
```

It exposes one length validator and the two stable Polish validation messages.
Registration, recovery reset, and authenticated account password change all:

- call the shared validator before calling Supabase Auth;
- reject values shorter than 12 or longer than 72;
- expose matching `minLength` and `maxLength` input attributes;
- show a truthful 12-character minimum in the UI.

The registration path does not call `signUp()` after a local length failure.
The reset and account paths do not call `updateUser()` after such a failure.
Password equality, recovery-code exchange, recovery-session validation,
successful sign-out, and the existing account session flow were not changed.

The login screen intentionally does not apply a new-password strength rule to
existing credentials. Forgot-password behavior is also unchanged.

## Supabase Auth policy

Production was deliberately not changed in this task. Its verified state
remains:

```text
minimum length: 6
maximum length: 72
required character classes: none
leaked-password protection: off
```

The production project was verified on the Free plan. Supabase documents
leaked-password protection as a Pro-plan-or-higher feature, so the approved
target cannot be completed on the current plan. No report claims that this
control is enabled.

The required production change, after the plan prerequisite is satisfied, is:

1. set the Auth password minimum to 12;
2. leave required character classes unset;
3. enable leaked-password protection;
4. leave the provider maximum at 72;
5. verify all values again in the production Auth dashboard and with a bounded
   synthetic boundary test.

References:

- [Supabase password security](https://supabase.com/docs/guides/auth/password-security)
- [Supabase password-based Auth](https://supabase.com/docs/guides/auth/passwords)

## Local Supabase configuration

The repository does not contain `supabase/config.toml`. Consequently, this
remediation did not create a configuration file that the existing local stack
would not consume and did not imply that local or production Auth changed.
The running local Auth service will continue to enforce its current provider
minimum until its real environment/configuration is changed separately.

Application validation is nevertheless deterministic and testable at 12–72.

## Leaked-password protection

The application cannot reproduce the provider's Have I Been Pwned check safely
or equivalently, and no parallel password database was added. The control must
be enabled at Supabase Auth level. It remains blocked by the current plan and
requires a post-change production verification.

No real or known-compromised user password was used in this remediation.

## Existing-user impact

No user is removed and no password is rewritten or reset by changing the
application constants or by later strengthening the provider setting.
Supabase documents that existing users can continue to sign in with their
current password after requirements are strengthened; Auth may surface weak
password information during sign-in. New registrations and future password
changes must meet the strengthened provider policy once it is enabled.

The production rollout should therefore monitor sign-in responses and explain
any provider weak-password notice, without forcing an automatic reset in this
remediation.

## Tests

Focused `node --test lib/password-policy.test.mjs`:

```text
tests: 7
pass: 7
fail: 0
```

Covered boundaries and integration:

| Case | Expected | Result |
|---|---|---|
| 5 characters | deny | PASS |
| 6 characters | deny | PASS |
| 8 characters | deny | PASS |
| 11 characters | deny | PASS |
| 12 characters | allow application validation | PASS |
| longer valid values through 72 | allow application validation | PASS |
| 73 characters | deny | PASS |
| register uses shared validation before `signUp` | required | PASS |
| reset uses shared validation before `updateUser` | required | PASS |
| account uses shared validation before `updateUser` | required | PASS |
| all three inputs expose 12–72 | required | PASS |
| active runtime contains no old 6/8 minimum | required | PASS |
| login remains independent | required | PASS |

Regression results:

```text
all Node tests: 557/557 PASS
TypeScript (npx.cmd tsc --noEmit): PASS
Next.js 16.3.4 production build: PASS
git diff --check: PASS
```

Full ESLint reproduced exactly the accepted project baseline:

```text
KNOWN ESLINT BASELINE: 14 errors / 6 warnings
NEW SECURITY REMEDIATION ESLINT REGRESSIONS: 0
```

`npm audit --omit=dev` was attempted repeatedly without changing dependencies,
but the npm advisory endpoint timed out from the execution environment. This
check is therefore **NOT VERIFIED in this run**, rather than reported as a
false pass. The prior production dependency remediation was not modified.

No DB/Auth test was triggered because no local Auth configuration, SQL, schema,
or migration changed.

## Deployment order

Use a controlled two-step rollout:

### A. Application deployment

1. Deploy the application with the shared 12–72 validation.
2. Smoke-test register, reset-password, and account password change at the
   11/12 and 72/73 boundaries without recording test passwords.
3. Stop if any flow bypasses local validation or if reset/session behavior
   regresses.

During this short transition the UI is stricter than Supabase Auth. It does not
weaken the declared application policy, although a caller bypassing the UI can
still reach the old provider minimum until step B.

### B. Production Supabase Auth setting

1. Upgrade/confirm a plan that supports leaked-password protection.
2. In production Auth settings set the minimum to 12, leave character classes
   unset, and enable leaked-password protection.
3. Re-read the saved settings and perform a synthetic boundary smoke test.
4. Confirm that existing-user sign-in remains functional and observe any weak
   password signal without exposing credentials.

Do not reverse the order. Updating the provider first would leave the old UI
advertising 6/8 characters while the backend rejects them. If application
deployment fails before step B, roll back the application normally. If step B
fails, leave the already stricter application in place and resolve the Auth
configuration; do not weaken the UI.

## Production verification

```text
COMPLETED — 2026-09-04
```

Verified evidence:

- deployed application contains the shared 12–72 policy;
- production Auth reports minimum 12 and no required character classes;
- leaked-password protection remains off because it is unavailable on the
  current Free plan and is tracked as an accepted residual;
- synthetic 11/12 and 72/73 checks matched the contract;
- register, reset, account change, and existing-user login remain operational;
- synthetic fixture cleanup equalled zero.

## Files changed by this remediation

- `lib/password-policy.ts`
- `lib/password-policy.test.mjs`
- `app/register/page.tsx`
- `app/reset-password/page.tsx`
- `app/account/page.tsx`
- `SECURITY_REMEDIATION_09_SEC010_PASSWORD_POLICY.md`

The pre-existing untracked verification report
`SECURITY_VERIFICATION_09_SEC010_PASSWORD_POLICY.md` was read as evidence and
was not modified by this remediation.

## Verdict

```text
SEC-010 REMEDIATED WITH ACCEPTED RESIDUAL
```

The application and production password-length policies are consistently
12–72 with no required character classes. The production smoke passed and all
synthetic fixture was removed. Leaked-password protection remains unavailable
and off on the current Free plan; it is explicitly accepted as residual risk
and retained as future hardening after a plan upgrade.
