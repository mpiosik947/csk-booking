import { notFound, redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/server/platform-admin";
import { uuid } from "@/lib/platform-wizard";
import { parseConfiguration } from "@/lib/platform-draft-configuration";
import DraftConfigurationWizard from "./DraftConfigurationWizard";
import TenantHandoverPage from "./TenantHandover";
import { readHandover } from "@/lib/platform-handover";

export default async function DraftSetupPage({ params }: { params: Promise<{ id: string }> }) {
  const client = await requirePlatformAdmin(), { id } = await params;
  if (!uuid(id)) notFound();
  const { data } = await client.auth.getUser();
  if (!data?.user) redirect("/login?redirectTo=%2Fplatform-admin");
  const handover = await client.rpc("platform_get_tenant_handover_v1", { p_tenant_id: id });
  const state = handover.error ? null : readHandover(handover.data, id);
  if (!state) notFound();
  if (state.receipt) return <TenantHandoverPage key={id} tenantId={id} actorId={data.user.id} />;
  const result = await client.rpc("platform_get_draft_configuration_v1", { p_tenant_id: id });
  if (result.error || !parseConfiguration(result.data, id)) notFound();
  return <DraftConfigurationWizard key={id} tenantId={id} actorId={data.user.id} />;
}
