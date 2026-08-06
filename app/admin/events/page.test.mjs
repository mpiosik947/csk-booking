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

test("create uses the atomic RPC while edit, toggle, and public events remain separate", async () => {
  const adminSource = await readAdminPage();
  const publicSource = await readFile(publicPageUrl, "utf8");
  const createEvent = functionSource(
    adminSource,
    "async function createEvent()",
    "function toggleCreateLane("
  );
  const saveEditedEvent = functionSource(
    adminSource,
    "async function saveEditedEvent(",
    "async function toggleEvent("
  );
  const toggleEvent = functionSource(
    adminSource,
    "async function toggleEvent(",
    "function beginRegistrationAction("
  );

  assert.match(createEvent, /buildCreateEventPayload\(form\.value\)/);
  assert.match(createEvent, /\.rpc\("admin_create_event", payload\)/);
  assert.doesNotMatch(createEvent, /\.from\("events"\)\.insert\(/);
  assert.doesNotMatch(saveEditedEvent, /admin_update_event/);
  assert.match(saveEditedEvent, /\.from\("events"\)[\s\S]*\.update\(/);
  assert.doesNotMatch(toggleEvent, /admin_set_event_active/);
  assert.match(toggleEvent, /\.from\("events"\)[\s\S]*\.update\(\{ is_active:/);
  assert.doesNotMatch(publicSource, /event-management|normalizeAdminEvent/);
});

test("every admin event card renders its normalized lane assignment", async () => {
  const source = await readAdminPage();
  const summary = functionSource(
    source,
    "function EventLanesSummary(",
    "function FieldHelp("
  );

  assert.equal(
    (source.match(/<EventLanesSummary lanes=\{event\.lanes\} \/>/g) ?? [])
      .length,
    1
  );
  assert.match(summary, /lanes: AdminEvent\["lanes"\]/);
  assert.match(summary, /Zajmowane osie/);
  assert.match(summary, /lanes\.length === 0/);
  assert.match(summary, /Event globalny — nie blokuje osi/);
  assert.match(summary, /lanes\.map\(\(lane\) =>/);
  assert.match(summary, /\{lane\.name\}/);
  assert.match(summary, /!lane\.is_active/);
  assert.match(summary, /Nieaktywna/);
});

test("lane summary preserves helper order and is read-only for every admin role", async () => {
  const source = await readAdminPage();
  const summary = functionSource(
    source,
    "function EventLanesSummary(",
    "function FieldHelp("
  );
  assert.doesNotMatch(summary, /\.sort\(|canManageEvents|userRole/);
  assert.doesNotMatch(summary, /lane\.(?:type|display_order)/);
  assert.doesNotMatch(summary, />\s*\{lane\.id\}\s*</);
  assert.match(summary, /flex flex-wrap gap-2/);
  assert.match(summary, /inline-flex max-w-full flex-wrap/);
  assert.match(summary, /break-words/);
});

test("active lanes load only for management roles with a fail-closed stable contract", async () => {
  const source = await readAdminPage();
  const loadRole = functionSource(
    source,
    "async function loadRole()",
    "async function loadActiveLanes()"
  );
  const loadActiveLanes = functionSource(
    source,
    "async function loadActiveLanes()",
    "async function loadEvents()"
  );

  assert.match(source, /useState<AdminEventLane\[\]>\(\[\]\)/);
  assert.match(source, /const \[activeLanesLoading, setActiveLanesLoading\] = useState\(false\)/);
  assert.match(source, /const \[activeLanesLoaded, setActiveLanesLoaded\] = useState\(false\)/);
  assert.match(source, /const \[activeLanesError, setActiveLanesError\] = useState<string \| null>/);
  assert.match(source, /const activeLanesRequestRef = useRef\(0\)/);
  assert.match(source, /const componentMountedRef = useRef\(true\)/);
  assert.match(source, /return \(\) => \{[\s\S]*componentMountedRef\.current = false[\s\S]*activeLanesRequestRef\.current \+= 1/);
  assert.match(loadRole, /role === "admin" \|\| role === "pracownik"/);
  assert.match(loadRole, /void loadActiveLanes\(\)/);
  assert.doesNotMatch(loadRole, /instruktor[\s\S]*loadActiveLanes/);
  assert.match(loadActiveLanes, /\.from\("shooting_lanes"\)/);
  assert.match(loadActiveLanes, /\.select\("id,name,type,is_active,display_order"\)/);
  assert.doesNotMatch(loadActiveLanes, /\.select\(\s*["'`]\*["'`]\s*\)/);
  assert.match(loadActiveLanes, /\.eq\("is_active", true\)/);
  assert.match(loadActiveLanes, /\.order\("display_order", \{ ascending: true \}\)/);
  assert.match(loadActiveLanes, /\.order\("name", \{ ascending: true \}\)/);
  assert.match(loadActiveLanes, /\.order\("id", \{ ascending: true \}\)/);
  assert.match(loadActiveLanes, /const requestId = \+\+activeLanesRequestRef\.current/);
  assert.match(loadActiveLanes, /!componentMountedRef\.current[\s\S]*requestId !== activeLanesRequestRef\.current/);
  assert.match(loadActiveLanes, /normalizeActiveEventLanes\(data\)/);
  assert.match(loadActiveLanes, /if \(error \|\| normalizedLanes === null\)/);
  assert.doesNotMatch(loadActiveLanes, /setActiveLanes\(\[\]\)|error\.message|console\./);
});

test("create form exposes safe lane selection states and never displays lane UUIDs", async () => {
  const source = await readAdminPage();

  assert.match(source, /const \[createLaneIds, setCreateLaneIds\] = useState<string\[\]>\(\[\]\)/);
  assert.doesNotMatch(source, /editLaneIds|setEditLaneIds/);
  assert.match(source, /function toggleCreateLane\(laneId: string\)/);
  assert.match(source, /if \(createSubmittingRef\.current\) \{\s*return;\s*\}/);
  assert.match(source, /new Set\(current\)/);
  assert.match(source, /activeLanes\s*\.filter\(\(lane\) => selectedLaneIds\.has\(lane\.id\)\)/);
  assert.match(source, /Brak zaznaczonych osi oznacza event globalny/);
  assert.match(source, /Ładowanie osi…/);
  assert.match(source, /Brak aktywnych osi\./);
  assert.match(source, /Nie udało się wczytać listy osi\./);
  assert.match(source, /type="checkbox"/);
  assert.match(source, /checked=\{createLaneIds\.includes\(lane\.id\)\}/);
  assert.match(source, /disabled=\{createSubmitting\}/);
  assert.match(source, /\{lane\.name\}/);
  assert.doesNotMatch(source, />\s*\{lane\.id\}\s*</);
  assert.match(source, /flex flex-wrap gap-3/);
});

test("a successful lane reload removes hidden selections but an error preserves them", async () => {
  const source = await readAdminPage();
  const loadActiveLanes = functionSource(
    source,
    "async function loadActiveLanes()",
    "async function loadEvents()"
  );

  assert.match(loadActiveLanes, /setActiveLanes\(normalizedLanes\)/);
  assert.match(loadActiveLanes, /setCreateLaneIds\(\(current\) => \{/);
  assert.match(loadActiveLanes, /const activeLaneIds = new Set\(normalizedLanes\.map\(\(lane\) => lane\.id\)\)/);
  assert.match(loadActiveLanes, /current\.filter\(\(laneId\) => activeLaneIds\.has\(laneId\)\)/);
  assert.ok(
    loadActiveLanes.indexOf("if (error || normalizedLanes === null)") <
      loadActiveLanes.indexOf("setCreateLaneIds((current) =>")
  );
});

test("create validates and maps only safe RPC results before its success-only reset", async () => {
  const source = await readAdminPage();
  const createEvent = functionSource(
    source,
    "async function createEvent()",
    "function toggleCreateLane("
  );

  assert.match(source, /const createSubmittingRef = useRef\(false\)/);
  assert.match(createEvent, /createSubmittingRef\.current/);
  assert.match(createEvent, /validateEventForm\(\{/);
  assert.match(createEvent, /laneIds: createLaneIds/);
  assert.match(createEvent, /validateEventRpcResult\(data\)/);
  assert.match(createEvent, /getEventManagementMessage\(/);
  assert.match(
    createEvent,
    /new Map\(activeLanes\.map\(\(lane\) => \[lane\.id, lane\.name\]\)\)/
  );
  assert.match(createEvent, /result\.value\.code !== "created"/);
  assert.match(createEvent, /setCreateLaneIds\(\[\]\)/);
  assert.match(createEvent, /void loadEvents\(\)/);
  assert.match(createEvent, /finally \{[\s\S]*createSubmittingRef\.current = false[\s\S]*setCreateSubmitting\(false\)/);
  assert.doesNotMatch(createEvent, /error\.message|event_id|conflict_lane_id/);
  assert.ok(createEvent.indexOf('result.value.code !== "created"') < createEvent.indexOf("setTitle(\"\")"));
});

test("create button fails closed while lanes are unknown, loading, or unavailable", async () => {
  const source = await readAdminPage();

  assert.match(source, /disabled=\{[\s\S]*createSubmitting[\s\S]*activeLanesLoading[\s\S]*!activeLanesLoaded[\s\S]*activeLanesError !== null[\s\S]*\}/);
  assert.match(source, /\{createSubmitting \? "Dodawanie…" : "Dodaj szkolenie"\}/);
  assert.match(source, /activeLanesLoading \|\| !activeLanesLoaded \|\| activeLanesError/);
});

test("public events remain unchanged while lane selection does not alter existing cards", async () => {
  const adminSource = await readAdminPage();
  const publicSource = await readFile(publicPageUrl, "utf8");

  assert.doesNotMatch(publicSource, /EventLanesSummary|Zajmowane osie/);
  assert.doesNotMatch(publicSource, /createLaneIds|admin_create_event/);
  assert.match(adminSource, /async function createEvent\(\)/);
  assert.match(adminSource, /function startEditing\(event: AdminEvent\)/);
  assert.match(adminSource, /async function saveEditedEvent\(eventId: string\)/);
  assert.match(adminSource, /async function toggleEvent\(/);
});
