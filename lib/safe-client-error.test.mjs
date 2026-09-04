import assert from "node:assert/strict";
import test from "node:test";

import {
  getEventConfirmationResponseMessage,
  getLoginErrorMessage,
  getPasswordUpdateErrorMessage,
  getRegistrationErrorMessage,
  getSafeErrorCode,
  reportClientError,
} from "./safe-client-error.ts";

const RAW_SECRET =
  "relation public.profiles failed; details=secret@example.com; hint=Bearer test.jwt.token";

test("raw provider details never become user-facing auth messages", () => {
  const rawError = {
    code: "unexpected_failure",
    message: RAW_SECRET,
    details: "profiles_user_id_key",
    hint: "service_role",
  };

  for (const message of [
    getLoginErrorMessage(rawError),
    getRegistrationErrorMessage(rawError),
    getPasswordUpdateErrorMessage(rawError, "account"),
    getPasswordUpdateErrorMessage(rawError, "reset"),
  ]) {
    assert.doesNotMatch(message, /profiles|secret@example|Bearer|service_role/u);
  }
});

test("confirmation UI ignores raw backend messages and maps stable codes", () => {
  assert.equal(
    getEventConfirmationResponseMessage("expired", false),
    "Link potwierdzający wygasł."
  );
  assert.equal(
    getEventConfirmationResponseMessage(
      { message: RAW_SECRET, details: "private" },
      false
    ),
    "Nie udało się potwierdzić miejsca. Spróbuj ponownie."
  );
});

test("known business auth codes retain controlled Polish messages", () => {
  assert.match(
    getLoginErrorMessage({ code: "email_not_confirmed", message: RAW_SECRET }),
    /weryfikacja adresu e-mail/u
  );
  assert.equal(
    getLoginErrorMessage({ code: "invalid_credentials" }),
    "Nieprawidłowy adres e-mail lub hasło."
  );
  assert.match(
    getRegistrationErrorMessage({ code: "user_already_exists" }),
    /już istnieje/u
  );
  assert.match(
    getPasswordUpdateErrorMessage({ code: "same_password" }, "reset"),
    /inne niż poprzednie/u
  );
  assert.match(
    getPasswordUpdateErrorMessage({ code: "session_expired" }, "reset"),
    /wygasł/u
  );
});

test("client logger keeps only a bounded stable code", () => {
  const calls = [];
  const original = console.error;
  console.error = (...args) => calls.push(args);

  try {
    reportClientError("Account profile read failed", {
      code: "42501",
      message: RAW_SECRET,
      details: "private details",
      access_token: "secret-token",
    });
    reportClientError("Unknown operation failed", new Error(RAW_SECRET));
  } finally {
    console.error = original;
  }

  assert.deepEqual(calls, [
    ["Account profile read failed", { code: "42501" }],
    ["Unknown operation failed"],
  ]);
  assert.doesNotMatch(JSON.stringify(calls), /secret@example|Bearer|service_role|secret-token|private details/u);
});

test("malformed or user-controlled codes are not logged", () => {
  assert.equal(getSafeErrorCode({ code: "42501" }), "42501");
  assert.equal(getSafeErrorCode({ code: "token\nsecret@example.com" }), null);
  assert.equal(getSafeErrorCode({ code: "x".repeat(65) }), null);
});
