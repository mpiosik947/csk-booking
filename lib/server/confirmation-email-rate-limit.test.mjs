import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  checkConfirmationEmailRateLimit,
  getConfirmationRateLimitSecret,
  hashConfirmationRequestIp,
} from "./confirmation-email-rate-limit.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SECRET_A = "a".repeat(32);
const SECRET_B = "b".repeat(32);

function requestWithIp(ipAddress) {
  return new Request("https://example.invalid", {
    headers: ipAddress ? { "x-forwarded-for": ipAddress } : {},
  });
}

test("HMAC is stable lowercase hex and never passes raw IP to RPC", async () => {
  const rawIp = "203.0.113.10";
  const firstHash = hashConfirmationRequestIp(rawIp, SECRET_A);
  const secondHash = hashConfirmationRequestIp(rawIp, SECRET_A);
  let rpcInput = null;

  const outcome = await checkConfirmationEmailRateLimit({
    request: requestWithIp(`${rawIp}, 10.0.0.1`),
    userId: USER_ID,
    secret: SECRET_A,
    nodeEnv: "production",
    rpc: async (ipHash) => {
      rpcInput = ipHash;
      return {
        data: { ok: true, code: "allowed", allowed: true },
        error: null,
      };
    },
  });

  assert.match(firstHash, /^[0-9a-f]{64}$/);
  assert.equal(firstHash, secondHash);
  assert.equal(rpcInput, firstHash);
  assert.notEqual(rpcInput, rawIp);
  assert.deepEqual(outcome, { kind: "allowed" });
});

test("different IP addresses produce different hashes", () => {
  assert.notEqual(
    hashConfirmationRequestIp("203.0.113.10", SECRET_A),
    hashConfirmationRequestIp("203.0.113.11", SECRET_A)
  );
});

test("different secrets produce different hashes", () => {
  assert.notEqual(
    hashConfirmationRequestIp("203.0.113.10", SECRET_A),
    hashConfirmationRequestIp("203.0.113.10", SECRET_B)
  );
});

for (const secret of [null, "too-short"]) {
  test(`missing or short secret fails before RPC: ${String(secret)}`, async () => {
    let rpcCount = 0;
    const outcome = await checkConfirmationEmailRateLimit({
      request: requestWithIp("203.0.113.10"),
      userId: USER_ID,
      secret,
      nodeEnv: "production",
      rpc: async () => {
        rpcCount += 1;
        return { data: null, error: null };
      },
    });

    assert.deepEqual(outcome, { kind: "error" });
    assert.equal(rpcCount, 0);
  });
}

test("secret reader requires at least 32 non-whitespace characters", () => {
  assert.equal(getConfirmationRateLimitSecret({}), null);
  assert.equal(
    getConfirmationRateLimitSecret({
      CONFIRMATION_RATE_LIMIT_IP_SECRET: " ".repeat(32),
    }),
    null
  );
  assert.equal(
    getConfirmationRateLimitSecret({
      CONFIRMATION_RATE_LIMIT_IP_SECRET: SECRET_A,
    }),
    SECRET_A
  );
});

for (const [name, request] of [
  ["missing production IP", requestWithIp(null)],
  ["invalid production IP", requestWithIp("not-an-ip")],
]) {
  test(`${name} fails before RPC`, async () => {
    let rpcCount = 0;
    const outcome = await checkConfirmationEmailRateLimit({
      request,
      userId: USER_ID,
      secret: SECRET_A,
      nodeEnv: "production",
      rpc: async () => {
        rpcCount += 1;
        return { data: null, error: null };
      },
    });

    assert.deepEqual(outcome, { kind: "error" });
    assert.equal(rpcCount, 0);
  });
}

test("development without a forwarded IP uses a controlled loopback", async () => {
  let rpcInput = null;
  const outcome = await checkConfirmationEmailRateLimit({
    request: requestWithIp(null),
    userId: USER_ID,
    secret: SECRET_A,
    nodeEnv: "development",
    rpc: async (ipHash) => {
      rpcInput = ipHash;
      return {
        data: { ok: true, code: "allowed", allowed: true },
        error: null,
      };
    },
  });

  assert.equal(rpcInput, hashConfirmationRequestIp("127.0.0.1", SECRET_A));
  assert.deepEqual(outcome, { kind: "allowed" });
});

test("rate limited contract preserves safe Retry-After", async () => {
  const outcome = await checkConfirmationEmailRateLimit({
    request: requestWithIp("2001:db8::1"),
    userId: USER_ID,
    secret: SECRET_A,
    nodeEnv: "production",
    rpc: async () => ({
      data: {
        ok: true,
        code: "rate_limited",
        allowed: false,
        retry_after_seconds: 123,
      },
      error: null,
    }),
  });

  assert.deepEqual(outcome, {
    kind: "rate_limited",
    retryAfterSeconds: 123,
  });
});

for (const [name, rpcResult] of [
  ["invalid RPC contract", { data: { ok: true }, error: null }],
  ["Supabase RPC error", { data: null, error: { code: "technical" } }],
]) {
  test(`${name} returns a safe error`, async () => {
    const outcome = await checkConfirmationEmailRateLimit({
      request: requestWithIp("203.0.113.10"),
      userId: USER_ID,
      secret: SECRET_A,
      nodeEnv: "production",
      rpc: async () => rpcResult,
    });

    assert.deepEqual(outcome, { kind: "error" });
    assert.equal(JSON.stringify(outcome).includes("technical"), false);
  });
}

test("thrown RPC error returns a safe error", async () => {
  const outcome = await checkConfirmationEmailRateLimit({
    request: requestWithIp("203.0.113.10"),
    userId: USER_ID,
    secret: SECRET_A,
    nodeEnv: "production",
    rpc: async () => {
      throw new Error("raw database detail");
    },
  });

  assert.deepEqual(outcome, { kind: "error" });
  assert.equal(JSON.stringify(outcome).includes("raw database detail"), false);
});

for (const routePath of [
  "../../app/api/send-event-registration-confirmation/route.ts",
  "../../app/api/send-reservation-confirmation/route.ts",
]) {
  test(`${routePath}: limiter precedes business reads and delivery`, async () => {
    const source = await readFile(new URL(routePath, import.meta.url), "utf8");
    const authIndex = source.indexOf("supabase.auth.getUser(accessToken)");
    const unauthorizedIndex = source.indexOf(
      'return jsonError("unauthorized", 401);'
    );
    const secretIndex = source.indexOf("getConfirmationRateLimitSecret()");
    const limiterIndex = source.indexOf("checkConfirmationEmailRateLimit({");
    const ownershipIndex = source.indexOf('.eq("user_id", user.id)');
    const prepareIndex = source.indexOf(
      'supabase.rpc("prepare_confirmation_email"'
    );
    const resendIndex = source.indexOf(
      "new Resend(configuration.resendApiKey)"
    );
    const rateLimitedResponseIndex = source.indexOf(
      'code: "rate_limited"'
    );
    const completeIndex = source.indexOf(
      'completionClient.rpc("complete_confirmation_email"'
    );

    assert.notEqual(authIndex, -1);
    assert.notEqual(unauthorizedIndex, -1);
    assert.notEqual(secretIndex, -1);
    assert.notEqual(limiterIndex, -1);
    assert.notEqual(ownershipIndex, -1);
    assert.notEqual(prepareIndex, -1);
    assert.notEqual(resendIndex, -1);
    assert.notEqual(rateLimitedResponseIndex, -1);
    assert.notEqual(completeIndex, -1);
    assert.equal(unauthorizedIndex < limiterIndex, true);
    assert.equal(authIndex < secretIndex, true);
    assert.equal(secretIndex < limiterIndex, true);
    assert.equal(limiterIndex < ownershipIndex, true);
    assert.equal(rateLimitedResponseIndex < ownershipIndex, true);
    assert.equal(ownershipIndex < resendIndex, true);
    assert.equal(resendIndex < prepareIndex, true);
    assert.equal(rateLimitedResponseIndex < completeIndex, true);
    assert.match(source, /"Retry-After": String\(.+retryAfterSeconds/);
    assert.match(source, /"Cache-Control": "no-store"/);
  });
}
