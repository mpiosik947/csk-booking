import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import {
  ADMIN_ROUTE_PERMISSIONS,
  ADMIN_STAFF_ROLES,
  canRoleAccessAdminRoute,
  isAdminRoutePath,
} from "@/lib/admin/route-protection.js";

type UserRole =
  | "admin"
  | "pracownik"
  | "instruktor"
  | "user";

const LEGACY_CSK_SLUG = "csk";
const SAFE_QUERY_KEYS: Record<string, readonly string[]> = {
  "/admin/calendar": ["view", "date", "laneId"],
  "/admin/check-in": ["date", "attendance", "page"],
  "/admin/reservations": ["date", "search", "status", "payment", "sort", "page"],
  "/admin/events": ["scope", "sort", "q", "page", "participantStatus", "participantPayment", "participantPage"],
  "/admin/reports": ["from", "to", "lane", "bookingType", "status", "payment", "page"],
  "/admin/users": ["role", "status", "sort", "page"],
};

export async function middleware(
  request: NextRequest
) {
  let response = NextResponse.next({
    request,
  });

  const path = request.nextUrl.pathname.replace(/\/$/, "") || "/";

  const isAdminRoute =
    isAdminRoutePath(path);

  if (!isAdminRoute) {
    return response;
  }

  if (path !== "/admin" && !Object.hasOwn(ADMIN_ROUTE_PERMISSIONS, path)) {
    return new NextResponse("Not found", { status: 404 });
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

  const { data: tenants, error: tenantError } = await supabase.rpc(
    "resolve_active_tenant_by_slug_v1", { p_slug: LEGACY_CSK_SLUG }
  );
  const tenant = Array.isArray(tenants) && tenants.length === 1 ? tenants[0] : null;
  if (tenantError || !tenant || tenant.tenant_slug !== LEGACY_CSK_SLUG ||
      tenant.tenant_status !== "active" || typeof tenant.tenant_id !== "string") {
    return NextResponse.redirect(
      new URL(
        "/dashboard",
        request.url
      )
    );
  }

  const { data: membershipRole, error: membershipError } = await supabase.rpc(
    "get_my_tenant_role_v1", { p_tenant_id: tenant.tenant_id }
  );
  const role: UserRole = membershipRole === "employee" ? "pracownik"
    : membershipRole === "instructor" ? "instruktor"
    : membershipRole === "admin" ? "admin" : "user";

  if (membershipError) {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

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

  const destination = new URL(`/t/${LEGACY_CSK_SLUG}${path}`, request.url);
  for (const key of SAFE_QUERY_KEYS[path] ?? []) {
    const values = request.nextUrl.searchParams.getAll(key);
    if (values.length === 1 && /^[a-zA-Z0-9_-]{1,64}$/.test(values[0])) {
      destination.searchParams.set(key, values[0]);
    }
  }
  const redirect = NextResponse.redirect(destination);
  response.cookies.getAll().forEach((cookie) => redirect.cookies.set(cookie));
  return redirect;
}

export const config = {
  matcher: ["/admin/:path*"],
};
