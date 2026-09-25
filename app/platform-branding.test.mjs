import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import test from "node:test";
const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
test("branding preserves PRODUCT-10F canonical auth redirects", () => {
  for (const route of ["register", "forgot-password"]) {
    const source = read("./" + route + "/page.tsx");
    assert.match(source, /import \{ PLATFORM_BASE_URL \} from "@\/lib\/platform-domain"/);
    assert.doesNotMatch(source, /window\.location\.origin/);
  }
  assert.ok(read("./register/page.tsx").includes('emailRedirectTo: `${PLATFORM_BASE_URL}/auth/callback`'));
  assert.ok(read("./forgot-password/page.tsx").includes('const redirectTo = `${PLATFORM_BASE_URL}/reset-password`'));
  assert.match(read("../lib/platform-domain.ts"), /PLATFORM_BASE_URL = "https:\/\/strzelajtu.pl"/);
});
test("registration consent copy refers to the global platform without changing consent controls", () => {
  const source = read("./register/page.tsx");
  const labels = [...source.matchAll(/<label className="flex gap-3[\s\S]*?<\/label>/g)]
    .map(([label]) => label.slice(label.indexOf("<span>")).replace(/\{" "\}/g, " ").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().replace(/ \./g, "."));
  assert.deepEqual(labels, [
    "Oświadczam, że zapoznałem/am się z regulaminem serwisu StrzelajTu.pl i akceptuję jego treść.",
    "Oświadczam, że zapoznałem/am się z polityką prywatności.",
  ]);
  assert.doesNotMatch(source, /RODO|regulamin(?:em)? strzelnicy/);
  assert.match(source, /checked=\{acceptedTerms\}/);
  assert.match(source, /checked=\{acceptedPrivacy\}/);
  assert.match(source, /href="\/terms"/);
  assert.match(source, /href="\/privacy"/);
});
for (const route of ["login", "register", "forgot-password", "reset-password", "account", "dashboard"]) {
  test(route + " uses platform-only brand", () => {
    const source = read("./" + route + "/page.tsx");
    assert.match(source, /PlatformBrand/);
    assert.doesNotMatch(source, /login-brand\.png|CSK Booking|CSK BOOKING|Centrum Szkolenia Krutla/);
    assert.match(source, /platform-ui/);
  });
}
test("login return context and auth contract remain intact", () => {
  const source = read("./login/page.tsx");
  assert.match(source, /supabase.auth.signInWithPassword/);
  assert.match(source, /getSafeLoginRedirect\(params.get\("redirectTo"\)\)/);
  assert.match(source, /window.location.href = redirectTo/);
});
test("platform admin authority guard remains before UI", () => {
  const source = read("./platform-admin/page.tsx");
  assert.match(source, /await requirePlatformAdmin\(\)/);
  assert.match(source, /PlatformBrand/);
});
test("platform metadata uses supplied icon and identity", () => {
  const source = read("./layout.tsx");
  assert.match(source, /logo-symbol.png/);
  assert.match(source, /logo-horizontal.png/);
  assert.doesNotMatch(source, /CSK|Krutla/);
});
