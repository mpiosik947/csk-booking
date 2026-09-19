import Link from "next/link";
import { notFound } from "next/navigation";
import { getPublicRouteContext } from "@/lib/server/tenant-route-context";

export default async function TenantHome({
  params,
}: Readonly<{ params: Promise<{ slug: string }> }>) {
  const { slug } = await params;
  const context = await getPublicRouteContext(slug);
  if (!context.ok) notFound();

  return (
    <section className="rounded-2xl border border-[#8b986f] bg-[#192019] p-6 sm:p-8">
      <h1 className="text-2xl font-semibold text-[#e8ebe4]">{context.value.name}</h1>
      <p className="mt-3 max-w-2xl text-[#d0d5c9]">
        Strona lokalizacji. Rezerwacje i pozostałe operacje tenantowe nie są jeszcze dostępne pod nowym adresem.
      </p>
      {context.value.slug === "csk" && (
        <div className="mt-6 flex flex-wrap gap-3">
          <Link href="/booking" className="rounded-lg border border-[#d7c895] px-4 py-3 text-[#d7c895]">
            Rezerwacje CSK — obecny adres
          </Link>
          <Link href="/events" className="rounded-lg border border-[#d7c895] px-4 py-3 text-[#d7c895]">
            Eventy CSK — obecny adres
          </Link>
        </div>
      )}
    </section>
  );
}
