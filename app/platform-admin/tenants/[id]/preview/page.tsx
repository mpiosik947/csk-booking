import { notFound } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/server/platform-admin";
import { readLanding } from "@/lib/server/public-tenant-directory";
import { PublicTenantLanding } from "@/app/_components/PublicTenantLanding";

export default async function PreviewPage({ params }: { params: Promise<{ id: string }> }) {
  const client = await requirePlatformAdmin();
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { data, error } = await client.rpc("platform_preview_tenant_v1", { p_tenant_id: id });
  const tenant = error ? null : readLanding(data);
  if (!tenant) notFound();
  return <><p className="bg-amber-950 p-4 text-center text-amber-100">Prywatny podgląd. Nie publikuje obiektu i nie nadaje dostępu do operacji.</p><PublicTenantLanding tenant={tenant} preview /></>;
}
