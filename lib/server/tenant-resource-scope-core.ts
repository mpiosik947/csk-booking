import type { SupabaseClient } from "@supabase/supabase-js";

type ResourceTable = "shooting_lanes" | "events" | "reservations" | "event_registrations";
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

/** A browser-supplied slug is a selector, never authority: compare it to persisted ownership. */
export async function tenantResourceMatches(
  client: SupabaseClient,
  slug: string,
  table: ResourceTable,
  resourceId: string,
): Promise<boolean> {
  if (slug.length < 2 || slug.length > 63 || !SLUG.test(slug)) return false;
  const { data: tenants, error: tenantError } = await client.rpc("resolve_active_tenant_by_slug_v1", {
    p_slug: slug,
  });
  if (tenantError || !Array.isArray(tenants) || tenants.length !== 1) return false;
  const tenantId: unknown = tenants[0]?.tenant_id;
  if (typeof tenantId !== "string") return false;
  const { data: resource, error: resourceError } = await client
    .from(table).select("tenant_id").eq("id", resourceId).maybeSingle();
  return !resourceError && resource?.tenant_id === tenantId;
}
