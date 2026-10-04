import { notFound, redirect } from "next/navigation";
import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import TenantOnboardingSettings from "../TenantOnboardingSettings";
import { isDormantTenant } from "@/lib/setup-discovery";

export default async function TenantSetupPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const client = await getTenantRequestClient();
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) redirect("/login");
  // The RPC independently requires active tenant-admin membership, including draft.
  const result = await client.rpc("admin_get_tenant_public_settings_v1", { p_tenant_slug: slug });
  if (result.error || !result.data) notFound();
  const setup = await client.rpc("get_my_dormant_admin_tenants_v1", {});
  if (setup.error || !Array.isArray(setup.data) || !setup.data.every(isDormantTenant)) notFound();
  const dormant = setup.data.find(row => row.tenant_slug === slug);
  let tenantId: string | null = dormant?.tenant_id ?? null;
  if (!dormant) {
    const active = await client.rpc("get_my_active_tenants_v1", {});
    if (!active.error && Array.isArray(active.data)) tenantId = active.data.find(row => row.tenant_slug === slug)?.tenant_id ?? null;
  }
  return <TenantOnboardingSettings tenantSlug={slug} tenantId={tenantId} dormant={!!dormant} />;
}
