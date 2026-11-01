"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import { configError } from "@/lib/platform-draft-configuration";
import { readReadiness, readinessNotice, type Readiness } from "@/lib/platform-draft-readiness";

const button = "min-h-11 rounded-lg border border-[#626b55] bg-[#232c20] px-4 py-2 disabled:opacity-50";

export default function DraftReadiness({ tenantId, actorId, archived }: { tenantId: string; actorId: string; archived: boolean }) {
  const [data, setData] = useState<Readiness | null>(null), [busy, setBusy] = useState(false), [denied, setDenied] = useState(false);
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
  }, [actorId, load]);
  useEffect(() => { if (error) alert.current?.focus(); }, [error]);

  async function validate() {
    const revision = retry ?? data?.revision;
    if (!revision || writing.current || busy || denied || archived) return;
    writing.current = true; readSequence.current++; setBusy(true); setError(""); setData(null);
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
    } finally { writing.current = false; if (alive.current) setBusy(false); }
  }

  return <section aria-label="Sprawdzenie gotowości" className="space-y-4 rounded-lg border border-[#626b55] p-4">
    <h3 className="text-xl font-bold">Sprawdzenie gotowości</h3>
    <p>Weryfikacja dotyczy zapisanej konfiguracji. Nie publikuje obiektu i nie przypisuje administratora.</p>
    {busy && <p role="status">Sprawdzanie danych…</p>}
    {error && <p ref={alert} tabIndex={-1} role="alert">{error}</p>}
    {denied ? <p role="alert">Dostęp do weryfikacji jest niedostępny.</p> : <>
      {data && <>
        <p role="status" className={data.current ? "font-bold text-green-300" : "font-bold text-amber-200"}>{readinessNotice(data)}</p>
        <p className="break-all text-sm">Rewizja konfiguracji: {data.revision ?? "Nie można ustalić spójnej rewizji"}</p>
        {data.validatedAt && <div className="space-y-1 text-sm"><p>Ostatnia pomyślna weryfikacja: {new Date(data.validatedAt).toLocaleString("pl-PL")}</p><p className="break-all">Weryfikujący PA: {data.validatedBy ?? "Usunięte konto"}</p><p className="break-all">Zweryfikowana rewizja: {data.validatedRevision}</p></div>}
        <ul className="space-y-3">{data.checks.map(c => <li key={c.key} className="rounded-lg border border-[#626b55] p-3"><p className="font-semibold">{c.label}: {c.result === "PASS" ? "OK" : c.severity === "BLOCKER" ? "Blokuje weryfikację" : "Ostrzeżenie"}</p><p>{c.explanation}</p></li>)}</ul>
      </>}
      <div className="flex flex-wrap gap-3"><button className={button} type="button" disabled={busy || archived || (!retry && !data?.revision)} onClick={() => void validate()}>{retry ? "Ponów tę samą weryfikację" : "Sprawdź gotowość"}</button><button className={button} type="button" disabled={busy} onClick={() => void load()}>Odśwież gotowość</button></div>
      {archived && <p>Archiwalny draft nie może zostać zweryfikowany do przekazania. Przywróć go i sprawdź ponownie.</p>}
    </>}
  </section>;
}
