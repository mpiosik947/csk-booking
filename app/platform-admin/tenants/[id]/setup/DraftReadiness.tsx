"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { checkStep, wizardSteps } from "@/lib/platform-onboarding-steps";
import { supabase } from "@/lib/supabase";
import { configError } from "@/lib/platform-draft-configuration";
import { readReadiness, readinessNotice, type Readiness } from "@/lib/platform-draft-readiness";

const button = "min-h-11 rounded-lg border border-[#626b55] bg-[#232c20] px-4 py-2 disabled:opacity-50";

const checkCopy: Record<string, [label: string, help: string]> = {
  identity: ["Podstawowe dane obiektu", "Uzupełnij nazwę, miejscowość i poprawne adresy panelu oraz strony."],
  safe_state: ["Obiekt w przygotowaniu", "Przed przekazaniem obiekt musi być niepubliczny i dostępny wkrótce."],
  plan: ["Aktywny plan", "Przypisz aktywny pakiet do obiektu."],
  membership: ["Dostęp do obiektu", "Pierwsza osoba otrzyma dostęp do obiektu podczas przekazania."],
  resources: ["Osie i stanowiska", "Sprawdź pojemności, aktywność i przypisanie stanowisk do osi."],
  booking: ["Rezerwacje online", "Pakiet z rezerwacjami wymaga przynajmniej jednej dostępnej osi lub stanowiska z czasami i cenami."],
  prices: ["Ceny", "Sprawdź ceny na stronie i stawki godzinowe dla wszystkich liczebności grup."],
  durations: ["Długości rezerwacji", "Każda długość musi być wielokrotnością odstępu między godzinami rozpoczęcia."],
  references: ["Powiązania osi i stanowisk", "Osie i przypisane do nich stanowiska muszą należeć do tego obiektu."],
  branding: ["Logo i zdjęcie główne", "Obrazy na stronę możesz dodać później."],
  contact: ["Dane kontaktowe", "Klientom przyda się adres strzelnicy oraz e-mail lub telefon."],
  content: ["Opis strzelnicy", "Krótki opis strony możesz uzupełnić później."],
  hours: ["Godziny otwarcia", "Informacja dla klientów jest opcjonalna i nie wyznacza dostępności terminów."],
  partners: ["Partnerzy", "Partnerów możesz dodać później."],
};
export function useDraftReadiness(tenantId: string, actorId: string, archived: boolean, revision: string | undefined) {
  const [data, setData] = useState<Readiness | null>(null), [busy, setBusy] = useState(false), [denied, setDenied] = useState(false);
  const [validating, setValidating] = useState(false);
  const [error, setError] = useState(""), [retry, setRetry] = useState<string | null>(null);
  const alive = useRef(true), writing = useRef(false), terminalDenial = useRef(false), readSequence = useRef(0), alert = useRef<HTMLParagraphElement>(null);
  const read = useCallback(async () => {
    const response = await supabase.rpc("platform_get_draft_readiness_v1", { p_tenant_id: tenantId });
    if (response.error) throw { ...response.error, status: response.status };
    const parsed = readReadiness(response.data, tenantId);
    if (!parsed) throw new Error("INVALID_READINESS");
    return parsed;
  }, [tenantId]);
  const load = useCallback(async () => {
    if (!alive.current || writing.current || terminalDenial.current) return;
    const sequence = ++readSequence.current; setBusy(true); setError(""); setData(null);
    try { const fresh = await read(); if (alive.current && sequence === readSequence.current) setData(fresh); }
    catch (e) { if (alive.current && sequence === readSequence.current) { setData(null); setError("Nie udało się odczytać gotowości. Odśwież dane przed weryfikacją."); if (configError(e as { code?: string; status?: number }).kind === "denied") { terminalDenial.current = true; setDenied(true); } } }
    finally { if (alive.current && sequence === readSequence.current) setBusy(false); }
  }, [read]);
  useEffect(() => {
    alive.current = true; readSequence.current++; const timer = setTimeout(() => void load(), 0);
    const focus = () => { if (document.visibilityState === "visible") void load(); };
    window.addEventListener("focus", focus); document.addEventListener("visibilitychange", focus);
    const listener = supabase.auth.onAuthStateChange((_event, session) => { if (!session || session.user.id !== actorId) { alive.current = false; readSequence.current++; setData(null); setRetry(null); setDenied(true); } });
    return () => { alive.current = false; clearTimeout(timer); listener.data.subscription.unsubscribe(); window.removeEventListener("focus", focus); document.removeEventListener("visibilitychange", focus); };
  }, [actorId, load, revision]);
  useEffect(() => { if (error) alert.current?.focus(); }, [error]);

  async function validate() {
    const revision = retry ?? data?.revision;
    if (!revision || writing.current || busy || denied || archived) return;
    writing.current = true; setValidating(true); readSequence.current++; setBusy(true); setError(""); setData(null);
    try {
      const response = await supabase.rpc("platform_validate_draft_readiness_v1", { p_tenant_id: tenantId, p_expected_revision: revision });
      if (response.error) throw { ...response.error, status: response.status };
      const receipt = readReadiness(response.data, tenantId);
      if (!receipt || (receipt.revision !== null && receipt.revision !== revision)) throw new Error("INVALID_READINESS_RECEIPT");
      const fresh = await read(); if (!alive.current) return;
      setData(fresh); setRetry(null);
    } catch (e) {
      if (!alive.current) return;
      const issue = configError(e as { code?: string; status?: number });
      if (issue.kind === "denied") { terminalDenial.current = true; setDenied(true); setRetry(null); setError("Brak dostępu do weryfikacji. Wróć do listy obiektów."); }
      else {
        setRetry(issue.kind === "uncertain" ? revision : null);
        setError(issue.kind === "conflict" ? "Konfiguracja zmieniła się. Odczytano aktualną gotowość; sprawdź ją przed ponowną weryfikacją." : "Nie potwierdzono wyniku weryfikacji. Ponów próbę lub odczytaj stan serwera.");
        try { const fresh = await read(); if (alive.current) { setData(fresh); if (fresh.current || fresh.revision !== revision) setRetry(null); } } catch { /* Remain without an authoritative status. */ }
      }
    } finally { writing.current = false; if (alive.current) { setBusy(false); setValidating(false); } }
  }

  return { data, busy, validating, denied, error, retry, validate, load, alert };
}

type Props = {
  controller: ReturnType<typeof useDraftReadiness>;
  synchronized: boolean;
  onRefresh: () => void;
  onStep: (step: number) => void;
};

export default function DraftReadiness({ controller, synchronized, onRefresh, onStep }: Props) {
  const { data, busy, denied, error, retry, validate, alert } = controller;
  return <section aria-label="Sprawdzenie gotowości" className="space-y-4 rounded-lg border border-[#626b55] p-4">
    <h3 className="text-xl font-bold">Sprawdzenie gotowości</h3>
    <p>Weryfikacja dotyczy zapisanej konfiguracji. Nie publikuje obiektu i nie przypisuje administratora.</p>
    {busy && <p role="status">Sprawdzanie danych…</p>}
    {error && <p ref={alert} tabIndex={-1} role="alert">{error}</p>}
    {denied ? <p role="alert">Dostęp do weryfikacji jest niedostępny.</p> : <>
      {data && <>
        <p role="status" className={data.current ? "font-bold text-green-300" : "font-bold text-amber-200"}>{readinessNotice(data)}</p>
        {data.validatedAt && <div className="space-y-1 text-sm"><p>Ostatnia pomyślna weryfikacja: {new Date(data.validatedAt).toLocaleString("pl-PL")}</p></div>}
        {wizardSteps.map((title, i) => {
          const failed = data.checks.filter(c => c.result === "FAIL" && checkStep(c.key) === i);
          if (!failed.length) return null;
          return <div key={title}><h4 className="font-semibold">{title}</h4><ul className="list-disc pl-5">{failed.map(c =>
            <li key={c.key}>{checkCopy[c.key]?.[0] ?? c.label}: {c.severity === "BLOCKER" ? "Blokuje weryfikację" : "Ostrzeżenie"}.
              {" "}{checkCopy[c.key]?.[1] ?? c.explanation}</li>)}</ul>
            {i < 6 && <button className={button} onClick={() => onStep(i)}>Przejdź do kroku {i + 1}</button>}
          </div>;
        })}
      </>}
      <div className="flex flex-wrap gap-3"><button className={button} type="button" disabled={busy || !synchronized || (!retry && !data?.revision)} onClick={() => void validate()}>{retry ? "Ponów tę samą weryfikację" : data?.current ? "Sprawdź ponownie" : "Sprawdź gotowość"}</button><button className={button} type="button" disabled={busy} onClick={onRefresh}>Odśwież gotowość</button></div>
    </>}
  </section>;
}
