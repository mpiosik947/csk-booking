import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const pageUrl = new URL("./page.tsx", import.meta.url);

async function readPage() {
  return readFile(pageUrl, "utf8");
}

function functionSource(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(start, -1, `Missing start marker: ${startMarker}`);
  assert.notEqual(end, -1, `Missing end marker: ${endMarker}`);
  return source.slice(start, end);
}

test("my events uses the canonical status and payment presentation", async () => {
  const source = await readPage();

  assert.match(source, /getEventRegistrationStatusPresentation/);
  assert.match(source, /getEventRegistrationStatusBadgeClass/);
  assert.match(source, /getPaymentStatusLabel\(item\.payment_status\)/);
  assert.doesNotMatch(source, /function translateStatus/);
  assert.doesNotMatch(source, /function getStatusClass/);
});

test("cancellation CTA matches the Warsaw 72-hour backend boundary", async () => {
  const source = await readPage();
  const cancellation = functionSource(
    source,
    "async function cancelRegistration(",
    "const warsawNowKey"
  );

  assert.match(source, /isEventCancellationBeforeCutoff/);
  assert.match(source, /\.userCanCancel/);
  assert.doesNotMatch(source, /new Date\(`\$\{eventDate\}T/);
  assert.match(cancellation, /\/api\/cancel-event-registration/);
  assert.match(cancellation, /registration_status:[\s\S]*"cancelled"/);
});

test("my events keeps owner scope and refreshes the local cancellation state", async () => {
  const source = await readPage();

  assert.match(source, /\.rpc\("get_my_event_registrations_v1"/);
  assert.match(source, /p_scope: scope/);
  assert.match(source, /p_status: statusFilter \|\| null/);
  assert.match(source, /p_page: page/);
  assert.match(source, /p_page_size: EVENT_LIST_PAGE_SIZE/);
  assert.doesNotMatch(source, /\.from\("event_registrations"\)/);
  assert.match(source, /setItems\(\(currentItems\) =>/);
  assert.match(source, /data\.cancellation\?\.newStatus \?\? "cancelled"/);
  assert.doesNotMatch(source, /\.update\(|\.insert\(/);
  assert.match(source, /window\.history\.pushState/);
  assert.match(source, /window\.addEventListener\("popstate"/);
});

test("public, my, and admin screens share one status presentation source", async () => {
  const [mySource, publicSource, adminSource] = await Promise.all([
    readPage(),
    readFile(new URL("../events/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../admin/events/page.tsx", import.meta.url), "utf8"),
  ]);

  for (const source of [mySource, publicSource, adminSource]) {
    assert.match(source, /getEventRegistrationStatusPresentation/);
  }
});
