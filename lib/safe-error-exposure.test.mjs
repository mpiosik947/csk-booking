import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const CLIENT_FILES = [
  "../app/account/page.tsx",
  "../app/admin/check-in/page.tsx",
  "../app/admin/page.tsx",
  "../app/admin/reports/page.tsx",
  "../app/admin/reservations/page.tsx",
  "../app/admin/users/page.tsx",
  "../app/events/page.tsx",
  "../app/forgot-password/page.tsx",
  "../app/login/page.tsx",
  "../app/my-events/page.tsx",
  "../app/register/page.tsx",
  "../app/reset-password/page.tsx",
];

async function read(relativePath) {
  return readFile(new URL(relativePath, import.meta.url), "utf8");
}

test("remediated UI components do not render raw provider error properties", async () => {
  const sources = await Promise.all(CLIENT_FILES.map(read));

  for (const source of sources) {
    assert.doesNotMatch(source, /\$\{[^}]*\.message\}/u);
    assert.doesNotMatch(source, /\b(?:body|data|response)\??\.(?:error|details|hint)\b/u);
    assert.doesNotMatch(
      source,
      /console\.(?:error|warn|log)\([^\n]*,\s*(?:error|[A-Za-z]+Error|data|payload|body)\b/u
    );
  }
});

test("confirmation API maps RPC codes instead of exposing RPC messages", async () => {
  const source = await read(
    "../app/api/confirm-event-reserve-promotion/route.ts"
  );

  assert.match(source, /getConfirmEventReserveMessage\(rpcData\.code\)/u);
  assert.doesNotMatch(source, /rpcData\.message/u);
});

test("event promotion client helper never forwards an API error body", async () => {
  const source = await read("./event-registration-actions.ts");

  assert.doesNotMatch(source, /data\??\.error/u);
  assert.match(
    source,
    /error: "Nie udało się wysłać powiadomień do listy rezerwowej\."/u
  );
});

test("known controlled action errors remain available to the UI", async () => {
  const source = await read("./reservation-actions.ts");

  assert.match(source, /Nie udało się anulować rezerwacji\./u);
  assert.match(source, /Nie udało się zapisać zmiany\. Spróbuj ponownie\./u);
});

test("server promotion diagnostics omit entity ids and bound technical values", async () => {
  const source = await read("./server/event-reserve-promotion.ts");
  const logger = source.slice(
    source.indexOf("function getSafeErrorDetails"),
    source.indexOf("function isPreparedPromotion")
  );

  assert.match(logger, /\^\[a-z0-9_\.:-\]\{1,64\}\$/iu);
  assert.doesNotMatch(logger, /eventId|registrationId/u);
  assert.doesNotMatch(logger, /\.message|\.details|\.hint/u);
});
