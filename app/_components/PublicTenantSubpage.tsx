import Image from "next/image";
import Link from "next/link";
import { notFound, permanentRedirect } from "next/navigation";
import { getPublicSubpageTenant, getPublicTenantContent, type PublicSection } from "@/lib/server/public-tenant-subpages";

const titles = { cennik: "Cennik", "o-obiekcie": "O obiekcie", kontakt: "Kontakt i lokalizacja" };

export async function renderPublicTenantSubpage(slug: string, section: PublicSection) {
  const tenant = await getPublicSubpageTenant(slug, section);
  if (!tenant) notFound();
  if (slug !== tenant.publicSlug) permanentRedirect(`/${tenant.publicSlug}/${section}`);
  const content = await getPublicTenantContent(tenant.publicSlug);
  const prices = content?.pricing_items ?? null;
  return <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
    <article className="mx-auto w-full max-w-[880px] rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 sm:p-8">
      <header className="text-center">
        {tenant.logoPath && <Image src={tenant.logoPath} alt={`Logo ${tenant.name}`} width={1536} height={1024} priority className="mx-auto h-auto w-full max-w-[280px] rounded-xl" />}
        <p className="mt-4 break-words text-[#d7c895]">{tenant.name}</p>
        <h1 className="mt-2 text-2xl font-bold sm:text-3xl">{titles[section]}</h1>
      </header>
      <div className="mt-6 space-y-4">
        {section === "cennik" && <>
          {prices === null ? <p role="status">Nie udało się pobrać cennika. Spróbuj ponownie później.</p>
            : prices.length === 0 ? <p>Cennik nie został jeszcze opublikowany.</p>
            : prices.map((item, index) => <section key={index} className="rounded-xl border border-[#343a31] bg-[#1a1e1a] p-4">
              <h2 className="break-words font-semibold">{item.title}</h2>
              {item.short_description && <p className="mt-2 break-words text-sm text-[#a9ada4]">{item.short_description}</p>}
              <p className="mt-3 break-words font-semibold text-[#d7c895]">{new Intl.NumberFormat("pl-PL", { style: "currency", currency: item.currency }).format(item.price)} / {item.unit}</p>
            </section>)}
          <p className="text-sm text-[#a9ada4]">Cennik informacyjny oferty. Ostateczna cena rezerwacji jest potwierdzana w systemie booking.</p>
          {tenant.showBooking && <Link href={`/t/${tenant.tenantSlug}/booking`} className="inline-flex min-h-11 items-center rounded-xl border border-[#536143] bg-[#26301f] px-5 py-3 font-semibold">Zarezerwuj termin</Link>}
        </>}
        {section === "o-obiekcie" && <>
          {tenant.heroImagePath && <Image src={tenant.heroImagePath} alt="" width={1200} height={600} className="h-auto w-full rounded-xl" />}
          {tenant.description && <p className="whitespace-pre-line break-words leading-7 text-[#a9ada4]">{tenant.description}</p>}
          {([["Co oferujemy",content?.about_offer],["Dla kogo",content?.about_audience]] as const).map(([title,text])=>text&&<section key={title}><h2 className="font-semibold">{title}</h2><p className="mt-2 whitespace-pre-line break-words leading-7 text-[#a9ada4]">{text}</p></section>)}
          {!tenant.description&&!content?.about_offer&&!content?.about_audience&&<p>Opis obiektu nie został jeszcze uzupełniony.</p>}
          <p className="text-[#a9ada4]">Miejscowość: {tenant.city}</p>
        </>}
        {section === "kontakt" && <div className="grid gap-6 md:grid-cols-2"><div className="min-w-0">
          <dl className="space-y-4 break-words leading-6 text-[#a9ada4]">
            <div><dt className="font-semibold text-[#d7c895]">Miejscowość</dt><dd>{tenant.city}</dd></div>
            {tenant.publicAddress && <div><dt className="font-semibold text-[#d7c895]">Adres</dt><dd>{tenant.publicAddress}</dd></div>}
            {tenant.publicPhone && <div><dt className="font-semibold text-[#d7c895]">Telefon</dt><dd><a className="underline" href={`tel:${tenant.publicPhone}`}>Zadzwoń: {tenant.publicPhone}</a></dd></div>}
            {tenant.publicEmail && <div><dt className="font-semibold text-[#d7c895]">E-mail</dt><dd><a className="underline" href={`mailto:${tenant.publicEmail}`}>Napisz wiadomość: {tenant.publicEmail}</a></dd></div>}
            {tenant.openingHours && <div><dt className="font-semibold text-[#d7c895]">Godziny otwarcia</dt><dd className="whitespace-pre-line">{tenant.openingHours}</dd></div>}
          </dl>
          {Object.keys(tenant.socialLinks).length > 0 && <nav aria-label="Media społecznościowe" className="flex flex-wrap gap-4">
            {Object.entries(tenant.socialLinks).map(([name, url]) => <a key={name} href={url} target="_blank" rel="noreferrer" className="capitalize text-[#d7c895] underline">{name}</a>)}
          </nav>}
          {!tenant.publicAddress && !tenant.publicPhone && !tenant.publicEmail && !tenant.openingHours && <p className="text-sm text-[#a9ada4]">Szczegółowe dane kontaktowe nie zostały jeszcze uzupełnione.</p>}
        </div><section className="min-w-0 rounded-xl border border-[#343a31] p-4"><h2 className="font-semibold">Lokalizacja</h2>{content?.public_map_url ? <a href={content.public_map_url} target="_blank" rel="noreferrer" className="mt-3 inline-flex min-h-11 items-center text-[#d7c895] underline">Otwórz mapę</a> : <p className="mt-3 text-sm text-[#a9ada4]">Link do mapy nie został jeszcze uzupełniony.</p>}</section></div>}
      </div>
      <nav className="mt-8 border-t border-[#30372c] pt-4">
        <Link href={`/${tenant.publicSlug}`} className="inline-flex min-h-11 items-center text-[#d7c895]">← Wróć do strony obiektu</Link>
      </nav>
    </article>
  </main>;
}
