import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import test from "node:test";
import ts from "typescript";

const exports = {};
runInNewContext(ts.transpileModule(readFileSync(new URL("./tenant-public-access.ts", import.meta.url), "utf8"), {
  compilerOptions: { module: ts.ModuleKind.CommonJS },
}).outputText, { exports });
const { readTenantPublicAccess, fetchTenantPublicAccess, publicAccessError } = exports;

test("public availability DTO is minimal and fail-closed", () => {
  for (const state of ["live", "coming_soon"]) for (const allowed of [true, false]) {
    assert.equal(readTenantPublicAccess({ state, allowed })?.allowed, allowed);
  }
  for (const invalid of [null, [], {}, { state: "archived", allowed: true },
    { state: "live", allowed: "true" }, { state: "live", allowed: true, role: "admin" }]) {
    assert.equal(readTenantPublicAccess(invalid), null);
  }
});

test("concurrent actors and tenants never share an authorization decision", async () => {
  const requests = [];
  const client = allowed => ({ rpc: async (name, args) => {
    requests.push([name, args.p_slug, allowed]);
    return { data: { state: "coming_soon", allowed }, error: null };
  } });
  const results = await Promise.all([true, false, true, false].map((allowed, i) =>
    fetchTenantPublicAccess(client(allowed), i < 2 ? "a" : "b")));
  assert.deepEqual(Array.from(results, x => x.allowed), [true, false, true, false]);
  assert.equal(requests.length, 4);
  assert.ok(requests.every(x => x[0] === "get_public_tenant_access_v1"));
});

test("RPC failures never default to live or allow", async () => {
  for (const rpc of [async () => { throw Error("network"); }, async () => ({ data: { state: "live", allowed: true }, error: {} }),
    async () => ({ data: null, error: null })]) {
    assert.equal(await fetchTenantPublicAccess({ rpc }, "a"), null);
  }
});

test("availability and retry errors have stable, separate Polish contracts", () => {
  assert.equal(publicAccessError({ code: "PT423" }).code, "TENANT_PUBLIC_ACCESS_UNAVAILABLE");
  assert.equal(publicAccessError({ code: "PT423" }).error, "Dostępna wkrótce");
  assert.equal(publicAccessError({ code: "PT409" }).status, 409);
  for (const code of ["42501", "22023", "P0002", "PT500"]) assert.equal(publicAccessError({ code }), null);
});
