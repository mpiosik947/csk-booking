import assert from "node:assert/strict";
import test from "node:test";
import {
  executeAccountDeletion,
  isAccountExportPayload,
} from "./account-lifecycle.js";

const validExport = {
  export_version: 1,
  generated_at: "2026-09-04T12:00:00.000Z",
  account: { id: "account-a", email: "user@example.invalid" },
  profile: { first_name: "Test" },
  reservations: [{ id: "reservation-a", reservation_note: "own note" }],
  event_registrations: [{ id: "registration-a" }],
};

test("versioned owner export accepts the allowlisted shape", () => {
  assert.equal(isAccountExportPayload(validExport), true);
});

test("owner export fails closed on tokens, admin notes and extra top-level data", () => {
  for (const forbidden of [
    { reservations: [{ check_in_token: "secret" }] },
    { profile: { admin_note: "internal" } },
    { event_registrations: [{ promotion_token: "secret" }] },
  ]) {
    assert.equal(isAccountExportPayload({ ...validExport, ...forbidden }), false);
  }

  assert.equal(isAccountExportPayload({ ...validExport, user_id: "other" }), false);
});

test("DB anonymization failure prevents Auth deletion", async () => {
  let deleteCalls = 0;
  const result = await executeAccountDeletion({
    anonymizeBusinessData: async () => ({ data: null, error: { code: "P0001" } }),
    deleteAuthUser: async () => {
      deleteCalls += 1;
      return { error: null };
    },
  });

  assert.deepEqual(result, { ok: false, code: "internal_error", status: 500 });
  assert.equal(deleteCalls, 0);
});

test("malformed anonymization response fails closed and never deletes Auth", async () => {
  let deleteCalls = 0;
  const result = await executeAccountDeletion({
    anonymizeBusinessData: async () => ({
      data: { ok: true, changed: false, code: "anonymized" },
      error: null,
    }),
    deleteAuthUser: async () => {
      deleteCalls += 1;
      return { error: null };
    },
  });

  assert.deepEqual(result, { ok: false, code: "internal_error", status: 500 });
  assert.equal(deleteCalls, 0);
});

test("successful anonymization is followed by exactly one Auth deletion", async () => {
  let anonymizeCalls = 0;
  let deleteCalls = 0;
  const result = await executeAccountDeletion({
    anonymizeBusinessData: async () => {
      anonymizeCalls += 1;
      return {
        data: { ok: true, changed: true, code: "anonymized" },
        error: null,
      };
    },
    deleteAuthUser: async () => {
      deleteCalls += 1;
      return { error: null };
    },
  });

  assert.deepEqual(result, {
    ok: true,
    code: "deleted",
    status: 200,
    alreadyAnonymized: false,
  });
  assert.equal(anonymizeCalls, 1);
  assert.equal(deleteCalls, 1);
});

test("Auth deletion failure is retryable without restoring anonymized PII", async () => {
  let deleteCalls = 0;
  const result = await executeAccountDeletion({
    anonymizeBusinessData: async () => ({
      data: { ok: true, changed: true, code: "anonymized" },
      error: null,
    }),
    deleteAuthUser: async () => {
      deleteCalls += 1;
      return { error: { status: 503, code: "upstream_unavailable" } };
    },
  });

  assert.deepEqual(result, {
    ok: false,
    code: "auth_deletion_pending",
    status: 503,
  });
  assert.equal(deleteCalls, 1);
});

test("already-anonymized retry safely completes Auth deletion", async () => {
  const result = await executeAccountDeletion({
    anonymizeBusinessData: async () => ({
      data: { ok: true, changed: false, code: "already_anonymized" },
      error: null,
    }),
    deleteAuthUser: async () => ({ error: null }),
  });

  assert.deepEqual(result, {
    ok: true,
    code: "deleted",
    status: 200,
    alreadyAnonymized: true,
  });
});

test("already deleted Auth account is treated as idempotent success", async () => {
  const result = await executeAccountDeletion({
    anonymizeBusinessData: async () => ({
      data: { ok: true, changed: false, code: "already_anonymized" },
      error: null,
    }),
    deleteAuthUser: async () => ({
      error: { status: 404, code: "user_not_found" },
    }),
  });

  assert.equal(result.ok, true);
  assert.equal(result.code, "deleted");
});
