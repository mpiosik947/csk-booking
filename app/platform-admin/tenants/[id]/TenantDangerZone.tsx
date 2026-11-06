import { noticeLabel } from "@/lib/platform-management";
import type { Eligibility } from "@/lib/platform-management";
import type { Section } from "@/lib/platform-management-session";
import { control, Notices } from "./ManagementCards";

export default function TenantDangerZone({ value, locked, check }: {
  value: Section<Eligibility>; locked: boolean; check: () => void;
}) {
  const result = value.data;
  return <section id="strefa-niebezpieczna" aria-labelledby="danger-heading" className="min-w-0 space-y-4 rounded-xl border border-[#b78676] p-4 [overflow-wrap:anywhere] sm:p-6">
    <h2 id="danger-heading" className="text-xl font-bold">Strefa niebezpieczna</h2>
    <h3 className="text-lg font-semibold">Usuń obiekt na stałe</h3>
    <p id="danger-warning">Trwałe usunięcie obiektu jest nieodwracalne. Funkcja jest dostępna tylko dla obiektów, które nie posiadają danych wymagających zachowania.</p>
    <p>Obecnie można tylko sprawdzić powody blokady. Sprawdzenie nie zmienia żadnych danych.</p>
    <button type="button" className={control} aria-describedby="danger-warning" aria-disabled={locked} onClick={() => { if (!locked) check(); }}>Sprawdź możliwość usunięcia</button>
    <p role="status" className="empty:hidden">{value.loading ? "Sprawdzanie możliwości usunięcia…" : result ? "Nie można trwale usunąć tego obiektu." : ""}</p>
    {value.error && <p role="alert">Nie udało się sprawdzić możliwości usunięcia. Spróbuj ponownie.</p>}
    {result && <>
      <h4 className="font-bold">Powody blokady</h4>
      <ul className="list-disc space-y-2 pl-5">{result.blockers.map((b, index) => <li key={index}>{noticeLabel(b.code, true)}{!["HARD_DELETE_POLICY_DEFERRED", "TENANT_NOT_ARCHIVED", "TENANT_PUBLIC", "UNKNOWN_DEPENDENCY"].includes(b.code) && b.count !== undefined && <> (liczba: {b.count})</>}</li>)}</ul>
      {result.warnings.length > 0 && <><h4 className="font-bold">Ważne informacje</h4><Notices items={result.warnings} deletion /></>}
      {result.tenant.status === "archived" ? <p>Obiekt jest już zarchiwizowany. Jego historia pozostaje zachowana.</p> :
        <a className="inline-flex min-h-11 items-center underline" href="#archiwizacja">Zarchiwizuj obiekt</a>}
    </>}
  </section>;
}
