import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { hostFromRequest, PLATFORM_BASE_URL, PLATFORM_HOST } from "@/lib/platform-domain";

export async function GET(request: NextRequest) {
  const local = process.env.NEXT_PUBLIC_SUPABASE_URL?.startsWith("http://127.0.0.1:") === true;
  const host = hostFromRequest(request.headers.get("host"), local);
  if (host !== PLATFORM_HOST && host !== "localhost") return new NextResponse("Unavailable", { status: 404 });
  // PKCE completion belongs exclusively to the canonical origin (or explicit local development).
  const origin = host === "localhost" ? new URL(request.url).origin : PLATFORM_BASE_URL;
  const code = request.nextUrl.searchParams.get("code");
  const errorUrl = new URL("/login?confirmationError=1", origin);

  if (!code) {
    return NextResponse.redirect(errorUrl);
  }

  const successUrl = new URL("/dashboard?emailConfirmed=1", origin);
  const response = NextResponse.redirect(successUrl);

  try {
    const supabase = createServerClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      {
        cookies: {
          getAll() {
            return request.cookies.getAll();
          },
          setAll(cookiesToSet) {
            cookiesToSet.forEach(({ name, value, options }) => {
              response.cookies.set(name, value, options);
            });
          },
        },
      }
    );

    const { error } = await supabase.auth.exchangeCodeForSession(code);

    if (error) {
      return NextResponse.redirect(errorUrl);
    }

    return response;
  } catch {
    return NextResponse.redirect(errorUrl);
  }
}
