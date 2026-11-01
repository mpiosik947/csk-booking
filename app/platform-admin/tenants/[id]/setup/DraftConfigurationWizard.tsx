"use client";

import Link from "next/link";
import DraftReadiness from "./DraftReadiness";
import TenantHandoverPage, { TenantHandover } from "./TenantHandover";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import AdminShell from "@/app/admin/_components/AdminShell";
import LaneFamilyCreateDialog from "@/app/admin/lane-configuration/_components/LaneFamilyCreateDialog";
import LaneConfigurationEditor from "@/app/admin/lane-configuration/_components/LaneConfigurationEditor";
import { parseLaneFamilyCreateResult, parseLaneConfigurationWriteResult } from "@/lib/admin/lane-configuration";
import { supabase } from "@/lib/supabase";
import { readPlans, type Plan } from "@/lib/platform-wizard";
import { noticeLabel, readPlanPreview, type PlanPreview } from "@/lib/platform-management";
import { configError, configReceipt, configStorageKey, parseConfigAttempt, parseConfiguration, profileFlagKeys, type ConfigAttempt, type Configuration, type PricingItem, type Profile, type Section } from "@/lib/platform-draft-configuration";
import { parseHours, serializeHours, validateSettings, type Hours } from "@/app/tenant-setup/settings-validation";

const steps = ["Dane obiektu", "Branding", "Kontakt i godziny", "Osie i rezerwacje", "Cennik publiczny", "Treści i moduły", "Plan", "Podgląd / test", "Przekazanie obiektu"];
const input = "mt-1 min-h-11 w-full min-w-0 rounded-lg border border-[#626b55] bg-[#161c14] p-3";
const button = "min-h-11 rounded-lg border border-[#626b55] bg-[#232c20] px-4 py-2 disabled:opacity-50";
const flagLabels = ["Rezerwacje", "Cennik", "Instruktorzy", "Wydarzenia", "O obiekcie", "Kontakt", "Regulamin"];

export default function DraftConfigurationWizard({ tenantId, actorId }: { tenantId: string; actorId: string }) {
  const [handedOver, setHandedOver] = useState(false);
  const [saved, setSaved] = useState<Configuration | null>(null), [form, setForm] = useState<Profile | null>(null);
  const [name, setName] = useState(""), [pricing, setPricing] = useState<PricingItem[]>([]), [hours, setHours] = useState<Hours>(parseHours(null));
  const [step, setStep] = useState(0), [busy, setBusy] = useState(false), [loading, setLoading] = useState(true);
  const [error, setError] = useState(""), [message, setMessage] = useState(""), [conflict, setConflict] = useState(false), [denied, setDenied] = useState(false);
  const [pending, setPending] = useState<ConfigAttempt | null>(null), [storageBroken, setStorageBroken] = useState(false);
  const [plans, setPlans] = useState<Plan[]>([]), [targetPlan, setTargetPlan] = useState(""), [planPreview, setPlanPreview] = useState<PlanPreview | null>(null);
  const [creating, setCreating] = useState(false), [editing, setEditing] = useState<string | null>(null), [laneDirty, setLaneDirty] = useState(false);
  const inFlight = useRef(false), alive = useRef(true), heading = useRef<HTMLHeadingElement>(null), alert = useRef<HTMLDivElement>(null);
  const key = configStorageKey(actorId, tenantId);
  const dirty = !!saved && !!form && (name !== saved.name || JSON.stringify(form) !== JSON.stringify(saved.profile) || JSON.stringify(pricing) !== JSON.stringify(saved.pricing) || serializeHours(hours) !== saved.profile.opening_hours || laneDirty || creating);
  const locked = busy || loading || denied || conflict || storageBroken || !!pending || saved?.status === "archived";

  const install = useCallback((data: Configuration) => {
    setSaved(data); setForm(structuredClone(data.profile)); setName(data.name); setPricing(structuredClone(data.pricing)); setHours(parseHours(data.profile.opening_hours)); setTargetPlan(data.planKey ?? ""); setPlanPreview(null);
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
      try { const raw = sessionStorage.getItem(key); if (raw) { const a = parseConfigAttempt(raw, tenantId); if (!a) { setStorageBroken(true); setError("Nie można bezpiecznie odczytać poprzedniej próby. Wróć do listy i sprawdź zapisane dane."); } else setPending(a); } }
      catch { setStorageBroken(true); }
      void load();
    }, 0);
    const listener = supabase.auth.onAuthStateChange((_event, session) => { if (!session || session.user.id !== actorId) { alive.current = false; setDenied(true); setSaved(null); setForm(null); } });
    return () => { alive.current = false; clearTimeout(timer); listener.data.subscription.unsubscribe(); };
  }, [actorId, key, load, tenantId]);
  useEffect(() => { heading.current?.focus(); }, [step]);
  useEffect(() => { if (error) alert.current?.focus(); }, [error]);
  useEffect(() => {
    if (!dirty && !pending && !busy) return;
    const before = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ""; };
    const navigation = (e: MouseEvent) => { const a = (e.target as Element)?.closest?.("a[href]"); if (a && (busy || !window.confirm("Masz niezapisane zmiany lub niepotwierdzony zapis. Czy opuścić konfigurację?"))) { e.preventDefault(); e.stopPropagation(); } };
    window.addEventListener("beforeunload", before); document.addEventListener("click", navigation, true);
    return () => { window.removeEventListener("beforeunload", before); document.removeEventListener("click", navigation, true); };
  }, [busy, dirty, pending]);

  async function save(section: Section, payload: Record<string, unknown>, retry?: ConfigAttempt): Promise<Record<string, unknown>> {
    if (!saved || inFlight.current || denied || (!retry && locked)) throw new Error("SAVE_UNAVAILABLE");
    const attempt = retry ?? { tenantId, revision: saved.revision, requestId: crypto.randomUUID(), section, payload };
    if (attempt.tenantId !== tenantId) throw new Error("TENANT_MISMATCH");
    try { sessionStorage.setItem(key, JSON.stringify(attempt)); } catch { setStorageBroken(true); setError("Nie można zachować próby zapisu w tej karcie. Sprawdź dostęp do pamięci sesji."); throw new Error("STORAGE_UNAVAILABLE"); }
    inFlight.current = true; setBusy(true); setPending(attempt); setError(""); setMessage("");
    try {
      const r = await supabase.rpc("platform_save_draft_configuration_v1", { p_tenant_id: tenantId, p_expected_revision: attempt.revision, p_request_id: attempt.requestId, p_section: attempt.section, p_payload: attempt.payload });
      if (r.error) throw { ...r.error, status: r.status };
      const receipt = configReceipt(r.data, attempt); if (!receipt) throw new Error("INVALID_RECEIPT");
      const current = await read(); if (!alive.current) throw new Error("SESSION_CHANGED");
      sessionStorage.removeItem(key); setPending(null); setConflict(false); install(current); setMessage("Zapis potwierdzony. Odczytano bieżącą konfigurację."); return receipt;
    } catch (e) {
      if (alive.current) {
        const issue = configError(e as { code?: string }); setError(issue.message);
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
  function move(next: number) { if (busy || pending) return; if (dirty && !window.confirm("Masz niezapisane zmiany. Czy je odrzucić i zmienić sekcję?")) return; if (saved) install(saved); setStep(next); setError(""); setMessage(""); }
  function text(k: keyof Profile, value: string) { setForm(p => p ? { ...p, [k]: value || null } : p); }
  function flag(k: typeof profileFlagKeys[number], value: boolean) { setForm(p => p ? { ...p, [k]: value } : p); }
  async function saveSection(e: FormEvent) {
    e.preventDefault(); if (!form || !saved) return;
    if (step === 0 && (!name.trim() || Array.from(name.trim()).length > 120)) { setError("Nazwa obiektu musi mieć od 1 do 120 znaków."); return; }
    const validation = validateSettings(form, hours);
    if (Object.keys(validation).length) { setError(Object.values(validation)[0]); return; }
    const take = (keys: (keyof Profile)[]) => Object.fromEntries(keys.map(k => [k, typeof form[k] === "string" ? (form[k] as string).trim() || null : form[k]]));
    try {
      if (step === 0) await save("identity", { name: name.trim(), ...take(["display_name", "city"]) });
      if (step === 1) await save("profile", take(["logo_path", "hero_image_path"]));
      if (step === 2) await save("profile", { ...take(["public_address", "public_phone", "public_email", "social_links", "public_map_url"]), opening_hours: serializeHours(hours) });
      if (step === 4) await save("pricing", { pricing_items: pricing });
      if (step === 5) await save("profile", take(["description", "about_offer", "about_audience", "regulations_path", ...profileFlagKeys]));
    } catch { /* Keep values and the actionable error set by save. */ }
  }
  async function previewPlan() {
    setPlanPreview(null); setError("");
    try { const r = await supabase.rpc("platform_get_tenant_plan_change_preview_v1", { p_tenant_id: tenantId, p_target_plan_key: targetPlan }); const p = r.error ? null : readPlanPreview(r.data, tenantId, targetPlan); if (!p) throw r.error; if (alive.current) setPlanPreview(p); }
    catch { setError("Nie udało się pobrać podglądu zmiany planu. Odśwież dane."); }
  }
  const field = (k: keyof Profile, label: string, type = "text", multiline = false) => <Field key={k} label={label} value={String(form?.[k] ?? "")} type={type} multiline={multiline} onChange={value => text(k, value)} />;
  const completeLane = async () => { setCreating(false); setEditing(null); setLaneDirty(false); };
  const family = saved?.lanes.families.find(f => f.root_lane_id === editing);
  if (handedOver) return <TenantHandoverPage tenantId={tenantId} actorId={actorId} />;

  return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title={saved?.name ?? "Konfiguracja draftu"} description="Zapisuj kolejne części konfiguracji i wracaj do nich później. Obiekt pozostaje niepubliczny.">
    <nav className="mb-5 flex flex-wrap gap-4"><Link className="underline" href="/platform-admin">Lista obiektów</Link><Link className="underline" href={`/platform-admin/tenants/${tenantId}`}>Zarządzaj draftem</Link></nav>
    {saved && <p className="mb-5">{saved.status === "archived" ? "Obiekt zarchiwizowany — przywróć go na stronie zarządzania przed edycją." : "W konfiguracji · Dostępna wkrótce · Nieopublikowana"} · Administratorzy lokalni: 0.</p>}
    <nav aria-label="Sekcje konfiguracji" className="mb-6 grid grid-cols-2 gap-2 md:grid-cols-4">{steps.map((label, i) => <button key={label} className={button + (step === i ? " border-[#d7c895]" : "")} aria-current={step === i ? "step" : undefined} onClick={() => move(i)} disabled={busy || !!pending}>{i + 1}. {label}</button>)}</nav>
    <h2 ref={heading} tabIndex={-1} className="mb-4 text-2xl font-bold">{steps[step]}</h2>
    {loading && <p role="status">Odczytywanie konfiguracji…</p>}
    {error && <div role="alert" ref={alert} tabIndex={-1} className="my-4 rounded-lg border border-red-700 p-4">{error}</div>}
    {storageBroken && <p role="alert">Pamięć zapisanej próby jest niedostępna lub uszkodzona. Edycja została zablokowana; sprawdź zapisane dane obiektu.</p>}
    {message && <p role="status" className="my-4 rounded-lg border border-green-700 p-4">{message}</p>}
    {pending && !denied && <div className="my-4 rounded-lg border border-amber-700 p-4"><p>Poprzedni zapis wymaga potwierdzenia. Ponowienie zachowa te same dane i identyfikator próby.</p><button className={button} disabled={busy || loading} onClick={() => void save(pending.section, pending.payload, pending).then(completeLane).catch(() => {})}>Sprawdź / ponów zapis</button></div>}
    {!denied && <button type="button" className={button + " mb-5"} disabled={busy || !!pending} onClick={() => { if (!dirty || window.confirm("Odczyt zastąpi niezapisane wartości. Kontynuować?")) void load(); }}>Odczytaj bieżące dane</button>}
    {saved && form && !denied && <>
      <form onSubmit={saveSection} className="space-y-5">
        <fieldset disabled={locked} className="min-w-0 space-y-5">
          {step === 0 && <><div className="grid gap-4 sm:grid-cols-2"><Field label="Pełna nazwa obiektu" value={name} onChange={setName} />{field("display_name", "Nazwa publiczna")}{field("city", "Miejscowość")}</div><p className="break-all">Adres techniczny: /t/{saved.slug}<br />Adres publiczny: /{saved.publicSlug}</p><p>Adresy ustalono przy tworzeniu obiektu; w konfiguracji pozostają bez zmian.</p></>}
          {step === 1 && <><div className="grid gap-4 sm:grid-cols-2">{field("logo_path", "Ścieżka logo")}{field("hero_image_path", "Ścieżka obrazu głównego")}</div><p>Wybierz ścieżkę istniejącego pliku tej witryny, np. /brand/logo.png. Ten formularz nie przesyła plików.</p></>}
          {step === 2 && <><div className="grid gap-4 sm:grid-cols-2">{field("public_address", "Adres publiczny")}{field("public_phone", "Telefon publiczny")}{field("public_email", "E-mail publiczny", "email")}{field("public_map_url", "Link do mapy (HTTPS)", "url")}{["facebook", "instagram", "youtube"].map(k => <Field key={k} label={`${k} URL`} type="url" value={form.social_links[k] ?? ""} onChange={v => setForm(p => p ? { ...p, social_links: Object.fromEntries(Object.entries({ ...p.social_links, [k]: v }).filter(([, v]) => v)) } : p)} />)}</div><p>Godziny poniżej są informacją publiczną. Nie zmieniają godzin przyjmowania rezerwacji.</p>{hours.legacy !== null ? <><p>{hours.legacy}</p><button className={button} type="button" onClick={() => setHours(parseHours(null))}>Zastąp dotychczasowy zapis godzin</button></> : <div className="grid gap-4 sm:grid-cols-2"><Field label="Godzina otwarcia" type="time" value={hours.openingTime} onChange={v => setHours(h => ({ ...h, openingTime: v }))} /><Field label="Godzina zamknięcia" type="time" value={hours.closingTime} onChange={v => setHours(h => ({ ...h, closingTime: v }))} /></div>}</>}
          {step === 3 && <><p>Oś i jej stanowiska korzystają ze wspólnej konfiguracji pojemności, czasów i cennika. Włączenie rezerwacji online na osi nie publikuje draftu.</p><button type="button" className={button} onClick={() => setCreating(true)}>Dodaj oś i stanowiska</button>{saved.lanes.families.map(f => <article key={f.root_lane_id} className="rounded-lg border border-[#626b55] p-4"><h3 className="break-words text-xl">{f.root.name}</h3><p>Stanowiska: {f.children.length} · Pojemność osi: {f.root.max_shooters} · Cała oś: {f.root.whole_lane_bookable ? "tak" : "nie"}</p><button type="button" className={button} onClick={() => setEditing(f.root_lane_id)}>Edytuj oś, rezerwacje i ceny</button></article>)}<p>Godziny rezerwacji i zasady anulowania/weryfikacji wynikają z obecnych reguł aplikacji. Ten etap nie dodaje nowych przełączników tych zasad.</p></>}
          {step === 4 && <><p>Pozycje prezentowane na stronie cennika. Ceny rezerwacji ustawisz w sekcji osi. Zapisaną pozycję można wyłączyć.</p>{pricing.map((item, i) => <fieldset key={item.id ?? `new-${i}`} className="grid min-w-0 gap-4 rounded-lg border border-[#626b55] p-4 sm:grid-cols-2"><legend>Pozycja {i + 1}</legend>{([['title', 'Nazwa'], ['currency', 'Waluta'], ['unit', 'Jednostka'], ['short_description', 'Opis']] as const).map(([k, label]) => <Field key={k} label={label} value={item[k] ?? ""} onChange={v => setPricing(rows => rows.map((r, n) => n === i ? { ...r, [k]: v || (k === 'short_description' ? null : '') } : r))} />)}<Field label="Cena" type="number" value={String(item.price)} onChange={v => setPricing(rows => rows.map((r, n) => n === i ? { ...r, price: Number(v) } : r))} /><Field label="Kolejność" type="number" value={String(item.display_order)} onChange={v => setPricing(rows => rows.map((r, n) => n === i ? { ...r, display_order: Number(v) } : r))} /><label><input type="checkbox" checked={item.is_active} onChange={e => setPricing(rows => rows.map((r, n) => n === i ? { ...r, is_active: e.target.checked } : r))} /> Aktywna pozycja</label>{!item.id && <button type="button" className={button} onClick={() => setPricing(rows => rows.filter((_, n) => n !== i))}>Usuń niezapisaną pozycję</button>}</fieldset>)}<button type="button" className={button} disabled={pricing.length >= 100} onClick={() => setPricing(rows => [...rows, { id: null, title: "", price: 0, currency: "PLN", unit: "", short_description: null, display_order: rows.length * 10, is_active: true }])}>Dodaj pozycję cennika</button></>}
          {step === 5 && <><div className="grid gap-4 sm:grid-cols-2">{field("description", "Krótki opis", "text", true)}{field("about_offer", "Oferta obiektu", "text", true)}{field("about_audience", "Dla kogo", "text", true)}{field("regulations_path", "Ścieżka regulaminu")}</div><p>Widoczność sekcji nie włącza publicznego dostępu ani funkcji poza wybranym planem. Wydarzenia i konta pracowników powstaną poza tym etapem.</p><div className="grid gap-3 sm:grid-cols-2">{profileFlagKeys.map((k, i) => <label key={k} className="flex min-h-11 items-center gap-3"><input type="checkbox" checked={form[k]} onChange={e => flag(k, e.target.checked)} />{flagLabels[i]}</label>)}</div></>}
          {[0, 1, 2, 4, 5].includes(step) && <button className={button} disabled={!dirty}>{busy ? "Zapisywanie…" : "Zapisz sekcję"}</button>}
          {step === 6 && <><p>Bieżący plan: {saved.planKey ?? "Nieprzypisany"}. Wybór planu nie publikuje obiektu.</p><label>Plan<select className={input} value={targetPlan} onChange={e => { setTargetPlan(e.target.value); setPlanPreview(null); }}><option value="">Wybierz plan</option>{plans.map(p => <option key={p.plan_key} value={p.plan_key}>{p.display_name}</option>)}</select></label><button type="button" className={button} disabled={!targetPlan} onClick={() => void previewPlan()}>Sprawdź zmianę planu</button>{planPreview && <div className="space-y-3"><p>Dodawane funkcje: {planPreview.features_added.join(", ") || "brak"}</p><p>Usuwane funkcje: {planPreview.features_removed.join(", ") || "brak"}</p>{[...planPreview.warnings, ...planPreview.blockers].map((w, i) => <p key={i}>{noticeLabel(w.code)} {w.feature_key}</p>)}<button type="button" className={button} disabled={!planPreview.can_apply || planPreview.target_plan.plan_key !== targetPlan} onClick={() => { if (window.confirm("Potwierdzić przypisanie wybranego planu do tego draftu?")) void save("plan", { plan_key: targetPlan }).catch(() => {}); }}>Potwierdź plan</button></div>}</>}
        </fieldset>
      </form>
      {step === 7 && <section className="space-y-4"><p>Podgląd korzysta z zapisanej konfiguracji. Nie tworzy rezerwacji ani wydarzeń i nie nadaje publicznego dostępu.</p><Link className={button + " inline-flex items-center"} href={`/platform-admin/tenants/${tenantId}/preview`}>Otwórz prywatny podgląd i test konfiguracji</Link><p>Osie: {saved.lanes.families.length} · Stanowiska: {saved.lanes.resources.filter(r => r.resource_kind === "position").length} · Pozycje cennika: {saved.pricing.length}</p><p>Brak administratora lokalnego. Zapis konfiguracji nie oznacza zatwierdzenia gotowości.</p><DraftReadiness key={`${actorId}:${tenantId}:${saved.revision}`} tenantId={tenantId} actorId={actorId} archived={saved.status === "archived"} /></section>}
      {step === 8 && <TenantHandover key={`${actorId}:${tenantId}:${saved.revision}`} tenantId={tenantId} actorId={actorId} onBusy={setBusy} onCompleted={() => setHandedOver(true)} />}
      <nav aria-label="Kolejność konfiguracji" className="mt-7 flex flex-wrap gap-3"><button className={button} disabled={step === 0 || busy || !!pending} onClick={() => move(step - 1)}>Wstecz</button><button className={button} disabled={step === steps.length - 1 || busy || !!pending} onClick={() => move(step + 1)}>Dalej</button></nav>
      {creating && !denied && <LaneFamilyCreateDialog onClose={() => { if (!busy) setCreating(false); }} onCreate={async p => parseLaneFamilyCreateResult(await save("create_lane", p as unknown as Record<string, unknown>))} onCompleted={completeLane} />}
      {family && !denied && <LaneConfigurationEditor key={family.root_lane_id} family={family} onClose={() => { if (!busy) { setEditing(null); setLaneDirty(false); } }} onDirtyChange={setLaneDirty} onWrite={async (id, version, resources) => parseLaneConfigurationWriteResult(await save("update_lane", { root_lane_id: id, expected_version: version, resources }))} onCompleted={completeLane} />}
    </>}
  </AdminShell>;
}

function Field({ label, value, onChange, type = "text", multiline = false }: { label: string; value: string; onChange: (v: string) => void; type?: string; multiline?: boolean }) {
  return <label className="block min-w-0">{label}{multiline ? <textarea className={input + " min-h-28"} maxLength={1200} value={value} onChange={e => onChange(e.target.value)} /> : <input className={input} type={type} step={type === "number" ? "any" : undefined} value={value} onChange={e => onChange(e.target.value)} />}</label>;
}
