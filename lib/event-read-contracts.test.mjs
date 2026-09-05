import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  buildEventSearchParams,
  parseAdminEventList,
  parseMyEventList,
  parsePageNumber,
  parseParticipantList,
  parsePublicEventList,
} from "./event-read-contracts.ts";

const EVENT_ID = "10000000-0000-4000-8000-000000000001";
const REGISTRATION_ID = "20000000-0000-4000-8000-000000000001";

const pagination = { page: 1, page_size: 20, total: 1 };

function publicItem(overrides = {}) {
  return {
    event_id: EVENT_ID,
    title: "[TEST] Event",
    description: "Opis",
    event_date: "2026-12-10",
    start_time: "10:00:00",
    end_time: "12:00:00",
    location: "CSK",
    price: 100,
    max_participants: 10,
    registered_count: 3,
    reserve_count: 1,
    available_spots: 7,
    sold_out: false,
    ...overrides,
  };
}

test("public list parser accepts a bounded authoritative page", () => {
  const result = parsePublicEventList({
    ok: true,
    code: "ok",
    contract_version: 2,
    pagination,
    items: [publicItem()],
  });

  assert.equal(result?.items[0].available_spots, 7);
  assert.equal(result?.total, 1);
});

test("public list parser fails closed on PII and inconsistent availability", () => {
  for (const badItem of [
    publicItem({ customer_email: "private@example.test" }),
    publicItem({ available_spots: 8 }),
  ]) {
    assert.equal(
      parsePublicEventList({
        ok: true,
        code: "ok",
        contract_version: 2,
        pagination,
        items: [badItem],
      }),
      null
    );
  }
});

test("admin list parser preserves hierarchy labels and pagination", () => {
  const result = parseAdminEventList({
    ok: true,
    code: "ok",
    contract_version: 1,
    pagination,
    summary: { all_count: 2, upcoming_count: 1, past_count: 1, inactive_count: 0 },
    items: [{
      id: EVENT_ID,
      title: "Event",
      description: null,
      event_date: "2026-12-10",
      start_time: "10:00:00",
      end_time: "12:00:00",
      location: null,
      price: 100,
      max_participants: 10,
      is_active: true,
      created_at: "2026-09-05T12:00:00Z",
      lanes: [{
        id: "30000000-0000-4000-8000-000000000001",
        name: "Stanowisko 1",
        type: "position",
        is_active: true,
        display_order: 1,
        resource_kind: "position",
        parent_lane_id: "30000000-0000-4000-8000-000000000002",
        parent_name: "Oś 50 m",
      }],
    }],
  });

  assert.equal(result?.items[0].lanes[0].displayName, "Oś 50 m — Stanowisko 1");
  assert.equal(result?.summary.pastCount, 1);
});

test("participant parser keeps minimal DTO and page-independent counts", () => {
  const result = parseParticipantList({
    ok: true,
    code: "ok",
    contract_version: 1,
    pagination: { page: 2, page_size: 50, total: 75 },
    summary: { registered_count: 60, reserve_count: 10, cancelled_count: 5, paid_count: 20 },
    items: [{
      id: REGISTRATION_ID,
      customer_name: "Jan T.",
      customer_email: "synthetic@example.test",
      customer_phone: "000000000",
      registration_status: "registered",
      payment_status: "unpaid",
      created_at: "2026-09-05T12:00:00Z",
    }],
  });

  assert.equal(result?.items.length, 1);
  assert.equal(result?.summary.registeredCount, 60);
  assert.equal(result?.total, 75);
});

test("my events parser accepts only a bounded owned registration shape", () => {
  const result = parseMyEventList({
    ok: true,
    code: "ok",
    contract_version: 1,
    pagination,
    items: [{
      id: REGISTRATION_ID,
      registration_status: "registered",
      payment_status: "unpaid",
      created_at: "2026-09-05T12:00:00Z",
      events: {
        id: EVENT_ID,
        title: "Event",
        description: "Opis",
        event_date: "2026-12-10",
        start_time: "10:00:00",
        end_time: "12:00:00",
        location: "CSK",
        price: 100,
      },
    }],
  });

  assert.equal(result?.items[0].events.id, EVENT_ID);
});

test("URL state accepts only bounded pages and never serializes empty values", () => {
  assert.equal(parsePageNumber(null), 1);
  assert.equal(parsePageNumber("2"), 2);
  assert.equal(parsePageNumber("0"), null);
  assert.equal(parsePageNumber("1.5"), null);
  assert.equal(
    buildEventSearchParams({ q: "szkolenie", page: 1, status: "" }).toString(),
    "q=szkolenie"
  );
});

test("all four screens use bounded RPC reads without browser fetch-all or N+1", async () => {
  const [publicPage, adminPage, myPage, migration] = await Promise.all([
    readFile(new URL("../app/events/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/admin/events/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/my-events/page.tsx", import.meta.url), "utf8"),
    readFile(
      new URL(
        "../supabase/migrations/20260905190000_add_scalable_event_read_contracts.sql",
        import.meta.url
      ),
      "utf8"
    ),
  ]);

  assert.match(publicPage, /get_public_event_list_v2/);
  assert.match(adminPage, /admin_list_events_v1/);
  assert.match(adminPage, /admin_list_event_registrations_v1/);
  assert.match(myPage, /get_my_event_registrations_v1/);
  assert.doesNotMatch(publicPage, /\.from\("event_registrations"\)/);
  assert.doesNotMatch(adminPage, /\.from\("events"\)|\.from\("event_registrations"\)/);
  assert.doesNotMatch(myPage, /\.from\("event_registrations"\)/);
  assert.match(migration, /page_events as materialized/);
  assert.match(migration, /registration\.event_id in\(select page_event\.id from page_events/);
  assert.doesNotMatch(migration, /service_role[^;]*grant execute/is);
});
