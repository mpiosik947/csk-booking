import type { Metadata } from "next";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { PublicTenantLanding } from "@/app/_components/PublicTenantLanding";
import { renderPublicTenantSubpage } from "@/app/_components/PublicTenantSubpage";
import { getPublicTenantLanding } from "@/lib/server/public-tenant-directory";
import { resolvePublicDomain, tenantCanonical } from "@/lib/server/tenant-domain";
import { normalizeHostname } from "@/lib/platform-domain";

export const dynamic = "force-dynamic";
export const revalidate = 0;
type Props = { params: Promise<{ host: string; path?: string[] }> };
async function context(params: Props["params"]) {
  const { host, path = [] } = await params;
  if (normalizeHostname((await headers()).get("host")) !== host || path.length > 1 ||
      (path.length && !["cennik", "o-obiekcie", "kontakt"].includes(path[0]))) notFound();
  const resolved = await resolvePublicDomain(host);
  if (!resolved) notFound();
  return { ...resolved, section: path[0] };
}
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { publicSlug, section } = await context(params);
  const tenant = await getPublicTenantLanding(publicSlug);
  if (!tenant) return {};
  return { title: `${tenant.name} | StrzelajTu.pl`, alternates: { canonical: await tenantCanonical(publicSlug, section) } };
}
export default async function Page({ params }: Props) {
  const { publicSlug, section } = await context(params);
  if (section === "cennik" || section === "o-obiekcie" || section === "kontakt")
    return renderPublicTenantSubpage(publicSlug, section, true);
  const tenant = await getPublicTenantLanding(publicSlug);
  if (!tenant) notFound();
  return <PublicTenantLanding tenant={tenant} customDomain />;
}
