import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  deliverConfirmationEmail,
  getConfirmationEmailConfiguration,
} from "./confirmation-email-delivery.ts";

const MESSAGE_TYPES = [
  "event_registration_confirmation",
  "reservation_confirmation",
  "reservation_cancellation",
];
const CLAIM_ID = "11111111-1111-4111-8111-111111111111";
const DELIVERY_ID = "22222222-2222-4222-8222-222222222222";

function ready(messageType) {
  const idempotencyKey = `confirmation/${messageType}/${DELIVERY_ID}`;

  return {
    idempotencyKey,
    result: {
      data: {
        ok: true,
        changed: true,
        code: "ready",
        claim_id: CLAIM_ID,
        delivery_id: DELIVERY_ID,
        idempotency_key: idempotencyKey,
      },
      error: null,
    },
  };
}

for (const messageType of MESSAGE_TYPES) {
  test(`${messageType}: ready sends once and completes success`, async () => {
    const preparation = ready(messageType);
    const sentKeys = [];
    const completions = [];

    const outcome = await deliverConfirmationEmail({
      prepare: async () => preparation.result,
      send: async (idempotencyKey) => {
        sentKeys.push(idempotencyKey);
        return { data: { id: "provider-message-id" }, error: null };
      },
      complete: async (input) => {
        completions.push(input);
        return {
          data: { ok: true, changed: true, code: "sent" },
          error: null,
        };
      },
    });

    assert.deepEqual(outcome, { ok: true, code: "sent", status: 200 });
    assert.deepEqual(sentKeys, [preparation.idempotencyKey]);
    assert.deepEqual(completions, [
      {
        p_claim_id: CLAIM_ID,
        p_success: true,
        p_provider_message_id: "provider-message-id",
        p_error_code: null,
      },
    ]);
  });

  for (const [code, status, ok] of [
    ["already_sent", 200, true],
    ["in_progress", 409, false],
    ["attempt_limit_reached", 429, false],
    ["unauthorized", 401, false],
    ["not_found", 404, false],
    ["invalid_status", 409, false],
  ]) {
    test(`${messageType}: ${code} does not send`, async () => {
      let sendCount = 0;
      let completeCount = 0;

      const outcome = await deliverConfirmationEmail({
        prepare: async () => ({
          data: { ok, changed: false, code },
          error: null,
        }),
        send: async () => {
          sendCount += 1;
          return { data: { id: "unexpected" }, error: null };
        },
        complete: async () => {
          completeCount += 1;
          return { data: null, error: null };
        },
      });

      assert.deepEqual(outcome, { ok, code, status });
      assert.equal(sendCount, 0);
      assert.equal(completeCount, 0);
    });
  }

  test(`${messageType}: provider error completes safe failure`, async () => {
    const completions = [];

    const outcome = await deliverConfirmationEmail({
      prepare: async () => ready(messageType).result,
      send: async () => ({
        data: null,
        error: {
          statusCode: 422,
          code: "validation_error",
          message: "recipient email address is invalid",
        },
      }),
      complete: async (input) => {
        completions.push(input);
        return {
          data: { ok: true, changed: true, code: "failed" },
          error: null,
        };
      },
    });

    assert.deepEqual(outcome, {
      ok: false,
      code: "delivery_failed",
      status: 502,
    });
    assert.deepEqual(completions, [
      {
        p_claim_id: CLAIM_ID,
        p_success: false,
        p_provider_message_id: null,
        p_error_code: "invalid_recipient",
      },
    ]);
  });

  for (const providerData of [null, {}]) {
    test(`${messageType}: missing provider id completes safe failure`, async () => {
      let sendCount = 0;
      const completions = [];

      const outcome = await deliverConfirmationEmail({
        prepare: async () => ready(messageType).result,
        send: async () => {
          sendCount += 1;
          return { data: providerData, error: null };
        },
        complete: async (input) => {
          completions.push(input);
          return {
            data: { ok: true, changed: true, code: "failed" },
            error: null,
          };
        },
      });

      assert.deepEqual(outcome, {
        ok: false,
        code: "delivery_failed",
        status: 502,
      });
      assert.equal(sendCount, 1);
      assert.deepEqual(completions, [
        {
          p_claim_id: CLAIM_ID,
          p_success: false,
          p_provider_message_id: null,
          p_error_code: "unexpected_error",
        },
      ]);
    });
  }

  test(`${messageType}: API key error is a provider error`, async () => {
    const completions = [];

    const outcome = await deliverConfirmationEmail({
      prepare: async () => ready(messageType).result,
      send: async () => ({
        data: null,
        error: {
          statusCode: 400,
          code: "invalid_api_key",
          message: "raw provider configuration detail",
        },
      }),
      complete: async (input) => {
        completions.push(input);
        return {
          data: { ok: true, changed: true, code: "failed" },
          error: null,
        };
      },
    });

    assert.equal(outcome.code, "delivery_failed");
    assert.equal(completions[0].p_error_code, "email_provider_error");
    assert.notEqual(completions[0].p_error_code, "invalid_recipient");
  });

  test(`${messageType}: completion failure never resends`, async () => {
    let sendCount = 0;

    const outcome = await deliverConfirmationEmail({
      prepare: async () => ready(messageType).result,
      send: async () => {
        sendCount += 1;
        return { data: { id: "provider-message-id" }, error: null };
      },
      complete: async () => ({
        data: null,
        error: { code: "database-raw-detail" },
      }),
    });

    assert.deepEqual(outcome, {
      ok: false,
      code: "internal_error",
      status: 500,
    });
    assert.equal(sendCount, 1);
    assert.equal(
      JSON.stringify(outcome).includes("database-raw-detail"),
      false
    );
  });
}

test("missing configuration is rejected before delivery dependencies", () => {
  const completeEnvironment = {
    RESEND_API_KEY: "test-resend-key",
    RESERVATION_EMAIL_FROM: "CSK Test <test@example.invalid>",
    NEXT_PUBLIC_SUPABASE_URL: "https://example.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  };

  assert.notEqual(
    getConfirmationEmailConfiguration(completeEnvironment),
    null
  );

  for (const key of Object.keys(completeEnvironment)) {
    const incompleteEnvironment = { ...completeEnvironment };
    delete incompleteEnvironment[key];
    assert.equal(getConfirmationEmailConfiguration(incompleteEnvironment), null);
  }
});

for (const routePath of [
  "../../app/api/send-event-registration-confirmation/route.ts",
  "../../app/api/send-reservation-confirmation/route.ts",
  "../../app/api/send-reservation-cancellation/route.ts",
]) {
  test(`${routePath}: auth and ownership checks precede prepare`, async () => {
    const source = await readFile(new URL(routePath, import.meta.url), "utf8");
    const authIndex = source.indexOf("supabase.auth.getUser(accessToken)");
    const ownershipIndex = source.indexOf('.eq("user_id", user.id)');
    const prepareIndex = source.indexOf(
      'supabase.rpc("prepare_confirmation_email"'
    );
    const configurationIndex = source.indexOf(
      "getConfirmationEmailConfiguration()"
    );
    const configurationFailureIndex = source.indexOf(
      'return jsonError("internal_error", 500);',
      configurationIndex
    );
    const resendIndex = source.indexOf(
      "new Resend(configuration.resendApiKey)"
    );
    const serviceRoleIndex = source.indexOf(
      "getConfirmationServiceRoleClient(configuration)"
    );
    const rateLimitIndex = source.indexOf(
      "checkConfirmationEmailRateLimit({"
    );

    assert.notEqual(authIndex, -1);
    assert.notEqual(ownershipIndex, -1);
    assert.notEqual(prepareIndex, -1);
    assert.notEqual(configurationIndex, -1);
    assert.notEqual(configurationFailureIndex, -1);
    assert.notEqual(resendIndex, -1);
    assert.notEqual(serviceRoleIndex, -1);
    assert.notEqual(rateLimitIndex, -1);
    assert.equal(authIndex < configurationIndex, true);
    assert.equal(configurationIndex < configurationFailureIndex, true);
    assert.equal(configurationFailureIndex < serviceRoleIndex, true);
    assert.equal(serviceRoleIndex < rateLimitIndex, true);
    assert.equal(rateLimitIndex < ownershipIndex, true);
    assert.equal(ownershipIndex < resendIndex, true);
    assert.equal(resendIndex < prepareIndex, true);
    assert.equal(serviceRoleIndex < prepareIndex, true);
    assert.equal(
      source.match(/new Resend\(configuration\.resendApiKey\)/g)?.length,
      1
    );
    assert.equal(
      source.match(/getConfirmationServiceRoleClient\(configuration\)/g)
        ?.length,
      1
    );
  });
}
