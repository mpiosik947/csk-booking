import { getTenantPublicAccess } from "@/lib/server/tenant-public-access";
import type { PublicTenantLanding as Tenant } from "@/lib/server/public-tenant-directory";
import { PublicTenantLanding as Landing } from "./PublicTenantLanding";
import PublicAccessSessionBoundary from "./PublicAccessSessionBoundary";
import TenantComingSoon from "./TenantComingSoon";

export async function PublicTenantLanding({ tenant, customDomain = false }: {
  tenant: Tenant; customDomain?: boolean;
}) {
  const access = await getTenantPublicAccess(tenant.publicSlug);
  const content = access?.allowed
    ? <Landing tenant={tenant} customDomain={customDomain} />
    : <TenantComingSoon name={tenant.name} unavailable={!access} customDomain={customDomain} />;
  return customDomain ? content : <PublicAccessSessionBoundary>{content}</PublicAccessSessionBoundary>;
}
