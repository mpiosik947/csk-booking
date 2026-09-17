import assert from "node:assert/strict";
import test from "node:test";
import {
  executeAccountDeletion,
  isAccountExportPayload,
} from "./account-lifecycle.js";

const validExport = {
  export_version: 1,
  generated_at: "2026-09-04T12:00:00.000Z",
  account: {
    id: "account-a",
    email: "user@example.invalid",
    phone: null,
    created_at: "2026-09-01T10:00:00.000Z",
    accepted_terms: true,
    accepted_terms_at: "2026-09-01T10:00:00.000Z",
    accepted_privacy: true,
    accepted_privacy_at: "2026-09-01T10:00:00.000Z",
  },
  profile: null,
  reservations: [],
  event_registrations: [],
};

const validTenantRelationship = {
  tenant: {
    id: "c5c00000-0000-4000-8000-000000000001",
    name: "CSK",
    slug: "csk",
  },
  membership: {
    role: "user",
    status: "active",
    created_at: "2026-09-01T10:00:00.000Z",
    updated_at: "2026-09-02T10:00:00.000Z",
  },
  verification: {
    status: "verified",
    permissions_verified: true,
    permissions_verified_at: "2026-09-02T10:00:00.000Z",
    updated_at: "2026-09-02T10:00:00.000Z",
  },
};

const validExportV2 = {
  ...validExport,
  export_version: 2,
  tenant_relationships: [validTenantRelationship],
};

const currentProductionShape = {
  ...validExport,
  profile: {
    id: "profile-a",
    first_name: "Test",
    last_name: "User",
    full_name: "Test User",
    email: "user@example.invalid",
    phone: null,
    postal_code: "00-001",
    city: "Warszawa",
    street: "Testowa",
    house_number: "1",
    apartment_number: null,
    weapon_permit_number: null,
    weapon_permit_type: null,
    weapon_permit_issuer: null,
    has_range_officer: false,
    range_officer_number: null,
    has_instructor: false,
    instructor_number: null,
    permission_sport: true,
    permission_collector: false,
    permission_hunting: false,
    permission_training: false,
    permission_personal_protection: false,
    permission_other: false,
    qualification_instructor: false,
    qualification_range_officer: false,
    qualification_pzss_license: false,
    qualification_hunter: false,
    verification_status: "niezweryfikowane",
    permissions_verified: false,
    permissions_verified_at: null,
    created_at: "2026-09-01T10:00:00.000Z",
    updated_at: "2026-09-02T10:00:00.000Z",
  },
  reservations: [
    {
      id: "reservation-a",
      lane_id: "lane-a",
      reservation_date: "2026-09-30",
      start_time: "10:00:00",
      end_time: "11:00:00",
      duration_minutes: 60,
      shooters_count: 1,
      reservation_status: "confirmed",
      attendance_status: "not_checked_in",
      payment_status: "unpaid",
      checked_in_at: null,
      completed_at: null,
      lane_name: "Oś A",
      pricing_day_group: "weekday",
      pricing_label: "Standard",
      price_per_hour: 100,
      total_price: 100,
      currency_code: "PLN",
      reservation_note: "own note",
      created_at: "2026-09-01T10:00:00.000Z",
    },
  ],
  event_registrations: [
    {
      id: "registration-a",
      event_id: "event-a",
      registration_status: "registered",
      payment_status: "unpaid",
      promotion_email_sent_at: null,
      promotion_confirmed_at: null,
      created_at: "2026-09-01T10:00:00.000Z",
    },
  ],
};

test("current production v1 owner export remains accepted", () => {
  assert.equal(isAccountExportPayload(validExport), true);
  assert.equal(isAccountExportPayload(currentProductionShape), true);
});

test("target v2 owner export accepts an exact tenant relationship contract", () => {
  assert.equal(isAccountExportPayload(validExportV2), true);
  assert.equal(
    isAccountExportPayload({
      ...validExportV2,
      tenant_relationships: [
        { ...validTenantRelationship, verification: null },
      ],
    }),
    true
  );
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

test("malformed v1 fails closed instead of falling through to v2", () => {
  assert.equal(
    isAccountExportPayload({
      ...validExport,
      account: { ...validExport.account, accepted_terms: "true" },
    }),
    false
  );
  assert.equal(
    isAccountExportPayload({ ...validExport, tenant_relationships: [] }),
    false
  );
  assert.equal(
    isAccountExportPayload({ ...validExport, reservations: [{}] }),
    false
  );
});

test("malformed v2 and a missing relationship structure fail closed", () => {
  const withoutRelationships = { ...validExportV2 };
  delete withoutRelationships.tenant_relationships;

  assert.equal(isAccountExportPayload(withoutRelationships), false);
  assert.equal(
    isAccountExportPayload({
      ...validExportV2,
      tenant_relationships: [{ tenant: validTenantRelationship.tenant }],
    }),
    false
  );
  assert.equal(
    isAccountExportPayload({
      ...validExportV2,
      tenant_relationships: [
        {
          ...validTenantRelationship,
          membership: {
            ...validTenantRelationship.membership,
            role: "owner",
          },
        },
      ],
    }),
    false
  );
});

test("v2 rejects semantic corruption, duplicate tenants and staff-only fields", () => {
  assert.equal(
    isAccountExportPayload({
      ...validExportV2,
      tenant_relationships: [
        validTenantRelationship,
        validTenantRelationship,
      ],
    }),
    false
  );
  assert.equal(
    isAccountExportPayload({
      ...validExportV2,
      tenant_relationships: [
        {
          ...validTenantRelationship,
          verification: {
            ...validTenantRelationship.verification,
            status: "pending",
          },
        },
      ],
    }),
    false
  );
  assert.equal(
    isAccountExportPayload({
      ...validExportV2,
      tenant_relationships: [
        {
          ...validTenantRelationship,
          verification: {
            ...validTenantRelationship.verification,
            permissions_verification_note: "staff only",
          },
        },
      ],
    }),
    false
  );
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
