import { getTenantPublicAccess } from "@/lib/server/tenant-public-access";
import type { PublicTenantLanding as Tenant } from "@/lib/server/public-tenant-directory";
import { PublicTenantLanding as Landing } from "./PublicTenantLanding";
import PublicAccessSessionBoundary from "./PublicAccessSessionBoundary";
import TenantComingSoon from "./TenantComingSoon";
import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import { readPublicPartners } from "@/lib/tenant-partners";

export async function PublicTenantLanding({ tenant, customDomain = false }: {
  tenant: Tenant; customDomain?: boolean;
}) {
  const access = await getTenantPublicAccess(tenant.publicSlug);
  const result = access?.allowed ? await (await getTenantRequestClient()).rpc("get_public_tenant_partners_v1", { p_public_slug: tenant.publicSlug }) : null;
  const partners = result && !result.error ? readPublicPartners(result.data) ?? [] : [];
  const content = access?.allowed
    ? <Landing tenant={tenant} customDomain={customDomain} partners={partners} />
    : <TenantComingSoon name={tenant.name} unavailable={!access} customDomain={customDomain} />;
  return customDomain ? content : <PublicAccessSessionBoundary>{content}</PublicAccessSessionBoundary>;
}
