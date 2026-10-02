"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import AdminShell from "@/app/admin/_components/AdminShell";
import { supabase } from "@/lib/supabase";
import { classifyError, identityValid, normalizeSlug, readAccount, readAttempt, readDetail, readPlans, receiptId, slugError, storageKey, type Account, type Attempt, type Plan } from "@/lib/platform-wizard";

const control = "min-h-12 w-full min-w-0 rounded-lg border border-[#626b55] bg-[#161c14] px-3 py-2 disabled:opacity-50";
const button = "min-h-12 rounded-lg border border-[#626b55] bg-[#232c20] px-4 py-2 disabled:opacity-50";
const steps = ["Dane obiektu", "Adresy", "Plan", "Administrator", "Podsumowanie", "Utworzenie"];
const featureLabels: Record<string, string> = { booking: "Rezerwacje", events: "Wydarzenia", instructors: "Instruktorzy", staff: "Pracownicy", checkin: "Check-in", reports: "Raporty", lane_blocks: "Blokady osi", advanced_calendar: "Kalendarz", branding: "Branding", custom_domain: "Domena własna" };

export default function TenantWizard({ actorId }: { actorId: string }) {
  const router = useRouter(), requestId = useRef<string | null>(null), inFlight = useRef(false), heading = useRef<HTMLHeadingElement>(null), alert = useRef<HTMLDivElement>(null);
  const [ready, setReady] = useState(false), [step, setStep] = useState(0), [name, setName] = useState(""), [city, setCity] = useState("");
  const [technical, setTechnical] = useState(""), [publicSlug, setPublicSlug] = useState(""), [planKey, setPlanKey] = useState("");
  const [plans, setPlans] = useState<Plan[]>([]), [plansLoading, setPlansLoading] = useState(true), [plansError, setPlansError] = useState("");
  const [email, setEmail] = useState(""), [account, setAccount] = useState<Account | null>(null), [lookupState, setLookupState] = useState("");
  const [attempt, setAttempt] = useState<Attempt | null>(null), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const [corruptRecovery, setCorruptRecovery] = useState(false);
  const key = storageKey(actorId), locked = attempt !== null || corruptRecovery;
  const selectedPlan = plans.find(p => p.plan_key === planKey);
  const loadPlans = useCallback(async () => {
    setPlansLoading(true); setPlansError("");
    try { const { data, error } = await supabase.rpc("platform_list_active_plans_v1"); const parsed = error ? null : readPlans(data); if (!parsed) { setPlans([]); setPlansError("Nie udało się pobrać planów. Sprawdź dostęp i ponów odczyt."); } else setPlans(parsed); }
    catch { setPlans([]); setPlansError("Nie udało się połączyć z katalogiem planów."); }
    finally { setPlansLoading(false); }
  }, []);
  useEffect(() => {
    const timer = setTimeout(() => {
      requestId.current = crypto.randomUUID();
      try {
        const raw = sessionStorage.getItem(key);
        if (raw) {
          const saved = readAttempt(raw);
          if (!saved) { setCorruptRecovery(true); setError("Zapisanej próby nie można bezpiecznie odczytać. Rozpocznij nowe tworzenie."); }
          else { setAttempt(saved); requestId.current = saved.requestId; setName(saved.payload.p_name); setCity(saved.payload.p_city); setTechnical(saved.payload.p_tenant_slug); setPublicSlug(saved.payload.p_public_slug); setPlanKey(saved.payload.p_plan_key); setEmail(saved.adminEmail); setAccount({ user_id: saved.payload.p_initial_admin_user_id, email: saved.adminEmail }); setStep(5); if (saved.failure) setError(classifyErrorForRecovery(saved.failure)); }
        }
      } catch { setCorruptRecovery(true); setError("Nie można odczytać zapisanej próby. Przed tworzeniem sprawdź dostęp do pamięci tej karty."); }
      setReady(true); void loadPlans();
    }, 0);
    return () => clearTimeout(timer);
  }, [key, loadPlans]);
  useEffect(() => { if (ready) heading.current?.focus(); }, [step, ready]);
  useEffect(() => { if (error) alert.current?.focus(); }, [error]);
  function persist(value: Attempt) { sessionStorage.setItem(key, JSON.stringify(value)); setAttempt(value); }
  function startNew() {
    if (inFlight.current) return;
    try { sessionStorage.removeItem(key); } catch { setError("Nie można usunąć zapisanej próby. Sprawdź pamięć tej karty."); return; }
    const failure = attempt?.failure;
    setAttempt(null); setCorruptRecovery(false); requestId.current = crypto.randomUUID(); setError("");
    if (failure === "plan") { setPlanKey(""); setStep(2); void loadPlans(); }
    else if (failure === "admin") { setAccount(null); setLookupState(""); setStep(3); }
    else if (failure === "slug" || failure === "invalid") setStep(1);
    else setStep(0);
  }
  async function lookup() {
    if (locked || inFlight.current) return;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim()) || email.trim().length > 254) { setError("Podaj poprawny, dokładny adres e-mail."); return; }
    inFlight.current = true; setBusy(true); setError(""); setAccount(null); setLookupState("Sprawdzanie konta…");
    try { const { data, error } = await supabase.rpc("platform_lookup_initial_admin_v1", { p_email: email.trim() }); const found = error ? null : readAccount(data); if (error) setLookupState("Nie udało się sprawdzić konta. Sprawdź dostęp i ponów wyszukiwanie."); else if (!found) setLookupState("Konto administratora musi wcześniej istnieć i mieć potwierdzony adres e-mail."); else { setAccount(found); setLookupState("Potwierdzone konto może zostać administratorem."); } }
    catch { setLookupState("Nie udało się połączyć. Ponów sprawdzenie konta."); }
    finally { inFlight.current = false; setBusy(false); }
  }
  function next() {
    setError("");
    if (attempt) { setStep(Math.min(5, step + 1)); return; }
    if (step === 0 && (!identityValid(name) || !identityValid(city))) { setError("Nazwa i miejscowość muszą mieć od 1 do 120 znaków po usunięciu spacji na brzegach."); return; }
    if (step === 1) { const message = slugError(technical) || slugError(publicSlug) || (technical === publicSlug ? "Adres techniczny i publiczny muszą być różne." : ""); if (message) { setError(message); return; } }
    if (step === 2 && !selectedPlan) { setError("Wybierz jeden aktywny plan."); return; }
    if (step === 3 && !account) { setError("Sprawdź i wybierz istniejące potwierdzone konto administratora."); return; }
    setStep(Math.min(5, step + 1));
  }
  async function submit() {
    if (inFlight.current || corruptRecovery || attempt?.state === "failed") return;
    let frozen = attempt;
    if (!frozen) {
      if (!account || !selectedPlan || !identityValid(name) || !identityValid(city) || slugError(technical) || slugError(publicSlug) || technical === publicSlug) { setError("Sprawdź dane we wcześniejszych krokach."); return; }
      frozen = { version: 1, requestId: requestId.current ?? crypto.randomUUID(), payload: { p_name: name.trim(), p_city: city.trim(), p_tenant_slug: technical, p_public_slug: publicSlug, p_plan_key: planKey, p_initial_admin_user_id: account.user_id }, adminEmail: account.email, state: "uncertain" };
    }
    // Persist and freeze before the first request; a reload always recovers its exact payload.
    try { persist(frozen); } catch { setError("Nie można zachować próby w tej karcie. Włącz pamięć sesji przed tworzeniem."); return; }
    inFlight.current = true; setBusy(true); setError("");
    try {
      if (frozen.state !== "confirmed") {
        const { data, error } = await supabase.rpc("platform_create_tenant_bundle_v2", { ...frozen.payload, p_creation_request_id: frozen.requestId });
        if (error) {
          const classified = classifyError(error); setError(classified.message);
          if (classified.kind !== "retry") { persist({ ...frozen, state: "failed", failure: classified.kind }); if (classified.kind === "plan") { setPlanKey(""); setStep(2); void loadPlans(); } if (classified.kind === "admin") { setAccount(null); setLookupState(""); setStep(3); } }
          return;
        }
        const id = receiptId(data, frozen);
        if (!id) { setError("Nie udało się potwierdzić odpowiedzi. Ponów tę samą próbę."); return; }
        frozen = { ...frozen, state: "confirmed", tenantId: id }; persist(frozen);
      }
      const id = frozen.tenantId!;
      const { data, error } = await supabase.rpc("platform_get_tenant_onboarding_detail_v1", { p_tenant_id: id });
      if (error || !readDetail(data, id)) { setError("Utworzenie potwierdzone. Nie udało się odczytać bieżącego stanu. Ponów otwarcie obiektu."); return; }
      router.push(`/platform-admin/tenants/${id}?created=1`);
    } catch { setError("Nie udało się potwierdzić wyniku połączenia. Zachowano próbę — ponów ją bez zmiany danych."); }
    finally { inFlight.current = false; setBusy(false); }
  }
  return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Dodaj nową strzelnicę" description="Utwórz obiekt w trybie przygotowania z planem i administratorem istniejącego konta.">
    <Link href="/platform-admin" className="underline">Wróć do listy</Link>
    <ol aria-label="Etapy tworzenia" className="my-6 grid gap-2 text-sm sm:grid-cols-3">{steps.map((label, index) => <li key={label} aria-current={step === index ? "step" : undefined} className={`rounded-lg border p-3 ${step === index ? "border-[#d7c895]" : "border-[#394131]"}`}>{index + 1}. {label}</li>)}</ol>
    {!ready ? <p role="status">Odczytywanie zapisanej próby…</p> : <>
      <h2 ref={heading} tabIndex={-1} className="mb-4 text-2xl font-bold outline-offset-4">{steps[step]}</h2>
      {error && <div ref={alert} tabIndex={-1} role="alert" className="mb-4 rounded-lg border border-[#b58f58] p-4">{error}</div>}
      {attempt && <p role="status" className="mb-4 rounded-lg border border-[#626b55] p-4">{attempt.state === "confirmed" ? "Utworzenie potwierdzone. Otwórz bieżący stan obiektu." : attempt.state === "failed" ? "Operacja została odrzucona. Zmiana danych wymaga rozpoczęcia nowego tworzenia." : "Próba została rozpoczęta. Dane są zachowane; ponowienie użyje tej samej próby."}</p>}
      <form onSubmit={event => { event.preventDefault(); if (step < 5) next(); else void submit(); }} className="max-w-3xl space-y-5">
        {step === 0 && <div className="grid gap-4 sm:grid-cols-2"><label className="grid gap-2">Nazwa obiektu<input className={control} value={name} disabled={locked} onChange={e => setName(e.target.value)} autoComplete="off" /></label><label className="grid gap-2">Miejscowość<input className={control} value={city} disabled={locked} onChange={e => setCity(e.target.value)} autoComplete="off" /></label></div>}
        {step === 1 && <div className="space-y-4"><label className="grid gap-2">Adres techniczny<input className={control} value={technical} disabled={locked} onChange={e => setTechnical(normalizeSlug(e.target.value))} autoCapitalize="none" spellCheck={false} /><span className="break-all text-sm">Ścieżka operacyjna: /t/{technical || "example-range"}</span></label><label className="grid gap-2">Adres publiczny<input className={control} value={publicSlug} disabled={locked} onChange={e => setPublicSlug(normalizeSlug(e.target.value))} autoCapitalize="none" spellCheck={false} /><span className="break-all text-sm">https://strzelajtu.pl/{publicSlug || "example-range-public"}</span></label><p>Adresy muszą być różne. Dostępność adresu zostanie ostatecznie sprawdzona podczas tworzenia.</p></div>}
        {step === 2 && <fieldset disabled={locked || plansLoading} className="space-y-3"><legend className="mb-3">Wybierz plan</legend>{plansLoading && <p role="status">Pobieranie planów…</p>}{plansError && <p role="alert">{plansError}</p>}{!plansLoading && !plansError && plans.length === 0 && <p>Brak dostępnych aktywnych planów.</p>}{plans.map(plan => <label key={plan.plan_key} className="block min-w-0 rounded-xl border border-[#48523c] p-4"><span className="flex items-start gap-3"><input type="radio" name="plan" value={plan.plan_key} checked={planKey === plan.plan_key} onChange={() => setPlanKey(plan.plan_key)} className="mt-1" /><span className="min-w-0 break-words font-bold">{plan.display_name}{plan.display_name !== plan.plan_key && <span className="block text-sm font-normal">{plan.plan_key}</span>}</span></span><ul className="mt-3 space-y-2 pl-7 text-sm">{plan.features.map(feature => <li key={feature.feature_key} className="break-words"><strong>{featureLabels[feature.feature_key] ?? feature.feature_key}</strong>: {feature.description}</li>)}</ul>{plan.features.some(f => f.feature_key === "custom_domain") && <p className="mt-3 text-sm">Domena własna może zostać skonfigurowana później.</p>}</label>)}</fieldset>}
        {step === 2 && <button type="button" className={button} disabled={plansLoading || busy} onClick={() => void loadPlans()}>Odśwież katalog planów</button>}
        {step === 3 && <div className="space-y-4"><label className="grid gap-2">E-mail administratora<input className={control} type="email" value={email} disabled={locked} onChange={e => { setEmail(e.target.value); setAccount(null); setLookupState(""); }} autoComplete="off" /></label><button type="button" className={button} disabled={busy || locked} onClick={() => void lookup()}>Sprawdź konto</button><p role="status">{lookupState}</p>{account && <p className="break-all">Wybrane konto: {account.email}</p>}<p>Konto administratora musi wcześniej istnieć i mieć potwierdzony adres e-mail. <Link href="/register" className="underline">Rejestracja konta</Link></p></div>}
        {step >= 4 && <div className="space-y-3 rounded-xl border border-[#48523c] p-4"><dl className="grid gap-3 break-words sm:grid-cols-2">{[["Obiekt", name.trim()], ["Miejscowość", city.trim()], ["Adres techniczny", `/t/${technical}`], ["Adres publiczny", `/${publicSlug}`], ["Plan", selectedPlan?.display_name ?? attempt?.payload.p_plan_key ?? planKey], ["Administrator początkowy", account?.email ?? email]].map(([label, value]) => <div key={label} className="min-w-0"><dt className="text-sm text-[#a9ada4]">{label}</dt><dd className="break-all">{value}</dd></div>)}</dl>{selectedPlan && <p>Możliwości: {selectedPlan.features.map(f => featureLabels[f.feature_key] ?? f.feature_key).join(", ") || "Brak w katalogu"}</p>}<p>Stan początkowy: DORMANT · PRIVATE · NOT PUBLISHED.</p><p>Bez osi i domeny własnej. Utworzenie obiektu nie aktywuje jeszcze rezerwacji ani publikacji.</p></div>}
        <div className="flex flex-wrap gap-3">{step > 0 && <button type="button" className={button} disabled={busy} onClick={() => { setError(""); setStep(step - 1); }}>Wstecz</button>}{step < 5 ? <button className={button} disabled={busy || corruptRecovery}>Dalej</button> : <button className={button} disabled={busy || corruptRecovery || attempt?.state === "failed"}>{busy ? "Potwierdzanie tworzenia…" : attempt?.state === "confirmed" ? "Otwórz utworzony obiekt" : attempt ? "Sprawdź / ponów utworzenie" : "Utwórz strzelnicę"}</button>}{locked && <button type="button" className={button} disabled={busy} onClick={startNew}>Rozpocznij nowe tworzenie</button>}</div>
      </form>
    </>}
  </AdminShell>;
}

function classifyErrorForRecovery(kind: string) {
  return kind === "conflict" ? "Ta próba ma inne dane. Rozpocznij nowe tworzenie." : "Zapisana operacja została odrzucona. Rozpocznij nowe tworzenie, aby poprawić dane.";
}
