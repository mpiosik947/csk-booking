import { NextResponse, type NextRequest } from "next/server";
import { RECOVERY_COOKIE, sessionIdentity, recoveryGrantHash } from "@/lib/server/recovery-context";
import { clearRecovery, protectResponse, recoveryClient, recoveryOrigin } from "@/lib/server/recovery-http";
import { getPasswordLengthError } from "@/lib/password-policy";

async function handle(request: NextRequest, update: boolean) {
  const origin = recoveryOrigin(request);
  const deny = () => protectResponse(NextResponse.json({ ok: false }, { status: 403 }));
  if (!origin || (update && request.headers.get("origin") !== origin)) return deny();
  let claimAttempted = false;
  const freshLink = (code?: "same_password") => {
    const failed = protectResponse(NextResponse.json({ ok: false, status: "fresh_recovery_link_required", ...(code ? { code } : {}) }, { status: 400 }));
    clearRecovery(failed, origin);
    return failed;
  };
  try {
    const response = protectResponse(NextResponse.json({ ok: true }));
    const client = recoveryClient(request, response);
    const { data: { session } } = await client.auth.getSession();
    if (!session) return deny();
    // Supabase verifies the exact token used for the session binding.
    const { data: { user }, error } = await client.auth.getUser(session.access_token);
    const sessionId = sessionIdentity(session.access_token);
    const hash = recoveryGrantHash(request.cookies.get(RECOVERY_COOKIE)?.value);
    if (error || !user || !sessionId || !hash) return deny();
    if (!update) {
      const checked = await client.rpc("check_recovery_grant_v1", { p_grant_hash: hash });
      return !checked.error && checked.data === true ? response : deny();
    }
    if (!request.headers.get("content-type")?.startsWith("application/json")) return deny();
    const body = await request.text();
    if (body.length > 4096) return deny();
    const { password } = JSON.parse(body);
    if (typeof password !== "string" || getPasswordLengthError(password)) return deny();
    claimAttempted = true;
    const consumed = await client.rpc("consume_recovery_grant_v1", { p_grant_hash: hash });
    if (consumed.error) return freshLink();
    if (consumed.data !== true) {
      const failed = deny();
      clearRecovery(failed, origin);
      return failed;
    }
    clearRecovery(response, origin);
    const result = await client.auth.updateUser({ password });
    if (result.error) return freshLink(result.error.code === "same_password" ? "same_password" : undefined);
    let cleanupFailed = false;
    try {
      const cleanup = await client.auth.signOut({ scope: "local" });
      cleanupFailed = Boolean(cleanup.error);
    } catch { cleanupFailed = true; }
    if (cleanupFailed) {
      const partial = protectResponse(NextResponse.json({ ok: false, status: "password_changed_session_cleanup_failed" }, { status: 503 }));
      response.cookies.getAll().forEach(cookie => partial.cookies.set(cookie));
      clearRecovery(partial, origin);
      return partial;
    }
    return response;
  } catch { return claimAttempted ? freshLink() : deny(); }
}

export async function GET(request: NextRequest) { return handle(request, false); }
export async function POST(request: NextRequest) { return handle(request, true); }
