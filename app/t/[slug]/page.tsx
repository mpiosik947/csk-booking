import Link from "next/link";
import type { Metadata } from "next";
import { notFound, permanentRedirect } from "next/navigation";
import { getPublicTenantLanding } from "@/lib/server/public-tenant-directory";
import { getPublicRouteContext } from "@/lib/server/tenant-route-context";

export const metadata: Metadata = { robots: { index: false, follow: true } };

export default async function TenantHome({
  params,
}: Readonly<{ params: Promise<{ slug: string }> }>) {
  const { slug } = await params;
  const publishedTenant = await getPublicTenantLanding(slug);
  if (publishedTenant) permanentRedirect(`/${publishedTenant.publicSlug}`);
  const context = await getPublicRouteContext(slug);
  if (!context.ok) notFound();

  return (
    <section className="rounded-2xl border border-[#8b986f] bg-[#192019] p-6 sm:p-8">
      <h1 className="text-2xl font-semibold text-[#e8ebe4]">{context.value.name}</h1>
      <p className="mt-3 max-w-2xl text-[#d0d5c9]">
        Wybierz usługę w tej lokalizacji. Dostęp do modułów obsługi wymaga aktywnego członkostwa i odpowiedniej roli.
      </p>
      <div className="mt-6 flex flex-wrap gap-3">
        <Link href={`/t/${slug}/booking`} className="rounded-lg border border-[#d7c895] px-4 py-3 text-[#d7c895]">
          Rezerwacje
        </Link>
        <Link href={`/t/${slug}/events`} className="rounded-lg border border-[#d7c895] px-4 py-3 text-[#d7c895]">
          Szkolenia i eventy
        </Link>
        <Link href={`/t/${slug}/admin`} className="rounded-lg border border-[#8b986f] px-4 py-3 text-[#d0d5c9]">
          Panel obsługi
        </Link>
      </div>
    </section>
  );
}
