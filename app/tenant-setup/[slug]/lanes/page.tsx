import { notFound, redirect } from "next/navigation";
import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import { isDormantTenant } from "@/lib/setup-discovery";
import AdminLaneConfigurationPage from "@/app/admin/lane-configuration/page";

export default async function DormantLaneSetup({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const client = await getTenantRequestClient();
  const auth = await client.auth.getUser();
  if (auth.error || !auth.data?.user) redirect("/login");
  const rows = await client.rpc("get_my_dormant_admin_tenants_v1", {});
  if (rows.error || !Array.isArray(rows.data) || !rows.data.every(isDormantTenant)) notFound();
  const tenant = rows.data.find(row => row.tenant_slug === slug);
  if (!tenant) notFound();
  // The existing setup RPC independently rechecks dormant admin authority and booking feature.
  const configuration = await client.rpc("tenant_setup_get_lane_configuration_v1", { p_tenant_id: tenant.tenant_id });
  if (configuration.error || !configuration.data) notFound();
  return <AdminLaneConfigurationPage tenantId={tenant.tenant_id} tenantSlug={slug} dormantSetup />;
}
