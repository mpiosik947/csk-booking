import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const path = request.nextUrl.pathname;

  const isAdminRoute = path.startsWith("/admin");
  const isAdminUsersRoute = path.startsWith("/admin/users");
  const isAdminReportsRoute = path.startsWith("/admin/reports");

  if (!isAdminRoute) {
    return response;
  }

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => {
            request.cookies.set(name, value);
          });

          response = NextResponse.next({ request });

          cookiesToSet.forEach(({ name, value, options }) => {
            response.cookies.set(name, value, options);
          });
        },
      },
    }
  );

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("redirectTo", path);
    return NextResponse.redirect(loginUrl);
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("role")
    .eq("user_id", user.id)
    .single();

  if (profileError || !profile) {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

  const role = profile.role as UserRole;

  const canAccessAdmin =
    role === "admin" || role === "pracownik" || role === "instruktor";

  if (!canAccessAdmin) {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

  if (isAdminUsersRoute && role !== "admin") {
    return NextResponse.redirect(new URL("/admin", request.url));
  }

  if (isAdminReportsRoute && role !== "admin") {
    return NextResponse.redirect(new URL("/admin", request.url));
  }

  return response;
}

export const config = {
  matcher: ["/admin/:path*"],
};