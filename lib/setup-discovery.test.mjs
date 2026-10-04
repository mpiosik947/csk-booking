import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import ts from "typescript";
const code = ts.transpileModule(readFileSync(new URL("./setup-discovery.ts", import.meta.url), "utf8"), { compilerOptions: { module: ts.ModuleKind.ESNext } }).outputText;
const { isDormantTenant } = await import("data:text/javascript;base64," + Buffer.from(code).toString("base64"));
const row = { tenant_id: "6d466b63-8711-41c2-9fc5-a7457e481d23", tenant_slug: "synthetic-range", display_name: "Synthetic", city: null, tenant_status: "dormant" };
test("discovery accepts canonical technical slugs and nullable city", () => {
  assert.equal(isDormantTenant(row), true);
  assert.equal(isDormantTenant({ ...row, city: "City" }), true);
});
test("discovery rejects active tenants, incomplete rows and route injection", () => {
  for (const value of [null, [], {}, { ...row, tenant_status: "active" }, { ...row, tenant_id: "invalid" }, { ...row, city: 12 }]) assert.equal(isDormantTenant(value), false);
  for (const tenant_slug of ["../admin", "a/b", "a?b", "a#b", "https://example.invalid", "-range", "range--x"]) assert.equal(isDormantTenant({ ...row, tenant_slug }), false);
});
