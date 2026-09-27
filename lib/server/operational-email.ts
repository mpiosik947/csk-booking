import "server-only";
import { createClient } from "@supabase/supabase-js";
import { PLATFORM_BASE_URL } from "../platform-domain.ts";
import type { OperationalEmailResource, OperationalEmailTenantContext } from "./operational-email-core.ts";
export { operationalEmailBrand, operationalEmailHistoryUrl, operationalEmailActionUrl } from "./operational-email-core.ts";
export { getOperationalEmailSenderConfiguration } from "./operational-email-config.ts";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const slug = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const unavailable = () => new Error("Operational email context unavailable");

async function resolveOperationalEmailTenantContext(
  resource: OperationalEmailResource,
  read: (type: OperationalEmailResource["resourceType"], id: string) => Promise<unknown>,
): Promise<OperationalEmailTenantContext> {
  if (!resource || Object.keys(resource).sort().join(",") !== "resourceId,resourceType" ||
      !["reservation", "event", "event_registration"].includes(resource.resourceType) ||
      typeof resource.resourceId !== "string" || !uuid.test(resource.resourceId)) throw unavailable();
  const result = await read(resource.resourceType, resource.resourceId);
  if (!Array.isArray(result) || result.length !== 1) throw unavailable();
  const row = result[0];
  if (!row || typeof row !== "object" || Object.keys(row).sort().join(",") !== "display_name,public_slug,tenant_id,tenant_slug" ||
      typeof row.tenant_id !== "string" || !uuid.test(row.tenant_id) ||
      typeof row.tenant_slug !== "string" || !slug.test(row.tenant_slug) ||
      typeof row.public_slug !== "string" || !slug.test(row.public_slug) ||
      typeof row.display_name !== "string" || !row.display_name.trim() ||
      row.display_name.length > 200 || /[\r\n\x00-\x1f\x7f]/.test(row.display_name)) throw unavailable();
  return Object.freeze({ tenantId: row.tenant_id, tenantSlug: row.tenant_slug,
    publicSlug: row.public_slug, displayName: row.display_name.trim(),
    canonicalPublicUrl: `${PLATFORM_BASE_URL}/${row.public_slug}` });
}


type ResourceReader = (type: OperationalEmailResource["resourceType"], id: string) => Promise<unknown>;

/** Server-only injectable reader for tests; production wrappers use the internal RPC reader. */
export function createOperationalEmailResolvers(read: ResourceReader) {
  return Object.freeze({
    resolveReservationEmailTenantContext: (id: string) => resolveOperationalEmailTenantContext({ resourceType: "reservation", resourceId: id }, read),
    resolveEventEmailTenantContext: (id: string) => resolveOperationalEmailTenantContext({ resourceType: "event", resourceId: id }, read),
    resolveEventRegistrationEmailTenantContext: (id: string) => resolveOperationalEmailTenantContext({ resourceType: "event_registration", resourceId: id }, read),
  });
}

async function readResource(type: OperationalEmailResource["resourceType"], id: string) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw unavailable();
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.rpc("resolve_operational_email_tenant_context_v1", {
    p_resource_type: type, p_resource_id: id,
  });
  if (error) throw unavailable();
  return data;
}

// Resource kind is never accepted from endpoint payloads. Authorize the operation first.
export const {
  resolveReservationEmailTenantContext,
  resolveEventEmailTenantContext,
  resolveEventRegistrationEmailTenantContext,
} = createOperationalEmailResolvers(readResource);
