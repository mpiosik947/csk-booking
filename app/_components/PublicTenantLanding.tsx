import Image from "next/image";
import Link from "next/link";
import type { ReactNode } from "react";
import type { PublicTenantLanding as PublicTenantLandingData } from "@/lib/server/public-tenant-directory";
import { PLATFORM_BASE_URL } from "@/lib/platform-domain";

function LandingLink({ href, className, children, preview, label }: { href: string; className?: string; children: ReactNode; preview: boolean; label?: string }) {
  return preview ? <span className={className} aria-disabled="true">{children}</span>
    : <Link href={href} aria-label={label} className={className}>{children}</Link>;
}

function Icon({ name, className = "h-5 w-5" }: { name: "calendar" | "training" | "target" | "document" | "arrow" | "user"; className?: string }) {
  return <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className={className}>
    {name === "calendar" && <><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 10h18M8 14h.01M12 14h.01M16 14h.01" /></>}
    {name === "training" && <><path d="m3 7 9-4 9 4-9 4-9-4Z" /><path d="M6 9v5c0 1.7 2.7 3 6 3s6-1.3 6-3V9M21 7v6" /></>}
    {name === "target" && <><circle cx="12" cy="12" r="8" /><circle cx="12" cy="12" r="3" /><path d="M15 9 21 3M17 3h4v4" /></>}
    {name === "document" && <><path d="M6 3h8l4 4v14H6z" /><path d="M14 3v5h5M9 13h6M9 17h6" /></>}
    {name === "user" && <><circle cx="12" cy="8" r="4" /><path d="M4 21a8 8 0 0 1 16 0" /></>}
    {name === "arrow" && <path d="m9 18 6-6-6-6" />}
  </svg>;
}

const infoRow = "flex h-[72px] w-full items-center gap-2.5 rounded-xl border border-[#343a31] bg-[#1a1e1a] px-3 text-left sm:gap-3 sm:px-4";
const infoHover = "transition hover:border-[#56614d] hover:bg-[#202520] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a]";

function InformationLabel({ title, description, soon = false }: { title: string; description: string; soon?: boolean }) {
  return <>
    <Icon name={soon ? "target" : "document"} className="h-5 w-5 shrink-0 text-[#aab58f]" />
    <span className="min-w-0 flex-1">
      <span className="flex items-center gap-1.5"><span className="min-w-0 text-[13px] font-semibold leading-5 sm:text-sm">{title}</span>
        {soon && <span className="shrink-0 rounded-full border border-[#75643b] bg-[#2b261b] px-1.5 py-0.5 text-[8px] font-bold text-[#d7c895]">WKRÓTCE</span>}
      </span>
      <span className="block truncate text-xs leading-5 text-[#92988e] sm:text-sm">{description}</span>
    </span>
    <Icon name="arrow" className="h-4 w-4 shrink-0 text-[#7f8877]" />
  </>;
}

export function PublicTenantLanding({ tenant, preview = false, customDomain = false }: Readonly<{ tenant: PublicTenantLandingData; preview?: boolean; customDomain?: boolean }>) {
  const bookingHref = `${customDomain ? PLATFORM_BASE_URL : ""}/t/${tenant.tenantSlug}/booking`;
  const eventsHref = `${customDomain ? PLATFORM_BASE_URL : ""}/t/${tenant.tenantSlug}/events`;
  const publicBase = customDomain ? "" : `/${tenant.publicSlug}`;
  const platformBase = customDomain ? PLATFORM_BASE_URL : "";
  const hasInformation = tenant.showInstructor || tenant.showPricing || tenant.showAbout || tenant.showContact || (tenant.showRegulations && tenant.regulationsPath);
  const rows = [
    { visible: tenant.showPricing, title: "Cennik", description: "Sprawdź ceny i dostępne opcje", href: `${publicBase}/cennik` },
    { visible: tenant.showAbout, title: "O obiekcie", description: `Poznaj ${tenant.name}`, href: `${publicBase}/o-obiekcie` },
    { visible: tenant.showRegulations && !!tenant.regulationsPath, title: "Regulamin", description: "Zasady korzystania z obiektu", href: tenant.regulationsPath ?? "" },
    { visible: tenant.showContact, title: "Kontakt i lokalizacja", description: "Dane kontaktowe i lokalizacja", href: `${publicBase}/kontakt` },
  ];
  const ctas = [
    { visible: tenant.showBooking, href: bookingHref, title: "Zarezerwuj termin", description: "Sprawdź dostępność osi i wybierz termin.", icon: "calendar" as const, colors: "border-[#536143] bg-[#26301f] hover:border-[#78865f] hover:bg-[#303b27]", divider: "border-[#536143]" },
    { visible: tenant.showEvents, href: eventsHref, title: "Szkolenia i eventy", description: "Sprawdź dostępne szkolenia i zapisz się online.", icon: "training" as const, colors: "border-[#6f5a2e] bg-[#332b1d] hover:border-[#9a7c3e] hover:bg-[#403522]", divider: "border-[#6f5a2e]" },
  ];

  return <main inert={preview} data-testid="tenant-landing" className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
    <section data-testid="tenant-landing-panel" className="mx-auto w-full max-w-[880px] rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/30 sm:p-8 xl:p-9">
      <header className="relative isolate text-center">
        {tenant.heroImagePath && <div className="pointer-events-none absolute inset-0 -z-10 overflow-hidden rounded-xl opacity-25"><Image src={tenant.heroImagePath} alt="" fill className="object-cover" /></div>}
        {tenant.logoPath ? <Image data-testid="tenant-logo" src={tenant.logoPath} alt={`Logo ${tenant.name}`} width={1536} height={1024} priority className="mx-auto h-auto w-full max-w-[300px] rounded-xl sm:max-w-[340px] xl:max-w-[360px]" />
          : <div className="mx-auto flex min-h-40 max-w-[360px] items-center justify-center rounded-xl border border-[#536143] text-4xl font-bold text-[#d7c895]">{tenant.name.split(/\s+/).filter(Boolean).slice(0, 2).map(part => part[0]).join("")}</div>}
        <h1 className={tenant.logoPath ? "sr-only" : "mt-4 break-words text-2xl font-bold"}>{tenant.name}</h1>
        <span className="sr-only">{tenant.city}</span>
        {tenant.description && <p className="mx-auto mt-4 max-w-xl text-base text-[#a9ada4] sm:text-lg xl:mt-3.5">{tenant.description}</p>}
      </header>
      {(tenant.showBooking || tenant.showEvents) && <div data-testid="tenant-main-ctas" className="mt-6 grid gap-4 md:grid-cols-2 md:gap-5">
        {ctas.filter(cta => cta.visible).map(cta => <LandingLink key={cta.title} preview={preview} href={cta.href} label={cta.title} className={`group flex min-h-32 items-center rounded-2xl border p-4 text-left transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] xl:p-4.5 ${cta.colors}`}>
          <span className={`flex shrink-0 items-center self-stretch border-r pr-4 text-[#d7c895] ${cta.divider}`}><Icon name={cta.icon} className="h-7 w-7 xl:h-8 xl:w-8" /></span>
          <span className="min-w-0 flex-1 px-4"><span className="block text-lg font-bold xl:text-xl">{cta.title}</span><span className="mt-1 block text-sm leading-5 text-[#c3c8bb] xl:text-base xl:leading-6">{cta.description}</span></span>
          <Icon name="arrow" className="h-5 w-5 shrink-0 text-[#bca266]" />
        </LandingLink>)}
      </div>}
      <nav aria-label="Konto" className="my-6 flex flex-wrap items-center justify-center gap-x-4 gap-y-3 border-y border-[#30372c] py-4 text-sm text-[#b7bbb1] md:text-base">
        <Icon name="user" className="h-5 w-5 text-[#aab58f]" />
        {[["/login", "Zaloguj się"], ["/register", "Rejestracja"], ["/account", "Moje konto"]].map(([path, label]) => <LandingLink key={path} preview={preview} href={`${platformBase}${path}`} className="inline-flex min-h-11 items-center font-semibold text-[#d7c895] underline-offset-4 hover:underline">{label}</LandingLink>)}
      </nav>
      {hasInformation && <section aria-label="Informacje o obiekcie">
        <h2 className="mb-3 text-xs font-bold tracking-[0.2em] text-[#858c7f]">INFORMACJE</h2>
        <div data-testid="information-rows" className="space-y-2">
          {tenant.showInstructor && <div data-testid="information-row" aria-disabled="true" className={`${infoRow} opacity-80`}><InformationLabel title="Strzelanie z instruktorem" description="Moduł będzie dostępny wkrótce" soon /></div>}
          {rows.filter(row => row.visible).map(row => <div key={row.title} data-testid="information-row"><LandingLink preview={preview} href={row.href} className={`${infoRow} ${infoHover}`}><InformationLabel title={row.title} description={row.description} /></LandingLink></div>)}
        </div>
      </section>}
      <footer className="mt-5 text-center text-xs text-[#858c7f]"><LandingLink preview={preview} href={customDomain ? PLATFORM_BASE_URL : "/"} className="inline-flex min-h-11 items-center hover:text-[#d7c895]">StrzelajTu.pl — znajdź strzelnicę</LandingLink></footer>
    </section>
  </main>;
}
