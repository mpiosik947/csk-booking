# SECURITY REMEDIATION 03 — production dependencies

Date: 2026-09-02

Scope: remediation of the production dependency findings reported by `npm audit --omit=dev`. No application logic, SQL, migrations, RLS, ACL, or production systems were changed.

## Before

```text
npm audit --omit=dev:
CRITICAL: 0
HIGH: 4
MEDIUM: 0
LOW: 0
```

The audit counted four affected production packages. Some package entries aggregated more than one advisory.

## Findings

### 1. next

```text
package: next
old version: 16.2.6
new version: 16.3.4
vulnerable range: 9.3.4-canary.0 - 16.3.0-preview.10 (aggregate audit range)
patched version used: 16.3.4
direct/transitive: direct
dependency path: application -> next
reachability: REACHABLE overall; the middleware/proxy bypass applies to the App Router middleware protection used by /admin
advisory: GHSA-6gpp-xcg3-4w24, GHSA-m99w-x7hq-7vfj, GHSA-89xv-2m56-2m9x, GHSA-p9j2-gv94-2wf4
fix: exact minor update from next 16.2.6 to 16.3.4
breaking change risk: low-to-medium; no major-version change, Node 24.16.0 satisfies Node >=20.9.0, React 19.2.4 remains compatible
```

Reachability details:

- The middleware/proxy bypass was treated as reachable because the application uses `middleware.ts` to protect `/admin/:path*`.
- No Server Actions (`"use server"`) were found, so the Server Actions DoS and custom-server SSRF paths are not currently reachable.
- No custom Next server or rewrite rules were found, so those advisory-specific paths are not currently reachable.

### 2. postcss

```text
package: postcss
old version: 8.4.31 in the production Next dependency path
new version: 8.5.23
vulnerable range: <=8.5.22 (aggregate audit range)
patched version used: 8.5.23
direct/transitive: transitive
dependency path: application -> next -> postcss
reachability: NOT REACHABLE in application runtime; UNKNOWN at build time for hostile source-map input
advisory: GHSA-6g55-p6wh-862q, GHSA-r28c-9q8g-f849 (HIGH; audit also aggregated moderate PostCSS advisories)
fix: update through the direct Next dependency; the obsolete nested Next copy was removed
breaking change risk: low; no application import or API call changed
```

The package participates in the trusted build pipeline. No user-controlled CSS or source-map input was found, but severity was not reduced merely because the package was transitive.

### 3. nanoid

```text
package: nanoid
old version: 3.3.12
new version: 3.3.18
vulnerable range: <3.3.18 (the two advisories cover <3.3.16 and <3.3.18)
patched version used: 3.3.18
direct/transitive: transitive
dependency path: application -> next -> postcss -> nanoid
reachability: NOT REACHABLE for the vulnerable APIs
advisory: GHSA-28wg-ghj8-5hjv, GHSA-2v37-7h3g-55p8
fix: update through Next/PostCSS
breaking change risk: low; application code does not import nanoid and the major version is unchanged
```

The affected negative/zero-size custom generator inputs are not exposed by application code.

### 4. sharp

```text
package: sharp
old version: 0.34.5
new version: 0.35.4
vulnerable range: <0.35.0
patched version used: 0.35.4
direct/transitive: transitive optional production dependency
dependency path: application -> next -> sharp
reachability: LIKELY REACHABLE through Next image optimization; no configured remote image source was found
advisory: GHSA-f88m-g3jw-g9cj (inherited libvips issues including CVE-2026-33327, CVE-2026-33328, CVE-2026-35590, CVE-2026-35591)
fix: update through Next's optional dependency
breaking change risk: low-to-medium; Sharp minor version changed, but Next owns the integration and the production build completed successfully
```

## Update strategy

The smallest coherent update was an exact, non-major update of the direct dependency:

```text
next: 16.2.6 -> 16.3.4
```

This brought the production dependency path to:

```text
next 16.3.4
├─ postcss 8.5.23
│  └─ nanoid 3.3.18
└─ sharp 0.35.4
```

No override, forced audit fix, React update, Supabase update, or unrelated dependency upgrade was used. `eslint-config-next` remains a development dependency at its pre-existing version because it is outside the production HIGH remediation scope.

## Lockfile review

- `package.json` and `package-lock.json` both pin Next to `16.3.4`.
- The production tree contains one Next version (`16.3.4`), PostCSS `8.5.23`, Nano ID `3.3.18`, and Sharp `0.35.4`.
- The vulnerable nested `next/node_modules/postcss` copy was removed.
- `npm ls next postcss nanoid sharp --all --omit=dev` completed successfully and found no duplicate vulnerable production copy.
- Additional lockfile movement is limited to packages owned by the updated Next/PostCSS/Sharp dependency graph, including platform-specific optional Sharp/libvips and Next SWC packages.

## Files changed

Files changed by SECURITY REMEDIATION 03:

- `package.json`
- `package-lock.json`
- `SECURITY_REMEDIATION_03_DEPENDENCIES.md`

Other modified or untracked files already existed in the working tree and were preserved without staging, reverting, or incorporating them into this remediation.

## After

```text
npm audit --omit=dev:
CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
```

## Tests

```text
Node: PASS — 540/540
Supabase DB: PASS — 7 files, 103/103 (local database only)
TypeScript: PASS — npx tsc --noEmit
Build: PASS — Next.js 16.3.4, 35/35 static pages generated
ESLint baseline: EXISTING FAILURE — 14 errors, 6 warnings (unchanged)
New ESLint regressions: 0
git diff --check: PASS
```

The build reported the existing Next.js deprecation notice for the `middleware` file convention. It is not a build failure and was not refactored because that would exceed this remediation's dependency-only scope.

## Runtime review

- Supabase client/server and authentication tests passed in the complete Node suite.
- Middleware/admin protection compiled under Next 16.3.4; the middleware-to-proxy deprecation warning remains informational.
- Event, reservation, booking, confirmation, reporting, user-management, and admin route contracts passed in the complete Node suite.
- The production build compiled all application routes successfully.
- Local database contracts passed; no remote or production operation was performed.

## Verdict

```text
PRODUCTION DEPENDENCY HIGH FINDING:
FULLY REMEDIATED
```

The production audit contains zero HIGH and zero CRITICAL findings, vulnerable versions do not remain in the production dependency tree, regression tests and build pass, and there are no new ESLint regressions.
