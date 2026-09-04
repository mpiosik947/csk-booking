import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const routeUrl = new URL("./route.ts", import.meta.url);

async function readRoute() {
  return readFile(routeUrl, "utf8");
}

test("caller JWT owns all business reads while service role is internal-only", async () => {
  const source = await readRoute();

  assert.match(source, /function getAuthenticatedSupabaseClient\(accessToken: string\)/u);
  assert.match(source, /Authorization: `Bearer \$\{accessToken\}`/u);
  assert.match(source, /getAuthenticatedSupabaseClient\(accessToken\)/u);
  assert.match(source, /getConfirmationServiceRoleClient\(configuration\)/u);
  assert.doesNotMatch(
    source,
    /completionClient\s*\.from\((?:"reservations"|"profiles"|"shooting_lanes")\)/u
  );
});

test("auth and limiter precede scoped reads and delivery", async () => {
  const source = await readRoute();
  const authIndex = source.indexOf("supabase.auth.getUser(accessToken)");
  const limiterIndex = source.indexOf("checkConfirmationEmailRateLimit({");
  const reservationIndex = source.indexOf('.from("reservations")');
  const accessGateIndex = source.indexOf("if (!isOwner && !isStaff)");
  const statusGateIndex = source.indexOf(
    "if (!isCancelledReservationStatus(reservation.reservation_status))"
  );
  const profileRpcIndex = source.indexOf(
    'supabase.rpc("get_reservation_customer_profiles_v1"'
  );
  const htmlIndex = source.indexOf("const html = `");
  const deliveryIndex = source.indexOf("deliverConfirmationEmail({");
  const prepareIndex = source.indexOf(
    'supabase.rpc("prepare_confirmation_email"'
  );

  for (const [name, index] of [
    ["auth", authIndex],
    ["limiter", limiterIndex],
    ["reservation lookup", reservationIndex],
    ["ownership/role gate", accessGateIndex],
    ["status gate", statusGateIndex],
    ["profile RPC", profileRpcIndex],
    ["HTML", htmlIndex],
    ["delivery", deliveryIndex],
    ["claim", prepareIndex],
  ]) {
    assert.notEqual(index, -1, `${name} should exist`);
  }

  assert.ok(authIndex < limiterIndex);
  assert.ok(limiterIndex < reservationIndex);
  assert.ok(reservationIndex < accessGateIndex);
  assert.ok(accessGateIndex < statusGateIndex);
  assert.ok(statusGateIndex < profileRpcIndex);
  assert.ok(profileRpcIndex < htmlIndex);
  assert.ok(htmlIndex < deliveryIndex);
  assert.ok(deliveryIndex < prepareIndex);
});

test("request, authorization, rate-limit and delivery responses are controlled", async () => {
  const source = await readRoute();

  assert.match(source, /Object\.keys\(parsedBody\)\.length !== 1/u);
  assert.match(source, /!\("reservationId" in parsedBody\)/u);
  assert.match(source, /return jsonError\("unauthorized", 401\)/u);
  assert.match(source, /return jsonError\("forbidden", 403\)/u);
  assert.match(source, /return jsonError\("invalid_status", 409\)/u);
  assert.match(source, /code: "rate_limited"/u);
  assert.match(source, /"Retry-After": String\(rateLimit\.retryAfterSeconds\)/u);
  assert.match(source, /"Cache-Control": "no-store"/u);
  assert.match(source, /\{ ok: outcome\.ok, code: outcome\.code \}/u);
  assert.doesNotMatch(source, /details:\s*\w+Error/u);
  assert.doesNotMatch(source, /message:\s*\w+Error/u);
});

test("recipient and content come only from trusted reservation/profile records", async () => {
  const source = await readRoute();
  const parsedPayload = source.match(
    /type ReservationCancellationPayload = \{([\s\S]*?)\};/u
  )?.[1];

  assert.match(parsedPayload ?? "", /reservationId\?: unknown/u);
  assert.doesNotMatch(parsedPayload ?? "", /email|recipient|subject|html|text/iu);
  assert.match(
    source,
    /const customerEmail =\s*reservation\.customer_email\?\.trim\(\)\s*\|\|\s*ownerProfile\?\.email\?\.trim\(\)/u
  );
  assert.match(source, /to: customerEmail/u);
  assert.doesNotMatch(source, /to:\s*body\./u);
});

test("cancellation uses the shared atomic delivery contract without retry", async () => {
  const source = await readRoute();

  assert.match(source, /deliverConfirmationEmail\(\{/u);
  assert.match(source, /p_message_type: "reservation_cancellation"/u);
  assert.match(source, /p_record_id: reservationId/u);
  assert.match(source, /\{ idempotencyKey \}/u);
  assert.match(
    source,
    /completionClient\.rpc\("complete_confirmation_email", input\)/u
  );
  assert.equal(source.match(/deliverConfirmationEmail\(\{/gu)?.length, 1);
  assert.equal(source.match(/resend\.emails\.send\(/gu)?.length, 1);
  assert.doesNotMatch(source, /setTimeout|while\s*\(/u);
});

test("dynamic HTML remains escaped and plain text remains plain", async () => {
  const source = await readRoute();
  for (const value of [
    "displayName",
    "formattedDate",
    "startTime",
    "endTime",
    "laneName",
  ]) {
    assert.match(
      source,
      new RegExp(`const safe[A-Za-z]+ = escapeHtml\\(${value}\\)`)
    );
  }

  const html = source.match(/const html = `([\s\S]*?)`;/u)?.[1] ?? "";
  assert.ok(html.length > 0);
  assert.deepEqual(
    [...html.matchAll(/\$\{([^}]+)\}/gu)]
      .map((match) => match[1])
      .filter(
        (interpolation) =>
          !interpolation.startsWith("safe") &&
          interpolation !== "cancelledByText"
      ),
    []
  );
  assert.doesNotMatch(html, /href=/u);

  const plainText = source.match(/const text = `([\s\S]*?)`;/u)?.[1] ?? "";
  assert.match(plainText, /\$\{displayName\}/u);
  assert.doesNotMatch(plainText, /safeDisplayName/u);
});
