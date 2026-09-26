import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { hostFromRequest, PLATFORM_BASE_URL, PLATFORM_HOST } from "@/lib/platform-domain";
import { RECOVERY_COOKIE } from "./recovery-context";

export function recoveryOrigin(request: NextRequest) {
  const local = process.env.NEXT_PUBLIC_SUPABASE_URL?.startsWith("http://127.0.0.1:") === true;
  const host = hostFromRequest(request.headers.get("host"), local);
  return host === PLATFORM_HOST ? PLATFORM_BASE_URL : host === "localhost" ? new URL(request.url).origin : null;
}

export function protectResponse(response: NextResponse) {
  response.headers.set("Cache-Control", "private, no-store");
  response.headers.set("Referrer-Policy", "no-referrer");
  response.headers.set("X-Robots-Tag", "noindex, nofollow");
  return response;
}

export function recoveryCookieOptions(origin: string) {
  return { httpOnly: true, secure: origin.startsWith("https:"), sameSite: "lax" as const, path: "/auth" };
}

export function clearRecovery(response: NextResponse, origin: string) {
  response.cookies.set(RECOVERY_COOKIE, "", { ...recoveryCookieOptions(origin), maxAge: 0 });
}

export function recoveryClient(request: NextRequest, response: NextResponse) {
  return createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: values => values.forEach(({ name, value, options }) => response.cookies.set(name, value, options)),
    },
  });
}
