import { notFound, redirect } from "next/navigation";
import { getPublishedTenantBySlug } from "@/lib/server/public-tenant-directory";

export default async function PublicTenantAlias({
  params,
}: Readonly<{ params: Promise<{ slug: string }> }>) {
  const { slug } = await params;
  const tenant = await getPublishedTenantBySlug(slug);
  if (!tenant) notFound();
  redirect(`/t/${tenant.slug}`);
}
