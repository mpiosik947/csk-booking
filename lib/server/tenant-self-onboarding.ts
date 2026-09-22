import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ROLES = new Set(["user", "admin", "employee", "instructor"]);
const STATUSES = new Set(["active", "pending", "suspended"]);

type OnboardingRow = {
  tenant_id: string;
  user_id: string;
  role: string;
  status: string;
  created: boolean;
};

/** The API must bind the slug to its persisted resource before calling this helper. */
export async function selfOnboardTenantUser(
  client: SupabaseClient,
  tenantSlug: string,
  expectedUserId: string,
): Promise<boolean> {
  const { data, error } = await client.rpc("self_onboard_tenant_v1", {
    p_tenant_slug: tenantSlug,
  });
  if (error || !Array.isArray(data) || data.length !== 1) return false;
  const row = data[0] as Partial<OnboardingRow> | null;
  return Boolean(row && typeof row.tenant_id === "string" && UUID.test(row.tenant_id) &&
    row.user_id === expectedUserId && ROLES.has(row.role ?? "") &&
    STATUSES.has(row.status ?? "") && typeof row.created === "boolean");
}
