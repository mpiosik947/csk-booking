import { renderPublicTenantSubpage } from "@/app/_components/PublicTenantSubpage";

export const dynamic = "force-dynamic";

export default async function Page({ params }: { params: Promise<{ slug: string }> }) {
  return renderPublicTenantSubpage((await params).slug, "kontakt");
}
