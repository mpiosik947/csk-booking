import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const routeUrl = new URL("./route.ts", import.meta.url);

async function readRoute() {
  return readFile(routeUrl, "utf8");
}

test("cancellation route uses the caller JWT and never service role", async () => {
  const source = await readRoute();

  assert.match(source, /function getAuthenticatedSupabaseClient\(accessToken: string\)/u);
  assert.match(source, /process\.env\.NEXT_PUBLIC_SUPABASE_ANON_KEY/u);
  assert.match(source, /Authorization: `Bearer \$\{accessToken\}`/u);
  assert.match(source, /getAuthenticatedSupabaseClient\(accessToken\)/u);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY/u);
  assert.doesNotMatch(source, /getAdminSupabaseClient/u);
});

test("authorization precedes the scoped staff profile lookup", async () => {
  const source = await readRoute();
  const authIndex = source.indexOf("verifyAuthUser");
  const reservationIndex = source.indexOf('.from("reservations")');
  const accessGateIndex = source.indexOf("if (!isOwner && !isStaff)");
  const statusGateIndex = source.indexOf(
    "if (!isCancelledReservationStatus(reservation.reservation_status))"
  );
  const profileRpcIndex = source.indexOf(
    'supabase.rpc("get_reservation_customer_profiles_v1"'
  );
  const htmlIndex = source.indexOf("const html = `");
  const providerIndex = source.indexOf("resend.emails.send");

  for (const [name, index] of [
    ["auth", authIndex],
    ["reservation lookup", reservationIndex],
    ["ownership/role gate", accessGateIndex],
    ["status gate", statusGateIndex],
    ["profile RPC", profileRpcIndex],
    ["HTML", htmlIndex],
    ["provider", providerIndex],
  ]) {
    assert.notEqual(index, -1, `${name} should exist`);
  }

  assert.ok(authIndex < reservationIndex);
  assert.ok(reservationIndex < accessGateIndex);
  assert.ok(accessGateIndex < statusGateIndex);
  assert.ok(statusGateIndex < profileRpcIndex);
  assert.ok(profileRpcIndex < htmlIndex);
  assert.ok(htmlIndex < providerIndex);
});

test("unauthorized access and lookup failures remain controlled", async () => {
  const source = await readRoute();

  assert.match(
    source,
    /if \(!isOwner && !isStaff\)[\s\S]*?Brak uprawnień do tej operacji\.[\s\S]*?status: 403/u
  );
  assert.match(
    source,
    /if \(ownerProfileError\)[\s\S]*?Nie udało się pobrać danych odbiorcy\.[\s\S]*?status: 500/u
  );
  assert.doesNotMatch(
    source,
    /ownerProfileError[\s\S]{0,300}(?:message|details|hint)/u
  );
});

test("provider is reached only after lookup and dynamic HTML stays escaped", async () => {
  const source = await readRoute();
  const lookupErrorIndex = source.indexOf("if (ownerProfileError)");
  const providerIndex = source.indexOf("resend.emails.send");

  assert.ok(lookupErrorIndex !== -1 && lookupErrorIndex < providerIndex);
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

  // Cancellation mail has no dynamic link. URL validation remains covered by
  // the shared email-html tests for every link-bearing template.
  assert.doesNotMatch(html, /href=/u);
});
