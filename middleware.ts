import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { hostFromRequest, isLegacyAuthHost, PLATFORM_BASE_URL, PLATFORM_HOST, platformUrl } from "@/lib/platform-domain";
import { getSafeLoginRedirect } from "@/lib/safe-login-redirect";
import { customOperationalDestination, isCustomPublicPath } from "@/lib/domain-routing";
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
  // Host is only a public selector. Forwarded/X-Forwarded-Host are never authority.
  // Production must serve this deployment only through Vercel's verified domain binding.
  const local = process.env.NEXT_PUBLIC_SUPABASE_URL?.startsWith("http://127.0.0.1:") === true;
  const host = hostFromRequest(request.headers.get("host"), local);
  const requestedPath = request.nextUrl.pathname;
  const safeOrigin = host === "localhost" ? new URL(request.url).origin : PLATFORM_BASE_URL;
  const unavailable = () => new NextResponse("Not found", { status: 404, headers: { "Cache-Control": "private, no-store" } });
  if (!host || requestedPath.startsWith("/domain-view.internal/")) return unavailable();
  if (host === `www.${PLATFORM_HOST}`) {
    if (!['GET', 'HEAD'].includes(request.method)) return unavailable();
    return NextResponse.redirect(platformUrl(requestedPath), 308);
  }
  if (isLegacyAuthHost(host)) {
    if (!['GET', 'HEAD'].includes(request.method)) return unavailable();
    // Legacy codes/tokens are never completed or forwarded across origins.
    const path = requestedPath === "/auth/callback" ? "/login" : requestedPath === "/reset-password" ? "/forgot-password" : requestedPath;
    const destination = new URL(platformUrl(path));
    if (path === "/login" && requestedPath === "/login") {
      destination.searchParams.set("redirectTo", getSafeLoginRedirect(request.nextUrl.searchParams.get("redirectTo")));
    }
    // Next normalizes an empty fragment away; a fixed marker prevents token inheritance.
    return NextResponse.redirect(`${destination.toString()}#canonical`, 307);
  }
  if (host !== PLATFORM_HOST && host !== "localhost") {
    if (!['GET', 'HEAD'].includes(request.method)) return unavailable();
    const client = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await client.rpc("resolve_public_tenant_domain_v1", { p_hostname: host });
    if (error || !data || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(data.tenant_slug ?? "")) return unavailable();
    if (isCustomPublicPath(requestedPath)) {
      // Use the unnormalized framework server origin, NOT a caller-supplied host,
      // to keep this an internal route rewrite rather than an outbound proxy request.
      const url = new URL(request.url);
      url.pathname = `/domain-view.internal/${host}${requestedPath === "/" ? "" : requestedPath}`;
      url.search = "";
      const headers = new Headers(request.headers);
      headers.delete("cookie");
      headers.delete("authorization");
      headers.delete("x-forwarded-host");
      headers.delete("forwarded");
      const rewritten = NextResponse.rewrite(url, { request: { headers } });
      rewritten.headers.set("Cache-Control", "private, no-store, max-age=0");
      return rewritten;
    }
    const destination = customOperationalDestination(requestedPath, data.tenant_slug);
    return destination ? NextResponse.redirect(destination, 307) : unavailable();
  }
  // Existing platform-only compatibility aliases; never used to resolve a custom host.
  if (requestedPath === "/reset-password" && request.nextUrl.searchParams.has("code")) {
    // Intercept before any browser SDK mounts; only this server handler exchanges PKCE.
    const legacy = new URL(request.url);
    legacy.pathname = "/auth/recovery/legacy";
    const rewritten = NextResponse.rewrite(legacy);
    rewritten.headers.set("Cache-Control", "private, no-store");
    rewritten.headers.set("Referrer-Policy", "no-referrer");
    return rewritten;
  }
  if (["/booking", "/events", "/my-reservations", "/my-events"].includes(requestedPath)) {
    return NextResponse.redirect(new URL(`/t/csk${requestedPath}`, safeOrigin));
  }
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
      safeOrigin
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
        safeOrigin
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
    return NextResponse.redirect(new URL("/dashboard", safeOrigin));
  }

  const adminAccess =
    ADMIN_STAFF_ROLES.includes(role);

  if (!adminAccess) {
    return NextResponse.redirect(
      new URL(
        "/dashboard",
        safeOrigin
      )
    );
  }

  if (!canRoleAccessAdminRoute(path, role)) {
    return NextResponse.redirect(
      new URL(
        "/admin",
        safeOrigin
      )
    );
  }

  const destination = new URL(`/t/${LEGACY_CSK_SLUG}${path}`, safeOrigin);
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
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|webp|ico|woff2)$).*)"],
};
