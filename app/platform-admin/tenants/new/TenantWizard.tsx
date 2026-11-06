"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import FieldGuide from "@/app/_components/FieldGuide";
import WizardFrame from "../WizardFrame";
import WizardProgress from "../WizardProgress";
import useUnsavedNavigation from "../useUnsavedNavigation";
import AdminShell from "@/app/admin/_components/AdminShell";
import { supabase } from "@/lib/supabase";
import { classifyError, identityValid, normalizeSlug, readDetail, slugError } from "@/lib/platform-wizard";
import { readAttempt, receiptId, storageKey, type Attempt } from "@/lib/platform-draft";

const control = "min-h-12 w-full min-w-0 rounded-lg border border-[#626b55] bg-[#161c14] px-3 py-2 disabled:opacity-50";
const button = "min-h-12 rounded-lg border border-[#626b55] bg-[#232c20] px-4 py-2 disabled:opacity-50";

export default function TenantWizard({ actorId }: { actorId: string }) {
  const router = useRouter(), requestId = useRef<string | null>(null), inFlight = useRef(false), heading = useRef<HTMLHeadingElement>(null), alert = useRef<HTMLDivElement>(null);
  const [ready, setReady] = useState(false), [name, setName] = useState(""), [city, setCity] = useState("");
  const [technical, setTechnical] = useState(""), [publicSlug, setPublicSlug] = useState(""), [planKey, setPlanKey] = useState("");
  const [attempt, setAttempt] = useState<Attempt | null>(null), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const [corruptRecovery, setCorruptRecovery] = useState(false);
  const key = storageKey(actorId), locked = attempt !== null || corruptRecovery;
  useUnsavedNavigation(!locked && !!(name || city || technical || publicSlug), busy);
  useEffect(() => {
    const timer = setTimeout(() => {
      requestId.current = crypto.randomUUID();
      try {
        const raw = sessionStorage.getItem(key);
        if (raw) {
          const saved = readAttempt(raw);
          if (!saved) { setCorruptRecovery(true); setError("Zapisanej próby nie można bezpiecznie odczytać. Rozpocznij nowe tworzenie."); }
          else { setAttempt(saved); requestId.current = saved.requestId; setName(saved.payload.p_name); setCity(saved.payload.p_city); setTechnical(saved.payload.p_tenant_slug); setPublicSlug(saved.payload.p_public_slug); setPlanKey(saved.payload.p_plan_key ?? ""); if (saved.failure) setError(classifyErrorForRecovery(saved.failure)); }
        }
      } catch { setCorruptRecovery(true); setError("Nie można odczytać zapisanej próby. Przed tworzeniem sprawdź dostęp do pamięci tej karty."); }
      setReady(true);
    }, 0);
    return () => clearTimeout(timer);
  }, [key]);
  useEffect(() => { if (ready) heading.current?.focus(); }, [ready]);
  useEffect(() => { if (error) (document.querySelector<HTMLElement>('[aria-invalid="true"]') ?? alert.current)?.focus(); }, [error]);
  function persist(value: Attempt) { sessionStorage.setItem(key, JSON.stringify(value)); setAttempt(value); }
  function startNew() {
    if (inFlight.current) return;
    try { sessionStorage.removeItem(key); } catch { setError("Nie można usunąć zapisanej próby. Sprawdź pamięć tej karty."); return; }
    setAttempt(null); setPlanKey(""); setCorruptRecovery(false); requestId.current = crypto.randomUUID(); setError("");
  }
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  function valid() {
    const issues: Record<string, string> = {};
    {
      if (!identityValid(name)) issues.name = "Podaj nazwę obiektu (1–120 znaków).";
      if (!identityValid(city)) issues.city = "Podaj miejscowość (1–120 znaków).";
    }
    {
      const panel = slugError(technical);
      const site = slugError(publicSlug);
      if (panel) issues.technical = panel;
      if (site) issues.publicSlug = site;
      else if (technical === publicSlug) issues.publicSlug = "Adres strony musi różnić się od adresu panelu.";
    }
    setFieldErrors(issues);
    if (Object.keys(issues).length) { setError(Object.values(issues)[0]); return false; }
    return true;
  }
  async function submit() {
    if (inFlight.current || corruptRecovery || attempt?.state === "failed") return;
    let frozen = attempt;
    if (!frozen) {
      if (!valid()) return;
      frozen = { version: 2, requestId: requestId.current ?? crypto.randomUUID(), payload: { p_name: name.trim(), p_city: city.trim(), p_tenant_slug: technical, p_public_slug: publicSlug, p_plan_key: planKey || null }, state: "uncertain" };
    }
    // Persist and freeze before the first request; a reload always recovers its exact payload.
    try { persist(frozen); } catch { setError("Nie można zachować próby w tej karcie. Włącz pamięć sesji przed tworzeniem."); return; }
    inFlight.current = true; setBusy(true); setError("");
    try {
      if (frozen.state !== "confirmed") {
        const { data, error } = await supabase.rpc("platform_create_tenant_draft_v1", { ...frozen.payload, p_creation_request_id: frozen.requestId });
        if (error) {
          const classified = classifyError(error); setError(classified.message);
          if (classified.kind !== "retry") { persist({ ...frozen, state: "failed", failure: classified.kind });  }
          return;
        }
        const id = receiptId(data, frozen);
        if (!id) { setError("Nie udało się potwierdzić odpowiedzi. Ponów tę samą próbę."); return; }
        frozen = { ...frozen, state: "confirmed", tenantId: id }; persist(frozen);
      }
      const id = frozen.tenantId!;
      const { data, error } = await supabase.rpc("platform_get_tenant_onboarding_detail_v1", { p_tenant_id: id });
      if (error || !readDetail(data, id)) { setError("Utworzenie potwierdzone. Nie udało się odczytać bieżącego stanu. Ponów otwarcie obiektu."); return; }
      router.push(`/platform-admin/tenants/${id}/setup?created=1`);
    } catch { setError("Nie udało się potwierdzić wyniku połączenia. Zachowano próbę — ponów ją bez zmiany danych."); }
    finally { inFlight.current = false; setBusy(false); }
  }
  const actions = ready && <div className="flex flex-wrap items-center gap-3">
          <span className="text-sm font-semibold">Krok 1 z 7 · Podstawowe dane</span>
          <button form="create-draft-form" className={button} disabled={busy || corruptRecovery || attempt?.state === "failed"}>
            {busy ? "Potwierdzanie tworzenia…" : attempt?.state === "confirmed" ? "Otwórz utworzony obiekt" : attempt ? "Sprawdź / ponów utworzenie" : "Utwórz szkic i kontynuuj"}
          </button>
          {locked && <button type="button" className={button} disabled={busy} onClick={startNew}>Rozpocznij nowe tworzenie</button>}
        </div>;
  return <WizardFrame actions={actions}><AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Dodaj nową strzelnicę" description="Utwórz obiekt w trybie przygotowania bez administratora lokalnego. Plan możesz przypisać później.">
    <Link href="/platform-admin" className="underline">Wróć do listy</Link>
    <WizardProgress step={0} />
    {!ready ? <p role="status">Odczytywanie zapisanej próby…</p> : <>
      <h2 ref={heading} tabIndex={-1} className="mb-4 text-2xl font-bold outline-offset-4">Podstawowe dane</h2>
      {error && <div ref={alert} tabIndex={-1} role="alert" className="mb-4 rounded-lg border border-[#b58f58] p-4">{error}</div>}
      {attempt && <p role="status" className="mb-4 rounded-lg border border-[#626b55] p-4">{attempt.state === "confirmed" ? "Utworzenie potwierdzone. Otwórz bieżący stan obiektu." : attempt.state === "failed" ? "Operacja została odrzucona. Zmiana danych wymaga rozpoczęcia nowego tworzenia." : "Próba została rozpoczęta. Dane są zachowane; ponowienie użyje tej samej próby."}</p>}
      <form id="create-draft-form" onSubmit={event => { event.preventDefault(); void submit(); }} className="max-w-3xl space-y-5">
        <div className="grid max-w-2xl gap-5 sm:grid-cols-2">
          <FieldGuide label="Nazwa obiektu" help="Pełna nazwa strzelnicy używana w panelu administracyjnym." example="Strzelnica Leśna" required error={fieldErrors.name}>
            <input className={control} value={name} disabled={locked} onChange={e => { setName(e.target.value); setFieldErrors(prev => ({ ...prev, name: "" })); }} autoComplete="off" />
          </FieldGuide>
          <FieldGuide label="Miejscowość" help="Miasto lub miejscowość wyświetlana klientom przy nazwie strzelnicy." example="Wolsztyn" required error={fieldErrors.city}>
            <input className={control} value={city} disabled={locked} onChange={e => { setCity(e.target.value); setFieldErrors(prev => ({ ...prev, city: "" })); }} autoComplete="off" />
          </FieldGuide>
        </div>
        <div className="max-w-xl space-y-5">
          <FieldGuide label="Adres panelu obiektu" help="Wpisz krótką nazwę używaną w adresie panelu po /t/." example="lesna" required error={fieldErrors.technical}>
            <input className={control} value={technical} disabled={locked} onChange={e => { setTechnical(normalizeSlug(e.target.value)); setFieldErrors({}); }} autoCapitalize="none" spellCheck={false} />
          </FieldGuide>
          <p className="break-all">/t/{technical || "lesna"}</p>
          <FieldGuide label="Adres strony obiektu" help="Pod tym adresem klienci znajdą stronę strzelnicy po jej publikacji." example="lesna-public" required error={fieldErrors.publicSlug}>
            <input className={control} value={publicSlug} disabled={locked} onChange={e => { setPublicSlug(normalizeSlug(e.target.value)); setFieldErrors({}); }} autoCapitalize="none" spellCheck={false} />
          </FieldGuide>
          <p className="break-all">https://strzelajtu.pl/{publicSlug || "lesna-public"}</p>
          <p>Adresy muszą być różne. Ich dostępność sprawdzimy przy tworzeniu obiektu.</p>
        </div>
        <p>Utworzysz niepubliczny szkic bez administratora lokalnego. Pakiet wybierzesz w kroku 6.</p>

      </form>
    </>}
  </AdminShell></WizardFrame>;
}

function classifyErrorForRecovery(kind: string) {
  return kind === "conflict" ? "Ta próba ma inne dane. Rozpocznij nowe tworzenie." : "Zapisana operacja została odrzucona. Rozpocznij nowe tworzenie, aby poprawić dane.";
}
