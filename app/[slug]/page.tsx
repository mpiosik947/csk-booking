import type { Metadata } from "next";
import { notFound, permanentRedirect } from "next/navigation";
import { PublicTenantLanding } from "@/app/_components/PublicTenantLanding";
import { getPublicTenantLanding } from "@/lib/server/public-tenant-directory";
import { tenantCanonical } from "@/lib/server/tenant-domain";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: Readonly<{ params: Promise<{ slug: string }> }>): Promise<Metadata> {
  const { slug } = await params;
  const tenant = await getPublicTenantLanding(slug);
  if (!tenant) return {};
  return {
    title: `${tenant.name} | StrzelajTu.pl`,
    description: tenant.description ?? `Rezerwacje online — ${tenant.name}, ${tenant.city}.`,
    alternates: { canonical: await tenantCanonical(tenant.publicSlug) },
  };
}

export default async function PublicTenantAlias({
  params,
}: Readonly<{ params: Promise<{ slug: string }> }>) {
  const { slug } = await params;
  const tenant = await getPublicTenantLanding(slug);
  if (!tenant) notFound();
  if (slug !== tenant.publicSlug) permanentRedirect(`/${tenant.publicSlug}`);
  return <PublicTenantLanding tenant={tenant} />;
}
