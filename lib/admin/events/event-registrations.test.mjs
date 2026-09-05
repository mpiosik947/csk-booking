import assert from "node:assert/strict";
import test from "node:test";
import { parseAdminEventRegistrations } from "./event-registrations.ts";

const REGISTRATION_ID = "11111111-1111-4111-8111-111111111111";

function row(overrides = {}) {
  return {
    id: REGISTRATION_ID,
    customer_name: "Użytkownik testowy",
    customer_email: "user@example.test",
    customer_phone: "+48000000000",
    registration_status: "registered",
    payment_status: "pay_on_site",
    created_at: "2026-09-05T12:00:00.000Z",
    ...overrides,
  };
}

test("minimal participant DTO accepts exactly the operational fields", () => {
  assert.deepEqual(parseAdminEventRegistrations([row()]), [row()]);
});

test("minimal participant DTO supports all canonical event statuses", () => {
  for (const registration_status of [
    "registered",
    "approved",
    "reserve",
    "cancelled",
    "participant",
  ]) {
    assert.equal(
      parseAdminEventRegistrations([row({ registration_status })])?.[0]
        .registration_status,
      registration_status
    );
  }
});

test("minimal participant DTO safely preserves a legacy null queue timestamp", () => {
  assert.equal(parseAdminEventRegistrations([row({ created_at: null })])?.[0].created_at, null);
});

test("participant DTO rejects PII and internal delivery fields not used by the UI", () => {
  for (const field of [
    "user_id",
    "admin_note",
    "address",
    "promotion_token",
    "promotion_claim_id",
    "promotion_last_error_code",
  ]) {
    assert.equal(parseAdminEventRegistrations([row({ [field]: "secret" })]), null);
  }
});

test("participant DTO fails closed on malformed or duplicate rows", () => {
  assert.equal(parseAdminEventRegistrations({}), null);
  assert.equal(parseAdminEventRegistrations([row({ registration_status: "" })]), null);
  assert.equal(parseAdminEventRegistrations([row(), row()]), null);
});
