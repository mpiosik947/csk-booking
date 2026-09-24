import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("./page.tsx", import.meta.url), "utf8");
const directory = readFileSync(
  new URL("../lib/server/public-tenant-directory.ts", import.meta.url),
  "utf8",
);
const alias = readFileSync(new URL("./[slug]/page.tsx", import.meta.url), "utf8");

test("home is the neutral StrzelajTu.pl platform directory", () => {
  assert.match(source, /StrzelajTu/u);
  assert.match(source, /Znajdź strzelnicę i zarezerwuj termin online/u);
  assert.match(source, /Publiczny katalog/u);
  assert.doesNotMatch(source, /Strzelnica CSK nie została|Centrum Szkolenia Krutla/u);
});

test("home search is accessible, bounded and server-backed", () => {
  assert.match(source, /role="search"/u);
  assert.match(source, /Wyszukaj strzelnicę lub miejscowość/u);
  assert.match(source, /name="q"/u);
  assert.match(source, /maxLength=\{80\}/u);
  assert.match(source, /getPublicTenantDirectory/u);
});

test("directory cards use public slug routes and have safe empty/error states", () => {
  assert.match(source, /href=\{`\/\$\{tenant\.publicSlug\}`\}/u);
  assert.match(source, /Nie znaleźliśmy strzelnicy/u);
  assert.match(source, /Nie udało się pobrać katalogu/u);
  assert.match(source, /sm:grid-cols-2/u);
  assert.doesNotMatch(source, /\/t\/csk|tenant\.tenantId|profiles|service_role/u);
});

test("server directory accepts only the four-field PII-free RPC contract", () => {
  assert.match(directory, /get_public_tenant_directory_v2/u);
  assert.match(directory, /public_slug/u);
  assert.match(directory, /tenant_city/u);
  assert.match(directory, /tenant_logo_path/u);
  assert.match(directory, /tenant_name/u);
  assert.doesNotMatch(
    directory,
    /user_id|email|phone|address|membership|SUPABASE_SERVICE_ROLE_KEY/u,
  );
});

test("root slug renders the published canonical landing and redirects technical aliases", () => {
  assert.match(alias, /getPublicTenantLanding\(slug\)/u);
  assert.match(alias, /if \(!tenant\) notFound\(\)/u);
  assert.match(alias, /permanentRedirect\(`\/\$\{tenant\.publicSlug\}`\)/u);
  assert.match(alias, /<PublicTenantLanding tenant=\{tenant\}/u);
});
