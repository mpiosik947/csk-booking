import { NextResponse, type NextRequest } from "next/server";
import { RECOVERY_COOKIE, RECOVERY_TTL, sessionIdentity, validRecoveryQuery } from "@/lib/server/recovery-context";
import { recoveryGrantMinter } from "@/lib/server/recovery-grant-mint";
import { clearRecovery, protectResponse, recoveryClient, recoveryCookieOptions, recoveryOrigin } from "@/lib/server/recovery-http";

export async function GET(request: NextRequest) {
  const origin = recoveryOrigin(request);
  if (!origin) return protectResponse(new NextResponse("Unavailable", { status: 404 }));
  const failure = protectResponse(NextResponse.redirect(new URL("/reset-password?recoveryError=1", origin), 303));
  clearRecovery(failure, origin);
  if (!validRecoveryQuery(request.nextUrl.searchParams)) return failure;
  try {
    const mint = recoveryGrantMinter();
    const response = protectResponse(NextResponse.redirect(new URL("/reset-password", origin), 303));
    const client = recoveryClient(request, response);
    const { data, error } = await client.auth.verifyOtp({
      token_hash: request.nextUrl.searchParams.get("token_hash")!, type: "recovery",
    });
    if (error || !data.session || !data.user) return failure;
    const sessionId = sessionIdentity(data.session.access_token);
    if (!sessionId) return failure;
    response.cookies.set(RECOVERY_COOKIE, await mint(sessionId), {
      ...recoveryCookieOptions(origin), maxAge: RECOVERY_TTL,
    });
    return response;
  } catch { return failure; }
}
