import Image from "next/image";
import Link from "next/link";
import type { ReactNode } from "react";
import type { PublicTenantLanding as PublicTenantLandingData } from "@/lib/server/public-tenant-directory";
import { PLATFORM_BASE_URL } from "@/lib/platform-domain";

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2)
    .map((part) => part[0]?.toUpperCase()).join("");
}

function LandingLink({ href, className, children, preview }: { href: string; className?: string; children: ReactNode; preview: boolean }) {
  return preview ? <span className={className} aria-disabled="true">{children}</span>
    : <Link href={href} className={className}>{children}</Link>;
}

export function PublicTenantLanding({
  tenant,
  preview = false,
  customDomain = false,
}: Readonly<{ tenant: PublicTenantLandingData; preview?: boolean; customDomain?: boolean }>) {
  const bookingHref = `${customDomain ? PLATFORM_BASE_URL : ""}/t/${tenant.tenantSlug}/booking`;
  const eventsHref = `${customDomain ? PLATFORM_BASE_URL : ""}/t/${tenant.tenantSlug}/events`;
  const publicBase = customDomain ? "" : `/${tenant.publicSlug}`;

  return (
    <main inert={preview} className="min-h-screen overflow-x-hidden bg-[#090b09] text-[#f2efe4]">
      <section className="relative border-b border-[#30372c] px-4 py-8 sm:px-6 sm:py-12">
        {tenant.heroImagePath && (
          <div className="absolute inset-0 overflow-hidden opacity-25">
            <Image src={tenant.heroImagePath} alt="" fill priority className="object-cover" />
            <div className="absolute inset-0 bg-gradient-to-b from-[#090b09]/40 to-[#090b09]" />
          </div>
        )}
        <div className="relative mx-auto flex w-full max-w-6xl flex-col items-center text-center">
          <LandingLink preview={preview} href={customDomain ? PLATFORM_BASE_URL : "/"} className="self-start text-sm font-semibold text-[#d7c895] underline-offset-4 hover:underline">
            ← StrzelajTu.pl
          </LandingLink>
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
            {tenant.showBooking && <LandingLink preview={preview} href={bookingHref} className="min-h-12 rounded-xl border border-[#c5a861] bg-[#3a301d] px-6 py-3 font-bold text-[#f0d17b] transition hover:bg-[#493b22] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d2b66f]">
              Zarezerwuj termin
            </LandingLink>}
            {tenant.showEvents && <LandingLink preview={preview} href={eventsHref} className="min-h-12 rounded-xl border border-[#657054] bg-[#1a2019] px-6 py-3 font-bold text-[#d7ddcd] transition hover:bg-[#222a20] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#9eaa88]">
              Szkolenia i eventy
            </LandingLink>}
          </div>
        </div>
      </section>

      <section aria-label="Oferta obiektu" className="mx-auto grid w-full max-w-6xl gap-4 px-4 py-8 sm:grid-cols-2 sm:px-6 lg:grid-cols-3">
        {tenant.showBooking && <LandingLink preview={preview} href={bookingHref} className="rounded-2xl border border-[#3d4638] bg-[#171c17] p-6 transition hover:border-[#778462] hover:bg-[#20261e]">
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#b89545]">Rezerwacje</p>
          <h2 className="mt-3 text-xl font-bold">Wybierz termin online</h2>
          <p className="mt-3 text-sm leading-6 text-[#aeb4a8]">Sprawdź dostępność stanowisk i przejdź do bezpiecznego procesu rezerwacji.</p>
        </LandingLink>}
        {tenant.showEvents && <LandingLink preview={preview} href={eventsHref} className="rounded-2xl border border-[#3d4638] bg-[#171c17] p-6 transition hover:border-[#778462] hover:bg-[#20261e]">
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#b89545]">Wydarzenia</p>
          <h2 className="mt-3 text-xl font-bold">Szkolenia i eventy</h2>
          <p className="mt-3 text-sm leading-6 text-[#aeb4a8]">Zobacz opublikowane wydarzenia i dostępne miejsca.</p>
        </LandingLink>}
        {tenant.showInstructor && <div className="rounded-2xl border border-[#30372c] bg-[#121612] p-6">
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#7e8875]">Wkrótce</p>
          <h2 className="mt-3 text-xl font-bold">Strzelanie z instruktorem</h2>
          <p className="mt-3 text-sm leading-6 text-[#8f968b]">Ten moduł nie jest jeszcze dostępny w publicznej ofercie platformy.</p>
        </div>}
      </section>

      <section className="mx-auto grid w-full max-w-6xl gap-4 px-4 pb-10 sm:grid-cols-2 sm:px-6">
        {tenant.showAbout && <div className="rounded-2xl border border-[#30372c] bg-[#141814] p-6">
          <h2 className="text-xl font-bold"><LandingLink preview={preview} href={`${publicBase}/o-obiekcie`}>O obiekcie</LandingLink></h2>
          <p className="mt-3 leading-7 text-[#aeb4a8]">{tenant.description ?? `${tenant.name} — obiekt w miejscowości ${tenant.city}.`}</p>
        </div>}
        {(tenant.showContact || tenant.showPricing || (tenant.showRegulations && tenant.regulationsPath)) && <div className="rounded-2xl border border-[#30372c] bg-[#141814] p-6">
          <h2 className="text-xl font-bold">Informacje</h2>
          {tenant.showContact && <dl className="mt-3 space-y-2 text-[#aeb4a8]">
            <div><dt className="inline font-semibold text-[#d7ddcd]">Lokalizacja: </dt><dd className="inline">{tenant.publicAddress ?? tenant.city}</dd></div>
            {tenant.openingHours && <div><dt className="inline font-semibold text-[#d7ddcd]">Godziny: </dt><dd className="inline">{tenant.openingHours}</dd></div>}
            {tenant.publicPhone && <div><dt className="inline font-semibold text-[#d7ddcd]">Telefon: </dt><dd className="inline"><a href={`tel:${tenant.publicPhone}`} className="hover:underline">{tenant.publicPhone}</a></dd></div>}
            {tenant.publicEmail && <div><dt className="inline font-semibold text-[#d7ddcd]">E-mail: </dt><dd className="inline"><a href={`mailto:${tenant.publicEmail}`} className="hover:underline">{tenant.publicEmail}</a></dd></div>}
          </dl>}
          <div className="mt-5 flex flex-wrap gap-4 text-sm font-semibold text-[#d7c895]">
            {tenant.showPricing && <LandingLink preview={preview} href={`${publicBase}/cennik`} className="underline-offset-4 hover:underline">Cennik</LandingLink>}
            {tenant.showContact && <LandingLink preview={preview} href={`${publicBase}/kontakt`} className="underline-offset-4 hover:underline">Kontakt i lokalizacja</LandingLink>}
            {tenant.showRegulations && tenant.regulationsPath && (
              <LandingLink preview={preview} href={tenant.regulationsPath} className="underline-offset-4 hover:underline">Regulamin</LandingLink>
            )}
          </div>
          {tenant.showContact && Object.entries(tenant.socialLinks).length > 0 && <div className="mt-4 flex flex-wrap gap-4 text-sm text-[#d7c895]">{Object.entries(tenant.socialLinks).map(([name,url]) => <a key={name} href={url} rel="noreferrer" target="_blank" className="capitalize hover:underline">{name}</a>)}</div>}
        </div>}
      </section>
    </main>
  );
}
