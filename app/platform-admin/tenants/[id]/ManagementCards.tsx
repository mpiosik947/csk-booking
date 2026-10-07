"use client";
import { useEffect, useRef, type ReactNode } from "react";
import { featureName, memberLabels, noticeLabel, operationalLabels, planName, roleLabels, tenantLabels, type Candidate, type Lifecycle, type Notice, type PlanPreview } from "@/lib/platform-management";
import { actionLabels, type Attempt, type Section } from "@/lib/platform-management-session";

export const control = "inline-flex min-h-12 max-w-full items-center justify-center rounded-lg border border-[#626b55] bg-[#20271b] px-4 py-2 text-left disabled:cursor-not-allowed disabled:opacity-50";
export const warningControl = `${control} border-amber-500/70 text-amber-100`;
export function Card({ title, children }: { title: string; children: ReactNode }) {
  return <section aria-label={title} className="min-w-0 space-y-4 rounded-xl border border-[#48523c] p-4 sm:p-6"><h2 className="text-xl font-bold">{title}</h2>{children}</section>;
}
export function Availability({ value }: { value: Section<unknown> }) {
  return value.loading ? <p role="status">Wczytywanie danych…</p> : value.error ? <p role="alert">{value.error}</p> : null;
}
export function Notices({ items, deletion = false }: { items: (Notice | string)[]; deletion?: boolean }) {
  return items.length ? <ul className="list-disc space-y-2 pl-5">{items.map((item, i) => {
    const n = typeof item === "string" ? { code: item } : item;
    return <li key={i}>{noticeLabel(n.code, deletion)}{n.feature_key ? ` (${featureName(n.feature_key)})` : ""}{n.count !== undefined ? ` · ${n.count}` : ""}</li>;
  })}</ul> : <p>Brak.</p>;
}
export function PlanSummary({ preview: p }: { preview: PlanPreview }) {
  return <div className="space-y-3"><p>Obecny plan: <strong>{planName(p.current_plan?.plan_key)}</strong></p><p>Docelowy plan: <strong>{planName(p.target_plan.plan_key)}</strong></p><p>Dodawane funkcje: {p.features_added.map(featureName).join(", ") || "Brak"}</p><p>Usuwane funkcje: {p.features_removed.map(featureName).join(", ") || "Brak"}</p><h3 className="font-bold">Blokady zmiany planu</h3><Notices items={p.blockers} /><h3 className="font-bold">Ostrzeżenia zmiany planu</h3><Notices items={p.warnings} /><p>Możliwość zastosowania: {p.can_apply && !p.blockers.length ? "Tak" : "Nie"}</p><p className="text-sm">Wersja podglądu: {p.revision}</p></div>;
}
export function CandidateSummary({ candidate }: { candidate: Candidate }) {
  const m = candidate.membership;
  return <div className="space-y-3"><p className="break-all">Konto: <strong>{candidate.email}</strong></p><p>{m.exists ? `Rola: ${roleLabels[m.role]} · Status: ${memberLabels[m.status]}` : "Brak członkostwa w tym obiekcie."}</p>
    {m.exists && m.role === "admin" && m.status === "active" && <p>Użytkownik jest już administratorem</p>}
    {m.exists && m.status === "pending" && <p>Członkostwo oczekuje na rozstrzygnięcie. Operacja jest niedostępna.</p>}
    {m.exists && m.status === "suspended" && m.role !== "admin" && <p>Członkostwo jest zawieszone. Awans jest niedostępny.</p>}
    {m.exists && m.status === "active" && m.role === "employee" && <p className="text-amber-100">Awans zastąpi rolę pracownika rolą administratora obiektu. Potwierdź zmianę roli.</p>}
    {m.exists && m.status === "active" && m.role === "instructor" && <div className="space-y-2 text-amber-100"><p>Po awansie konto przestanie pełnić rolę instruktora.</p><p>Konto utraci dostęp instruktora i nie otrzyma nowych przypisań instruktorskich. Historia pozostanie zachowana. Otwarte obowiązki mogą zablokować awans.</p></div>}
  </div>;
}
export function LifecycleSummary({ lifecycle: l }: { lifecycle: Lifecycle }) {
  return <div className="space-y-3"><p>Status: {tenantLabels[l.tenant.status]} · {l.tenant.is_public ? "Opublikowany" : "Niepubliczny"}</p><p>Plan: {planName(l.current_plan?.plan_key)} · Aktywni administratorzy: {l.admin_summary.active_admin_count}</p><p className="text-sm">Wersja statusu: {l.revision}</p>
    <details><summary className="cursor-pointer py-2">Zbiorcze zależności operacyjne</summary><dl className="grid gap-2 sm:grid-cols-2">{Object.entries(l.operational_counts).map(([key, value]) => <div key={key}><dt>{operationalLabels[key]}</dt><dd className="font-bold">{value}</dd></div>)}</dl></details>
    <h3 className="font-bold">Blokady archiwizacji</h3><Notices items={l.blockers} /><h3 className="font-bold">Ważne informacje</h3><Notices items={l.warnings} />
  </div>;
}
export function Confirmation({ attempt, busy, message, returnFocus, onConfirm, onDismiss }: { attempt: Attempt; busy: boolean; message: string; returnFocus: HTMLElement | null; onConfirm: () => void; onDismiss: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const element = dialog.current;
    element?.showModal();
    return () => { element?.close(); requestAnimationFrame(() => {
      const target = returnFocus?.isConnected && !returnFocus.hasAttribute("disabled") ? returnFocus : document.querySelector<HTMLElement>("[data-management-retry]");
      target?.focus();
    }); };
  }, [returnFocus]);
  return <dialog ref={dialog} aria-labelledby="management-confirm-title" aria-describedby="management-confirm-body" onCancel={event => { event.preventDefault(); if (!busy) onDismiss(); }} className="m-auto max-h-[90dvh] w-[calc(100%-2rem)] max-w-2xl overflow-y-auto rounded-2xl border border-[#626b55] bg-[#141814] p-5 text-[#f2efe4] backdrop:bg-black/70">
    <h2 id="management-confirm-title" className="mb-4 text-xl font-bold">{actionLabels[attempt.operation]}</h2>
    <div id="management-confirm-body" className="space-y-4 break-words">
      {attempt.preview && <PlanSummary preview={attempt.preview} />}{attempt.candidate && <CandidateSummary candidate={attempt.candidate} />}
      {attempt.operation === "demote" && <p>Użytkownik pozostanie członkiem obiektu, ale straci uprawnienia administratora.</p>}
      {attempt.operation === "suspend" && <p>Konto utraci dostęp administratora tego obiektu. Historia i konto użytkownika pozostaną.</p>}
      {attempt.lifecycle && <LifecycleSummary lifecycle={attempt.lifecycle} />}
      {attempt.operation === "archive" && <ul className="list-disc space-y-2 pl-5"><li>Obiekt zniknie z publicznego katalogu.</li><li>Nowe rezerwacje i rejestracje zostaną zablokowane.</li><li>Dane i historyczne rekordy nie zostaną usunięte.</li><li>Administratorzy i konfiguracja pozostaną.</li><li>Operacja jest odwracalna.</li></ul>}
      {attempt.operation === "restore" && <p>Obiekt zostanie przywrócony jako nieaktywny obiekt w przygotowaniu. Nie zostanie automatycznie opublikowany.</p>}
      {message && <p role="status">{message}</p>}
    </div>
    <div className="mt-6 flex flex-wrap gap-3"><button autoFocus disabled={busy} className={control} onClick={onDismiss}>{attempt.phase === "uncertain" ? "Zamknij potwierdzenie" : "Anuluj"}</button><button disabled={busy} className={warningControl} onClick={onConfirm}>{busy ? "Zapisywanie…" : attempt.phase === "uncertain" ? "Ponów tę samą próbę" : "Potwierdź operację"}</button></div>
  </dialog>;
}
