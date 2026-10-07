"use client";

import Link from "next/link";
import { useEffect, useState, useSyncExternalStore } from "react";
import AdminShell from "@/app/admin/_components/AdminShell";
import { supabase } from "@/lib/supabase";
import { readAttempt, storageKey, type Detail } from "@/lib/platform-wizard";
import { candidateActions, memberLabels, planName, tenantLabels, type TenantStatus } from "@/lib/platform-management";
import { actionLabels, ManagementSession } from "@/lib/platform-management-session";
import { Availability, CandidateSummary, Card, Confirmation, control, LifecycleSummary, Notices, PlanSummary, warningControl } from "./ManagementCards";

const readinessLabels: Record<string, string> = { identity_ready: "Dane obiektu", slug_ready: "Adresy", settings_ready: "Ustawienia", plan_ready: "Plan", admin_ready: "Administrator", lanes_ready: "Osie" };

export default function TenantDetail({ id, actorId, initial }: { id: string; actorId: string; initial: Detail | null }) {
  const [session] = useState(() => new ManagementSession(id, (name, args) => supabase.rpc(name, args).abortSignal(AbortSignal.timeout(20000)), initial));
  const state = useSyncExternalStore(session.subscribe, session.snapshot, session.snapshot);
  const [email, setEmail] = useState(""), [modal, setModal] = useState(false);
  const [returnFocus, setReturnFocus] = useState<HTMLElement | null>(null);
  const detail = state.detail.data, candidate = state.candidate.data, lifecycle = state.lifecycle.data;
  const locked = session.locked;
  useEffect(() => {
    const timer = setTimeout(() => void session.refresh(), 0);
    const { data } = supabase.auth.onAuthStateChange((event, auth) => {
      if (event === "SIGNED_OUT" || (auth && auth.user.id !== actorId)) session.deny();
    });
    return () => { clearTimeout(timer); session.invalidate(); data.subscription.unsubscribe(); };
  }, [session, actorId]);
  useEffect(() => {
    if (!detail) return;
    try {
      const key = storageKey(actorId), raw = sessionStorage.getItem(key), attempt = raw ? readAttempt(raw) : null;
      if (attempt?.state === "confirmed" && attempt.tenantId === id) sessionStorage.removeItem(key);
    } catch { /* A preserved onboarding receipt remains safe to reopen. */ }
  }, [actorId, detail, id]);
  useEffect(() => {
    if (state.attempt?.phase !== "uncertain") return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [state.attempt?.phase]);
  useEffect(() => {
    if (modal && !state.attempt && !state.busy) {
      const target = returnFocus?.isConnected && !returnFocus.hasAttribute("disabled") ? returnFocus : document.querySelector<HTMLElement>("[data-management-focus]");
      target?.focus();
    }
  }, [modal, state.attempt, state.busy, returnFocus]);
  function open(action: () => void, trigger: HTMLElement) { setReturnFocus(trigger); action(); setModal(true); }
  function dismiss() { session.cancel(); setModal(false); }
  if (state.denied) return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Brak dostępu"><p role="alert">{state.message}</p><Link className={control} href="/login?redirectTo=%2Fplatform-admin">Zaloguj się ponownie</Link></AdminShell>;
  return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title={detail?.tenant.name ?? "Zarządzanie obiektem"} description="Plany, administratorzy i status obiektu. Każda zmiana wymaga potwierdzenia i jest sprawdzana przez platformę.">
    <div className="flex flex-wrap gap-3"><Link href="/platform-admin" className={control}>Lista obiektów</Link><button className={control} disabled={locked} onClick={() => void session.refresh()}>Odśwież stan</button></div>
    {state.message && <p role="status" tabIndex={-1} data-management-focus className="my-4 rounded-lg border border-[#807144] p-4">{state.message}</p>}
    {state.attempt?.phase === "uncertain" && !modal && <div className="my-4 space-y-3"><p>Zachowano niepotwierdzoną próbę. Rozstrzygnij jej wynik przed kolejną zmianą i opuszczeniem strony.</p><button data-management-retry disabled={state.busy} className={control} onClick={event => open(() => {}, event.currentTarget)}>Sprawdź / ponów tę samą próbę</button></div>}
    <div className="my-6 space-y-6 break-words">
      <Card title="Obiekt"><Availability value={state.detail} />{detail && <><p>Nazwa publiczna: {detail.public_profile?.display_name ?? detail.tenant.name}</p><p>Miejscowość: {detail.public_profile?.city ?? "Brak profilu"}</p><p className="break-all">Adres techniczny: /t/{detail.tenant.technical_slug}</p><p className="break-all">Adres publiczny: {detail.public_profile ? `https://strzelajtu.pl/${detail.public_profile.public_slug}` : "Brak profilu"}</p><p>Plan: {planName(detail.plan?.plan_key)}</p></>}</Card>
      <Card title="Plan / pakiet"><Availability value={state.plans} />{state.plans.data && <>
        <p>Bieżący plan: {state.detail.error ? "Odczyt niedostępny" : planName(detail?.plan?.plan_key)}</p>
        <label className="grid max-w-lg gap-2">Docelowy plan<select className={control} value={state.target} disabled={locked || state.plans.loading} onChange={event => void session.selectPlan(event.target.value)}><option value="" disabled>Wybierz plan</option>{state.plans.data.map(p => <option key={p.plan_key} value={p.plan_key}>{planName(p.plan_key) === p.plan_key ? p.display_name : planName(p.plan_key)}</option>)}</select></label>
        <Availability value={state.preview} />{state.preview.data && <><PlanSummary preview={state.preview.data} /><button className={warningControl} disabled={locked || !state.preview.data.can_apply || !!state.preview.data.blockers.length || state.preview.data.tenant.status === "archived"} onClick={event => open(() => session.preparePlan(), event.currentTarget)}>Zmień plan</button></>}
      </>}</Card>
      <Card title="Administratorzy obiektu"><Availability value={state.admins} />{state.admins.data && <>
        <p>Aktywni administratorzy: {state.admins.data.active_admin_count}</p>
        <ul className="space-y-3">{state.admins.data.admins.map(admin => <li key={admin.user_id} className="space-y-2 rounded-lg border border-[#48523c] p-3"><p className="break-all">{admin.email ?? "Adres e-mail niedostępny"}</p><p>Rola: Administrator · Status: {memberLabels[admin.membership_status]}</p><p className="text-sm">Ostatnia zmiana: <time dateTime={admin.updated_at}>{new Date(admin.updated_at).toLocaleString("pl-PL")}</time></p><button className={control} disabled={locked || !session.adminAvailable || !admin.email} onClick={() => { setEmail(admin.email ?? ""); void session.findCandidate(admin.email ?? "", admin.user_id); }}>Zarządzaj uprawnieniami: {admin.email ?? "konto niedostępne"}</button></li>)}</ul>
        {state.admins.data.tenant.status === "archived" && <p>Zmiany administratorów wymagają przywrócenia obiektu do konfiguracji.</p>}
        <form className="flex flex-col gap-3 sm:flex-row sm:items-end" onSubmit={event => { event.preventDefault(); void session.findCandidate(email); }}><label className="grid min-w-0 flex-1 gap-2">Dokładny e-mail konta<input type="email" maxLength={254} required className={`${control} w-full`} value={email} disabled={locked || !session.adminAvailable} onChange={event => setEmail(event.target.value)} /></label><button className={control} disabled={locked || !session.adminAvailable}>Znajdź konto</button></form>
        <Availability value={state.candidate} />{candidate && <div className="space-y-4 rounded-lg border border-[#626b55] p-4"><CandidateSummary candidate={candidate} /><div className="flex flex-wrap gap-3">{candidateActions(candidate).map(action => <button key={action} className={warningControl} disabled={locked || !session.adminAvailable || email.trim().toLowerCase() !== candidate.email.trim().toLowerCase()} onClick={event => open(() => session.prepareAdmin(action), event.currentTarget)}>{action === "add" && candidate.membership.exists ? "Awansuj do administratora" : actionLabels[action]}</button>)}</div></div>}
      </>}</Card>
      <Card title="Status obiektu"><Availability value={state.lifecycle} />{lifecycle && <><p><span className="inline-flex rounded-full border border-[#626b55] px-3 py-1">{tenantLabels[lifecycle.tenant.status]}</span> · {lifecycle.tenant.is_public ? "Opublikowany" : "Niepubliczny"}</p>{lifecycle.tenant.status !== "archived" && <p>Aktywacja i publikacja wymagają osobnej decyzji. Dotychczasowe opcje konfiguracji są dostępne na <Link className="underline" href="/platform-admin">liście obiektów</Link>.</p>}</>}</Card>
      <Card title="Archiwizacja / przywracanie"><Availability value={state.lifecycle} />{lifecycle && <><LifecycleSummary lifecycle={lifecycle} />{lifecycle.tenant.status === "archived" ? <button className={control} disabled={locked} onClick={event => open(() => session.prepareLifecycle("restore"), event.currentTarget)}>Przywróć obiekt do konfiguracji</button> : <button className={warningControl} disabled={locked || !lifecycle.can_archive || !!lifecycle.blockers.length} onClick={event => open(() => session.prepareLifecycle("archive"), event.currentTarget)}>Archiwizuj obiekt</button>}</>}</Card>
      <Card title="Możliwość trwałego usunięcia"><p>Trwałe usuwanie obiektów nie jest obecnie dostępne.</p><Availability value={state.eligibility} />{state.eligibility.data && <><Notices items={state.eligibility.data.blockers} deletion /><Notices items={state.eligibility.data.warnings} deletion /></>}</Card>
      <Card title="Gotowość techniczna"><Availability value={state.detail} />{detail && <>
        <p>Status: {tenantLabels[detail.tenant.status as TenantStatus] ?? "Niedostępny"}</p><ul>{[["Utworzenie", detail.readiness.create_ready], ["Aktywacja", detail.readiness.activation_ready], ["Publikacja", detail.readiness.public_ready], ["Rezerwacje", detail.readiness.booking_ready]].map(([label, ready]) => <li key={String(label)}>{label}: {ready ? "Gotowe" : "Wymaga konfiguracji"}</li>)}</ul><ul>{Object.entries(detail.readiness.checks).map(([key, ready]) => <li key={key}>{readinessLabels[key] ?? "Dodatkowa konfiguracja"}: {ready ? "Gotowe" : "Wymaga konfiguracji"}</li>)}</ul>
        <p>Gotowość techniczna nie potwierdza gotowości prawnej. Formalna bramka prawna pozostaje odroczona.</p>{!detail.readiness.publication_gate_enforced && <p>Raport gotowości nie stanowi jeszcze egzekwowanej bramki publikacji.</p>}
        <div className="flex flex-wrap gap-3"><Link className={control} href={`/tenant-setup/${detail.tenant.technical_slug}`}>Ustawienia — wymagany tenant admin</Link><Link className={control} href={`/platform-admin/tenants/${id}/preview`}>Prywatny podgląd</Link></div>
      </>}</Card>
    </div>
    {modal && state.attempt && <Confirmation returnFocus={returnFocus} attempt={state.attempt} busy={state.busy} message={state.message} onConfirm={() => void session.confirm()} onDismiss={dismiss} />}
  </AdminShell>;
}
