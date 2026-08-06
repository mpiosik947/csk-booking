import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const adminPageUrl = new URL("./page.tsx", import.meta.url);
const publicPageUrl = new URL("../../events/page.tsx", import.meta.url);

async function readAdminPage() {
  return readFile(adminPageUrl, "utf8");
}

function functionSource(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(start, -1, `Missing start marker: ${startMarker}`);
  assert.notEqual(end, -1, `Missing end marker: ${endMarker}`);
  return source.slice(start, end);
}

test("admin events uses the normalized relational event contract", async () => {
  const source = await readAdminPage();
  const loadEvents = functionSource(
    source,
    "async function loadEvents()",
    "async function loadRegistrations("
  );

  assert.match(source, /type AdminEvent[\s\S]*from "\.\.\/\.\.\/\.\.\/lib\/admin\/events\/event-management"/);
  assert.match(source, /useState<AdminEvent\[\]>\(\[\]\)/);
  assert.match(loadEvents, /\.from\("events"\)/);
  assert.doesNotMatch(loadEvents, /\.select\(\s*["'`]\*["'`]\s*\)/);
  for (const field of [
    "id",
    "title",
    "description",
    "event_date",
    "start_time",
    "end_time",
    "location",
    "price",
    "max_participants",
    "is_active",
    "created_at",
    "event_lanes",
    "lane_id",
    "shooting_lanes",
    "display_order",
  ]) {
    assert.match(loadEvents, new RegExp(`\\b${field}\\b`));
  }
  assert.doesNotMatch(loadEvents, /event_registrations|customer_|user_id/);
  assert.match(loadEvents, /normalizeAdminEvent\(record\)/);
});

test("event loading fails closed without replacing a valid list", async () => {
  const source = await readAdminPage();
  const loadEvents = functionSource(
    source,
    "async function loadEvents()",
    "async function loadRegistrations("
  );
  const safeMessage = "Nie udało się poprawnie wczytać listy szkoleń.";

  assert.equal((loadEvents.match(/setEvents\(/g) ?? []).length, 1);
  assert.equal((loadEvents.match(/setMessage\(EVENTS_LOAD_ERROR_MESSAGE\)/g) ?? []).length, 3);
  assert.match(loadEvents, /if \(error\)[\s\S]*setMessage\(EVENTS_LOAD_ERROR_MESSAGE\);[\s\S]*return;/);
  assert.match(loadEvents, /if \(!Array\.isArray\(data\)\)[\s\S]*return;/);
  assert.match(loadEvents, /if \(!normalized\.ok\)[\s\S]*setMessage\(EVENTS_LOAD_ERROR_MESSAGE\);[\s\S]*return;/);
  assert.ok(loadEvents.indexOf("normalizeAdminEvent(record)") < loadEvents.indexOf("setEvents(normalizedEvents)"));
  assert.equal(source.includes(`const EVENTS_LOAD_ERROR_MESSAGE =\n  "${safeMessage}";`), true);
  assert.doesNotMatch(loadEvents, /error\.message|console\.(?:log|error|warn)/);
});

test("event loading ignores stale responses and clears only its own old error", async () => {
  const source = await readAdminPage();
  const loadEvents = functionSource(
    source,
    "async function loadEvents()",
    "async function loadRegistrations("
  );

  assert.match(source, /const eventsLoadRequestRef = useRef\(0\)/);
  assert.match(loadEvents, /const requestId = \+\+eventsLoadRequestRef\.current/);
  assert.match(loadEvents, /if \(requestId !== eventsLoadRequestRef\.current\) \{\s*return;\s*\}/);
  assert.ok(loadEvents.indexOf("requestId !== eventsLoadRequestRef.current") < loadEvents.indexOf("setLoading(false)"));
  assert.match(
    loadEvents,
    /setMessage\(\(current\) =>\s*current === EVENTS_LOAD_ERROR_MESSAGE \? "" : current\s*\)/
  );
  assert.doesNotMatch(loadEvents, /setMessage\(""\)/);
});

test("startEditing safely maps nullable values and PostgreSQL times", async () => {
  const source = await readAdminPage();
  const startEditing = functionSource(
    source,
    "function startEditing(",
    "function cancelEditing("
  );

  assert.match(startEditing, /event: AdminEvent/);
  assert.match(startEditing, /setEditDescription\(event\.description \?\? ""\)/);
  assert.match(startEditing, /setEditLocation\(event\.location \?\? ""\)/);
  assert.match(startEditing, /setEditStartTime\(event\.start_time\.slice\(0, 5\)\)/);
  assert.match(startEditing, /setEditEndTime\(event\.end_time\.slice\(0, 5\)\)/);
  assert.equal("11:00:00".slice(0, 5), "11:00");
  assert.equal("12:30:00".slice(0, 5), "12:30");
});

test("this stage keeps existing mutations and the public events page separate", async () => {
  const adminSource = await readAdminPage();
  const publicSource = await readFile(publicPageUrl, "utf8");

  assert.doesNotMatch(
    adminSource,
    /admin_create_event|admin_update_event|admin_set_event_active/
  );
  assert.match(adminSource, /\.from\("events"\)\.insert\(/);
  assert.match(adminSource, /\.from\("events"\)[\s\S]*\.update\(/);
  assert.doesNotMatch(publicSource, /event-management|normalizeAdminEvent/);
});
