# SECURITY REMEDIATION 15A — SEC-016 privacy policy

## Status

- SEC-ID: `SEC-016`
- Original severity: `INFO`
- Verdict: `SEC-016 PARTIALLY REMEDIATED — OWNER DATA DEFERRED`
- Deployment scope: application content only; no database or configuration change

## Before

The public privacy page described itself as a draft, stated that controller
contact data would be completed before production, and rendered blank dotted
fields. It covered accounts and reservations at a high level but did not reflect
the current event, check-in, e-mail delivery, security metadata, audit, export,
or account-anonymization flows. The terms page also described itself as draft
content requiring later production adjustment.

## Placeholders removed

General draft and pre-production wording was removed from `/privacy` and
`/terms`. The only remaining placeholders are the explicitly approved owner-data
block and the corresponding privacy-contact line. They are marked as requiring
completion before formal service launch and do not contain invented values.

## Current system and data flows reflected

The updated notice covers:

- account, authentication, profile, contact and optional address data;
- declared permissions, qualifications and their operational verification;
- reservations, event registrations, payment status, attendance and check-in;
- service e-mail delivery metadata;
- session, abuse-prevention and audit data;
- reservation and event operations, cancellations and reserve-list handling;
- Supabase for database/authentication, Vercel for hosting and Resend for e-mail;
- user-owned export and account deletion/anonymization.

No advertising or marketing cookies are claimed because the application does
not implement those uses.

## Owner data source

The repository contains the product/brand name but no approved legal controller
identity or privacy contact. Owner decision 15A explicitly deferred those data.
No legal identity, address, registration number, telephone number or e-mail was
inferred from repository paths, developer identity, test recipients or service
configuration.

## Retention wording

SEC-009 10B remains deferred. The notice therefore uses purpose-based neutral
retention wording and explicitly says that category-specific periods require
separate approval. It does not introduce arbitrary day or year values.

## SEC-009 lifecycle consistency

The notice states that the user can download a versioned allowlisted export and
request account deletion. It explains that direct PII is removed or anonymized,
active account tokens are invalidated, non-identifying operational history can
remain, and security/audit records can remain pseudonymized. It does not promise
physical deletion of every historical row.

## Tests

Focused integrity tests cover:

- removal of general draft wording and absence of `example.com`/`TODO`;
- the exact, limited owner placeholder inventory;
- current PII, operational and provider coverage;
- consistency with account export/deletion copy;
- existence of user-facing `/privacy` and `/terms` links.

The Next.js build provides the rendering regression check for both static pages.

Verification results:

- focused SEC-016 tests: 5/5 passed;
- all Node tests: 611/611 passed;
- TypeScript `tsc --noEmit`: passed;
- Next.js production build: passed and prerendered `/privacy` and `/terms`;
- `npm audit --omit=dev`: 0 vulnerabilities;
- `git diff --check`: passed;
- full ESLint: known baseline reproduced exactly (14 errors, 6 warnings);
- new SEC-016 ESLint regressions: 0. The two changed-page findings are the
  pre-existing root-link findings already present at `HEAD`.

## Remaining legal and business decisions

Remaining required owner data:

- legal name;
- legal form;
- address;
- privacy contact.

Category-specific retention periods also require the separate SEC-009 10B
business/legal decision. SEC-016 cannot be marked fully remediated until the
owner-data block has approved final values.

## Verdict

```text
SEC-016 PARTIALLY REMEDIATED — OWNER DATA DEFERRED
```
