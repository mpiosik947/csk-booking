import { notFound } from "next/navigation";
import Link from "next/link";
import { getPublicRouteContext } from "@/lib/server/tenant-route-context";

export const dynamic = "force-dynamic";

export default async function TenantLayout({
  children,
  params,
}: Readonly<{
  children: React.ReactNode;
  params: Promise<{ slug: string }>;
}>) {
  const { slug } = await params;
  const context = await getPublicRouteContext(slug);
  if (!context.ok) notFound();

  return (
    <div data-testid="tenant-shell" className="min-h-screen w-full flex-1 bg-[#090b09] text-[#e8ebe4]">
    <div className="mx-auto w-full max-w-5xl px-4 py-8 sm:px-6">
      <nav aria-label="Lokalizacja" className="mb-8 flex flex-wrap items-center gap-3 text-sm">
        <Link href="/" className="text-[#d7c895] underline-offset-4 hover:underline">StrzelajTu.pl</Link>
        <span aria-hidden="true">/</span>
        <Link href={`/t/${context.value.slug}`} className="text-[#d7c895] underline-offset-4 hover:underline">
          {context.value.name}
        </Link>
      </nav>
      {children}
    </div>
    </div>
  );
}
