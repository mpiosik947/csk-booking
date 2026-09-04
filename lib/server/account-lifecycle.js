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
]);

function hasExactKeys(value, keys) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).length === keys.length &&
    Object.keys(value).every((key) => keys.includes(key))
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
  const keys = [
    "export_version",
    "generated_at",
    "account",
    "profile",
    "reservations",
    "event_registrations",
  ];

  if (!hasExactKeys(value, keys)) {
    return false;
  }

  return (
    value.export_version === 1 &&
    typeof value.generated_at === "string" &&
    value.generated_at.length > 0 &&
    value.account !== null &&
    typeof value.account === "object" &&
    !Array.isArray(value.account) &&
    (value.profile === null ||
      (typeof value.profile === "object" && !Array.isArray(value.profile))) &&
    Array.isArray(value.reservations) &&
    Array.isArray(value.event_registrations) &&
    !containsForbiddenExportKey(value)
  );
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
