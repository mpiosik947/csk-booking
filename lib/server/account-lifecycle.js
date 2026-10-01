const ANONYMIZATION_CODES = new Set(["anonymized", "already_anonymized"]);

const FORBIDDEN_EXPORT_KEYS = new Set([
  "admin_note",
  "verification_note",
  "permissions_verification_note",
  "check_in_token",
  "promotion_token",
  "promotion_token_expires_at",
  "promotion_claim_id",
  "promotion_claim_expires_at",
  "promotion_last_error_code",
  "confirmation_token",
  "reserve_token",
  "access_token",
  "refresh_token",
  "encrypted_password",
  "password_hash",
  "jwt",
  "service_role",
  "scope_key",
  "request_timestamps",
  "claim_id", "claim_expires_at", "provider_message_id", "last_error_code",
  "verification_hash", "verification_expires_at", "idempotency_key",
  "actor_user_id", "recipient_user_id", "assigned_by", "unassigned_by",
  "attendance_marked_by", "details", "external_reference",
]);

const ACCOUNT_KEYS = [
  "id",
  "email",
  "phone",
  "created_at",
  "accepted_terms",
  "accepted_terms_at",
  "accepted_privacy",
  "accepted_privacy_at",
];

const PROFILE_KEYS = [
  "id",
  "first_name",
  "last_name",
  "full_name",
  "email",
  "phone",
  "postal_code",
  "city",
  "street",
  "house_number",
  "apartment_number",
  "weapon_permit_number",
  "weapon_permit_type",
  "weapon_permit_issuer",
  "has_range_officer",
  "range_officer_number",
  "has_instructor",
  "instructor_number",
  "permission_sport",
  "permission_collector",
  "permission_hunting",
  "permission_training",
  "permission_personal_protection",
  "permission_other",
  "qualification_instructor",
  "qualification_range_officer",
  "qualification_pzss_license",
  "qualification_hunter",
  "verification_status",
  "permissions_verified",
  "permissions_verified_at",
  "created_at",
  "updated_at",
];

const RESERVATION_KEYS = [
  "id",
  "lane_id",
  "reservation_date",
  "start_time",
  "end_time",
  "duration_minutes",
  "shooters_count",
  "reservation_status",
  "attendance_status",
  "payment_status",
  "checked_in_at",
  "completed_at",
  "lane_name",
  "pricing_day_group",
  "pricing_label",
  "price_per_hour",
  "total_price",
  "currency_code",
  "reservation_note",
  "created_at",
];

const EVENT_REGISTRATION_KEYS = [
  "id",
  "event_id",
  "registration_status",
  "payment_status",
  "promotion_email_sent_at",
  "promotion_confirmed_at",
  "created_at",
];

const TENANT_RELATIONSHIP_KEYS = ["tenant", "membership", "verification"];
const TENANT_KEYS = ["id", "name", "slug"];
const MEMBERSHIP_KEYS = ["role", "status", "created_at", "updated_at"];
const VERIFICATION_KEYS = [
  "status",
  "permissions_verified",
  "permissions_verified_at",
  "updated_at",
];
const MEMBERSHIP_ROLES = new Set(["admin", "employee", "user", "instructor"]);
const MEMBERSHIP_STATUSES = new Set(["active", "pending", "suspended"]);
const VERIFICATION_STATUSES = new Set(["pending", "verified", "rejected"]);

function hasExactKeys(value, keys) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).length === keys.length &&
    Object.keys(value).every((key) => keys.includes(key))
  );
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

function isNullableString(value) {
  return value === null || typeof value === "string";
}

function isNullableBoolean(value) {
  return value === null || typeof value === "boolean";
}

function isNullableNumber(value) {
  return value === null || (typeof value === "number" && Number.isFinite(value));
}

function isTimestamp(value) {
  return isNonEmptyString(value) && !Number.isNaN(Date.parse(value));
}

function isNullableTimestamp(value) {
  return value === null || isTimestamp(value);
}

function isAccount(value) {
  return (
    hasExactKeys(value, ACCOUNT_KEYS) &&
    isNonEmptyString(value.id) &&
    isNullableString(value.email) &&
    isNullableString(value.phone) &&
    isTimestamp(value.created_at) &&
    typeof value.accepted_terms === "boolean" &&
    isNullableString(value.accepted_terms_at) &&
    typeof value.accepted_privacy === "boolean" &&
    isNullableString(value.accepted_privacy_at)
  );
}

function isProfile(value) {
  if (value === null) {
    return true;
  }

  if (!hasExactKeys(value, PROFILE_KEYS) || !isNonEmptyString(value.id)) {
    return false;
  }

  const nullableStrings = [
    "first_name",
    "last_name",
    "full_name",
    "email",
    "phone",
    "postal_code",
    "city",
    "street",
    "house_number",
    "apartment_number",
    "weapon_permit_number",
    "weapon_permit_type",
    "weapon_permit_issuer",
    "range_officer_number",
    "instructor_number",
    "verification_status",
  ];
  const nullableBooleans = [
    "has_range_officer",
    "has_instructor",
    "permission_sport",
    "permission_collector",
    "permission_hunting",
    "permission_training",
    "permission_personal_protection",
    "permission_other",
    "qualification_instructor",
    "qualification_range_officer",
    "qualification_pzss_license",
    "qualification_hunter",
    "permissions_verified",
  ];

  return (
    nullableStrings.every((key) => isNullableString(value[key])) &&
    nullableBooleans.every((key) => isNullableBoolean(value[key])) &&
    isNullableTimestamp(value.permissions_verified_at) &&
    isTimestamp(value.created_at) &&
    isTimestamp(value.updated_at)
  );
}

function isReservation(value) {
  return (
    hasExactKeys(value, RESERVATION_KEYS) &&
    isNonEmptyString(value.id) &&
    isNonEmptyString(value.lane_id) &&
    isNonEmptyString(value.reservation_date) &&
    isNonEmptyString(value.start_time) &&
    isNonEmptyString(value.end_time) &&
    Number.isInteger(value.duration_minutes) &&
    Number.isInteger(value.shooters_count) &&
    isNonEmptyString(value.reservation_status) &&
    isNullableString(value.attendance_status) &&
    isNonEmptyString(value.payment_status) &&
    isNullableTimestamp(value.checked_in_at) &&
    isNullableTimestamp(value.completed_at) &&
    isNullableString(value.lane_name) &&
    isNullableString(value.pricing_day_group) &&
    isNullableString(value.pricing_label) &&
    isNullableNumber(value.price_per_hour) &&
    isNullableNumber(value.total_price) &&
    isNullableString(value.currency_code) &&
    isNullableString(value.reservation_note) &&
    isTimestamp(value.created_at)
  );
}

function isEventRegistration(value) {
  return (
    hasExactKeys(value, EVENT_REGISTRATION_KEYS) &&
    isNonEmptyString(value.id) &&
    isNullableString(value.event_id) &&
    isNonEmptyString(value.registration_status) &&
    isNonEmptyString(value.payment_status) &&
    isNullableTimestamp(value.promotion_email_sent_at) &&
    isNullableTimestamp(value.promotion_confirmed_at) &&
    isTimestamp(value.created_at)
  );
}

function isTenantRelationship(value) {
  if (!hasExactKeys(value, TENANT_RELATIONSHIP_KEYS)) {
    return false;
  }

  const { tenant, membership, verification } = value;

  if (
    !hasExactKeys(tenant, TENANT_KEYS) ||
    !isNonEmptyString(tenant.id) ||
    !isNonEmptyString(tenant.name) ||
    !isNonEmptyString(tenant.slug) ||
    tenant.slug !== tenant.slug.toLowerCase() ||
    !/^[a-z0-9]+(?:-[a-z0-9]+)*$/u.test(tenant.slug) ||
    !hasExactKeys(membership, MEMBERSHIP_KEYS) ||
    !MEMBERSHIP_ROLES.has(membership.role) ||
    !MEMBERSHIP_STATUSES.has(membership.status) ||
    !isTimestamp(membership.created_at) ||
    !isTimestamp(membership.updated_at)
  ) {
    return false;
  }

  if (verification === null) {
    return true;
  }

  return (
    hasExactKeys(verification, VERIFICATION_KEYS) &&
    VERIFICATION_STATUSES.has(verification.status) &&
    typeof verification.permissions_verified === "boolean" &&
    (!verification.permissions_verified || verification.status === "verified") &&
    isNullableTimestamp(verification.permissions_verified_at) &&
    isTimestamp(verification.updated_at)
  );
}

function containsForbiddenExportKey(value) {
  if (Array.isArray(value)) {
    return value.some(containsForbiddenExportKey);
  }

  if (value === null || typeof value !== "object") {
    return false;
  }

  return Object.entries(value).some(
    ([key, nestedValue]) =>
      FORBIDDEN_EXPORT_KEYS.has(key.toLowerCase()) ||
      containsForbiddenExportKey(nestedValue)
  );
}

export function isAccountExportPayload(value) {
  if (value?.export_version === 3) return isAccountExportV3(value);
  const commonKeys = [
    "export_version",
    "generated_at",
    "account",
    "profile",
    "reservations",
    "event_registrations",
  ];

  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    ![1, 2].includes(value.export_version) ||
    !hasExactKeys(
      value,
      value.export_version === 1
        ? commonKeys
        : [...commonKeys, "tenant_relationships"]
    )
  ) {
    return false;
  }

  const commonContractIsValid =
    isTimestamp(value.generated_at) &&
    isAccount(value.account) &&
    isProfile(value.profile) &&
    Array.isArray(value.reservations) &&
    value.reservations.every(isReservation) &&
    Array.isArray(value.event_registrations) &&
    value.event_registrations.every(isEventRegistration) &&
    !containsForbiddenExportKey(value);

  if (!commonContractIsValid || value.export_version === 1) {
    return commonContractIsValid;
  }

  if (!Array.isArray(value.tenant_relationships)) {
    return false;
  }

  const tenantIds = new Set();

  for (const relationship of value.tenant_relationships) {
    if (
      !isTenantRelationship(relationship) ||
      tenantIds.has(relationship.tenant.id)
    ) {
      return false;
    }

    tenantIds.add(relationship.tenant.id);
  }

  return true;
}

const V3_ACCOUNT_FIELDS = {
  updated_at: isNullableTimestamp, email_confirmed_at: isNullableTimestamp,
  phone_confirmed_at: isNullableTimestamp, last_sign_in_at: isNullableTimestamp,
  pending_email: isNullableString, pending_phone: isNullableString,
};
const V3_PROFILE_FIELDS = { verified_at: isNullableTimestamp, unverified_at: isNullableTimestamp };
function isTenant(value) {
  return hasExactKeys(value, TENANT_KEYS) && isNonEmptyString(value.id) &&
    isNonEmptyString(value.name) && /^[a-z0-9]+(?:-[a-z0-9]+)*$/u.test(value.slug);
}
function isEventContext(value) {
  return hasExactKeys(value, ['id', 'title', 'event_date', 'start_time', 'end_time']) &&
    Object.values(value).every(isNonEmptyString);
}
const isBoolean = value => typeof value === 'boolean';
const isCounter = value => Number.isSafeInteger(value) && value >= 0;
const enumValue = values => value => values.includes(value);
const V3_RESERVATION_FIELDS = {
  tenant: isTenant, customer_name: isNonEmptyString, customer_email: isNonEmptyString,
  customer_phone: isNonEmptyString, pii_anonymized_at: isNullableTimestamp,
};
const V3_REGISTRATION_FIELDS = {
  ...V3_RESERVATION_FIELDS, event: value => value === null || isEventContext(value),
  cancellation_email_initialized_at: isNullableTimestamp,
  attendance_status: enumValue(['unmarked', 'present', 'no_show']),
  attendance_marked_at: isNullableTimestamp, attendance_version: isCounter,
  attendance_marked_by_me: isBoolean,
};
const DELIVERY_TYPES = ['reservation_confirmation', 'event_registration_confirmation', 'reservation_cancellation',
  'event_reserve_acceptance_confirmation', 'event_registration_cancellation', 'booking_reminder_24h',
  'event_reminder_24h', 'event_cancellation', 'instructor_assignment', 'instructor_removal', 'instructor_event_cancellation'];
const contextFields = { id: isNonEmptyString, tenant: isTenant };
const resourceFields = { resource_type: enumValue(['reservation', 'event_registration']), resource_id: isNonEmptyString };
const V3_SECTIONS = {
  event_instructors: { ...contextFields, event: isEventContext, assigned_at: isTimestamp, unassigned_at: isNullableTimestamp,
    assignment_status: enumValue(['active', 'history']), is_instructor: isBoolean, assigned_by_me: isBoolean, unassigned_by_me: isBoolean },
  email_deliveries: { ...contextFields, message_type: enumValue(DELIVERY_TYPES), resource_id: isNonEmptyString,
    sent_at: isNullableTimestamp, delivery_state: enumValue([null, 'pending', 'sending', 'sent', 'failed']),
    attempt_count: isCounter, created_at: isTimestamp, updated_at: isTimestamp },
  reminder_schedules: { ...contextFields, ...resourceFields, generation: isCounter, scheduled_start: isTimestamp, changed_at: isTimestamp },
  reminder_occurrences: { ...contextFields, ...resourceFields, schedule_id: isNonEmptyString,
    message_type: enumValue(['booking_reminder_24h', 'event_reminder_24h']), generation: isCounter,
    scheduled_start: isTimestamp, created_at: isTimestamp },
  platform_audit_history: { ...contextFields, tenant: value => value === null || isTenant(value),
    action: enumValue(['tenant_created', 'plan_assigned', 'plan_changed', 'tenant_admin_assigned', 'tenant_activated',
      'tenant_suspended', 'tenant_published', 'tenant_unpublished', 'platform_admin_bootstrapped', 'domain_added',
      'domain_verification_started', 'domain_verified', 'domain_activated', 'domain_disabled', 'primary_domain_changed']),
    created_at: isTimestamp, relation: enumValue(['actor', 'subject']) },
  audit_history: { ...contextFields, tenant: value => value === null || isTenant(value),
    target_type: isNullableString, created_at: isTimestamp, relation: enumValue(['actor', 'subject', 'resource']) },
  external_settlements: { ...contextFields, kind: enumValue(['external_refund', 'external_reconciliation']),
    amount: value => typeof value === 'number' && Number.isFinite(value) && value > 0,
    currency: value => typeof value === 'string' && /^[A-Z]{3}$/u.test(value), recorded_at: isTimestamp,
    acted_by_me: isBoolean, reservation_id: isNullableString, registration_id: isNullableString },
  tenant_domain_requests: { ...contextFields, hostname: isNonEmptyString,
    domain_type: enumValue(['custom_domain', 'platform_subdomain']), status: enumValue(['pending', 'verified', 'active', 'disabled']),
    is_primary: isBoolean, verified_at: isNullableTimestamp, created_at: isTimestamp, updated_at: isTimestamp },
};
function exactShape(value, fields) {
  return hasExactKeys(value, Object.keys(fields)) && Object.entries(fields).every(([key, check]) => check(value[key]));
}
function extended(value, oldKeys, additions) {
  return hasExactKeys(value, [...oldKeys, ...Object.keys(additions)]) &&
    Object.entries(additions).every(([key, check]) => check(value[key]));
}
function strip(value, keys) { return Object.fromEntries(keys.map(key => [key, value[key]])); }
function isAccountExportV3(value) {
  const keys = ['export_version', 'generated_at', 'account', 'profile', 'reservations', 'event_registrations',
    'tenant_relationships', 'platform_admin', ...Object.keys(V3_SECTIONS)];
  if (!hasExactKeys(value, keys) || containsForbiddenExportKey(value) ||
    !extended(value.account, ACCOUNT_KEYS, V3_ACCOUNT_FIELDS) ||
    (value.profile !== null && !extended(value.profile, PROFILE_KEYS, V3_PROFILE_FIELDS)) ||
    !Array.isArray(value.reservations) || !value.reservations.every(row => extended(row, RESERVATION_KEYS, V3_RESERVATION_FIELDS)) ||
    !Array.isArray(value.event_registrations) || !value.event_registrations.every(row => extended(row, EVENT_REGISTRATION_KEYS, V3_REGISTRATION_FIELDS))) return false;
  if (value.platform_admin !== null && !exactShape(value.platform_admin, {
    status: enumValue(['active', 'suspended']), created_at: isTimestamp,
  })) return false;
  for (const [name, fields] of Object.entries(V3_SECTIONS)) {
    if (!Array.isArray(value[name]) || !value[name].every(row => exactShape(row, fields))) return false;
  }
  const rows = [...Object.keys(V3_SECTIONS), 'reservations', 'event_registrations', 'tenant_relationships'];
  if (rows.reduce((sum, key) => sum + (Array.isArray(value[key]) ? value[key].length : 0), 0) > 10000) return false;
  return isAccountExportPayload({
    export_version: 2, generated_at: value.generated_at,
    account: strip(value.account, ACCOUNT_KEYS), profile: value.profile === null ? null : strip(value.profile, PROFILE_KEYS),
    reservations: value.reservations.map(row => strip(row, RESERVATION_KEYS)),
    event_registrations: value.event_registrations.map(row => strip(row, EVENT_REGISTRATION_KEYS)),
    tenant_relationships: value.tenant_relationships,
  });
}

function isAnonymizationResult(value) {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    value.ok !== true ||
    typeof value.changed !== "boolean" ||
    typeof value.code !== "string" ||
    !ANONYMIZATION_CODES.has(value.code)
  ) {
    return false;
  }

  return (
    (value.code === "anonymized" && value.changed === true) ||
    (value.code === "already_anonymized" && value.changed === false)
  );
}

function isAlreadyDeletedError(error) {
  return (
    error !== null &&
    typeof error === "object" &&
    (error.status === 404 || error.code === "user_not_found")
  );
}

export async function executeAccountDeletion({
  anonymizeBusinessData,
  deleteAuthUser,
}) {
  let anonymization;

  try {
    anonymization = await anonymizeBusinessData();
  } catch {
    return { ok: false, code: "internal_error", status: 500 };
  }

  if (anonymization.error || !isAnonymizationResult(anonymization.data)) {
    return { ok: false, code: "internal_error", status: 500 };
  }

  let authDeletion;

  try {
    authDeletion = await deleteAuthUser();
  } catch {
    return { ok: false, code: "auth_deletion_pending", status: 503 };
  }

  if (authDeletion.error && !isAlreadyDeletedError(authDeletion.error)) {
    return { ok: false, code: "auth_deletion_pending", status: 503 };
  }

  return {
    ok: true,
    code: "deleted",
    status: 200,
    alreadyAnonymized: anonymization.data.code === "already_anonymized",
  };
}
