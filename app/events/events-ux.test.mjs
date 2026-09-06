import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const publicPageUrl = new URL("./page.tsx", import.meta.url);
const myEventsPageUrl = new URL("../my-events/page.tsx", import.meta.url);
const adminPageUrl = new URL("../admin/events/page.tsx", import.meta.url);
const contractsUrl = new URL("../../lib/event-read-contracts.ts", import.meta.url);

test("public events provides filter-aware empty, retry, and mobile pagination states", async () => {
  const source = await readFile(publicPageUrl, "utf8");

  assert.match(source, /Brak szkoleń pasujących do wyszukiwania/);
  assert.match(source, /setReloadKey\(\(current\) => current \+ 1\)/);
  assert.match(source, /grid grid-cols-2 gap-3 sm:flex/);
  assert.match(source, /min-h-12 w-full/);
  assert.match(source, /get_public_event_list_v2/);
  assert.doesNotMatch(source, /\.from\("event_registrations"\)/);
});

test("my events exposes all backend scopes and keeps cancellation eligibility canonical", async () => {
  const [source, contracts] = await Promise.all([
    readFile(myEventsPageUrl, "utf8"),
    readFile(contractsUrl, "utf8"),
  ]);

  assert.match(contracts, /MyEventScope = "upcoming" \| "history" \| "all"/);
  assert.match(source, /<option value="all">Wszystkie<\/option>/);
  assert.match(source, /isEventCancellationBeforeCutoff/);
  assert.match(source, /setReloadKey\(\(current\) => current \+ 1\)/);
  assert.match(source, /Brak historycznych szkoleń o wybranym statusie/);
  assert.match(source, /grid grid-cols-2 gap-3 sm:flex/);
});

test("admin participant management becomes stacked cards below desktop without changing actions", async () => {
  const source = await readFile(adminPageUrl, "utf8");

  assert.equal((source.match(/block w-full text-sm lg:table/g) ?? []).length, 3);
  assert.equal((source.match(/hidden lg:table-header-group/g) ?? []).length, 3);
  assert.ok((source.match(/lg:hidden">Imię i nazwisko/g) ?? []).length >= 3);
  assert.match(source, /participantsLoadError/);
  assert.match(source, /Nie udało się wczytać uczestników/);
  assert.match(source, /approveRegistration/);
  assert.match(source, /markRegistrationPaid/);
  assert.match(source, /cancelRegistration/);
  assert.match(source, /EVENT_PARTICIPANT_PAGE_SIZE/);
});
