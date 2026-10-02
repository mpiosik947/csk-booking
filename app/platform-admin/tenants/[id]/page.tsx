import { notFound, redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/server/platform-admin";
import { classifyError, readDetail, uuid } from "@/lib/platform-wizard";
import TenantDetail from "./TenantDetail";

export default async function TenantDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const client = await requirePlatformAdmin();
  const { id } = await params;
  if (!uuid(id)) notFound();
  const { data: auth } = await client.auth.getUser();
  if (!auth?.user) redirect("/login?redirectTo=%2Fplatform-admin");
  const { data, error } = await client.rpc("platform_get_tenant_onboarding_detail_v1", { p_tenant_id: id });
  if (error && classifyError(error).kind === "denied") notFound();
  if (!error && data === null) notFound();
  return <TenantDetail id={id} actorId={auth.user.id} initial={error ? null : readDetail(data, id)} />;
}
