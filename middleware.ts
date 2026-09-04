import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import {
  ADMIN_STAFF_ROLES,
  canRoleAccessAdminRoute,
  isAdminRoutePath,
} from "@/lib/admin/route-protection.js";

type UserRole =
  | "admin"
  | "pracownik"
  | "instruktor"
  | "user";

export async function middleware(
  request: NextRequest
) {
  let response = NextResponse.next({
    request,
  });

  const path =
    request.nextUrl.pathname;

  const isAdminRoute =
    isAdminRoutePath(path);

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
    ADMIN_STAFF_ROLES.includes(role);

  if (!adminAccess) {
    return NextResponse.redirect(
      new URL(
        "/dashboard",
        request.url
      )
    );
  }

  if (!canRoleAccessAdminRoute(path, role)) {
    return NextResponse.redirect(
      new URL(
        "/admin",
        request.url
      )
    );
  }

  return response;
}

export const config = {
  matcher: ["/admin/:path*"],
};
