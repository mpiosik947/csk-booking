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

test("event list uses the PostgREST column hint for the self-referencing parent lane", async () => {
  const source = await readAdminPage();
  const loadEvents = functionSource(
    source,
    "async function loadEvents()",
    "async function loadRegistrations("
  );

  assert.match(
    loadEvents,
    /parent_lane:shooting_lanes!parent_lane_id\s*\(\s*id,\s*name,\s*type,\s*is_active,\s*display_order,\s*resource_kind,\s*parent_lane_id\s*\)/
  );
  assert.doesNotMatch(
    loadEvents,
    /parent_lane:shooting_lanes!shooting_lanes_parent_lane_id_fkey/
  );
  assert.match(loadEvents, /event_lanes\s*\([\s\S]*shooting_lanes\s*\(/);
  assert.match(loadEvents, /if \(error\)[\s\S]*EVENTS_LOAD_ERROR_MESSAGE/);
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
  assert.match(
    source,
    new RegExp(
      `const EVENTS_LOAD_ERROR_MESSAGE =\\r?\\n  "${safeMessage}";`
    )
  );
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
  assert.match(loadEvents, /!componentMountedRef\.current[\s\S]*requestId !== eventsLoadRequestRef\.current/);
  assert.ok(loadEvents.indexOf("requestId !== eventsLoadRequestRef.current") < loadEvents.indexOf("setLoading(false)"));
  assert.match(
    loadEvents,
    /setMessage\(\(current\) =>\s*current === EVENTS_LOAD_ERROR_MESSAGE \? "" : current\s*\)/
  );
  assert.doesNotMatch(loadEvents, /setMessage\(""\)/);
});

test("event list controls are local, accessible, and keep event loading unchanged", async () => {
  const source = await readAdminPage();
  const loadEvents = functionSource(
    source,
    "async function loadEvents()",
    "async function loadRegistrations("
  );

  assert.match(source, /useState<EventSortOrder>\("nearest"\)/);
  assert.match(source, /Kolejność szkoleń/);
  assert.match(source, /<option value="nearest">Najbliższe terminy<\/option>/);
  assert.match(source, /<option value="latest">Najpóźniejsze terminy<\/option>/);
  assert.match(source, /htmlFor="event-sort-order"/);
  assert.match(source, /id="event-sort-order"/);
  assert.match(source, /useState<EventStatusFilter>\("all"\)/);
  assert.match(source, /Status/);
  assert.match(source, /<option value="all">Wszystkie<\/option>/);
  assert.match(source, /<option value="active">Aktywne<\/option>/);
  assert.match(source, /<option value="hidden">Ukryte<\/option>/);
  assert.match(source, /htmlFor="event-status-filter"/);
  assert.match(source, /id="event-status-filter"/);
  assert.match(source, /const visibleEvents = sortAdminEvents\([\s\S]*filterAdminEvents\(events, eventStatusFilter\)/);
  assert.match(source, /visibleEvents\.map\(\(event\) =>/);
  assert.doesNotMatch(loadEvents, /eventSortOrder|eventStatusFilter|sortAdminEvents|filterAdminEvents/);
  assert.doesNotMatch(source, /onChange=\{[^}]*loadEvents/);
});

test("event status filter has safe empty states and preserves V2 management RPCs", async () => {
  const source = await readAdminPage();

  assert.match(source, /Brak aktywnych szkoleń\./);
  assert.match(source, /Brak ukrytych szkoleń\./);
  assert.match(source, /Brak szkoleń\./);
  assert.match(source, /\.rpc\(\s*"admin_create_event_v2",\s*payload\s*\)/);
  assert.match(source, /\.rpc\(\s*"admin_update_event_v2",\s*payload\.value\s*\)/);
  assert.match(source, /\.rpc\(\s*"admin_set_event_active_v2",\s*payload\.value\s*\)/);
});

test("event registration payment uses only the controlled minimal RPC", async () => {
  const source = await readAdminPage();
  const paymentAction = functionSource(
    source,
    "async function markRegistrationPaid(",
    "function getMessageClass("
  );

  assert.match(
    paymentAction,
    /\.rpc\(\s*"mark_event_registration_paid",\s*\{ p_registration_id: registrationId \}\s*\)/
  );
  assert.doesNotMatch(paymentAction, /\.from\("event_registrations"\)/);
  assert.doesNotMatch(paymentAction, /\.update\(|\.insert\(|\.delete\(|\.upsert\(/);
  assert.doesNotMatch(
    paymentAction,
    /p_(?:user_id|event_id|payment_status|promotion_token|created_at)\s*:/
  );
  assert.doesNotMatch(paymentAction, /error\.message/);
  assert.match(paymentAction, /beginRegistrationAction\(registrationId, "payment"\)/);
  assert.match(paymentAction, /isMarkRegistrationPaidResult\(data\)/);
  assert.match(paymentAction, /data\.new_payment_status !== "paid_on_site"/);
  assert.match(paymentAction, /data\.event_id !== selectedEventId/);
  assert.match(paymentAction, /finally[\s\S]*endRegistrationAction\(registrationId\)/);
  assert.equal((paymentAction.match(/mark_event_registration_paid/g) ?? []).length, 1);
});

test("event card actions use the dashboard palette without a blue edit accent", async () => {
  const source = await readAdminPage();
  const actions = functionSource(
    source,
    '<div className="flex w-full flex-col gap-3 lg:w-56 lg:shrink-0">',
    "{selectedEventId === event.id && ("
  );

  assert.doesNotMatch(actions, /border-blue-800|text-blue-300|hover:bg-blue-950/);
  assert.match(actions, /Edytuj szkolenie/);
  assert.match(actions, /Pokaż zapisanych/);
  assert.match(actions, /bg-\[#536143\][\s\S]*hover:bg-\[#78865f\]/);
  assert.match(source, /Zobacz stronę szkoleń/);
  assert.match(actions, /border-\[#30372c\][\s\S]*focus-visible:ring-\[#d7c895\]/);
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

test("create, edit, and toggle use only hierarchy-aware V2 RPCs while public events remain separate", async () => {
  const adminSource = await readAdminPage();
  const publicSource = await readFile(publicPageUrl, "utf8");
  const openCreateConfirmation = functionSource(
    adminSource,
    "function openCreateConfirmation()",
    "function closeCreateConfirmation()"
  );
  const confirmCreateEvent = functionSource(
    adminSource,
    "async function confirmCreateEvent()",
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

  assert.match(openCreateConfirmation, /buildCreateEventPayload\(form\.value\)/);
  assert.doesNotMatch(openCreateConfirmation, /\.rpc\("admin_create_event_v2", payload\)/);
  assert.match(confirmCreateEvent, /\.rpc\(\s*"admin_create_event_v2",\s*payload\s*\)/);
  assert.doesNotMatch(confirmCreateEvent, /\.from\("events"\)\.insert\(/);
  assert.doesNotMatch(confirmCreateEvent, /error\.message/);
  assert.match(saveEditedEvent, /buildUpdateEventPayload\(eventId, form\.value\)/);
  assert.match(saveEditedEvent, /\.rpc\(\s*"admin_update_event_v2",\s*payload\.value\s*\)/);
  assert.doesNotMatch(saveEditedEvent, /\.from\("events"\)[\s\S]*\.update\(/);
  assert.doesNotMatch(saveEditedEvent, /error\.message/);
  assert.match(toggleEvent, /buildSetEventActivePayload\(eventId, targetStatus\)/);
  assert.match(toggleEvent, /\.rpc\(\s*"admin_set_event_active_v2",\s*payload\.value\s*\)/);
  assert.doesNotMatch(toggleEvent, /\.from\("events"\)[\s\S]*\.update\(/);
  assert.doesNotMatch(toggleEvent, /error\.message/);
  assert.doesNotMatch(adminSource, /["']admin_create_event["']/);
  assert.doesNotMatch(adminSource, /["']admin_update_event["']/);
  assert.doesNotMatch(adminSource, /["']admin_set_event_active["']/);
  assert.equal((adminSource.match(/admin_create_event_v2/g) ?? []).length, 1);
  assert.equal((adminSource.match(/admin_update_event_v2/g) ?? []).length, 1);
  assert.equal((adminSource.match(/admin_set_event_active_v2/g) ?? []).length, 1);
  assert.match(
    adminSource,
    /const canManageEvents = userRole === "admin" \|\| userRole === "pracownik"/
  );
  assert.doesNotMatch(publicSource, /event-management|normalizeAdminEvent/);
});

test("event activation uses an isolated lock, validates the RPC result, and preserves other event controls", async () => {
  const source = await readAdminPage();
  const toggleEvent = functionSource(
    source,
    "async function toggleEvent(",
    "function beginRegistrationAction("
  );

  assert.match(source, /const \[eventToggleActions, setEventToggleActions\] = useState<[\s\S]*Record<string, boolean>[\s\S]*>\(\{\}\)/);
  assert.match(source, /const eventToggleLocksRef = useRef\(new Set<string>\(\)\)/);
  assert.match(toggleEvent, /eventToggleLocksRef\.current\.has\(eventId\)/);
  assert.match(toggleEvent, /const targetStatus = !currentStatus/);
  assert.match(toggleEvent, /buildSetEventActivePayload\(eventId, targetStatus\)/);
  assert.match(toggleEvent, /eventToggleLocksRef\.current\.add\(eventId\)/);
  assert.match(toggleEvent, /setEventToggleActions\(\(current\) => \(\{[\s\S]*\[eventId\]: targetStatus/);
  assert.match(toggleEvent, /validateEventRpcResult\(data\)/);
  assert.match(toggleEvent, /result\.ok && result\.value\.event_id !== eventId/);
  assert.match(toggleEvent, /result\.value\.code === "activated" && !targetStatus/);
  assert.match(toggleEvent, /result\.value\.code === "deactivated" && targetStatus/);
  assert.match(toggleEvent, /getEventManagementMessage\(/);
  assert.match(toggleEvent, /getEditableEventLanes\(activeLanes, event\?\.lanes \?\? \[\]\)/);
  assert.match(toggleEvent, /result\.value\.code === "activated"[\s\S]*result\.value\.code === "deactivated"[\s\S]*result\.value\.code === "no_change"[\s\S]*void loadEvents\(\)/);
  assert.doesNotMatch(toggleEvent, /setEvents\(/);
  assert.doesNotMatch(toggleEvent, /error\.message|conflict_lane_id/);
  assert.match(toggleEvent, /finally \{[\s\S]*eventToggleLocksRef\.current\.delete\(eventId\)[\s\S]*delete next\[eventId\]/);
  assert.match(toggleEvent, /if \(!componentMountedRef\.current\) \{\s*return;\s*\}/);
  assert.match(toggleEvent, /if \(componentMountedRef\.current\) \{[\s\S]*setEventToggleActions/);
  assert.match(toggleEvent, /if \(editingEventId === eventId\) \{\s*return;\s*\}/);
  assert.match(source, /const isTogglePending = toggleTargetStatus !== undefined/);
  assert.match(source, /disabled=\{isTogglePending \|\| editingEventId === event\.id\}/);
  assert.match(source, /"Aktywowanie…"/);
  assert.match(source, /"Ukrywanie…"/);
  assert.match(source, /disabled=\{editSubmitting \|\| isTogglePending\}/);
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
  assert.match(summary, /HierarchyResourceLabel/);
  assert.match(summary, /displayName: lane\.displayName/);
  assert.match(summary, /isActive: lane\.is_active/);
  assert.match(summary, /showStatus/);
  assert.match(summary, /tree/);
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
  assert.match(summary, /grid gap-2 sm:grid-cols-2 xl:grid-cols-3/);
  assert.match(summary, /min-w-0 rounded-xl/);
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
  assert.match(
    loadActiveLanes,
    /id,name,type,is_active,display_order,resource_kind,parent_lane_id/
  );
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
  assert.match(source, /displayName: lane\.displayName/);
  assert.match(source, /HierarchyResourceLabel/);
  assert.doesNotMatch(source, />\s*\{lane\.id\}\s*</);
  assert.match(source, /grid gap-2 sm:grid-cols-2 xl:grid-cols-3/);
});

test("event management form presents sectioned lane summaries without exposing lane identifiers", async () => {
  const source = await readAdminPage();

  assert.match(source, /function EventFormSection\(/);
  assert.match(source, /function LaneSelectionSummary\(/);
  assert.match(source, /Dodaj szkolenie \/ event/);
  assert.match(source, /Tryb edycji/);
  assert.match(source, /Event globalny/);
  assert.match(source, /const laneCountLabel =/);
  assert.match(source, /Zajmuje \$\{lanes\.length\} osie/);
  assert.match(source, /Zajmuje \$\{lanes\.length\} osi/);
  assert.match(source, /<LaneSelectionSummary lanes=\{selectedCreateLanes\} \/>/);
  assert.match(source, /<LaneSelectionSummary lanes=\{selectedEditLanes\} \/>/);
  assert.match(source, /\{event\.is_active \? "Aktywny" : "Ukryty"\}/);
  assert.doesNotMatch(source, /\{lane\.id\}<\/span>/);
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
  assert.match(loadActiveLanes, /setEditLaneIds\(\(current\) => \{/);
  assert.match(loadActiveLanes, /\.\.\.editInitialInactiveLaneIdsRef\.current/);
  assert.match(loadActiveLanes, /allowedLaneIds\.has\(laneId\)/);
  assert.ok(
    loadActiveLanes.indexOf("if (error || normalizedLanes === null)") <
      loadActiveLanes.indexOf("setCreateLaneIds((current) =>")
  );
});

test("edit form preserves assigned inactive lanes and saves only through admin_update_event", async () => {
  const source = await readAdminPage();
  const startEditing = functionSource(
    source,
    "function startEditing(",
    "function resetEditingState("
  );
  const resetEditingState = functionSource(
    source,
    "function resetEditingState()",
    "function cancelEditing("
  );
  const cancelEditing = functionSource(
    source,
    "function cancelEditing()",
    "async function saveEditedEvent("
  );
  const saveEditedEvent = functionSource(
    source,
    "async function saveEditedEvent(",
    "function toggleEditLane("
  );
  const toggleEditLane = functionSource(
    source,
    "function toggleEditLane(",
    "function toggleEvent("
  );

  assert.match(source, /const \[editLaneIds, setEditLaneIds\] = useState<string\[\]>\(\[\]\)/);
  assert.match(source, /const \[editInitialInactiveLaneIds, setEditInitialInactiveLaneIds\] = useState<[\s\S]*string\[\][\s\S]*>\(\[\]\)/);
  assert.match(source, /const \[editSubmitting, setEditSubmitting\] = useState\(false\)/);
  assert.match(source, /const editSubmittingRef = useRef\(false\)/);
  assert.match(source, /const editInitialInactiveLaneIdsRef = useRef<string\[\]>\(\[\]\)/);
  assert.match(startEditing, /setEditLaneIds\(\[\.\.\.event\.laneIds\]\)/);
  assert.match(startEditing, /if \(editSubmittingRef\.current\) \{\s*return;\s*\}/);
  assert.match(startEditing, /event\.lanes[\s\S]*\.filter\(\(lane\) => !lane\.is_active\)[\s\S]*\.map\(\(lane\) => lane\.id\)/);
  assert.match(startEditing, /setEditMessage\(null\)/);
  assert.match(startEditing, /editInitialInactiveLaneIdsRef\.current = initialInactiveLaneIds/);
  assert.match(resetEditingState, /setEditLaneIds\(\[\]\)/);
  assert.match(resetEditingState, /editInitialInactiveLaneIdsRef\.current = \[\]/);
  assert.match(resetEditingState, /setEditInitialInactiveLaneIds\(\[\]\)/);
  assert.match(cancelEditing, /editSubmittingRef\.current/);
  assert.match(cancelEditing, /resetEditingState\(\)/);
  assert.match(cancelEditing, /setEditMessage\(null\)/);
  assert.match(source, /const editableLanes = getEditableEventLanes\(activeLanes, event\.lanes\)/);
  assert.match(source, /const isSelected = editLaneIds\.includes\(lane\.id\)/);
  assert.match(source, /checked=\{isSelected\}/);
  assert.match(source, /showStatus/);
  assert.match(source, /disabled=\{isDisabled\}/);
  assert.match(source, /disabled=\{editSubmitting\}/);
  assert.match(toggleEditLane, /if \(editSubmittingRef\.current\) \{\s*return;\s*\}/);
  assert.match(toggleEditLane, /if \(!isActive\) \{\s*return current;\s*\}/);
  assert.match(toggleEditLane, /editableLanes[\s\S]*\.filter\(\(lane\) => selectedLaneIds\.has\(lane\.id\)\)/);
  assert.match(saveEditedEvent, /activeLanesLoading \|\| !activeLanesLoaded \|\| activeLanesError/);
  assert.match(saveEditedEvent, /\.\.\.editInitialInactiveLaneIds/);
  assert.match(saveEditedEvent, /validateEventForm\(\{/);
  assert.match(saveEditedEvent, /laneIds: editLaneIds/);
  assert.match(saveEditedEvent, /buildUpdateEventPayload\(eventId, form\.value\)/);
  assert.match(saveEditedEvent, /validateEventRpcResult\(data\)/);
  assert.match(saveEditedEvent, /result\.ok && result\.value\.event_id !== eventId/);
  assert.match(saveEditedEvent, /getEventManagementMessage\(/);
  assert.match(saveEditedEvent, /\.rpc\(\s*"admin_update_event_v2",\s*payload\.value\s*\)/);
  assert.doesNotMatch(saveEditedEvent, /\.from\("events"\)[\s\S]*\.update\(/);
  assert.match(saveEditedEvent, /result\.value\.code === "updated"[\s\S]*void loadEvents\(\)[\s\S]*resetEditingState\(\)/);
  assert.match(saveEditedEvent, /result\.value\.code === "no_change"[\s\S]*resetEditingState\(\)/);
  assert.match(saveEditedEvent, /finally \{[\s\S]*editSubmittingRef\.current = false[\s\S]*setEditSubmitting\(false\)/);
  assert.match(source, /onClick=\{\(\) => startEditing\(event\)\}[\s\S]*disabled=\{editSubmitting \|\| isTogglePending\}/);
});

test("create confirmation validates once and executes only the approved snapshot", async () => {
  const source = await readAdminPage();
  const openCreateConfirmation = functionSource(
    source,
    "function openCreateConfirmation()",
    "function closeCreateConfirmation()"
  );
  const confirmCreateEvent = functionSource(
    source,
    "async function confirmCreateEvent()",
    "function toggleCreateLane("
  );

  assert.match(source, /const createSubmittingRef = useRef\(false\)/);
  assert.match(source, /const \[createConfirmation, setCreateConfirmation\] =/);
  assert.match(openCreateConfirmation, /validateEventForm\(\{/);
  assert.match(openCreateConfirmation, /laneIds: createLaneIds/);
  assert.match(openCreateConfirmation, /setCreateConfirmation\(\{ payload, lanes: selectedLanes \}\)/);
  assert.doesNotMatch(confirmCreateEvent, /validateEventForm\(/);
  assert.doesNotMatch(confirmCreateEvent, /buildCreateEventPayload\(/);
  assert.match(confirmCreateEvent, /const \{ payload, lanes \} = createConfirmation/);
  assert.match(confirmCreateEvent, /createSubmittingRef\.current/);
  assert.match(confirmCreateEvent, /validateEventRpcResult\(data\)/);
  assert.match(confirmCreateEvent, /getEventManagementMessage\(/);
  assert.match(
    confirmCreateEvent,
    /lanes\.map\(\(lane\) => \[lane\.id, lane\.displayName\]\)/
  );
  assert.match(confirmCreateEvent, /result\.value\.code !== "created"/);
  assert.match(confirmCreateEvent, /setCreateLaneIds\(\[\]\)/);
  assert.match(confirmCreateEvent, /setCreateConfirmation\(null\)/);
  assert.match(confirmCreateEvent, /void loadEvents\(\)/);
  assert.match(confirmCreateEvent, /finally \{[\s\S]*createSubmittingRef\.current = false[\s\S]*setCreateSubmitting\(false\)/);
  assert.doesNotMatch(confirmCreateEvent, /error\.message|event_id|conflict_lane_id/);
  assert.ok(confirmCreateEvent.indexOf('result.value.code !== "created"') < confirmCreateEvent.indexOf("setTitle(\"\")"));
});

test("create confirmation modal is accessible, preserves form state, and blocks unsafe closing during submission", async () => {
  const source = await readAdminPage();

  assert.match(source, /role="dialog"/);
  assert.match(source, /aria-modal="true"/);
  assert.match(source, /aria-labelledby="create-event-confirmation-title"/);
  assert.match(source, /Potwierdź dodanie szkolenia/);
  assert.match(source, /Sprawdź dane przed utworzeniem wydarzenia/);
  assert.match(source, /formatConfirmationDate\(/);
  assert.match(source, /formatConfirmationPrice\(/);
  assert.match(source, /Nie podano/);
  assert.match(source, /<LaneSelectionSummary lanes=\{createConfirmation\.lanes\} \/>/);
  assert.match(source, /Wróć do edycji/);
  assert.match(source, /Potwierdź i dodaj/);
  assert.match(source, /if \(event\.key === "Escape" && !createSubmittingRef\.current\)/);
  assert.match(source, /if \(event\.target === event\.currentTarget\) \{[\s\S]*closeCreateConfirmation\(\)/);
  assert.match(source, /disabled=\{createSubmitting\}/);
  assert.doesNotMatch(source, /p_lane_ids\}/);
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
  assert.match(adminSource, /function openCreateConfirmation\(\)/);
  assert.match(adminSource, /async function confirmCreateEvent\(\)/);
  assert.match(adminSource, /function startEditing\(event: AdminEvent\)/);
  assert.match(adminSource, /async function saveEditedEvent\(eventId: string\)/);
  assert.match(adminSource, /async function toggleEvent\(/);
});

test("event hierarchy presentation keeps dormant resources out and prepares active positions", async () => {
  const source = await readAdminPage();
  const loadActiveLanes = functionSource(
    source,
    "async function loadActiveLanes()",
    "async function loadEvents()"
  );
  const loadEvents = functionSource(
    source,
    "async function loadEvents()",
    "async function loadRegistrations("
  );

  assert.match(source, /normalizeActiveEventLanes/);
  assert.match(loadActiveLanes, /resource_kind,parent_lane_id/);
  assert.match(loadActiveLanes, /\.eq\("is_active", true\)/);
  assert.match(loadEvents, /parent_lane:shooting_lanes!parent_lane_id/);
  assert.doesNotMatch(loadEvents, /shooting_lanes_parent_lane_id_fkey/);
  assert.match(source, /lane\.displayName/);
  assert.match(source, /HierarchyResourceLabel/);
  assert.match(source, /isPosition: lane\.isPosition/);
  assert.doesNotMatch(source, /Oś 100 m — Stanowisko 1/);
  assert.equal((source.match(/admin_create_event_v2/g) ?? []).length, 1);
  assert.equal((source.match(/admin_update_event_v2/g) ?? []).length, 1);
  assert.equal((source.match(/admin_set_event_active_v2/g) ?? []).length, 1);
});
