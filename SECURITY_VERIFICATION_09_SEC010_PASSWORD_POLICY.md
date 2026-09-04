# CSK Booking — Security Verification 09

## SEC-010 — Password Policy / Supabase Auth

**SEC-ID:** `SEC-010`

**Original severity:** `MEDIUM`

**Verification date:** 2026-09-04

**Verified HEAD:** `c072fff — docs: record SEC-006 production smoke pass`

This was a verification-only review. No application code, Supabase Auth setting,
migration, deployment, commit, or push was changed.

## Evidence

The assessment used:

- the current Auth UI implementation and existing tests at `c072fff`;
- the effective environment of the running local Supabase Auth container;
- read-only inspection of the production Supabase Auth dashboard;
- a bounded production boundary test using one synthetic, already-confirmed
  account and anonymous `signUp` requests against that same address;
- the current Supabase Auth password-security and rate-limit documentation.

The repository does not contain `supabase/config.toml`. Consequently, no local
or production conclusion below is inferred from a missing config file.

Authoritative provider references:

- [Supabase password security](https://supabase.com/docs/guides/auth/password-security)
- [Supabase Auth rate limits](https://supabase.com/docs/guides/auth/rate-limits)
- [Supabase password-based Auth and reset behavior](https://supabase.com/docs/guides/auth/passwords)

## Current production policy

| Control | Verified production state | Evidence |
|---|---|---|
| Minimum password length | **6 characters** | Production boundary test rejected 1 and 5 characters with `weak_password/length`, but accepted a simple 6-character password. |
| Maximum password length | **72 characters** | Production accepted 72 characters and rejected 73 with `validation_failed`. This matches the current Supabase Auth bcrypt guard. |
| Required character classes | **None** | The dashboard shows no selected character requirement and production accepted simple lowercase passwords at both 6 and 8 characters. |
| Leaked-password protection | **Disabled** | Production Email provider and Attack Protection settings show the control disabled. The project is on the Free plan, while this provider feature requires Pro or higher. |
| Password hashing | bcrypt, provider-managed | Supabase Auth performs the server-side password validation and hashing. |
| Email confirmation | **Enabled** | Production `Confirm email` is enabled; a new user must confirm the address before first sign-in. |
| Secure password change | **Disabled** | Production does not require recent reauthentication before password change. |
| Current password on change | **Not required** | Production setting is disabled. |
| CAPTCHA | **Disabled** | Production Attack Protection reports CAPTCHA disabled. |
| Sign-up/sign-in rate limit | **30 requests per 5 minutes per IP** | Production Rate Limits page; dashboard also presents the equivalent 360 requests/hour refill rate. |
| Token refresh limit | **150 requests per 5 minutes per IP** | Production Rate Limits page. |
| OTP/magic-link verification limit | **30 requests per 5 minutes per IP** | Production Rate Limits page. |
| Auth e-mail per-user interval | **60 seconds** | Production custom SMTP configuration. |
| Custom Auth SMTP | **Enabled** | Production uses a configured custom SMTP provider; credentials were neither revealed nor read. |
| E-mail OTP/link expiration | **3600 seconds** | Production Email provider configuration. |
| E-mail OTP length | **8 digits** | Production Email provider configuration. |
| MFA capability | **TOTP enabled, not application-mandatory** | Production permits TOTP and limits a user to 10 factors. The AAL1-duration protection is enabled, but no application enrollment/challenge/role-enforcement flow exists. |

The production dashboard did not expose a populated numeric value for the
project-wide e-mail-per-hour input. This review therefore does not invent that
number. The verified per-user reset/sign-up e-mail interval is 60 seconds, and
the sign-up/sign-in IP limit is listed above.

## Local Supabase policy

The running local GoTrue container (`v2.194.0`) has the following effective
configuration:

```text
minimum password length: 6
required character classes: none
email autoconfirm: enabled
password-change reauthentication: disabled
TOTP/phone/WebAuthn MFA enrollment and verification: disabled
anonymous-user rate limit: 30/hour
token refresh rate limit: 150/5 minutes
OTP and verification limits: 30
local email rate limit: development-only high limit
```

Local e-mail autoconfirm and disabled MFA differ from production. Local
Supabase is therefore not an authoritative substitute for production Auth
configuration.

## Application enforcement

### Registration

`app/register/page.tsx` performs a hardcoded `password.length < 6` check and
shows `Minimum 6 znaków`. It then calls `supabase.auth.signUp()`. The provider
is the actual server-side enforcement layer, but its current production
minimum is also six, so the application permits the weak boundary identified
by SEC-010.

The registration form has no maximum-length check and no shared password-policy
helper. Provider errors other than the explicitly recognized existing-account
cases can be rendered through the raw Auth message; that is adjacent SEC-013
scope and was not changed here.

### Reset password

`app/forgot-password/page.tsx` calls `resetPasswordForEmail()` with a
`/reset-password` redirect and uses a neutral success message that does not
confirm whether the account exists. Supabase applies the verified 60-second
per-user e-mail interval.

`app/reset-password/page.tsx`:

- exchanges the recovery code for a session when present;
- refuses the change without an active recovery session;
- requires two matching values and at least 8 characters in the UI;
- calls `auth.updateUser({ password })`;
- signs the user out after success.

### Account password change

`app/account/page.tsx` also requires two matching values and at least 8
characters before `auth.updateUser({ password })`. Production Auth does not
require the current password or recent reauthentication, so possession of a
valid session is sufficient.

### Login and callback

`app/login/page.tsx` requires non-empty credentials but correctly does not apply
new-password strength rules during login. It maps the known unconfirmed-email
and invalid-credential cases. `app/auth/callback/route.ts` exchanges the
one-time code server-side and redirects invalid callbacks to a controlled
error state.

## Register/reset consistency

The flows are **not consistent**:

```text
registration UI:       minimum 6
production provider:   minimum 6
reset-password UI:     minimum 8
account-change UI:     minimum 8
maximum in UI:         not enforced
provider maximum:      72
shared policy source:  absent
```

Thus an account can be created with a password that the same application's
reset and account screens would refuse to set later. Conversely, values above
72 reach the provider because the UI does not expose its maximum.

## Production verification

One uniquely marked synthetic Auth user was created already confirmed, so no
confirmation e-mail was sent. Anonymous production `signUp` calls reused that
same existing address. This exercised the provider's password validation
without creating additional users or touching a real account.

| Boundary case | Production result |
|---|---|
| Very short | Rejected: HTTP 422, `weak_password`, reason `length` |
| 5 characters | Rejected: HTTP 422, `weak_password`, reason `length` |
| 6 simple lowercase characters | Accepted by password policy: HTTP 200 |
| 8 simple lowercase characters | Accepted by password policy: HTTP 200 |
| Longer mixed-class password | Accepted by password policy: HTTP 200 |
| 72 characters | Accepted by password policy: HTTP 200 |
| 73 characters | Rejected: HTTP 400, `validation_failed` |

No tested password, API key, token, or synthetic address is recorded in this
report. Cleanup independently confirmed:

```text
synthetic Auth user absent: true
synthetic profile absent: true
remaining synthetic fixture: 0
```

## Security assessment

### Length

**Insufficient.** The effective minimum is six. Supabase's current guidance
states that fewer than eight characters is not recommended. This is also the
exact condition anticipated by the original SEC-010 finding.

### Complexity

No character classes are required. Forced composition is not necessary as the
first remediation if a reasonable length and breached-password protection are
used. In the current state, however, a simple six-letter password is accepted.

### Breached-password protection

Disabled and unavailable on the current Free plan. This leaves reused known
passwords unchecked by the provider.

### Rate limiting and abuse protection

Supabase Auth rate limits are active, including 30 sign-up/sign-in requests per
5 minutes per IP and a 60-second per-user e-mail interval. These reduce online
abuse but do not make a six-character password an adequate policy. CAPTCHA is
disabled.

### Reset and password change

The forgot-password success response is enumeration-resistant and the recovery
page requires a valid session. The application requires eight characters for
reset/change, but the provider minimum remains six. Recent reauthentication and
current-password verification are both disabled for an already authenticated
password change.

### MFA

TOTP is available at provider level but is not required by the application for
admin, employee, instructor, or ordinary-user accounts. Mandatory MFA for
admin/staff is worthwhile future hardening, but it is not treated as the core
SEC-010 defect.

## Classification

```text
SEC-010: CONFIRMED
```

Evidence:

1. Production demonstrably accepts a simple six-character password.
2. Production requires no character classes and has leaked-password protection
   disabled.
3. Registration documents and enforces six characters, while reset and account
   change enforce eight.
4. There is no shared application policy or password-policy regression test.
5. Existing rate limits and e-mail confirmation are useful compensating
   controls, but they do not remove the finding.

The original `MEDIUM` severity remains appropriate. Current exploitability is
`MEDIUM`: exploitation still requires guessing/reuse of a user's credential,
but the production policy permits passwords below the provider's recommended
minimum, including staff accounts.

## Recommended target

Minimal, proportionate target:

1. Set the production Supabase Auth minimum to **8 characters**.
2. Use one shared application constant/helper for registration, recovery reset,
   and account password change; expose the same 8-character minimum everywhere.
3. Add the provider maximum of **72 characters** to the shared UI contract while
   retaining provider-side enforcement.
4. Do not require arbitrary character classes in the initial remediation;
   encourage longer passphrases instead.
5. Enable leaked-password protection when the project plan supports it, or
   explicitly track the required plan upgrade as a residual risk.
6. Add boundary tests for 7/8 and 72/73 characters across registration, reset,
   account change, and direct provider calls.
7. Evaluate CAPTCHA and recent-reauthentication/current-password enforcement as
   adjacent Auth hardening.
8. Track mandatory MFA/step-up for admin and staff as a separate future
   hardening item.

Strengthening the provider policy affects new sign-ups and password changes.
Existing passwords should be handled according to Supabase's strengthened
password-policy behavior and communicated before rollout.

## Change required

```text
YES
```

Minimal remediation scope:

- production Supabase Auth password minimum: 6 to 8;
- shared frontend policy and messages in registration, reset and account pages;
- maximum-length handling;
- focused boundary and consistency tests;
- no SQL migration required.

## Verification tests

The existing focused Auth-classification suite was run without modification:

```text
tests: 9
pass: 9
fail: 0
```

No full regression was run because this task changed no application behavior.

## Verdict

```text
SEC-010 CONFIRMED
```
