import "server-only";

/** Dependency-injected tenant contracts. Routes import the guarded facade. */

const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const STAFF_ROLES = new Set(["admin", "employee", "instructor"]);

export type TenantContext = Readonly<{
  tenantId: string;
  slug: string;
  name: string;
  status: "active";
}>;

export type AuthenticatedTenantContext = Readonly<{
  tenant: TenantContext;
  userId: string;
}>;

export type StaffTenantContext = AuthenticatedTenantContext & Readonly<{
  role: "admin" | "employee" | "instructor";
}>;

type RpcResult = { data: unknown; error: unknown };
type AuthResult = {
  data: { user: { id: string } | null } | null;
  error: unknown;
};

/** Pass a request-scoped, anon-key Supabase server client; never service_role. */
export type TenantContextClient = {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<RpcResult>;
  auth: { getUser(): PromiseLike<AuthResult> };
};

export type ContextResult<T> =
  | Readonly<{ ok: true; value: T }>
  | Readonly<{ ok: false; code: "not_found" | "unauthorized" | "forbidden" }>;

export function isCanonicalTenantSlug(value: unknown): value is string {
  return typeof value === "string" &&
    value.length >= 2 && value.length <= 63 && SLUG.test(value);
}

/** Parses a canonical path selector, never a query string or cookie. */
export function tenantSlugFromPath(pathname: string): string | null {
  const match = /^\/t\/([^/?#]+)(?:\/|$)/.exec(pathname);
  return match && isCanonicalTenantSlug(match[1]) ? match[1] : null;
}

/** RPC itself rechecks active status; the returned ID is context, not a grant. */
export async function resolvePublicTenantContext(
  client: TenantContextClient,
  slug: unknown,
): Promise<ContextResult<TenantContext>> {
  if (!isCanonicalTenantSlug(slug)) return { ok: false, code: "not_found" };
  try {
    const { data, error } = await client.rpc("resolve_active_tenant_by_slug_v1", {
      p_slug: slug,
    });
    if (error || !Array.isArray(data) || data.length !== 1) {
      return { ok: false, code: "not_found" };
    }
    const row = data[0];
    if (!row || typeof row !== "object" || Array.isArray(row) ||
        Object.keys(row).sort().join(",") !== "tenant_id,tenant_name,tenant_slug,tenant_status") {
      return { ok: false, code: "not_found" };
    }
    const { tenant_id: tenantId, tenant_slug: tenantSlug, tenant_name: name,
      tenant_status: status } = row;
    if (typeof tenantId !== "string" || !UUID.test(tenantId) ||
        tenantSlug !== slug || status !== "active" || typeof name !== "string" ||
        name !== name.trim() || name.length < 1 || name.length > 120) {
      return { ok: false, code: "not_found" };
    }
    return { ok: true, value: { tenantId, slug, name, status } };
  } catch {
    return { ok: false, code: "not_found" };
  }
}

/** Ordinary customer context: Auth identity, not automatic tenant membership. */
export async function resolveAuthenticatedTenantContext(
  client: TenantContextClient,
  slug: unknown,
): Promise<ContextResult<AuthenticatedTenantContext>> {
  const tenant = await resolvePublicTenantContext(client, slug);
  if (!tenant.ok) return tenant;
  try {
    const { data, error } = await client.auth.getUser();
    const userId = data?.user?.id;
    if (error || typeof userId !== "string" || !UUID.test(userId)) {
      return { ok: false, code: "unauthorized" };
    }
    return { ok: true, value: { tenant: tenant.value, userId } };
  } catch {
    return { ok: false, code: "unauthorized" };
  }
}

/** Membership is checked by the existing DB helper for this resolved tenant. */
export async function resolveStaffTenantContext(
  client: TenantContextClient,
  slug: unknown,
  allowedRoles: readonly ("admin" | "employee" | "instructor")[],
): Promise<ContextResult<StaffTenantContext>> {
  const actor = await resolveAuthenticatedTenantContext(client, slug);
  if (!actor.ok) return actor;
  if (allowedRoles.length === 0 || allowedRoles.some((role) => !STAFF_ROLES.has(role))) {
    return { ok: false, code: "forbidden" };
  }
  try {
    const { data, error } = await client.rpc("get_my_tenant_role_v1", {
      p_tenant_id: actor.value.tenant.tenantId,
    });
    if (error || typeof data !== "string" ||
        !allowedRoles.includes(data as StaffTenantContext["role"])) {
      return { ok: false, code: "forbidden" };
    }
    return {
      ok: true,
      value: { ...actor.value, role: data as StaffTenantContext["role"] },
    };
  } catch {
    return { ok: false, code: "forbidden" };
  }
}

/** `loadPersistedTenant` must read the actual resource under server/DB scope. */
export async function resourceBelongsToTenant(
  tenant: TenantContext,
  loadPersistedTenant: () => Promise<string | null>,
): Promise<boolean> {
  try {
    const resourceTenant = await loadPersistedTenant();
    return typeof resourceTenant === "string" &&
      UUID.test(resourceTenant) && resourceTenant === tenant.tenantId;
  } catch {
    return false;
  }
}
