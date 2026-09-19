import test from "node:test";
import assert from "node:assert/strict";
import {
  isCanonicalTenantSlug,
  tenantSlugFromPath,
  resolvePublicTenantContext,
  resolveAuthenticatedTenantContext,
  resolveStaffTenantContext,
  resourceBelongsToTenant,
} from "./tenant-context.ts";

const A = "c5c00000-0000-4000-8000-000000000001";
const B = "4e000000-0000-4000-8000-000000000001";
const USER = "2e000000-0000-4000-8000-000000000001";

function client({ active = ["csk"], roles = {}, user = USER, extra = false } = {}) {
  const calls = [];
  return {
    calls,
    auth: { async getUser() { return { data: { user: user ? { id: user } : null }, error: null }; } },
    async rpc(name, args) {
      calls.push({ name, args });
      if (name === "resolve_active_tenant_by_slug_v1") {
        const slug = args.p_slug;
        if (!active.includes(slug)) return { data: [], error: null };
        return { data: [{ tenant_id: slug === "csk" ? A : B,
          tenant_slug: slug, tenant_name: slug === "csk" ? "CSK" : "Tenant B",
          tenant_status: "active",
          ...(extra ? { admin_note: "PRIVATE" } : {}) }], error: null };
      }
      if (name === "get_my_tenant_role_v1") {
        return { data: roles[args.p_tenant_id] ?? null, error: null };
      }
      throw new Error("Unexpected RPC");
    },
  };
}

test("canonical route selector is strict and never uses query/cookie", () => {
  assert.equal(isCanonicalTenantSlug("csk"), true);
  for (const slug of ["CSK", " csk", "csk/other", "a", "ę", "csk%2fadmin", "csk_"]) {
    assert.equal(isCanonicalTenantSlug(slug), false);
  }
  assert.equal(tenantSlugFromPath("/t/csk/booking"), "csk");
  assert.equal(tenantSlugFromPath("/t/csk"), "csk");
  assert.equal(tenantSlugFromPath("/booking?tenant=csk"), null);
  assert.equal(tenantSlugFromPath("/t/CSK/admin"), null);
  assert.equal(tenantSlugFromPath("/t/csk%2Fother/admin"), null);
});

test("public A and local synthetic active B resolve independently", async () => {
  const source = client({ active: ["csk", "tenant-b"] });
  const [a, b] = await Promise.all([
    resolvePublicTenantContext(source, "csk"),
    resolvePublicTenantContext(source, "tenant-b"),
  ]);
  assert.equal(a.ok && a.value.tenantId, A);
  assert.equal(b.ok && b.value.tenantId, B);
  assert.deepEqual(source.calls.map(({ name }) => name), [
    "resolve_active_tenant_by_slug_v1", "resolve_active_tenant_by_slug_v1",
  ]);
});

test("unknown, inactive and malformed slugs fail closed without fallback", async () => {
  const source = client();
  assert.deepEqual(await resolvePublicTenantContext(source, "tenant-b"), { ok: false, code: "not_found" });
  assert.deepEqual(await resolvePublicTenantContext(source, "UNKNOWN"), { ok: false, code: "not_found" });
  assert.deepEqual(await resolvePublicTenantContext(source, null), { ok: false, code: "not_found" });
  assert.equal(source.calls.length, 1);
});

test("public DTO rejects extra PII/internal fields", async () => {
  assert.deepEqual(await resolvePublicTenantContext(client({ extra: true }), "csk"),
    { ok: false, code: "not_found" });
  const inactive = client();
  inactive.rpc = async () => ({ data: [{ tenant_id: A, tenant_slug: "csk",
    tenant_name: "CSK", tenant_status: "dormant" }], error: null });
  assert.deepEqual(await resolvePublicTenantContext(inactive, "csk"),
    { ok: false, code: "not_found" });
});

test("authenticated customer context does not infer membership from route", async () => {
  const source = client({ active: ["csk", "tenant-b"] });
  const a = await resolveAuthenticatedTenantContext(source, "csk");
  const b = await resolveAuthenticatedTenantContext(source, "tenant-b");
  assert.equal(a.ok && a.value.userId, USER);
  assert.equal(a.ok && a.value.tenant.tenantId, A);
  assert.equal(b.ok && b.value.tenant.tenantId, B);
  assert.equal(source.calls.some(({ name }) => name === "get_my_tenant_role_v1"), false);
  assert.deepEqual(await resolveAuthenticatedTenantContext(client({ user: null }), "csk"),
    { ok: false, code: "unauthorized" });
});

test("staff A is permitted only by active tenant membership role", async () => {
  const source = client({ active: ["csk", "tenant-b"], roles: { [A]: "admin" } });
  const a = await resolveStaffTenantContext(source, "csk", ["admin"]);
  const b = await resolveStaffTenantContext(source, "tenant-b", ["admin"]);
  assert.equal(a.ok && a.value.role, "admin");
  assert.deepEqual(b, { ok: false, code: "forbidden" });
  assert.deepEqual(source.calls.filter(({ name }) => name === "get_my_tenant_role_v1")
    .map(({ args }) => args.p_tenant_id), [A, B]);
});

test("pending, suspended, absent, wrong role and global profile role cannot authorize", async () => {
  for (const role of [null, "pending", "suspended", "user", "pracownik"]) {
    assert.deepEqual(await resolveStaffTenantContext(client({ roles: { [A]: role } }), "csk", ["admin"]),
      { ok: false, code: "forbidden" });
  }
});

test("employee and instructor remain confined to explicitly allowed roles", async () => {
  assert.equal((await resolveStaffTenantContext(client({ roles: { [A]: "employee" } }),
    "csk", ["admin", "employee"])).ok, true);
  assert.deepEqual(await resolveStaffTenantContext(client({ roles: { [A]: "instructor" } }),
    "csk", ["admin", "employee"]), { ok: false, code: "forbidden" });
  assert.equal((await resolveStaffTenantContext(client({ roles: { [A]: "instructor" } }),
    "csk", ["instructor"])).ok, true);
  assert.deepEqual(await resolveStaffTenantContext(client({ roles: { [A]: "user" } }),
    "csk", ["user"]), { ok: false, code: "forbidden" });
});

test("route A/resource B and route B/resource A deny without rewriting resource", async () => {
  const source = client({ active: ["csk", "tenant-b"] });
  const a = await resolvePublicTenantContext(source, "csk");
  const b = await resolvePublicTenantContext(source, "tenant-b");
  assert.equal(a.ok && await resourceBelongsToTenant(a.value, async () => A), true);
  assert.equal(a.ok && await resourceBelongsToTenant(a.value, async () => B), false);
  assert.equal(b.ok && await resourceBelongsToTenant(b.value, async () => A), false);
  assert.equal(b.ok && await resourceBelongsToTenant(b.value, async () => B), true);
  assert.equal(a.ok && await resourceBelongsToTenant(a.value, async () => null), false);
  assert.equal(a.ok && await resourceBelongsToTenant(a.value, async () => { throw Error("DB"); }), false);
});

test("two tabs and stale preference cannot change path/resource authority", async () => {
  const source = client({ active: ["csk", "tenant-b"], roles: { [A]: "admin" } });
  const [tabA, tabB] = await Promise.all([
    resolveStaffTenantContext(source, tenantSlugFromPath("/t/csk/admin"), ["admin"]),
    resolveStaffTenantContext(source, tenantSlugFromPath("/t/tenant-b/admin"), ["admin"]),
  ]);
  assert.equal(tabA.ok, true);
  assert.deepEqual(tabB, { ok: false, code: "forbidden" });
});
