import Image from "next/image";
import { PARTNER_KINDS, partnerMediaUrl, type PublicPartner } from "@/lib/tenant-partners";

function PartnerCard({ partner }: { partner: PublicPartner }) {
  const banner = partner.display_format === "banner";
  const image = <div className={`relative w-full overflow-hidden rounded-lg bg-[#f4f3ef] ${banner ? "aspect-[3/1]" : "aspect-[4/3]"}`}>
    {/* The optimizer must not cache an image across an access-state/session change. */}
    <Image unoptimized fill sizes={banner ? "100vw" : "(min-width: 768px) 180px, 40vw"} loading="lazy"
      src={partnerMediaUrl(partner.media_id)} alt={banner ? `Baner ${partner.name}` : `Logo ${partner.name}`}
      className={`object-contain ${banner ? "p-2" : "p-3"}`} />
  </div>;
  return <article className="min-w-0 rounded-xl border border-[#343a31] bg-[#1a1e1a] p-2.5">
    {partner.target_url ? <a href={partner.target_url} target="_blank" rel={`noopener noreferrer${partner.kind !== "partner" ? " sponsored" : ""}`}
      aria-label={`${partner.name} — otwórz stronę w nowej karcie`} className="block rounded-lg focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-[#d7c895]">{image}</a> : image}
    <h3 className="mt-2 break-words text-sm font-semibold">{partner.name}</h3>
    <p className="mt-1 text-xs text-[#a9ada4]">{PARTNER_KINDS[partner.kind]}</p>
    {partner.short_description && <p className="mt-2 break-words text-sm text-[#c3c8bb]">{partner.short_description}</p>}
    {partner.kind === "commercial_partner" && <p className="mt-2 text-xs text-[#d7c895]">Materiał reklamowy</p>}
  </article>;
}

export default function TenantPartners({ name, items }: { name: string; items: readonly PublicPartner[] }) {
  if (!items.length) return null;
  const logos = items.filter(p => p.display_format === "logo"), banners = items.filter(p => p.display_format === "banner");
  return <section data-testid="tenant-partners" aria-label={`Partnerzy ${name}`} className="mt-7 border-t border-[#30372c] pt-6">
    <h2 className="mb-4 break-words text-lg font-semibold">Partnerzy {name}</h2>
    {logos.length > 0 && <div data-testid="partner-logo-grid" className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-5">{logos.map(p => <PartnerCard key={p.id} partner={p} />)}</div>}
    {banners.length > 0 && <div data-testid="partner-banners" className="mt-4 grid gap-4">{banners.map(p => <PartnerCard key={p.id} partner={p} />)}</div>}
  </section>;
}
