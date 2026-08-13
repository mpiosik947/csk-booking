import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

type UserRole =
  | "admin"
  | "pracownik"
  | "instruktor"
  | "user";

const routePermissions: Record<string, UserRole[]> = {
  "/admin/users": ["admin", "pracownik"],

  "/admin/reports": ["admin"],

  "/admin/reservations": [
    "admin",
    "pracownik",
  ],

  "/admin/lane-blocks": [
    "admin",
    "pracownik",
  ],

  "/admin/calendar": [
    "admin",
    "pracownik",
    "instruktor",
  ],

  "/admin/check-in": [
    "admin",
    "pracownik",
  ],

  "/admin/events": [
    "admin",
    "pracownik",
    "instruktor",
  ],
};

export async function middleware(
  request: NextRequest
) {
  let response = NextResponse.next({
    request,
  });

  const path =
    request.nextUrl.pathname;

  const isAdminRoute =
    path.startsWith("/admin");

  if (!isAdminRoute) {
    return response;
  }

  const supabase =
    createServerClient(
      process.env
        .NEXT_PUBLIC_SUPABASE_URL!,
      process.env
        .NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      {
        cookies: {
          getAll() {
            return request.cookies.getAll();
          },

          setAll(cookiesToSet) {
            cookiesToSet.forEach(
              ({ name, value }) => {
                request.cookies.set(
                  name,
                  value
                );
              }
            );

            response =
              NextResponse.next({
                request,
              });

            cookiesToSet.forEach(
              ({
                name,
                value,
                options,
              }) => {
                response.cookies.set(
                  name,
                  value,
                  options
                );
              }
            );
          },
        },
      }
    );

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    const loginUrl = new URL(
      "/login",
      request.url
    );

    loginUrl.searchParams.set(
      "redirectTo",
      path
    );

    return NextResponse.redirect(
      loginUrl
    );
  }

  const {
    data: profile,
    error: profileError,
  } = await supabase
    .from("profiles")
    .select("role")
    .eq("user_id", user.id)
    .maybeSingle();

  if (
    profileError ||
    !profile?.role
  ) {
    return NextResponse.redirect(
      new URL(
        "/dashboard",
        request.url
      )
    );
  }

  const role =
    String(profile.role)
      .trim()
      .toLowerCase() as UserRole;

  const adminAccess =
    role === "admin" ||
    role === "pracownik" ||
    role === "instruktor";

  if (!adminAccess) {
    return NextResponse.redirect(
      new URL(
        "/dashboard",
        request.url
      )
    );
  }

  for (const route in routePermissions) {
    if (path.startsWith(route)) {
      const allowedRoles =
        routePermissions[route];

      if (
        !allowedRoles.includes(role)
      ) {
        return NextResponse.redirect(
          new URL(
            "/admin",
            request.url
          )
        );
      }
    }
  }

  return response;
}

export const config = {
  matcher: ["/admin/:path*"],
};
