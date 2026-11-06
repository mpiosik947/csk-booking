import { checkStatus, summaryGroups } from "@/lib/platform-onboarding-steps";
import type { Configuration } from "@/lib/platform-draft-configuration";
import type { Readiness } from "@/lib/platform-draft-readiness";
import { capabilities, visibleSections } from "@/lib/platform-onboarding-features";
import { planName } from "@/lib/platform-management";

type Props = { saved: Configuration; readiness: Readiness | null; onStep: (step: number) => void };
export default function WizardSummary({ saved, readiness, onStep }: Props) {
  const p = saved.profile;
  const values = [
    [p.display_name, p.city, p.public_address].filter(Boolean).join(" · "),
    `Osie: ${saved.lanes.families.length} · Stanowiska: ${saved.lanes.resources.filter(r => r.resource_kind === "position").length}`,
    `Oznaczone do rezerwacji online: ${saved.lanes.resources.filter(r => r.online_bookable).length}. Pozycje cennika informacyjnego: ${saved.pricing.length}.`,
    p.opening_hours ?? "Nie podano godzin informacyjnych.",
    [p.description || "Brak opisu.", "Strona niepubliczna."].join(" "),
    "",
    planName(saved.planKey),
    "Pierwszego administratora wybierzesz podczas przekazania.",
  ];
  return <section aria-label="Podsumowanie zapisanej konfiguracji" className="grid min-w-0 gap-3 sm:grid-cols-2">
    {summaryGroups.map((g, i) => <article key={g.title} className="min-w-0 space-y-2 rounded-lg border border-[#48523c] p-4">
      <h3 className="font-bold">{g.title}</h3>
      {i !== 5 && <p>{checkStatus(readiness?.checks.filter(c => g.keys.includes(c.key)) ?? [])}</p>}
      {i === 5 ? <div className="space-y-2 break-words text-sm">
        <p><strong>Pakiet obejmuje:</strong> {capabilities.filter(c => !c.lane && saved.planFeatures.includes(c.entitlement)).map(c => c.name).join(", ") || "Brak dostępnych funkcji pakietu."}</p>
        <p><strong>Wybrane sekcje strony:</strong> {visibleSections(p, saved.features).map(s => s.name).join(", ") || "Żadna"}. Strona pozostaje niepubliczna.</p>
        <p><strong>Partnerzy:</strong> {saved.partnerCount === null ? "Brak danych." : saved.partnerCount === 0 ? "Brak niezarchiwizowanych partnerów." : `Niezarchiwizowane wpisy: ${saved.partnerCount}. Widoczność zależy od aktywności i okresu emisji.`}</p>
      </div> : <p className="break-words text-sm">{values[i]}</p>}
      {g.step < 6 && <button type="button" className="min-h-11 underline" onClick={() => onStep(g.step)}>Przejdź do kroku {g.step + 1}</button>}
    </article>)}
  </section>;
}
