import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  AuthApiError,
  AuthError,
  AuthInvalidJwtError,
  AuthRetryableFetchError,
  AuthSessionMissingError,
  AuthUnknownError,
} from "@supabase/supabase-js";
import {
  getAuthUserFailureMessage,
  verifyAuthUser,
} from "./auth-user-verification.ts";

const user = { id: "00000000-0000-4000-8000-000000000001" };

test("missing user without an Auth error is unauthorized", async () => {
  const result = await verifyAuthUser(async () => ({
    data: { user: null },
    error: null,
  }));

  assert.deepEqual(result, {
    ok: false,
    code: "unauthorized",
    status: 401,
  });
});

test("missing session and invalid JWT are unauthorized", async () => {
  for (const error of [
    new AuthSessionMissingError(),
    new AuthInvalidJwtError("invalid token"),
    new AuthApiError("invalid token", 401, "bad_jwt"),
    new AuthApiError("expired session", 403, "session_expired"),
  ]) {
    const result = await verifyAuthUser(async () => ({
      data: { user: null },
      error,
    }));

    assert.deepEqual(result, {
      ok: false,
      code: "unauthorized",
      status: 401,
    });
  }
});

test("Auth 5xx responses are service unavailable, never unauthorized", async () => {
  for (const status of [500, 502, 503]) {
    const result = await verifyAuthUser(async () => ({
      data: { user: null },
      error: new AuthApiError("upstream failure", status, "unexpected_failure"),
    }));

    assert.deepEqual(result, {
      ok: false,
      code: "auth_unavailable",
      status: 503,
    });
    assert.equal(
      getAuthUserFailureMessage(result),
      "Usługa logowania jest chwilowo niedostępna. Spróbuj ponownie."
    );
  }
});

test("retryable and network failures are service unavailable", async () => {
  const failures = [
    () =>
      Promise.resolve({
        data: { user: null },
        error: new AuthRetryableFetchError("temporary failure", 0),
      }),
    () => Promise.reject(new TypeError("fetch failed")),
    () =>
      Promise.resolve({
        data: { user: null },
        error: new AuthUnknownError("wrapped fetch failure", new TypeError()),
      }),
  ];

  for (const getUser of failures) {
    const result = await verifyAuthUser(getUser);
    assert.deepEqual(result, {
      ok: false,
      code: "auth_unavailable",
      status: 503,
    });
  }
});

test("unknown Auth errors fail closed as internal errors, not unauthorized", async () => {
  const result = await verifyAuthUser(async () => ({
    data: { user: null },
    error: new AuthError("unknown auth failure"),
  }));

  assert.deepEqual(result, {
    ok: false,
    code: "internal_error",
    status: 500,
  });
});

test("a verified user passes through unchanged", async () => {
  const result = await verifyAuthUser(async () => ({
    data: { user },
    error: null,
  }));

  assert.equal(result.ok, true);
  assert.equal(result.user, user);
});

const authRoutePaths = [
  "../../app/api/create-reservation/route.ts",
  "../../app/api/register-event/route.ts",
  "../../app/api/cancel-event-registration/route.ts",
  "../../app/api/send-reservation-confirmation/route.ts",
  "../../app/api/send-event-registration-confirmation/route.ts",
  "../../app/api/send-reservation-cancellation/route.ts",
  "../../app/api/send-event-reserve-promotion/route.ts",
  "../../app/api/admin/calendar-feed/route.ts",
];

test("every getUser route delegates Auth failures to the shared classifier", async () => {
  for (const routePath of authRoutePaths) {
    const source = await readFile(new URL(routePath, import.meta.url), "utf8");
    assert.match(source, /verifyAuthUser\(\(\) =>/u, routePath);
    assert.match(source, /authResult\.code/u, routePath);
    assert.doesNotMatch(source, /userError\s*\|\|\s*!user/u, routePath);
    if (routePath.endsWith("admin/calendar-feed/route.ts")) {
      assert.match(source, /auth_unavailable[\s\S]*?503/u, routePath);
    } else {
      assert.match(source, /authResult\.status/u, routePath);
    }
  }
});

test("role-gated calendar preserves 403 for users and accepts admins", async () => {
  const source = await readFile(
    new URL("../../app/api/admin/calendar-feed/route.ts", import.meta.url),
    "utf8"
  );
  assert.match(source, /const role = parseCalendarFeedRole\(roleData\)/u);
  assert.match(source, /if \(!role\)[\s\S]*?"forbidden"[\s\S]*?403/u);
});

test("calendar redirects only true 401 responses and treats 503 as a view error", async () => {
  const source = await readFile(
    new URL("../../app/admin/calendar/page.tsx", import.meta.url),
    "utf8"
  );
  assert.match(
    source,
    /response\.status === 401[\s\S]*?router\.replace\("\/login/u
  );
  assert.doesNotMatch(
    source,
    /response\.status === 503[\s\S]*?router\.replace\("\/login/u
  );
  assert.match(source, /!response\.ok[\s\S]*?setViewState\("error"\)/u);
});
