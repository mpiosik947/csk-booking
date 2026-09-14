import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const routeUrl = new URL("./route.ts", import.meta.url);

async function readRoute() {
  return readFile(routeUrl, "utf8");
}

test("manual reserve promotion authenticates and tenant-authorizes before service execution", async () => {
  const source = await readRoute();
  const authIndex = source.indexOf("authenticatedSupabase.auth.getUser(accessToken)");
  const eventIndex = source.indexOf('.from("events")');
  const membershipIndex = source.indexOf(
    'authenticatedSupabase.rpc("has_tenant_role_v1"'
  );
  const serviceIndex = source.indexOf("promoteEventReserve(eventId)");

  for (const [name, index] of [
    ["auth", authIndex],
    ["event lookup", eventIndex],
    ["tenant membership", membershipIndex],
    ["service execution", serviceIndex],
  ]) {
    assert.notEqual(index, -1, `${name} should exist`);
  }

  assert.ok(authIndex < eventIndex);
  assert.ok(eventIndex < membershipIndex);
  assert.ok(membershipIndex < serviceIndex);
});

test("tenant authority is derived from the event and only active admin or employee membership is accepted", async () => {
  const source = await readRoute();

  assert.match(source, /\.select\("id, tenant_id"\)/u);
  assert.match(source, /p_tenant_id: event\.tenant_id/u);
  assert.match(source, /p_roles: \["admin", "employee"\]/u);
  assert.match(source, /if \(hasAllowedTenantRole !== true\)/u);
  assert.doesNotMatch(source, /\.from\("profiles"\)/u);
  assert.doesNotMatch(source, /operatorRole|profiles\.role|"pracownik"/u);
});

test("request accepts only one eventId and never accepts tenant or recipient authority", async () => {
  const source = await readRoute();
  const payload = source.match(
    /type EventReservePromotionPayload = \{([\s\S]*?)\};/u
  )?.[1];

  assert.match(payload ?? "", /eventId\?: unknown/u);
  assert.doesNotMatch(
    payload ?? "",
    /tenant|user|email|recipient|claim|registration/iu
  );
  assert.match(source, /Object\.keys\(parsedBody\)\.length !== 1/u);
  assert.match(source, /!\("eventId" in parsedBody\)/u);
});

test("new endpoint remains compatible with the old promotion RPC contract", async () => {
  const source = await readRoute();

  assert.match(source, /promoteEventReserve\(eventId\)/u);
  assert.doesNotMatch(source, /promoteEventReserve\([^)]*tenant/iu);
  assert.doesNotMatch(
    source,
    /prepare_event_reserve_promotions|complete_event_reserve_promotion/u
  );
});

test("authorization failures use controlled responses without tenant or membership disclosure", async () => {
  const source = await readRoute();

  assert.match(source, /\{ error: "Unauthorized" \}, \{ status: 401 \}/u);
  assert.match(source, /\{ error: "Forbidden" \}, \{ status: 403 \}/u);
  assert.match(source, /\{ error: "Nie znaleziono szkolenia\." \}/u);
  assert.doesNotMatch(source, /details:\s*\w+Error|message:\s*\w+Error/u);
});
