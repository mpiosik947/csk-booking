"use client";

import Link from "next/link";
import DraftReadiness, { useDraftReadiness } from "./DraftReadiness";
import TenantHandoverPage, { TenantHandover } from "./TenantHandover";
import { useCallback, useEffect, useRef, useState } from "react";
import FieldGuide from "@/app/_components/FieldGuide";
import AdminShell from "@/app/admin/_components/AdminShell";
import WizardFrame from "../../WizardFrame";
import WizardProgress from "../../WizardProgress";
import useUnsavedNavigation from "../../useUnsavedNavigation";
import LaneStep from "./LaneStep";
import FeatureChecklist from "./FeatureChecklist";
import WizardSummary from "./WizardSummary";
import { draftStatus, resumeStep, wizardSteps } from "@/lib/platform-onboarding-steps";
import type { Readiness } from "@/lib/platform-draft-readiness";
import LaneFamilyCreateDialog from "@/app/admin/lane-configuration/_components/LaneFamilyCreateDialog";
import LaneConfigurationEditor from "@/app/admin/lane-configuration/_components/LaneConfigurationEditor";
import { parseLaneFamilyCreateResult, parseLaneConfigurationWriteResult } from "@/lib/admin/lane-configuration";
import { supabase } from "@/lib/supabase";
import { readPlans, type Plan } from "@/lib/platform-wizard";
import { featureName, planName, noticeLabel, readPlanPreview, type PlanPreview } from "@/lib/platform-management";
import { configError, configReceipt, configStorageKey, parseConfigAttempt, parseConfiguration, profileFlagKeys, type ConfigAttempt, type Configuration, type PricingItem, type Profile, type Section } from "@/lib/platform-draft-configuration";
import { parseHours, serializeHours, validateSettings, type Hours } from "@/app/tenant-setup/settings-validation";

const input = "mt-1 min-h-11 w-full min-w-0 rounded-lg border border-[#626b55] bg-[#161c14] p-3";
const button = "min-h-11 rounded-lg border border-[#626b55] bg-[#232c20] px-4 py-2 disabled:opacity-50";
type Props = {
  tenantId: string; actorId: string; initial: Configuration; initialReadiness: Readiness | null;
  entry: "created" | "summary" | "resume";
};
export default function DraftConfigurationWizard({ tenantId, actorId, initial, initialReadiness, entry }: Props) {
  const [handedOver, setHandedOver] = useState(false);
  const [saved, setSaved] = useState<Configuration | null>(null), [form, setForm] = useState<Profile | null>(null);
  const [name, setName] = useState(""), [pricing, setPricing] = useState<PricingItem[]>([]), [hours, setHours] = useState<Hours>(parseHours(null));
  const [saveFailure, setSaveFailure] = useState(false);
  const [showValidation, setShowValidation] = useState(false);
  const [step, setStep] = useState(0), [busy, setBusy] = useState(false), [loading, setLoading] = useState(true);
  const [error, setError] = useState(""), [message, setMessage] = useState(""), [conflict, setConflict] = useState(false), [denied, setDenied] = useState(false);
  const [pending, setPending] = useState<ConfigAttempt | null>(null), [storageBroken, setStorageBroken] = useState(false);
  const [plans, setPlans] = useState<Plan[]>([]), [targetPlan, setTargetPlan] = useState(""), [planPreview, setPlanPreview] = useState<PlanPreview | null>(null);
  const [creating, setCreating] = useState(false), [editing, setEditing] = useState<string | null>(null), [laneDirty, setLaneDirty] = useState(false);
  const inFlight = useRef(false), alive = useRef(true), heading = useRef<HTMLHeadingElement>(null), alert = useRef<HTMLDivElement>(null);
  const [handoverDirty, setHandoverDirty] = useState(false);
  const resumeKey = `strzelajtu:setup-step:v2:${actorId}:${tenantId}`;
  const batch = useRef(false);
  const key = configStorageKey(actorId, tenantId);
  const dirty = !!saved && !!form && (name !== saved.name || JSON.stringify(form) !== JSON.stringify(saved.profile) || JSON.stringify(pricing) !== JSON.stringify(saved.pricing) || JSON.stringify(hours) !== JSON.stringify(parseHours(saved.profile.opening_hours)) || targetPlan !== (saved.planKey ?? "") || laneDirty || handoverDirty);
  const readiness = useDraftReadiness(tenantId, actorId, saved?.status === "archived", saved?.revision);
  const synchronized = !!saved && !!readiness.data && saved.revision === readiness.data.revision;
  const proof = synchronized ? readiness.data : null;
  const locked = busy || readiness.validating || loading || denied || conflict || storageBroken || !!pending || saved?.status === "archived";

  const install = useCallback((data: Configuration) => {
    setShowValidation(false); setSaveFailure(false); setSaved(data); setForm(structuredClone(data.profile)); setName(data.name); setPricing(structuredClone(data.pricing)); setHours(parseHours(data.profile.opening_hours)); setTargetPlan(data.planKey ?? ""); setPlanPreview(null);
  }, []);
  const read = useCallback(async () => {
    const r = await supabase.rpc("platform_get_draft_configuration_v1", { p_tenant_id: tenantId });
    if (r.error) throw { ...r.error, status: r.status };
    const parsed = parseConfiguration(r.data, tenantId);
    if (!parsed) throw new Error("INVALID_CONFIGURATION_READ");
    return parsed;
  }, [tenantId]);
  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await read(); if (!alive.current) return; install(data); setConflict(false); setError("");
      const catalog = await supabase.rpc("platform_list_active_plans_v1");
      if (alive.current) setPlans(catalog.error ? [] : readPlans(catalog.data) ?? []);
    } catch (e) { if (alive.current) { const issue = configError(e as { code?: string }); setError(issue.message); if (issue.kind === "denied") { setDenied(true); setSaved(null); setForm(null); } } }
    finally { if (alive.current) setLoading(false); }
  }, [install, read]);
  useEffect(() => {
    alive.current = true;
    const timer = setTimeout(() => {
      let last: string | null = null;
      try { last = sessionStorage.getItem(resumeKey); } catch { /* Step position is optional. */ }
      setStep(entry === "summary" ? 6 : entry === "created" && last === null ? 0 : resumeStep(last, initialReadiness, initial.lanes.families.length));
      try { const raw = sessionStorage.getItem(key); if (raw) { const a = parseConfigAttempt(raw, tenantId); if (!a) { setStorageBroken(true); setError("Nie można bezpiecznie odczytać poprzedniej próby. Wróć do listy i sprawdź zapisane dane."); } else setPending(a); } }
      catch { setStorageBroken(true); }
      void load();
    }, 0);
    const listener = supabase.auth.onAuthStateChange((_event, session) => { if (!session || session.user.id !== actorId) { alive.current = false; setDenied(true); setSaved(null); setForm(null); } });
    return () => { alive.current = false; clearTimeout(timer); listener.data.subscription.unsubscribe(); };
  }, [actorId, key, load, tenantId, resumeKey, entry, initialReadiness, initial]);
  useEffect(() => { heading.current?.focus(); }, [step]);
  useEffect(() => {
    if (!error) return;
    const invalid = document.querySelector<HTMLElement>('form [aria-invalid="true"]');
    invalid?.closest("details")?.setAttribute("open", "");
    (invalid ?? alert.current)?.focus();
  }, [error]);
  useUnsavedNavigation(dirty || !!pending, busy || readiness.validating || !!pending);
  function go(next: number) {
    setStep(next); setError(""); setMessage(""); setShowValidation(false);
    try { sessionStorage.setItem(resumeKey, String(next)); } catch { /* Use the server checks on reopen. */ }
  }

  async function save(section: Section, payload: Record<string, unknown>, retry?: ConfigAttempt, expected = saved?.revision): Promise<{ mutation: Record<string, unknown>; current: Configuration }> {
    if (!alive.current || !saved || !expected || inFlight.current || denied || (!retry && locked)) throw new Error("SAVE_UNAVAILABLE");
    const attempt = retry ?? { tenantId, revision: expected, requestId: crypto.randomUUID(), section, payload };
    if (attempt.tenantId !== tenantId) throw new Error("TENANT_MISMATCH");
    setSaveFailure(false);
    try { sessionStorage.setItem(key, JSON.stringify(attempt)); } catch { setSaveFailure(true); setStorageBroken(true); setError("Nie można zachować próby zapisu w tej karcie. Sprawdź dostęp do pamięci sesji."); throw new Error("STORAGE_UNAVAILABLE"); }
    inFlight.current = true; setBusy(true); setPending(attempt); setError(""); setMessage("");
    try {
      const r = await supabase.rpc("platform_save_draft_configuration_v1", { p_tenant_id: tenantId, p_expected_revision: attempt.revision, p_request_id: attempt.requestId, p_section: attempt.section, p_payload: attempt.payload });
      if (r.error) throw { ...r.error, status: r.status };
      const receipt = configReceipt(r.data, attempt); if (!receipt) throw new Error("INVALID_RECEIPT");
      const current = await read(); if (!alive.current) throw new Error("SESSION_CHANGED");
      if (current.revision !== r.data.revision) throw { code: "PT409" };
      sessionStorage.removeItem(key); setPending(null); setConflict(false);
      // A step may own two existing writes. Keep edits outside this acknowledgement, also on replay.
      setSaved(current);
      const ownsKey = (k: string) => (section === "identity" || section === "profile") && Object.hasOwn(payload, k);
      const nextProfile = structuredClone(current.profile);
      if (form) Object.assign(nextProfile, Object.fromEntries(Object.entries(form).filter(([k, v]) =>
        !ownsKey(k) && JSON.stringify(v) !== JSON.stringify(saved.profile[k as keyof Profile]))));
      setForm(nextProfile);
      if (section === "identity" || name === saved.name) setName(current.name);
      if (section === "pricing" || JSON.stringify(pricing) === JSON.stringify(saved.pricing)) setPricing(structuredClone(current.pricing));
      if (ownsKey("opening_hours") || JSON.stringify(hours) === JSON.stringify(parseHours(saved.profile.opening_hours))) setHours(parseHours(current.profile.opening_hours));
      if (section === "plan" || targetPlan === (saved.planKey ?? "")) setTargetPlan(current.planKey ?? "");
      setPlanPreview(null); setMessage("Zapisano");
      return { mutation: receipt, current };
    } catch (e) {
      if (alive.current) {
        const issue = configError(e as { code?: string }); setSaveFailure(true); setError(issue.message);
        if (issue.kind !== "uncertain") { sessionStorage.removeItem(key); setPending(null); }
        if (issue.kind === "conflict") setConflict(true);
        if (issue.kind === "denied") { setDenied(true); setSaved(null); setForm(null); }
        // Always reread after an uncertain acknowledgement. Do not overwrite edits or claim success.
        if (issue.kind === "uncertain" || issue.kind === "conflict") { try { await read(); } catch { setError("Nie udało się potwierdzić zapisu ani odczytać stanu. Zachowano próbę; sprawdź połączenie i ponów."); } }
        if (issue.kind === "uncertain" && ["create_lane", "update_lane"].includes(attempt.section)) { setCreating(false); setEditing(null); setLaneDirty(false); }
      }
      throw e;
    } finally { inFlight.current = false; if (alive.current) setBusy(false); }
  }
  function move(next: number) {
    if (step === next || busy || readiness.validating || pending || batch.current || creating || editing) return;
    if (dirty && !window.confirm("Masz niezapisane zmiany. Odrzucić je i przejść do innego kroku?")) return;
    if (saved) install(saved);
    go(next);
  }
  function text(k: keyof Profile, value: string) { setForm(p => p ? { ...p, [k]: value || null } : p); }
  function flag(k: typeof profileFlagKeys[number], value: boolean) { setForm(p => p ? { ...p, [k]: value } : p); }
  const issues = form ? validateSettings(form, hours) : {};
  if (!name.trim() || Array.from(name.trim()).length > 120) issues.name = "Podaj nazwę obiektu (1–120 znaków).";
  const rejectedPriceFields: Record<string, string> = {};
  if (step === 4 && showValidation && saveFailure) {
    // Explain a rejected row using the public price-list constraints.
    pricing.forEach((row, i) => {
      const key = (field: string) => `price-${i}-${field}`;
      if (!row.title.trim() || row.title.trim().length > 120) rejectedPriceFields[key("title")] = "Podaj nazwę usługi (1–120 znaków).";
      if (!row.unit.trim() || row.unit.trim().length > 80) rejectedPriceFields[key("unit")] = "Podaj jednostkę ceny (1–80 znaków).";
      if (!/^[A-Z]{3}$/.test(row.currency)) rejectedPriceFields[key("currency")] = "Podaj trzyliterowy kod waluty, np. PLN.";
      if (!Number.isFinite(row.price) || row.price < 0 || row.price > 9999999.99 || Math.abs(row.price * 100 - Math.round(row.price * 100)) > 0.000001) rejectedPriceFields[key("price")] = "Podaj cenę od 0 do 9 999 999,99 z maksymalnie dwoma miejscami po przecinku.";
      if (!Number.isInteger(row.display_order) || row.display_order < 0 || row.display_order > 9999) rejectedPriceFields[key("display_order")] = "Podaj całkowitą kolejność od 0 do 9999.";
      if ((row.short_description?.trim().length ?? 0) > 300) rejectedPriceFields[key("short_description")] = "Skróć opis do 300 znaków.";
    });
  }
  const fieldError = (key: string) => showValidation ? issues[key] ?? rejectedPriceFields[key] : undefined;
  async function saveStep(advance: boolean) {
    if (!form || !saved || locked || batch.current || inFlight.current) return;
    if (!(document.getElementById("draft-step-form") as HTMLFormElement | null)?.reportValidity()) return;
    setShowValidation(true);
    if (Object.keys(issues).length) {
      setError(Object.values(issues)[0]);
      requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());
      return;
    }
    const writes: { section: Section; payload: Record<string, unknown> }[] = [];
    if (step === 0 && (name !== saved.name || form.display_name !== saved.profile.display_name || form.city !== saved.profile.city)) {
      writes.push({ section: "identity", payload: { name: name.trim(), display_name: form.display_name?.trim(), city: form.city?.trim() } });
    }
    const profile: Record<string, unknown> = {};
    for (const [k, value] of Object.entries(form)) {
      if (k !== "display_name" && k !== "city" && JSON.stringify(value) !== JSON.stringify(saved.profile[k as keyof Profile])) {
        profile[k] = typeof value === "string" ? value.trim() || null : value;
      }
    }
    if (step === 3 && JSON.stringify(hours) !== JSON.stringify(parseHours(saved.profile.opening_hours))) profile.opening_hours = serializeHours(hours);
    if (Object.keys(profile).length) writes.push({ section: "profile", payload: profile });
    if (JSON.stringify(pricing) !== JSON.stringify(saved.pricing)) writes.push({ section: "pricing", payload: { pricing_items: pricing } });
    if (targetPlan !== (saved.planKey ?? "")) {
      if (!planPreview?.can_apply || planPreview.target_plan.plan_key !== targetPlan) {
        setError("Sprawdź zmianę planu przed zapisaniem pakietu."); return;
      }
      if (!window.confirm("Potwierdzić przypisanie wybranego pakietu do tego obiektu?")) return;
      writes.push({ section: "plan", payload: { plan_key: targetPlan } });
    }
    batch.current = true;
    try {
      let current = saved;
      for (const write of writes) {
        const ack = await save(write.section, write.payload, undefined, current.revision);
        current = ack.current;
      }
      if (!alive.current) return;
      install(current); setError(""); setMessage("Zapisano");
      if (advance) go(Math.min(step + 1, 6));
    } catch { /* Stay on this step. The failed or uncertain operation owns its retry. */ }
    finally { batch.current = false; }
  }

  async function previewPlan() {
    setPlanPreview(null); setError("");
    try { const r = await supabase.rpc("platform_get_tenant_plan_change_preview_v1", { p_tenant_id: tenantId, p_target_plan_key: targetPlan }); const p = r.error ? null : readPlanPreview(r.data, tenantId, targetPlan); if (!p) throw r.error; if (alive.current) setPlanPreview(p); }
    catch { setError("Nie udało się pobrać podglądu zmiany planu. Odśwież dane."); }
  }
  function field(key: keyof Profile, label: string, help: string, example?: string, type = "text", multiline = false) {
    return <Field label={label} help={help} example={example} required={key === "display_name" || key === "city"}
      error={fieldError(key)} value={String(form?.[key] ?? "")} type={type} multiline={multiline} onChange={value => text(key, value)} />;
  }
  const closeCreate = useCallback(() => {
    if (!inFlight.current) setCreating(false);
  }, []);
  const closeEditor = useCallback(() => {
    if (!inFlight.current) { setEditing(null); setLaneDirty(false); }
  }, []);
  const completeLane = async () => { setCreating(false); setEditing(null); setLaneDirty(false); };
  const family = saved?.lanes.families.find(f => f.root_lane_id === editing);
  if (handedOver) return <TenantHandoverPage tenantId={tenantId} actorId={actorId} />;
  if (denied || readiness.denied) return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Brak dostępu"><p role="alert">Otwórz listę obiektów na koncie administratora platformy.</p><Link href="/platform-admin">Lista obiektów</Link></AdminShell>;

  const actions = saved && <footer id="draft-actions" aria-label="Działania kroku" className="space-y-1 sm:flex sm:items-center sm:justify-between sm:gap-4">
        <p className="text-sm font-semibold">Krok {step + 1} z 7 · {wizardSteps[step]}</p>
        <p role="status" className="text-sm">{busy ? "Zapisywanie..." : pending ? "Zapis wymaga potwierdzenia" : error && (conflict || saveFailure || showValidation) ? "Błąd zapisu" : dirty ? "Masz niezapisane zmiany" : saved.status === "archived" ? "Archiwum · tylko do odczytu" : message || "Zapisano"}</p>
        <div className="flex flex-wrap gap-2">
          <button type="button" className={button} disabled={!step || busy || readiness.validating || !!pending} onClick={() => move(step - 1)}>Wstecz</button>
          {[0, 3, 4, 5].includes(step) && <button form="draft-step-form" className={button} disabled={!dirty || locked}>Zapisz zmiany</button>}
          {step < 6 && <button type="button" className={button} disabled={busy || readiness.validating || !!pending || (dirty && locked)}
            onClick={() => { if (dirty) void saveStep(true); else go(step + 1); }}>{dirty ? "Zapisz i przejdź dalej" : "Dalej"}</button>}
        </div>
      </footer>;
  return <WizardFrame actions={actions}><AdminShell eyebrow="StrzelajTu.pl · Platforma" title={saved?.name ?? "Konfiguracja obiektu"} description="Zapisuj kolejne części konfiguracji i wracaj do nich później. Obiekt pozostaje niepubliczny.">
    <nav className="mb-5 flex flex-wrap gap-4"><Link className="underline" href="/platform-admin">Lista obiektów</Link><Link className="underline" href={`/platform-admin/tenants/${tenantId}`}>Zarządzaj obiektem</Link></nav>
    {saved && <p className="mb-4 font-semibold">{draftStatus(saved.status === "archived", proof)} · Niepubliczny · Dostępna wkrótce · Administratorzy lokalni: 0.</p>}
    {dirty && step < 6 && proof?.current && <p>Wynik sprawdzenia dotyczy ostatnio zapisanych danych.</p>}
    {step !== 6 && saved?.status !== "archived" && proof?.stale && <p role="status">Konfiguracja zmieniła się od ostatniego sprawdzenia. Sprawdź gotowość ponownie przed przekazaniem obiektu.</p>}
    {saved?.status === "archived" && <p className="my-4">Obiekt zarchiwizowany. <Link className="underline" href={`/platform-admin/tenants/${tenantId}#archiwizacja`}>Przywróć obiekt do przygotowania</Link></p>}
    <WizardProgress step={step} readiness={proof} laneCount={saved?.lanes.families.length} onStep={move} locked={busy || readiness.validating || loading || !!pending || denied} />
    <h2 ref={heading} tabIndex={-1} className="mb-4 text-2xl font-bold outline-offset-4">{wizardSteps[step]}</h2>
    {loading && <p role="status">Odczytywanie konfiguracji…</p>}
    {error && <div role="alert" ref={alert} tabIndex={-1} className="my-4 rounded-lg border border-red-700 p-4">{error}</div>}
    {storageBroken && <p role="alert">Pamięć zapisanej próby jest niedostępna lub uszkodzona. Edycja została zablokowana; sprawdź zapisane dane obiektu.</p>}

    {pending && !denied && <div className="my-4 rounded-lg border border-amber-700 p-4"><p>Poprzedni zapis wymaga potwierdzenia. Ponowienie zachowa te same dane i identyfikator próby.</p><button className={button} disabled={busy || loading} onClick={() => void save(pending.section, pending.payload, pending).then(completeLane).catch(() => {})}>Sprawdź / ponów zapis</button></div>}
    {!denied && <button type="button" className={button + " mb-5"} disabled={busy || !!pending} onClick={() => { if (!dirty || window.confirm("Odczyt zastąpi niezapisane wartości. Kontynuować?")) void load(); }}>Odczytaj bieżące dane</button>}
    {saved && form && !denied && <>
      <form id="draft-step-form" onSubmit={e => { e.preventDefault(); void saveStep(false); }} className="space-y-5">
        <fieldset disabled={locked} className="min-w-0 space-y-5">
          {step === 0 && <>
            <div className="grid max-w-3xl gap-5 sm:grid-cols-2">
              <Field label="Nazwa obiektu" help="Pełna nazwa używana w panelu administracyjnym." example="Strzelnica Leśna" required value={name} error={fieldError("name")} onChange={setName} />
              {field("display_name", "Nazwa wyświetlana", "Nazwa widoczna dla klientów w katalogu i na stronie obiektu.", "Strzelnica Leśna")}
              {field("city", "Miejscowość", "Miejscowość widoczna przy nazwie strzelnicy.", "Wolsztyn")}
            </div>
            <p className="break-all">Adres panelu: /t/{saved.slug}<br />Adres strony: /{saved.publicSlug}</p>
            <p>Adresy ustalono przy tworzeniu obiektu.</p>
          </>}
          {step === 4 && <div className="grid max-w-3xl gap-5 sm:grid-cols-2">
            {field("logo_path", "Logo obiektu", "Wskaż istniejący plik witryny z logo na stronę obiektu.", "/brand/logo.png")}
            {field("hero_image_path", "Zdjęcie główne", "Wskaż istniejące zdjęcie wyświetlane u góry strony obiektu.", "/images/strzelnica.jpg")}
          </div>}
          {step === 0 && <>
            <h3 className="text-lg font-semibold">Dane kontaktowe</h3>
            <p>Te informacje zobaczą klienci po publikacji strony obiektu.</p>
            <div className="grid max-w-3xl gap-5 sm:grid-cols-2">
              {field("public_address", "Adres strzelnicy", "Podaj adres dojazdu do obiektu.", "ul. Leśna 10, Wolsztyn")}
              {field("public_phone", "Telefon kontaktowy", "Numer udostępniany klientom na stronie strzelnicy.", "+48 000 000 000")}
              {field("public_email", "E-mail kontaktowy", "Adres do kontaktu z obsługą strzelnicy.", "kontakt@example.com", "email")}
              {field("public_map_url", "Link do mapy", "Wklej link HTTPS do lokalizacji strzelnicy.", undefined, "url")}
            </div>
            <details className="max-w-3xl" open={showValidation && !!(issues.facebook || issues.instagram || issues.youtube) || undefined}><summary className="cursor-pointer py-3">Media społecznościowe</summary>
              <div className="grid gap-5 sm:grid-cols-2">
                {(["Facebook", "Instagram", "YouTube"] as const).map(label => {
                  const key = label.toLowerCase();
                  return <Field key={key} label={label} help={`Wklej link HTTPS do profilu strzelnicy w serwisie ${label}.`}
                    type="url" error={fieldError(key)} value={form.social_links[key] ?? ""}
                    onChange={v => setForm(p => p ? { ...p, social_links: Object.fromEntries(Object.entries({ ...p.social_links, [key]: v }).filter(([, value]) => value)) } : p)} />;
                })}
              </div>
            </details>
          </>}
          {step === 3 && <>
            <h3 className="text-lg font-semibold">Godziny otwarcia</h3>
            <p>Godziny informacyjne wyświetlane klientom. Nie określają automatycznie dostępności terminów rezerwacji.</p>
            {hours.legacy !== null ? <>
              <p>{hours.legacy}</p>
              <button className={button} type="button" onClick={() => setHours(parseHours(null))}>Zastąp dotychczasowy zapis godzin</button>
            </> : <div className="grid max-w-lg gap-5 sm:grid-cols-2">
              <Field label="Godzina otwarcia" help="Podaj wraz z godziną zamknięcia albo pozostaw oba pola puste." type="time" required={!!hours.closingTime} value={hours.openingTime} error={fieldError("openingTime")} onChange={v => setHours(h => ({ ...h, openingTime: v }))} />
              <Field label="Godzina zamknięcia" help="Wybierz godzinę późniejszą niż otwarcie tego samego dnia." type="time" required={!!hours.openingTime} value={hours.closingTime} error={fieldError("closingTime")} onChange={v => setHours(h => ({ ...h, closingTime: v }))} />
            </div>}
          </>}
          {(step === 1 || step === 2) && <LaneStep lanes={saved.lanes} booking={step === 2} onCreate={() => setCreating(true)} onEdit={setEditing} />}
          {step === 3 && <>
            {field("regulations_path", "Plik regulaminu", "Wskaż istniejący plik z regulaminem obiektu.", "/documents/regulamin.pdf")}
            <p>Terminy rezerwacji i zasady anulowania wynikają z reguł serwisu.</p>
          </>}
          {step === 4 && saved.features.booking && form.show_pricing && <>
            <p>Ten cennik pojawi się na stronie strzelnicy po publikacji. Stawki za rezerwację ustawisz przy osi i stanowiskach.</p>
            {pricing.map((item, i) => <fieldset key={item.id ?? `new-${i}`} className="grid min-w-0 max-w-3xl gap-5 border-t border-[#626b55] py-4 sm:grid-cols-2">
              <legend>Pozycja {i + 1}</legend>
              {([
                ["title", "Nazwa usługi", "Nazwa widoczna w cenniku na stronie."],
                ["currency", "Waluta ceny", "Podaj trzyliterowy kod waluty, np. PLN."],
                ["unit", "Jednostka ceny", "Określ, za co podana jest cena, np. za zajęcia."],
                ["short_description", "Opis usługi", "Krótko wyjaśnij klientom, co obejmuje cena."],
              ] as const).map(([key, label, help]) => <Field key={key} label={label} help={help} required={key !== "short_description"} error={fieldError(`price-${i}-${key}`)} value={item[key] ?? ""}
                onChange={v => setPricing(rows => rows.map((r, n) => n === i ? { ...r, [key]: v || (key === "short_description" ? null : "") } : r))} />)}
              <Field label="Cena informacyjna" help="Kwota za wskazaną usługę, wyświetlana na stronie." error={fieldError(`price-${i}-price`)} required type="number" value={String(item.price)} onChange={v => setPricing(rows => rows.map((r, n) => n === i ? { ...r, price: Number(v) } : r))} />
              <Field label="Kolejność na stronie" help="Niższa liczba oznacza wcześniejszą pozycję." error={fieldError(`price-${i}-display_order`)} required type="number" value={String(item.display_order)} onChange={v => setPricing(rows => rows.map((r, n) => n === i ? { ...r, display_order: Number(v) } : r))} />
              <FieldGuide label="Pokaż pozycję w cenniku" help="Wyłącz, aby ukryć usługę i zachować jej dane.">
                <input type="checkbox" checked={item.is_active} onChange={e => setPricing(rows => rows.map((r, n) => n === i ? { ...r, is_active: e.target.checked } : r))} />
              </FieldGuide>
              {!item.id && <button type="button" className={button} onClick={() => setPricing(rows => rows.filter((_, n) => n !== i))}>Usuń niezapisaną pozycję</button>}
            </fieldset>)}
            <button type="button" className={button} disabled={pricing.length >= 100} onClick={() => setPricing(rows => [...rows, { id: null, title: "", price: 0, currency: "PLN", unit: "", short_description: null, display_order: rows.length * 10, is_active: true }])}>Dodaj pozycję cennika</button>
          </>}
          {step === 4 && <>
            <p>Zapisane informacje pojawią się na stronie po publikacji obiektu.</p>
            <div className="grid max-w-3xl gap-5">
              {field("description", "Krótki opis", "Przedstaw klientom strzelnicę i jej najważniejszą ofertę.", undefined, "text", true)}
              {form.show_about && field("about_offer", "Oferta obiektu", "Opisz zajęcia i usługi dostępne w strzelnicy.", undefined, "text", true)}
              {form.show_about && field("about_audience", "Dla kogo", "Napisz, do kogo kierujesz ofertę.", undefined, "text", true)}
              <Link className="underline" href={`/platform-admin/tenants/${tenantId}/preview`}>Prywatny podgląd zapisanej strony</Link>
              <p>Kontakt i lokalizacja: {[saved.profile.public_address, saved.profile.city, saved.profile.public_email, saved.profile.public_phone].filter(Boolean).join(" · ")}</p>
            </div>
            <button type="button" className="min-h-11 underline" onClick={() => move(5)}>Wybierz widoczne sekcje w kroku „Funkcje obiektu”</button>
          </>}
          {step === 5 && <>
            <p>Wybierz funkcje, z których ma korzystać ten obiekt. Pokażemy tylko ustawienia, które są potrzebne.</p>
            <p>Bieżący plan: {saved.planKey ? planName(saved.planKey) : "Nieprzypisany"}. Wybór pakietu nie publikuje obiektu.</p>
            <FieldGuide className="max-w-lg" label="Pakiet obiektu" help={profileFlagKeys.some(k => form[k] !== saved.profile[k]) ? "Zapisz zmiany widoczności przed wyborem innego pakietu." : "Wybierz pakiet przed przekazaniem obiektu administratorowi."} required>
              <select className={input} value={targetPlan} disabled={profileFlagKeys.some(k => form[k] !== saved.profile[k])} onChange={e => { setTargetPlan(e.target.value); setPlanPreview(null); }}>
                <option value="" disabled={!!saved.planKey}>Wybierz pakiet</option>
                {plans.map(p => <option key={p.plan_key} value={p.plan_key}>{planName(p.plan_key) === p.plan_key ? p.display_name : planName(p.plan_key)}</option>)}
              </select>
            </FieldGuide>
            <button type="button" className={button} disabled={!targetPlan} onClick={() => void previewPlan()}>Sprawdź zmianę planu</button>
            {planPreview && <div className="space-y-3">
              <p>Dodawane funkcje: {planPreview.features_added.map(featureName).join(", ") || "brak"}</p>
              <p>Usuwane funkcje: {planPreview.features_removed.map(featureName).join(", ") || "brak"}</p>
              {[...planPreview.warnings, ...planPreview.blockers].map((w, i) =>
                <p key={i}>{noticeLabel(w.code)} {w.feature_key && featureName(w.feature_key)}</p>)}
              <p>Potwierdź wybór przy zapisie tego kroku.</p>
            </div>}
            <FeatureChecklist saved={saved} form={form} targetPlan={targetPlan} previewPlan={plans.find(p => p.plan_key === targetPlan)} onFlag={flag} onStep={move} />
          </>}
        </fieldset>
      </form>
      {step === 6 && <>
        <WizardSummary saved={saved} readiness={proof} onStep={move} />
        <Link className="my-4 inline-flex min-h-11 items-center underline" href={`/platform-admin/tenants/${tenantId}/preview`}>Prywatny podgląd zapisanej strony</Link>
        {saved.status !== "archived" && <>
          {readiness.data && !synchronized && <p role="alert">Zapisane dane obiektu się zmieniły. Odśwież gotowość, aby wczytać aktualną konfigurację.</p>}
          <DraftReadiness controller={readiness} synchronized={synchronized && !pending && !busy && !conflict}
            onRefresh={() => { void load(); void readiness.load(); }} onStep={move} />
          <TenantHandover tenantId={tenantId} actorId={actorId} permittedRevision={proof?.current && !conflict && !pending ? proof.revision : null}
            onDirty={setHandoverDirty} onSync={() => { void load(); void readiness.load(); }} onBusy={setBusy} onCompleted={() => setHandedOver(true)} />
        </>}
      </>}

      {creating && !denied && <LaneFamilyCreateDialog onDirtyChange={setLaneDirty} onClose={closeCreate} onCreate={async p => parseLaneFamilyCreateResult((await save("create_lane", p as unknown as Record<string, unknown>)).mutation)} onCompleted={completeLane} />}
      {family && !denied && <LaneConfigurationEditor key={family.root_lane_id} family={family} onClose={closeEditor} onDirtyChange={setLaneDirty} onWrite={async (id, version, resources) => parseLaneConfigurationWriteResult((await save("update_lane", { root_lane_id: id, expected_version: version, resources })).mutation)} onCompleted={completeLane} />}
    </>}
  </AdminShell></WizardFrame>;
}

type FieldProps = {
  label: string; help: string; value: string; onChange: (value: string) => void;
  type?: string; multiline?: boolean; required?: boolean; example?: string; error?: string;
};

function Field({ label, help, value, type = "text", multiline, required, example, error, onChange }: FieldProps) {
  return <FieldGuide label={label} help={help} example={example} required={required} error={error}>
    {multiline
      ? <textarea className={input + " min-h-28"} maxLength={1200} value={value} onChange={e => onChange(e.target.value)} />
      : <input className={input + (type === "number" || type === "time" ? " max-w-52" : " max-w-xl")} type={type} step={type === "number" ? "any" : undefined} value={value} onChange={e => onChange(e.target.value)} />}
  </FieldGuide>;
}
