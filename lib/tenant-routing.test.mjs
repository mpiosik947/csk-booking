import test from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { classifyTenantRoute, legacyCskPath } from "./tenant-routing.ts";

const root = new URL("../", import.meta.url);

test("9E-B has exactly three new route surfaces and no operational caller cutover", async () => {
  const tenantRoot = new URL("../app/t/[slug]/", import.meta.url);
  assert.deepEqual((await readdir(tenantRoot)).sort(),
    ["[...path]", "layout.tsx", "page.tsx"].sort());
  assert.deepEqual(await readdir(new URL("[...path]/", tenantRoot)), ["page.tsx"]);
  for (const file of ["layout.tsx", "page.tsx", "[...path]/page.tsx"]) {
    const source = await readFile(new URL(file, tenantRoot), "utf8");
    assert.doesNotMatch(source, /active_single_tenant_id_v1|service_role|\.from\(|\.rpc\(/);
  }
});

test("both trusted tenant modules deny non-server imports", async () => {
  const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
  assert.equal(pkg.dependencies["server-only"], "0.0.1");
  for (const filename of ["tenant-context.ts", "tenant-context-core.ts"]) {
    const source = await readFile(new URL(`./server/${filename}`, import.meta.url), "utf8");
    assert.match(source, /^import "server-only";/);
    const run = spawnSync(process.execPath,
      ["--input-type=module", "-e", `import('./lib/server/${filename}')`],
      { cwd: root, encoding: "utf8" });
    assert.notEqual(run.status, 0, `${filename} unexpectedly imported outside server runtime`);
    assert.match(run.stderr, /cannot be imported from a Client Component/u);
  }
});

test("both trusted tenant modules remain importable in server runtime", () => {
  const run = spawnSync(process.execPath,
    ["--conditions=react-server", "--input-type=module", "-e",
      "await import('./lib/server/tenant-context.ts'); await import('./lib/server/tenant-context-core.ts')"],
    { cwd: root, encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
});

test("public and ordinary user paths never imply staff membership", () => {
  assert.deepEqual(classifyTenantRoute(["booking"]), { kind: "public", path: "booking" });
  assert.deepEqual(classifyTenantRoute(["events"]), { kind: "public", path: "events" });
  assert.deepEqual(classifyTenantRoute(["my-reservations"]),
    { kind: "user", path: "my-reservations" });
  assert.deepEqual(classifyTenantRoute(["my-events"]),
    { kind: "user", path: "my-events" });
  assert.deepEqual(classifyTenantRoute(["account"]), { kind: "not_found" });
  assert.deepEqual(classifyTenantRoute(["booking", "foreign"]), { kind: "not_found" });
});

test("staff roles preserve the existing admin permission matrix", () => {
  assert.deepEqual(classifyTenantRoute(["admin"]),
    { kind: "staff", path: "admin", roles: ["admin", "employee", "instructor"], known: true });
  assert.deepEqual(classifyTenantRoute(["admin", "users"]),
    { kind: "staff", path: "admin/users", roles: ["admin"], known: true });
  assert.deepEqual(classifyTenantRoute(["admin", "check-in"]),
    { kind: "staff", path: "admin/check-in", roles: ["admin", "employee"], known: true });
  assert.deepEqual(classifyTenantRoute(["admin", "calendar"]),
    { kind: "staff", path: "admin/calendar", roles: ["admin", "employee", "instructor"], known: true });
  assert.deepEqual(classifyTenantRoute(["admin", "__future-test-route"]),
    { kind: "not_found" });
  assert.deepEqual(classifyTenantRoute(["admin", "future-test-route"]),
    { kind: "staff", path: "admin/future-test-route", roles: ["admin"], known: false });
});

test("legacy CSK paths are explicit links, never a selected-tenant fallback", () => {
  const booking = classifyTenantRoute(["booking"]);
  assert.equal(legacyCskPath("csk", booking), "/booking");
  assert.equal(legacyCskPath("tenant-b", booking), null);
  assert.equal(legacyCskPath("csk", classifyTenantRoute(["admin", "future-test-route"])), null);
});

test("new route shells use a server resolver, Auth and membership with no global role authority", async () => {
  const layout = await readFile(new URL("../app/t/[slug]/layout.tsx", import.meta.url), "utf8");
  const page = await readFile(new URL("../app/t/[slug]/[...path]/page.tsx", import.meta.url), "utf8");
  const adapter = await readFile(new URL("./server/tenant-route-context.ts", import.meta.url), "utf8");
  assert.match(layout, /getPublicRouteContext\(slug\)/);
  assert.match(page, /getUserRouteContext\(slug\)/);
  assert.match(page, /getStaffRouteContext\(slug, route\.roles\)/);
  assert.match(adapter, /resolveStaffTenantContext/);
  assert.match(adapter, /NEXT_PUBLIC_SUPABASE_ANON_KEY/);
  for (const source of [layout, page, adapter]) {
    assert.doesNotMatch(source, /profiles\.role|get_my_role|SUPABASE_SERVICE_ROLE_KEY|localStorage/);
  }
});
