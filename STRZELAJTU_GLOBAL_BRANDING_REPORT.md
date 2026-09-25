# StrzelajTu global branding — clean candidate

Base: 4a74987bf0d99066dbe505cdf499cf55a2e1c48f (fresh origin/main).
Branch: branding-clean-review-20260925.
Candidate: C:/Users/Mpios/Desktop/APP Krutla/branding-clean-review.

## Exact manifest (19 files)

- app/page.tsx
- app/page.test.mjs
- app/layout.tsx
- app/login/page.tsx
- app/register/page.tsx
- app/forgot-password/page.tsx
- app/reset-password/page.tsx
- app/account/page.tsx
- app/dashboard/page.tsx
- app/platform-admin/page.tsx
- app/_components/DirectorySearchInput.tsx
- app/_components/PlatformBrand.tsx
- app/platform-brand.css
- app/platform-branding.test.mjs
- tests/e2e/platform-branding.spec.ts
- playwright.branding.config.ts
- public/brand/strzelajtu/logo-horizontal.png
- public/brand/strzelajtu/logo-symbol.png
- STRZELAJTU_GLOBAL_BRANDING_REPORT.md

## Extraction and exclusions

Tracked UI hunks were applied against current origin, not copied wholesale from the old mixed worktree. Shared register/forgot-password files retain PRODUCT-10F imports and PLATFORM_BASE_URL redirects. Existing 10F Link navigation was retained. Only presentation, consent copy, metadata and branding tests are changed.

Excluded mixed files: AGENTS.md; PLATFORM_ADMIN_GLOBAL_AUDIT_FIX_REPORT.md; SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md; SAAS_FINAL_MIGRATION_MASTER_REPORT.md; FINAL_SAAS_SECURITY_AUDIT_2026_09.md; PRODUCT_10E_WORKTREE_RECONCILIATION_REPORT.md; PRODUCT_10F_CUSTOM_DOMAINS_REPORT.md; app/_components/PublicTenantLanding.tsx; app/public-tenant-landing.test.mjs; scripts/product10e-isolated-e2e.mjs; tests/e2e/csk-visual-restore.spec.ts; tests/e2e/information-rows.spec.ts; supabase/drafts/*; branding logs and unrelated work.

CSK landing, migrations, middleware, lib/platform-domain.ts and auth callback remain identical to base. No DB/security/authority changes. Tenant return context remains guarded by getSafeLoginRedirect.

PNG bytes are unchanged from supplied assets. Candidate path is lowercase public/brand/strzelajtu; exact spelling verified using git ls-files in a disposable GIT_INDEX_FILE. Normal candidate index remains empty. No commit/push/deploy.

## Verification

- Full Node suite: 850/850 PASS, including canonical auth regression and consent-copy checks.
- Playwright branding/auth: 8/8 PASS on this candidate's production build, local Supabase only. Viewports 375/430/768/1024/1440; directory, auth UI, return context, CSK landing and unauthenticated platform guard.
- TypeScript: PASS.
- Production webpack build: PASS.
- ESLint changed code/tests: 0 errors, 1 pre-existing unused-message warning in register.
- git diff --check: PASS.
- No emails sent or passwords changed; account test uses logged-out state; reset page uses no recovery session. No fixtures created.
- Test evidence logs are outside candidate. Local ignored .env.local and node_modules junction are test dependencies, not checkpoint files.

Homepage and auth visuals approved by user; registration copy adjusted as requested. Full LEGAL/GDPR gate remains separate before public launch.

Ready for authorized checkpoint/deploy review. Push may trigger Vercel deployment; neither push nor deployment performed here.
