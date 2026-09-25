import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { runInNewContext } from "node:vm";
import test from "node:test";
import ts from "typescript";

const require = createRequire(import.meta.url);
const source = readFileSync(new URL("./public-tenant-subpages.ts", import.meta.url), "utf8");
function load(mocks) {
  const exports = {};
  runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, {
    exports, process: { env: { NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:54321", NEXT_PUBLIC_SUPABASE_ANON_KEY: "test-anon" } },
    require: name => name === "server-only" ? {} : name === "../public-tenant-content" ? { parsePublicContent: value => value } : mocks[name] ?? require(name),
  });
  return exports;
}
const flagMap = { cennik: "showPricing", "o-obiekcie": "showAbout", kontakt: "showContact" };
for (let mask = 0; mask < 8; mask++) {
  test(`server gate enforces every section flag, combination ${mask}`, async () => {
    const tenant = Object.fromEntries(Object.values(flagMap).map((flag, bit) => [flag, Boolean(mask & (1 << bit))]));
    const api = load({
      "./public-tenant-directory": { getPublicTenantLanding: async slug => slug === "tenant-a" ? tenant : null },
      "./tenant-context": {}, "../public-booking-configuration": {},
    });
    for (const [section, flag] of Object.entries(flagMap)) {
      assert.equal(await api.getPublicSubpageTenant("tenant-a", section), tenant[flag] ? tenant : null);
      for (const unavailable of ["unknown", "private", "suspended"]) assert.equal(await api.getPublicSubpageTenant(unavailable, section), null);
    }
  });
}
test("content uses public selector RPC without client tenant authority", async () => {
  const calls = [];
  const api = load({
    "@supabase/supabase-js": { createClient: () => ({ rpc: async (name, args) => { calls.push({ name, args }); return { data: [], error: null }; } }) },
    "./public-tenant-directory": {},
    "./tenant-context": { resolvePublicTenantContext: async (_client, slug) => ({ ok: true, value: { tenantId: `resolved-${slug}` } }) },
    "../public-booking-configuration": { parsePublicBookingConfiguration: () => [{
      lane_id: "private-id", tenant_id: "never-export", display_name: "Oś A", display_order: 1,
      effective_online_bookable: true, currency_code: "PLN", pricing: [{
        day_group: "mon_thu", min_shooters: 1, max_shooters: 2, hourly_price: 50, label: "Wariant",
      }],
    }] },
  });
  const prices = JSON.parse(JSON.stringify(await api.getPublicTenantContent("tenant-a")));
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [{ name: "get_public_tenant_content_v1", args: { p_public_slug: "tenant-a" } }]);
  assert.doesNotMatch(JSON.stringify(prices), /private-id|tenant_id|lane_id|membership|billing|secret/);
});
test("unresolved tenant and failed pricing reader fail closed", async () => {
  const api = load({
    "@supabase/supabase-js": { createClient: () => ({ rpc: () => { throw new Error("must not query"); } }) },
    "./public-tenant-directory": {},
    "./tenant-context": { resolvePublicTenantContext: async () => ({ ok: false }) },
    "../public-booking-configuration": {},
  });
  assert.equal(await api.getPublicTenantContent("unknown"), null);
});
test("routes are server gated before rendering or alias redirect; no trusted query authority", () => {
  const route = readFileSync(resolve("app/_components/PublicTenantSubpage.tsx"), "utf8");
  assert.match(route, /if \(!tenant\) notFound\(\)/);
  assert.ok(route.indexOf("if (!tenant) notFound()") < route.indexOf("permanentRedirect(`"));
  assert.doesNotMatch(source + route, /SERVICE_ROLE|profiles\.role|searchParams|\.from\(/);
});
