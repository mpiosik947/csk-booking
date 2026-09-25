import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { normalizeHostname, OLD_PLATFORM_HOST, LEGACY_AUTH_HOSTS, isLegacyAuthHost, hostFromRequest, platformUrl } from "./platform-domain.ts";
import { getSafeLoginRedirect } from "./safe-login-redirect.ts";

test("domain normalization accepts exact DNS hosts and rejects malformed selectors", () => {
  assert.equal(normalizeHostname("Tenant-A.Test"), "tenant-a.test");
  for (const raw of [null, "", "localhost", "127.0.0.1", "https://tenant-a.test", "tenant-a.test:443", "tenant-a.test/x", "a.test ", "a.test.", "a..test", "xn--foo.test", "a".repeat(64)+".test", "a.test@evil.test", "a.test,evil.test", "a.test\n"]) assert.equal(normalizeHostname(raw), null, String(raw));
});
test("localhost exception is explicit and never enables arbitrary ports on custom domains", () => {
  assert.equal(hostFromRequest("127.0.0.1:3001", true), "localhost");
  assert.equal(hostFromRequest("127.0.0.1:3001", false), null);
  assert.equal(hostFromRequest("tenant-a.test:3001", true), null);
});
test("clean cutover has no legacy completion timer or grace bypass", () => {
  for(const path of ["./platform-domain.ts","../middleware.ts","../app/auth/callback/route.ts"]) {
    assert.doesNotMatch(readFileSync(new URL(path,import.meta.url),"utf8"), /oldAuthGrace|GRACE_MS|PLATFORM_AUTH_CUTOVER_AT/);
  }
  const callback=readFileSync(new URL("../app/auth/callback/route.ts",import.meta.url),"utf8");
  assert.match(callback, /host !== PLATFORM_HOST && host !== "localhost"/);
  assert.ok(callback.indexOf('status: 404') < callback.indexOf('exchangeCodeForSession'));
});
test("fixed canonical origin and login allowlist prevent external redirect authority", () => {
  assert.equal(platformUrl("/t/tenant-a/booking"),"https://strzelajtu.pl/t/tenant-a/booking");
  for(const input of ["//evil.test","https://evil.test","javascript:alert(1)","/\\evil.test","/\nfoo"]) assert.throws(()=>platformUrl(input));
  for(const input of ["//evil.test","https://evil.test","https://strzelajtu.pl.evil.test/account","/%2f%2fevil.test","/t/tenant-a/booking?tenant=other"]) assert.equal(getSafeLoginRedirect(input),"/dashboard");
});

test("legacy selectors remain exact without allowing arbitrary subdomains", () => {
  assert.deepEqual(LEGACY_AUTH_HOSTS,["krutla.pl","www.krutla.pl",OLD_PLATFORM_HOST]);
  for(const host of LEGACY_AUTH_HOSTS) assert.equal(isLegacyAuthHost(host),true);
  for(const host of ["evil.krutla.pl","krutla.pl.evil.test","www.krutla.pl.evil.test","evil.vercel.app"])
    assert.equal(isLegacyAuthHost(host),false);
});

test("encoded/external login returns are denied while tenant internal context is preserved", () => {
  for(const value of ["https://evil.example","//evil.example","javascript:alert(1)","%2f%2fevil.example","/%2f%2fevil.example","/%252f%252fevil.example","/t/csk/booking%3fnext=https://evil.example"])
    assert.equal(getSafeLoginRedirect(value),"/dashboard");
  assert.equal(getSafeLoginRedirect("/t/tenant-a/booking"),"/t/tenant-a/booking");
});

test("confirmation and recovery generate only exact canonical redirects", () => {
  const source=path=>readFileSync(new URL(path,import.meta.url),"utf8");
  assert.ok(source("../app/register/page.tsx").includes('emailRedirectTo: `${PLATFORM_BASE_URL}/auth/callback`'));
  assert.ok(source("../app/forgot-password/page.tsx").includes('redirectTo = `${PLATFORM_BASE_URL}/reset-password`'));
  for(const path of ["../app/register/page.tsx","../app/forgot-password/page.tsx","../app/auth/callback/route.ts","../app/reset-password/page.tsx"])
    assert.doesNotMatch(source(path), /https:\/\/(?:www\.)?krutla\.pl|https:\/\/csk-booking-5nwh\.vercel\.app/);
});
