import { NextResponse, type NextRequest } from "next/server";
import { RECOVERY_COOKIE, RECOVERY_TTL, sessionIdentity } from "@/lib/server/recovery-context";
import { recoveryGrantMinter } from "@/lib/server/recovery-grant-mint";
import { clearRecovery, protectResponse, recoveryClient, recoveryCookieOptions, recoveryOrigin } from "@/lib/server/recovery-http";

export async function GET(request: NextRequest) {
  const origin = recoveryOrigin(request);
  if (!origin) return protectResponse(new NextResponse("Unavailable", { status: 404 }));
  const failure = protectResponse(NextResponse.redirect(new URL("/reset-password?recoveryError=1", origin), 303));
  clearRecovery(failure, origin);
  const params = request.nextUrl.searchParams;
  const code = params.get("code");
  if (params.getAll("code").length !== 1 || !code || code.length > 512 || [...params.keys()].some(key => key !== "code")) return failure;
  try {
    const mint = recoveryGrantMinter();
    const response = protectResponse(NextResponse.redirect(new URL("/reset-password", origin), 303));
    const client = recoveryClient(request, response);
    const { data, error } = await client.auth.exchangeCodeForSession(code);
    if (error || !data.session || !data.user) return failure;
    // Server-issued AMR, NOT SDK redirectType (which comes from a writable verifier cookie).
    const claims = JSON.parse(Buffer.from(data.session.access_token.split(".")[1], "base64url").toString());
    const recovery = Array.isArray(claims.amr) && claims.amr.some((entry: { method?: string }) => entry.method === "recovery");
    const sessionId = sessionIdentity(data.session.access_token);
    if (!recovery || !sessionId || claims.sub !== data.user.id) return failure;
    response.cookies.set(RECOVERY_COOKIE, await mint(sessionId), {
      ...recoveryCookieOptions(origin), maxAge: RECOVERY_TTL,
    });
    return response;
  } catch { return failure; }
}
