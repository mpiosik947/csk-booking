import { createHmac } from "node:crypto";
import { isIP } from "node:net";

type RpcCallResult = {
  data: unknown;
  error: unknown;
};

type RateLimitDependencies = {
  request: Pick<Request, "headers">;
  userId: string;
  secret: string | null;
  rpc: (ipHash: string) => Promise<RpcCallResult>;
  nodeEnv?: string;
};

export type ConfirmationEmailRateLimitOutcome =
  | { kind: "allowed" }
  | { kind: "rate_limited"; retryAfterSeconds: number }
  | { kind: "error" };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HMAC_PATTERN = /^[0-9a-f]{64}$/;

export function getConfirmationRateLimitSecret(
  environment: NodeJS.ProcessEnv = process.env
) {
  const secret = environment.CONFIRMATION_RATE_LIMIT_IP_SECRET?.trim();
  return secret && secret.length >= 32 ? secret : null;
}

export function getConfirmationRequestIp(
  request: Pick<Request, "headers">,
  nodeEnv: string | undefined = process.env.NODE_ENV
) {
  const forwardedFor = request.headers.get("x-forwarded-for");

  if (!forwardedFor) {
    return nodeEnv === "production" ? null : "127.0.0.1";
  }

  const firstAddress = forwardedFor.split(",", 1)[0]?.trim();
  return firstAddress && isIP(firstAddress) !== 0 ? firstAddress : null;
}

export function hashConfirmationRequestIp(ipAddress: string, secret: string) {
  return createHmac("sha256", secret).update(ipAddress).digest("hex");
}

function parseRateLimitResult(
  value: unknown
): ConfirmationEmailRateLimitOutcome {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { kind: "error" };
  }

  const result = value as Record<string, unknown>;

  if (
    result.ok === true &&
    result.code === "allowed" &&
    result.allowed === true
  ) {
    return { kind: "allowed" };
  }

  if (
    result.ok === true &&
    result.code === "rate_limited" &&
    result.allowed === false &&
    Number.isInteger(result.retry_after_seconds) &&
    (result.retry_after_seconds as number) >= 1 &&
    (result.retry_after_seconds as number) <= 600
  ) {
    return {
      kind: "rate_limited",
      retryAfterSeconds: result.retry_after_seconds as number,
    };
  }

  return { kind: "error" };
}

export async function checkConfirmationEmailRateLimit({
  request,
  userId,
  secret,
  rpc,
  nodeEnv = process.env.NODE_ENV,
}: RateLimitDependencies): Promise<ConfirmationEmailRateLimitOutcome> {
  if (!UUID_PATTERN.test(userId) || !secret || secret.length < 32) {
    return { kind: "error" };
  }

  const ipAddress = getConfirmationRequestIp(request, nodeEnv);

  if (!ipAddress) {
    return { kind: "error" };
  }

  const ipHash = hashConfirmationRequestIp(ipAddress, secret);

  if (!HMAC_PATTERN.test(ipHash)) {
    return { kind: "error" };
  }

  let rateLimitResult: RpcCallResult;

  try {
    rateLimitResult = await rpc(ipHash);
  } catch {
    return { kind: "error" };
  }

  if (rateLimitResult.error) {
    return { kind: "error" };
  }

  return parseRateLimitResult(rateLimitResult.data);
}
