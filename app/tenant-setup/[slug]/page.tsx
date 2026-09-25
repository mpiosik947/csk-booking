import { notFound, redirect } from "next/navigation";
import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import TenantOnboardingSettings from "../TenantOnboardingSettings";

export default async function TenantSetupPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const client = await getTenantRequestClient();
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) redirect("/login");
  // The RPC independently requires active tenant-admin membership, including draft.
  const result = await client.rpc("admin_get_tenant_public_settings_v1", { p_tenant_slug: slug });
  if (result.error || !result.data) notFound();
  return <TenantOnboardingSettings tenantSlug={slug} />;
}
