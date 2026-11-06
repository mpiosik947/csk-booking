import FieldGuide from "@/app/_components/FieldGuide";
import type { Configuration, Profile } from "@/lib/platform-draft-configuration";
import { capabilities, pageSections, sectionAvailable, type VisibilityKey } from "@/lib/platform-onboarding-features";
import type { Plan } from "@/lib/platform-wizard";

type Props = {
  saved: Configuration;
  form: Profile;
  targetPlan: string;
  previewPlan?: Plan;
  onFlag: (key: VisibilityKey, value: boolean) => void;
  onStep: (step: number) => void;
};

const card = "min-w-0 space-y-1 rounded-lg border border-[#48523c] p-3";
const link = "min-h-11 text-left underline";
const unavailable = "Funkcja niedostępna w wybranym pakiecie.";

export default function FeatureChecklist({ saved, form, targetPlan, previewPlan, onFlag, onStep }: Props) {
  const changingPlan = targetPlan !== (saved.planKey ?? "");
  const available = new Set(changingPlan ? previewPlan?.features.map(f => f.feature_key) : saved.planFeatures);
  return <>
    <section className="space-y-3" aria-labelledby="plan-features">
      <h3 id="plan-features" className="text-lg font-bold">Dostępne w pakiecie</h3>
      <p>{changingPlan ? "Podgląd wybranego pakietu. Zmiana zacznie obowiązywać po zapisaniu." : "Zakres przypisanego pakietu. Dostęp pracowników zależy również od ich roli."}</p>
      {!targetPlan && <p>Wybierz pakiet, aby sprawdzić jego zakres.</p>}
      {[...new Set(capabilities.map(c => c.group))].map(group => <section key={group} className="space-y-2">
        <h4 className="font-semibold">{group}</h4>
        <ul className="grid gap-2 md:grid-cols-2">{capabilities.filter(c => c.group === group).map(c =>
          <li key={c.name} className={card}>
            <strong>{c.name}</strong>
            <p>{c.help}</p>
            <p className="text-sm">{!targetPlan ? "Pakiet nieprzypisany" : available.has(c.entitlement) ? "Dostępna w pakiecie" : unavailable}</p>
            {c.lane && <button type="button" className={link} onClick={() => onStep(1)}>Konfiguruj osie</button>}
          </li>)}</ul>
      </section>)}
    </section>
    <section aria-labelledby="page-settings" className="space-y-3">
      <h3 id="page-settings" className="text-lg font-bold">Włączone dla tego obiektu</h3>
      <p>Wybierz sekcje strony po publikacji. Ich widoczność nie zmienia uprawnień do rezerwacji ani zapisów na wydarzenia.</p>
      {changingPlan && <p>Ustawienia sekcji poniżej dotyczą dotychczas przypisanego pakietu.</p>}
      <ul className="grid gap-2 md:grid-cols-2">{pageSections.map(section => {
        const allowed = sectionAvailable(section, saved.features);
        const reason = changingPlan ? "Najpierw zapisz zmianę pakietu lub przywróć poprzedni wybór." :
          !allowed ? (saved.planKey ? unavailable : "Najpierw przypisz pakiet obsługujący tę sekcję.") : "";
        const status = allowed && form[section.key] ? "Włączona" : "Wyłączona";
        return <li className={card} key={section.key}>
          <FieldGuide label={section.name} help={[section.help, status + ".", reason, !allowed && form[section.key] ? "Zapisany wybór zostaje zachowany." : ""].filter(Boolean).join(" ")}>
            <input type="checkbox" checked={allowed && form[section.key]} disabled={!!reason} onChange={e => onFlag(section.key, e.target.checked)} />
          </FieldGuide>
        </li>;
      })}</ul>
      <button type="button" className={link} onClick={() => onStep(4)}>Konfiguruj treść i wygląd strony</button>
    </section>
    <section aria-label="Wbudowane możliwości" className="grid gap-2 md:grid-cols-2">
      <div className={card}><strong>Strona obiektu</strong><p>Wbudowana w system. Szkic jest niepubliczny. Publikacja i otwarcie zapisów wymagają osobnych działań.</p></div>
      <div className={card}><strong>Partnerzy</strong><p>Wbudowana w system. Sekcja pojawi się na dostępnej publicznie stronie, gdy aktywny partner będzie w okresie emisji.</p></div>
    </section>
  </>;
}
