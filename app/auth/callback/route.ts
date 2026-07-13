import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");
  const errorUrl = new URL("/login?confirmationError=1", request.url);

  if (!code) {
    return NextResponse.redirect(errorUrl);
  }

  const successUrl = new URL("/dashboard?emailConfirmed=1", request.url);
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
