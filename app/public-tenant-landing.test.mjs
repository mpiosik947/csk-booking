import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const adapter = readFileSync(
  new URL("../lib/server/public-tenant-directory.ts", import.meta.url),
  "utf8",
);
const landing = readFileSync(
  new URL("./_components/PublicTenantLanding.tsx", import.meta.url),
  "utf8",
);
const publicRoute = readFileSync(new URL("./[slug]/page.tsx", import.meta.url), "utf8");
const technicalRoot = readFileSync(new URL("./t/[slug]/page.tsx", import.meta.url), "utf8");

test("landing adapter accepts only the PRODUCT-10C public DTO", () => {
  assert.match(adapter, /get_public_tenant_landing_v2/u);
  for (const field of [
    "tenant_slug", "public_slug", "tenant_name", "tenant_city",
    "tenant_logo_path", "tenant_hero_image_path", "tenant_description",
    "tenant_regulations_path",
    "tenant_public_address", "tenant_public_phone", "tenant_public_email",
    "tenant_opening_hours", "tenant_social_links", "show_booking", "show_events",
  ]) assert.match(adapter, new RegExp(field, "u"));
  assert.doesNotMatch(adapter, /user_id|admin_note|membership|SUPABASE_SERVICE_ROLE_KEY/u);
});

test("landing section toggles are presentation-only and omit hidden blocks", () => {
  for (const flag of ["showBooking", "showPricing", "showInstructor", "showEvents", "showAbout", "showContact", "showRegulations"]) {
    assert.match(landing, new RegExp(`tenant\\.${flag}`, "u"));
  }
  assert.match(landing, /\/t\/\$\{tenant\.tenantSlug\}\/booking/u);
  assert.match(landing, /\/t\/\$\{tenant\.tenantSlug\}\/events/u);
  assert.doesNotMatch(landing, /dangerouslySetInnerHTML/u);
});

test("universal landing contains no CSK identity or contact hardcoding", () => {
  assert.doesNotMatch(landing, /CSK|Krutla|Wolsztyn|login-brand|\+48|example\.(?:com|pl)/u);
  assert.match(landing, /tenant\.name/u);
  assert.match(landing, /tenant\.city/u);
  assert.match(landing, /tenant\.logoPath/u);
  assert.match(landing, /tenant\.description/u);
});

test("booking and event CTA preserve the resolved technical tenant context", () => {
  assert.match(landing, /\/t\/\$\{tenant\.tenantSlug\}\/booking`/u);
  assert.match(landing, /\/t\/\$\{tenant\.tenantSlug\}\/events`/u);
  assert.match(landing, /customDomain \? PLATFORM_BASE_URL : ""/u);
  assert.doesNotMatch(landing, /\/t\/csk/u);
});

test("public canonical route fails closed and redirects only a resolved alias", () => {
  assert.match(publicRoute, /if \(!tenant\) notFound\(\)/u);
  assert.match(publicRoute, /slug !== tenant\.publicSlug/u);
  assert.match(publicRoute, /permanentRedirect/u);
  assert.match(publicRoute, /alternates: \{ canonical:/u);
});

test("technical tenant root remains compatible without a duplicate public page", () => {
  assert.match(technicalRoot, /getPublicTenantLanding\(slug\)/u);
  assert.match(technicalRoot, /permanentRedirect\(`\/\$\{publishedTenant\.publicSlug\}`\)/u);
  assert.match(technicalRoot, /robots: \{ index: false/u);
});
