import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  buildCreateEventPayload,
  buildSetEventActivePayload,
  buildUpdateEventPayload,
  getEditableEventLanes,
  getEventManagementMessage,
  normalizeActiveEventLanes,
  normalizeAdminEvent,
  sortAdminEvents,
  validateEventForm,
  validateEventRpcResult,
} from "./event-management.ts";

const EVENT_ID = "11111111-1111-4111-8111-111111111111";
const LANE_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const LANE_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const LANE_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

function eventRow(overrides = {}) {
  return {
    id: EVENT_ID,
    title: "Szkolenie testowe",
    description: "Opis",
    event_date: "2026-09-10",
    start_time: "10:00:00",
    end_time: "12:00:00",
    location: "Strzelnica",
    price: 150,
    max_participants: 10,
    is_active: true,
    created_at: "2026-08-06T12:00:00Z",
    event_lanes: [],
    ...overrides,
  };
}

function lane(id, name, displayOrder, overrides = {}) {
  return {
    lane_id: id,
    shooting_lanes: {
      id,
      name,
      type: "shooting",
      is_active: true,
      display_order: displayOrder,
      ...overrides,
    },
  };
}

function formInput(overrides = {}) {
  return {
    title: "  Szkolenie  ",
    description: "  Opis  ",
    eventDate: "2026-09-10",
    startTime: "10:00",
    endTime: "12:00",
    location: "  Strzelnica  ",
    price: "150.50",
    maxParticipants: "10",
    laneIds: [],
    ...overrides,
  };
}

function validatedForm(overrides = {}) {
  const result = validateEventForm(formInput(overrides));
  assert.equal(result.ok, true);
  return result.value;
}

function rpcResult(code, overrides = {}) {
  return {
    ok: true,
    changed: true,
    code,
    event_id: EVENT_ID,
    ...overrides,
  };
}

test("1. normalizes a global event", () => {
  const result = normalizeAdminEvent(eventRow());
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.laneIds, []);
  assert.deepEqual(result.value.lanes, []);
});

test("2. normalizes one lane", () => {
  const result = normalizeAdminEvent(eventRow({ event_lanes: [lane(LANE_A, "Oś A", 10)] }));
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.laneIds, [LANE_A]);
  assert.equal(result.value.lanes[0].name, "Oś A");
});

test("3. normalizes multiple lanes", () => {
  const result = normalizeAdminEvent(eventRow({
    event_lanes: [lane(LANE_A, "Oś A", 10), lane(LANE_B, "Oś B", 20)],
  }));
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.laneIds, [LANE_A, LANE_B]);
});

test("4. sorts lanes by display order, name and id", () => {
  const result = normalizeAdminEvent(eventRow({
    event_lanes: [
      lane(LANE_C, "Zulu", 20),
      lane(LANE_B, "Alfa", 20),
      lane(LANE_A, "Alfa", 20),
    ],
  }));
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.laneIds, [LANE_A, LANE_B, LANE_C]);
});

test("5. removes duplicate lane IDs", () => {
  const result = normalizeAdminEvent(eventRow({
    event_lanes: [lane(LANE_A, "Oś A", 10), lane(LANE_A, "Oś A", 10)],
  }));
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.laneIds, [LANE_A]);
});

test("6. preserves null description and location", () => {
  const result = normalizeAdminEvent(eventRow({ description: null, location: null }));
  assert.equal(result.ok, true);
  assert.equal(result.value.description, null);
  assert.equal(result.value.location, null);
});

test("7. safely skips a damaged shooting lane relation", () => {
  const result = normalizeAdminEvent(eventRow({
    event_lanes: [lane(LANE_A, "Oś A", 10), { lane_id: LANE_B, shooting_lanes: null }],
  }));
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.laneIds, [LANE_A]);
});

test("8. rejects an invalid required event record", () => {
  assert.deepEqual(normalizeAdminEvent(eventRow({ title: "" })), {
    ok: false,
    code: "invalid_event",
    message: "Nieprawidłowy rekord szkolenia.",
  });
});

test("9. normalization does not mutate its input", () => {
  const input = eventRow({
    event_lanes: [lane(LANE_B, "B", 20), lane(LANE_A, "A", 10)],
  });
  const before = structuredClone(input);
  normalizeAdminEvent(input);
  assert.deepEqual(input, before);
});

test("10. validates a global event", () => {
  const result = validateEventForm(formInput());
  assert.equal(result.ok, true);
  assert.equal(result.value.price, 150.5);
  assert.equal(result.value.maxParticipants, 10);
});

test("11. allows a global event outside lane booking hours", () => {
  assert.equal(validateEventForm(formInput({ startTime: "06:00", endTime: "22:00" })).ok, true);
});

test("12. validates a one-lane event", () => {
  assert.equal(validateEventForm(formInput({ laneIds: [LANE_A] })).ok, true);
});

test("13. validates a multi-lane event", () => {
  assert.equal(validateEventForm(formInput({ laneIds: [LANE_B, LANE_A] })).ok, true);
});

test("14. rejects an empty title", () => {
  const result = validateEventForm(formInput({ title: "   " }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_title");
});

test("15. rejects a missing date", () => {
  const result = validateEventForm(formInput({ eventDate: "" }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_date");
});

test("16. rejects an invalid time format", () => {
  for (const startTime of ["9:00", "24:00", "10:60", "10:00:00", ""]) {
    const result = validateEventForm(formInput({ startTime }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_time");
  }
});

test("17. rejects an end time not later than start", () => {
  for (const endTime of ["10:00", "09:59"]) {
    const result = validateEventForm(formInput({ endTime }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_time_range");
  }
});

test("18. rejects a negative price", () => {
  const result = validateEventForm(formInput({ price: "-1" }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_price");
});

test("19. rejects a NaN price", () => {
  const result = validateEventForm(formInput({ price: "NaN" }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_price");
});

test("20. rejects an infinite price", () => {
  const result = validateEventForm(formInput({ price: "Infinity" }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_price");
});

test("21. rejects zero participants", () => {
  const result = validateEventForm(formInput({ maxParticipants: "0" }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_max_participants");
});

test("22. rejects non-integer participants", () => {
  const result = validateEventForm(formInput({ maxParticipants: "1.5" }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_max_participants");
});

test("23. rejects a lane event before 08:00", () => {
  const result = validateEventForm(formInput({ startTime: "07:59", laneIds: [LANE_A] }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "outside_booking_hours");
});

test("24. rejects a lane event after 20:00", () => {
  const result = validateEventForm(formInput({ endTime: "20:01", laneIds: [LANE_A] }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "outside_booking_hours");
});

test("25. rejects null and empty lane IDs", () => {
  for (const laneIds of [[""], [null]]) {
    const result = validateEventForm(formInput({ laneIds }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_lane_ids");
  }
});

test("26. rejects duplicate lane IDs", () => {
  const result = validateEventForm(formInput({ laneIds: [LANE_A, LANE_A] }));
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_lane_ids");
});

test("27. create payload always sends an empty lane array for a global event", () => {
  assert.deepEqual(buildCreateEventPayload(validatedForm()).p_lane_ids, []);
});

test("28. validated and payload lane IDs are stably sorted", () => {
  const value = validatedForm({ laneIds: [LANE_C, LANE_A, LANE_B] });
  assert.deepEqual(value.laneIds, [LANE_A, LANE_B, LANE_C]);
  assert.deepEqual(buildCreateEventPayload(value).p_lane_ids, [LANE_A, LANE_B, LANE_C]);
});

test("29. builds the exact create payload", () => {
  assert.deepEqual(buildCreateEventPayload(validatedForm({ laneIds: [LANE_A] })), {
    p_title: "Szkolenie",
    p_description: "Opis",
    p_event_date: "2026-09-10",
    p_start_time: "10:00",
    p_end_time: "12:00",
    p_location: "Strzelnica",
    p_price: 150.5,
    p_max_participants: 10,
    p_lane_ids: [LANE_A],
  });
});

test("30. builds the update payload with event ID", () => {
  assert.deepEqual(buildUpdateEventPayload(EVENT_ID, validatedForm()), {
    ok: true,
    value: {
      p_event_id: EVENT_ID,
      p_title: "Szkolenie",
      p_description: "Opis",
      p_event_date: "2026-09-10",
      p_start_time: "10:00",
      p_end_time: "12:00",
      p_location: "Strzelnica",
      p_price: 150.5,
      p_max_participants: 10,
      p_lane_ids: [],
    },
  });
});

test("31. builds the active payload", () => {
  assert.deepEqual(buildSetEventActivePayload(EVENT_ID, false), {
    ok: true,
    value: {
      p_event_id: EVENT_ID,
      p_is_active: false,
    },
  });
});

test("32. validates a created RPC response", () => {
  assert.deepEqual(validateEventRpcResult(rpcResult("created")), {
    ok: true,
    value: rpcResult("created"),
  });
});

test("33. validates a conflict RPC response", () => {
  const input = rpcResult("reservation_conflict", {
    ok: false,
    changed: false,
    conflict_type: "reservation",
    conflict_lane_id: LANE_A,
  });
  assert.deepEqual(validateEventRpcResult(input), { ok: true, value: input });
});

test("34. accepts a null event ID", () => {
  assert.equal(validateEventRpcResult(rpcResult("not_allowed", {
    ok: false,
    changed: false,
    event_id: null,
  })).ok, true);
});

test("35. rejects a response without ok", () => {
  const { ok: _removed, ...input } = rpcResult("created");
  assert.equal(validateEventRpcResult(input).code, "invalid_rpc_response");
});

test("36. rejects a non-boolean changed value", () => {
  assert.equal(validateEventRpcResult(rpcResult("created", { changed: "true" })).code, "invalid_rpc_response");
});

test("37. rejects an unknown conflict type", () => {
  assert.equal(validateEventRpcResult(rpcResult("event_conflict", { conflict_type: "profile" })).code, "invalid_rpc_response");
});

test("38. rejects invalid UUID fields", () => {
  assert.equal(validateEventRpcResult(rpcResult("created", { event_id: "secret-id" })).code, "invalid_rpc_response");
  assert.equal(validateEventRpcResult(rpcResult("event_conflict", { conflict_lane_id: "secret-id" })).code, "invalid_rpc_response");
});

test("39. rejects non-object RPC values", () => {
  for (const value of [null, [], "created", 1]) {
    assert.equal(validateEventRpcResult(value).code, "invalid_rpc_response");
  }
});

test("40. maps every known RPC code to its exact Polish message", () => {
  const expected = {
    created: ["success", "Szkolenie zostało dodane."],
    updated: ["success", "Szkolenie zostało zaktualizowane."],
    activated: ["success", "Szkolenie zostało aktywowane."],
    deactivated: ["success", "Szkolenie zostało ukryte."],
    no_change: ["neutral", "Nie wprowadzono żadnych zmian."],
    not_allowed: ["error", "Nie masz uprawnień do zarządzania szkoleniami."],
    invalid_input: ["error", "Sprawdź poprawność danych szkolenia."],
    invalid_time_range: ["error", "Godzina zakończenia musi być późniejsza niż rozpoczęcia."],
    outside_booking_hours: ["error", "Event zajmujący oś musi mieścić się w godzinach 08:00–20:00."],
    invalid_lane: ["error", "Wybrana oś nie istnieje."],
    inactive_lane: ["error", "Wybrana oś jest nieaktywna."],
    reservation_conflict: ["error", "Termin koliduje z istniejącą rezerwacją."],
    lane_block_conflict: ["error", "Termin koliduje z blokadą osi."],
    event_conflict: ["error", "Termin koliduje z innym szkoleniem."],
    event_not_found: ["error", "Nie znaleziono szkolenia. Odśwież listę."],
  };

  for (const [code, [kind, message]] of Object.entries(expected)) {
    assert.deepEqual(getEventManagementMessage({ code }), { kind, message });
  }
});

test("41. adds a locally known lane name to conflict messages", () => {
  assert.deepEqual(
    getEventManagementMessage(
      { code: "reservation_conflict", conflict_lane_id: LANE_A },
      new Map([[LANE_A, "Oś 100 m"]])
    ),
    { kind: "error", message: "Termin koliduje z istniejącą rezerwacją na osi: Oś 100 m." }
  );
});

test("42. hides an unknown conflict UUID", () => {
  const result = getEventManagementMessage({
    code: "lane_block_conflict",
    conflict_lane_id: LANE_C,
  });
  assert.deepEqual(result, { kind: "error", message: "Termin koliduje z blokadą osi." });
  assert.equal(result.message.includes(LANE_C), false);
  assert.equal(result.message.includes(":"), false);
});

test("43. maps an unknown code to a controlled error", () => {
  assert.deepEqual(getEventManagementMessage({ code: "future_code" }), {
    kind: "error",
    message: "Nie udało się wykonać operacji. Spróbuj ponownie.",
  });
});

test("44. classifies success, neutral, errors and invalid contracts", () => {
  assert.equal(getEventManagementMessage({ code: "created" }).kind, "success");
  assert.equal(getEventManagementMessage({ code: "no_change" }).kind, "neutral");
  assert.equal(getEventManagementMessage({ code: "not_allowed" }).kind, "error");
  assert.equal(getEventManagementMessage({ code: "invalid_rpc_response" }).kind, "error");
});

test("45. messages and module source contain no PII or technical secrets", async () => {
  const source = await readFile(new URL("./event-management.ts", import.meta.url), "utf8");
  const messages = [
    getEventManagementMessage({ code: "reservation_conflict", conflict_lane_id: LANE_A }),
    getEventManagementMessage({ code: "invalid_rpc_response" }),
    getEventManagementMessage({ code: "future_code" }),
  ];
  const serialized = JSON.stringify(messages);

  assert.doesNotMatch(serialized, /@|\b\d{9}\b|customer|email|phone|token|uuid/i);
  assert.equal(serialized.includes(LANE_A), false);
  assert.doesNotMatch(
    source,
    /SUPABASE_(?:ANON|SERVICE_ROLE)_KEY|NEXT_PUBLIC_SUPABASE|\.env\.local|connection[_ -]?string|console\./i
  );
});

test("46. accepts PostgreSQL times and a numeric price returned as text", () => {
  const result = normalizeAdminEvent(eventRow({
    start_time: "11:00:00",
    end_time: "12:30:00",
    price: "150.50",
  }));

  assert.equal(result.ok, true);
  assert.equal(result.value.start_time, "11:00:00");
  assert.equal(result.value.end_time, "12:30:00");
  assert.equal(result.value.price, 150.5);
});

test("47. treats missing or null event_lanes as an empty relation", () => {
  const missing = eventRow();
  delete missing.event_lanes;

  for (const input of [missing, eventRow({ event_lanes: null })]) {
    const result = normalizeAdminEvent(input);
    assert.equal(result.ok, true);
    assert.deepEqual(result.value.laneIds, []);
  }
});

test("48. accepts a one-element lane array and skips invalid lane nullability", () => {
  const arrayRelation = lane(LANE_A, "Oś A", 10);
  arrayRelation.shooting_lanes = [arrayRelation.shooting_lanes];
  const result = normalizeAdminEvent(eventRow({
    event_lanes: [
      arrayRelation,
      lane(LANE_B, "Oś B", 20, { type: null }),
      lane(LANE_C, "Oś C", 30, { display_order: null }),
    ],
  }));

  assert.equal(result.ok, true);
  assert.deepEqual(result.value.laneIds, [LANE_A]);
});

test("49. resolves inconsistent duplicate lane relations deterministically", () => {
  const variants = [
    lane(LANE_A, "Zulu", 20, { type: "zeta", is_active: false }),
    lane(LANE_B, "Beta", 15),
    lane(LANE_A, "Alfa", 10, { type: "alpha", is_active: true }),
  ];
  const first = normalizeAdminEvent(eventRow({ event_lanes: variants }));
  const second = normalizeAdminEvent(eventRow({ event_lanes: [...variants].reverse() }));

  assert.equal(first.ok, true);
  assert.equal(second.ok, true);
  assert.deepEqual(first.value.lanes, second.value.lanes);
  assert.deepEqual(first.value.laneIds, [LANE_A, LANE_B]);
  assert.equal(first.value.lanes[0].name, "Alfa");
});

test("50. enforces exact HH:mm input while accepting global day boundaries", () => {
  for (const [startTime, endTime] of [
    ["00:00", "08:00"],
    ["08:00", "20:00"],
    ["20:00", "23:59"],
  ]) {
    assert.equal(validateEventForm(formInput({ startTime, endTime })).ok, true);
  }

  for (const startTime of ["8:00", "08:0", "24:00", "12:60", "tekst", ""]) {
    const result = validateEventForm(formInput({ startTime }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_time");
  }
});

test("51. applies lane booking-hour boundaries without restricting global events", () => {
  assert.equal(validateEventForm(formInput({
    startTime: "08:00",
    endTime: "20:00",
    laneIds: [LANE_A],
  })).ok, true);
  assert.equal(validateEventForm(formInput({
    startTime: "07:59",
    endTime: "20:00",
    laneIds: [LANE_A],
  })).code, "outside_booking_hours");
  assert.equal(validateEventForm(formInput({
    startTime: "08:00",
    endTime: "20:01",
    laneIds: [LANE_A],
  })).code, "outside_booking_hours");
  assert.equal(validateEventForm(formInput({
    startTime: "06:00",
    endTime: "07:00",
  })).ok, true);
});

test("52. validates all required price edge cases", () => {
  for (const price of ["", "   ", "NaN", "Infinity", "-Infinity", "-0.01"]) {
    const result = validateEventForm(formInput({ price }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_price");
  }

  const decimal = validateEventForm(formInput({ price: "0.01" }));
  assert.equal(decimal.ok, true);
  assert.equal(decimal.value.price, 0.01);
});

test("53. validates all required participant-count edge cases", () => {
  for (const maxParticipants of ["", "   ", "0", "-1", "1.5", "NaN", "Infinity"]) {
    const result = validateEventForm(formInput({ maxParticipants }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_max_participants");
  }

  const positive = validateEventForm(formInput({ maxParticipants: "1" }));
  assert.equal(positive.ok, true);
  assert.equal(positive.value.maxParticipants, 1);
});

test("54. validates lane IDs from unknown runtime values and accepts UUID case", () => {
  for (const laneIds of [null, "not-an-array", [null], [42], [{}]]) {
    const result = validateEventForm(formInput({ laneIds }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_lane_ids");
  }

  const uppercase = validateEventForm(formInput({ laneIds: [LANE_A.toUpperCase()] }));
  assert.equal(uppercase.ok, true);
  assert.deepEqual(uppercase.value.laneIds, [LANE_A.toUpperCase()]);
});

test("55. update and active builders reject invalid event IDs without a payload", () => {
  for (const eventId of ["", "not-a-uuid"]) {
    assert.deepEqual(buildUpdateEventPayload(eventId, validatedForm()), {
      ok: false,
      code: "invalid_event_id",
      message: "Nieprawidłowy identyfikator szkolenia.",
    });
    assert.deepEqual(buildSetEventActivePayload(eventId, true), {
      ok: false,
      code: "invalid_event_id",
      message: "Nieprawidłowy identyfikator szkolenia.",
    });
  }
});

test("56. payload builders copy lane arrays instead of mutating form state", () => {
  const value = validatedForm({ laneIds: [LANE_B, LANE_A] });
  const before = structuredClone(value);
  const create = buildCreateEventPayload(value);
  const update = buildUpdateEventPayload(EVENT_ID, value);

  assert.deepEqual(value, before);
  assert.notEqual(create.p_lane_ids, value.laneIds);
  assert.equal(update.ok, true);
  assert.notEqual(update.value.p_lane_ids, value.laneIds);
});

test("57. rejects inconsistent conflict response fields", () => {
  const invalidResponses = [
    rpcResult("reservation_conflict", { ok: false, changed: false }),
    rpcResult("reservation_conflict", {
      ok: false,
      changed: false,
      conflict_type: "event",
      conflict_lane_id: LANE_A,
    }),
    rpcResult("event_conflict", {
      ok: false,
      changed: false,
      conflict_type: "event",
      conflict_lane_id: null,
    }),
    rpcResult("updated", { conflict_lane_id: LANE_A }),
  ];

  for (const input of invalidResponses) {
    assert.equal(validateEventRpcResult(input).code, "invalid_rpc_response");
  }
});

test("58. validates lane errors and required success event IDs", () => {
  for (const code of ["invalid_lane", "inactive_lane"]) {
    assert.equal(validateEventRpcResult(rpcResult(code, {
      ok: false,
      changed: false,
      conflict_lane_id: LANE_A,
    })).ok, true);
    assert.equal(validateEventRpcResult(rpcResult(code, {
      ok: false,
      changed: false,
      conflict_lane_id: null,
    })).code, "invalid_rpc_response");
  }

  for (const code of ["created", "updated", "activated", "deactivated"]) {
    assert.equal(validateEventRpcResult(rpcResult(code, { event_id: null })).code, "invalid_rpc_response");
  }

  assert.equal(validateEventRpcResult(rpcResult("event_not_found", {
    ok: false,
    changed: false,
    event_id: null,
  })).ok, true);
});

test("59. rejects malformed database dates and times", () => {
  for (const input of [
    eventRow({ event_date: "10-09-2026" }),
    eventRow({ event_date: "2026-02-30" }),
    eventRow({ start_time: "11:00" , end_time: "24:00:00" }),
    eventRow({ start_time: "11:00:00", end_time: "12:60:00" }),
    eventRow({ price: "   " }),
  ]) {
    assert.equal(normalizeAdminEvent(input).code, "invalid_event");
  }
});

test("60. ignores unknown RPC fields without exposing them", () => {
  const result = validateEventRpcResult(rpcResult("created", {
    customer_email: "hidden@example.invalid",
    internal_payload: { secret: true },
  }));

  assert.equal(result.ok, true);
  assert.deepEqual(result.value, rpcResult("created"));
});

test("61. rejects impossible form dates", () => {
  for (const eventDate of ["2026-02-30", "2026-13-01", "10-09-2026"]) {
    const result = validateEventForm(formInput({ eventDate }));
    assert.equal(result.ok, false);
    assert.equal(result.code, "invalid_date");
  }
});

test("62. rejects contradictory RPC success and error flags", () => {
  for (const input of [
    rpcResult("created", { ok: false, changed: false }),
    rpcResult("updated", { changed: false }),
    rpcResult("no_change", { changed: true }),
    rpcResult("not_allowed", { ok: true, changed: false }),
    rpcResult("event_not_found", { ok: false, changed: true }),
  ]) {
    assert.equal(validateEventRpcResult(input).code, "invalid_rpc_response");
  }
});

test("63. normalizes a direct active lane list in stable display order", () => {
  const lanes = normalizeActiveEventLanes([
    lane(LANE_C, "Skeet", 20).shooting_lanes,
    lane(LANE_A, "Oś 100 m", 10).shooting_lanes,
    lane(LANE_B, "Trap", 10).shooting_lanes,
  ]);

  assert.deepEqual(
    lanes?.map((lane) => lane.id),
    [LANE_A, LANE_B, LANE_C]
  );
});

test("64. rejects malformed, inactive, and duplicate direct active lane records", () => {
  const activeLane = lane(LANE_A, "Oś 100 m", 10).shooting_lanes;

  assert.equal(normalizeActiveEventLanes(null), null);
  assert.equal(normalizeActiveEventLanes([{ ...activeLane, is_active: false }]), null);
  assert.equal(normalizeActiveEventLanes([activeLane, activeLane]), null);
  assert.equal(normalizeActiveEventLanes([{ ...activeLane, name: "" }]), null);
});

test("65. direct active lane normalization does not mutate its input", () => {
  const input = [
    lane(LANE_B, "Trap", 20).shooting_lanes,
    lane(LANE_A, "Oś 100 m", 10).shooting_lanes,
  ];
  const before = structuredClone(input);

  normalizeActiveEventLanes(input);

  assert.deepEqual(input, before);
});

test("66. editable lanes preserve assigned inactive lanes without duplicate IDs", () => {
  const activeLane = {
    id: LANE_A,
    name: "Oś 100 m",
    type: "shooting",
    is_active: true,
    display_order: 10,
  };
  const inactiveAssignedLane = {
    id: LANE_B,
    name: "Trap",
    type: "shooting",
    is_active: false,
    display_order: 20,
  };

  const lanes = getEditableEventLanes(
    [activeLane],
    [inactiveAssignedLane, { ...activeLane, name: "Stara nazwa" }]
  );

  assert.deepEqual(lanes, [activeLane, inactiveAssignedLane]);
});

test("67. sorts events by date and start time in both directions", () => {
  const early = normalizeAdminEvent(eventRow({
    id: "22222222-2222-4222-8222-222222222222",
    event_date: "2026-09-09",
    start_time: "12:00:00",
  })).value;
  const sameDayEarly = normalizeAdminEvent(eventRow({
    id: "33333333-3333-4333-8333-333333333333",
    start_time: "09:00:00",
  })).value;
  const sameDayLate = normalizeAdminEvent(eventRow({
    id: "44444444-4444-4444-8444-444444444444",
    start_time: "18:00:00",
  })).value;
  const events = [sameDayEarly, early, sameDayLate];

  assert.deepEqual(
    sortAdminEvents(events, "newest").map((event) => event.id),
    [sameDayLate.id, sameDayEarly.id, early.id]
  );
  assert.deepEqual(
    sortAdminEvents(events, "oldest").map((event) => event.id),
    [early.id, sameDayEarly.id, sameDayLate.id]
  );
});

test("68. event sorting is deterministic and does not mutate its input", () => {
  const first = normalizeAdminEvent(eventRow({
    id: "22222222-2222-4222-8222-222222222222",
    created_at: "2026-08-06T10:00:00Z",
  })).value;
  const second = normalizeAdminEvent(eventRow({
    id: "33333333-3333-4333-8333-333333333333",
    created_at: "2026-08-06T11:00:00Z",
  })).value;
  const events = [first, second];
  const before = [...events];
  const sorted = sortAdminEvents(events, "newest");

  assert.deepEqual(events, before);
  assert.notEqual(sorted, events);
  assert.deepEqual(sorted.map((event) => event.id), [second.id, first.id]);
});
