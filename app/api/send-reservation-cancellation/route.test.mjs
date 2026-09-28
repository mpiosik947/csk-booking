import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { operationalEmailBrand, operationalEmailHistoryUrl } from "../../../lib/server/operational-email-core.ts";
import { operationalEmailLayout } from "../../../lib/server/operational-email-layout.ts";

const source = readFileSync(new URL("./route.ts", import.meta.url), "utf8");
const reservationId = "11111111-1111-4111-8111-111111111111";
function handler({ denied = false, unavailable = false, cancelledBy = "user" } = {}) {
  const calls = { resolver: 0, sent: [], rpc: [] };
  const client = {
    auth: { getUser: async () => ({ data: { user: { id: reservationId } }, error: null }) },
    rpc: async (name, args) => {
      calls.rpc.push([name, args]);
      if (name === "get_reservation_cancellation_email_v1") return {
        data: denied || unavailable ? null : { recipient_email: "fixture@example.invalid", customer_name: "Synthetic",
          reservation_date: "2026-10-20", start_time: "10:00", end_time: "11:00", lane_name: "Lane B", cancelled_by: cancelledBy },
        error: denied ? { code: "42501" } : null,
      };
      return { data: { code: "ready" }, error: null };
    },
  };
  const deps = {
    "next/server": { NextResponse: { json: (data, options) => Response.json(data, options) } },
    "@supabase/supabase-js": { createClient: () => client },
    "resend": { Resend: class { emails = { send: async (mail) => { calls.sent.push(mail); return { data: { id: "synthetic" }, error: null }; } }; } },
    "@/lib/server/operational-email": { operationalEmailBrand, operationalEmailHistoryUrl,
      resolveReservationEmailTenantContext: async id => {
        assert.equal(id, reservationId); calls.resolver++;
        return { displayName: "Synthetic Range B", tenantSlug: "synthetic-b", publicSlug: "synthetic-range-b" };
      } },
    "@/lib/server/confirmation-email-delivery": {
      getConfirmationEmailConfiguration: () => ({ resendApiKey: "fixture", from: "fixture@example.invalid" }),
      getConfirmationServiceRoleClient: () => client,
      deliverConfirmationEmail: async ({ prepare, send }) => {
        await prepare(); await send("stable-fixture-key"); return { ok: true, code: "sent", status: 200 };
      },
    },
    "@/lib/server/confirmation-email-rate-limit": {
      getConfirmationRateLimitSecret: () => "fixture",
      checkConfirmationEmailRateLimit: async () => ({ kind: "allowed" }),
    },
    "@/lib/server/auth-user-verification": { verifyAuthUser: async read => ({ ok: true, user: (await read()).data.user }) },
    "@/lib/server/operational-email-layout": { operationalEmailLayout },
  };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, {
    exports, require: name => { assert.ok(deps[name], "Unexpected dependency " + name); return deps[name]; },
    process: { env: { NEXT_PUBLIC_SUPABASE_URL: "https://fixture.invalid", NEXT_PUBLIC_SUPABASE_ANON_KEY: "fixture" } },
    console: { error() {} }, Response,
  });
  return { calls, run: body => exports.POST(new Request("https://strzelajtu.pl/api/send-reservation-cancellation", {
    method: "POST", headers: { authorization: "Bearer synthetic" }, body: JSON.stringify(body),
  })) };
}
for (const actor of ["foreign-admin", "foreign-employee", "foreign-user", "inactive-member"]) {
  test(actor + ": denied DB authority stops before resolver/render/provider", async () => {
    const h = handler({ denied: true });
    assert.equal((await h.run({ reservationId })).status, 404);
    assert.equal(h.calls.resolver, 0); assert.equal(h.calls.sent.length, 0);
  });
}
test("missing resource fails before resolver/provider", async () => {
  const h = handler({ unavailable: true });
  assert.equal((await h.run({ reservationId })).status, 404);
  assert.equal(h.calls.resolver, 0); assert.equal(h.calls.sent.length, 0);
});
for (const extra of [{ tenant_id: reservationId }, { tenantSlug: "csk" }, { public_slug: "csk-krutla" }, { recipient_email: "evil@example.invalid" }]) {
  test("forged selector denied " + Object.keys(extra)[0], async () => {
    const h = handler();
    assert.equal((await h.run({ reservationId, ...extra })).status, 400);
    assert.equal(h.calls.rpc.length, 0); assert.equal(h.calls.sent.length, 0);
  });
}
for (const actor of ["user", "admin", "employee"]) test(actor + ": authorized reader supplies recipient before tenant renderer", async () => {
  const h = handler({ cancelledBy: actor === "user" ? "user" : "admin" });
  assert.equal((await h.run({ reservationId })).status, 200);
  assert.equal(h.calls.resolver, 1); assert.equal(h.calls.sent.length, 1);
  const mail = h.calls.sent[0];
  assert.equal(mail.to, "fixture@example.invalid");
  assert.equal(mail.subject, "StrzelajTu.pl / Synthetic Range B — Rezerwacja anulowana");
  assert.match(mail.html, /https:\/\/strzelajtu.pl\/t\/synthetic-b\/my-reservations/);
  assert.doesNotMatch(mail.html, /CSK|csk-krutla/);
  assert.deepEqual(JSON.parse(JSON.stringify(h.calls.rpc[0])), ["get_reservation_cancellation_email_v1", { p_reservation_id: reservationId }]);
});
test("no broad business reads or new business writes, and JWT precedes resource RPC", () => {
  assert.doesNotMatch(source, /\.from\(|\.insert\(|\.update\(|get_my_tenant_role_v1|profiles\.role/);
  assert.ok(source.indexOf("supabase.auth.getUser(accessToken)") < source.indexOf('"get_reservation_cancellation_email_v1"'));
  assert.ok(source.indexOf("if (reservationError)") < source.indexOf("await resolveReservationEmailTenantContext"));
  assert.match(source, /p_message_type: "reservation_cancellation"/);
  assert.match(source, /\{ idempotencyKey \}/);
});
