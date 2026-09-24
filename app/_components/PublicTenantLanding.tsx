import Image from "next/image";
import Link from "next/link";
import type { PublicTenantLanding as PublicTenantLandingData } from "@/lib/server/public-tenant-directory";

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2)
    .map((part) => part[0]?.toUpperCase()).join("");
}

export function PublicTenantLanding({
  tenant,
}: Readonly<{ tenant: PublicTenantLandingData }>) {
  const bookingHref = `/t/${tenant.tenantSlug}/booking`;
  const eventsHref = `/t/${tenant.tenantSlug}/events`;

  return (
    <main className="min-h-screen overflow-x-hidden bg-[#090b09] text-[#f2efe4]">
      <section className="relative border-b border-[#30372c] px-4 py-8 sm:px-6 sm:py-12">
        {tenant.heroImagePath && (
          <div className="absolute inset-0 overflow-hidden opacity-25">
            <Image src={tenant.heroImagePath} alt="" fill priority className="object-cover" />
            <div className="absolute inset-0 bg-gradient-to-b from-[#090b09]/40 to-[#090b09]" />
          </div>
        )}
        <div className="relative mx-auto flex w-full max-w-6xl flex-col items-center text-center">
          <Link href="/" className="self-start text-sm font-semibold text-[#d7c895] underline-offset-4 hover:underline">
            ← StrzelajTu.pl
          </Link>
          <div className="mt-8 flex h-28 w-28 items-center justify-center overflow-hidden rounded-2xl border border-[#7c6a39] bg-[#111511] text-2xl font-black text-[#e8d18f] shadow-2xl shadow-black/40 sm:h-32 sm:w-32">
            {tenant.logoPath ? (
              <Image src={tenant.logoPath} alt={`Logo ${tenant.name}`} width={256} height={256} className="h-full w-full object-contain" />
            ) : initials(tenant.name)}
          </div>
          <p className="mt-6 text-xs font-bold uppercase tracking-[0.22em] text-[#b89545]">{tenant.city}</p>
          <h1 className="mt-3 max-w-4xl break-words text-3xl font-black leading-tight sm:text-5xl">{tenant.name}</h1>
          {tenant.description && (
            <p className="mt-5 max-w-2xl text-base leading-7 text-[#bdc3b8] sm:text-lg">{tenant.description}</p>
          )}
          <div className="mt-8 flex w-full max-w-xl flex-col gap-3 sm:flex-row sm:justify-center">
            <Link href={bookingHref} className="min-h-12 rounded-xl border border-[#c5a861] bg-[#3a301d] px-6 py-3 font-bold text-[#f0d17b] transition hover:bg-[#493b22] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d2b66f]">
              Zarezerwuj termin
            </Link>
            <Link href={eventsHref} className="min-h-12 rounded-xl border border-[#657054] bg-[#1a2019] px-6 py-3 font-bold text-[#d7ddcd] transition hover:bg-[#222a20] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#9eaa88]">
              Szkolenia i eventy
            </Link>
          </div>
        </div>
      </section>

      <section aria-label="Oferta obiektu" className="mx-auto grid w-full max-w-6xl gap-4 px-4 py-8 sm:grid-cols-2 sm:px-6 lg:grid-cols-3">
        <Link href={bookingHref} className="rounded-2xl border border-[#3d4638] bg-[#171c17] p-6 transition hover:border-[#778462] hover:bg-[#20261e]">
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#b89545]">Rezerwacje</p>
          <h2 className="mt-3 text-xl font-bold">Wybierz termin online</h2>
          <p className="mt-3 text-sm leading-6 text-[#aeb4a8]">Sprawdź dostępność stanowisk i przejdź do bezpiecznego procesu rezerwacji.</p>
        </Link>
        <Link href={eventsHref} className="rounded-2xl border border-[#3d4638] bg-[#171c17] p-6 transition hover:border-[#778462] hover:bg-[#20261e]">
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#b89545]">Wydarzenia</p>
          <h2 className="mt-3 text-xl font-bold">Szkolenia i eventy</h2>
          <p className="mt-3 text-sm leading-6 text-[#aeb4a8]">Zobacz opublikowane wydarzenia i dostępne miejsca.</p>
        </Link>
        <div className="rounded-2xl border border-[#30372c] bg-[#121612] p-6">
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#7e8875]">Wkrótce</p>
          <h2 className="mt-3 text-xl font-bold">Strzelanie z instruktorem</h2>
          <p className="mt-3 text-sm leading-6 text-[#8f968b]">Ten moduł nie jest jeszcze dostępny w publicznej ofercie platformy.</p>
        </div>
      </section>

      <section className="mx-auto grid w-full max-w-6xl gap-4 px-4 pb-10 sm:grid-cols-2 sm:px-6">
        <div className="rounded-2xl border border-[#30372c] bg-[#141814] p-6">
          <h2 className="text-xl font-bold">O obiekcie</h2>
          <p className="mt-3 leading-7 text-[#aeb4a8]">{tenant.description ?? `${tenant.name} — obiekt w miejscowości ${tenant.city}.`}</p>
        </div>
        <div className="rounded-2xl border border-[#30372c] bg-[#141814] p-6">
          <h2 className="text-xl font-bold">Informacje</h2>
          <dl className="mt-3 text-[#aeb4a8]">
            <div><dt className="inline font-semibold text-[#d7ddcd]">Lokalizacja: </dt><dd className="inline">{tenant.city}</dd></div>
          </dl>
          <div className="mt-5 flex flex-wrap gap-4 text-sm font-semibold text-[#d7c895]">
            <Link href={bookingHref} className="underline-offset-4 hover:underline">Cennik i rezerwacja</Link>
            {tenant.regulationsPath && (
              <Link href={tenant.regulationsPath} className="underline-offset-4 hover:underline">Regulamin</Link>
            )}
          </div>
        </div>
      </section>
    </main>
  );
}
