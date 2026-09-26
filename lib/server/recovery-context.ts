import { createHash, randomBytes } from "node:crypto";

export const RECOVERY_COOKIE = "st-recovery-context";
export const RECOVERY_TTL = 600;

export function newRecoveryGrant() {
  return randomBytes(32).toString("base64url");
}

export function sessionIdentity(accessToken: string): string | null {
  try {
    // Only call with a Supabase-verified token; this is NOT token validation.
    const payload = JSON.parse(Buffer.from(accessToken.split(".")[1], "base64url").toString());
    return typeof payload.session_id === "string" ? payload.session_id : null;
  } catch { return null; }
}

export function recoveryGrantHash(value: string | undefined): string | null {
  if (!value || !/^[A-Za-z0-9_-]{43}$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  if (bytes.length !== 32 || bytes.toString("base64url") !== value) return null;
  return createHash("sha256").update(bytes).digest("hex");
}

export function validRecoveryQuery(params: URLSearchParams) {
  return params.getAll("token_hash").length === 1 &&
    /^[a-zA-Z0-9_-]{20,512}$/.test(params.get("token_hash") ?? "") &&
    params.getAll("type").length === 1 && params.get("type") === "recovery" &&
    params.getAll("next").length <= 1 &&
    (params.get("next") === null || params.get("next") === "/reset-password") &&
    [...params.keys()].every(key => ["token_hash", "type", "next"].includes(key));
}
