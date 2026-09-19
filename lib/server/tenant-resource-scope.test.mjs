import assert from "node:assert/strict";
import test from "node:test";
import { tenantResourceMatches } from "./tenant-resource-scope-core.ts";

const A = "c5c00000-0000-4000-8000-000000000001";
const B = "b5b00000-0000-4000-8000-000000000001";
const RESOURCE = "f00d0000-0000-4000-8000-000000000001";

function client({ tenantId = A, resourceTenant = A, tenantError = null, resourceError = null } = {}) {
  const calls = [];
  return {
    calls,
    rpc(name, args) {
      calls.push([name, args]);
      return Promise.resolve({ data: tenantError ? null : [{ tenant_id: tenantId }], error: tenantError });
    },
    from(table) {
      calls.push(["from", table]);
      return {
        select(columns) {
          calls.push(["select", columns]);
          return {
            eq(column, value) {
              calls.push(["eq", column, value]);
              return {
                maybeSingle: async () => ({ data: resourceError ? null : { tenant_id: resourceTenant }, error: resourceError }),
              };
            },
          };
        },
      };
    },
  };
}

test("trusted active slug and persisted tenant must match", async () => {
  const c = client();
  assert.equal(await tenantResourceMatches(c, "csk", "shooting_lanes", RESOURCE), true);
  assert.deepEqual(c.calls[0], ["resolve_active_tenant_by_slug_v1", { p_slug: "csk" }]);
  assert.deepEqual(c.calls.at(-1), ["eq", "id", RESOURCE]);
});

test("route A plus resource B is denied", async () => {
  assert.equal(await tenantResourceMatches(client({ resourceTenant: B }), "csk", "events", RESOURCE), false);
});

test("malformed slug and resolver failure deny before resource lookup", async () => {
  const malformed = client();
  assert.equal(await tenantResourceMatches(malformed, "CSK/other", "events", RESOURCE), false);
  assert.deepEqual(malformed.calls, []);
  const failed = client({ tenantError: { code: "unavailable" } });
  assert.equal(await tenantResourceMatches(failed, "csk", "events", RESOURCE), false);
  assert.equal(failed.calls.some(([name]) => name === "from"), false);
});

test("resource read failure denies selected-tenant write", async () => {
  assert.equal(await tenantResourceMatches(client({ resourceError: { code: "42501" } }), "csk", "reservations", RESOURCE), false);
});
