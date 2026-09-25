import { renderPublicTenantSubpage, publicSubpageMetadata } from "@/app/_components/PublicTenantSubpage";

export const dynamic = "force-dynamic";
export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }) {
  return publicSubpageMetadata((await params).slug, "o-obiekcie");
}

export default async function Page({ params }: { params: Promise<{ slug: string }> }) {
  return renderPublicTenantSubpage((await params).slug, "o-obiekcie");
}
