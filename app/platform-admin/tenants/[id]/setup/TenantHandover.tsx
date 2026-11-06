"use client";

import Link from "next/link";
import FieldGuide from "@/app/_components/FieldGuide";
import { useCallback, useEffect, useRef, useState } from "react";
import AdminShell from "@/app/admin/_components/AdminShell";
import { supabase } from "@/lib/supabase";
import { readAccount, type Account } from "@/lib/platform-wizard";
import { readinessNotice } from "@/lib/platform-draft-readiness";
import { handoverError, handoverStorageKey, matchesHandover, parseHandoverAttempt, readHandover, readHandoverReceipt, type HandoverAttempt, type HandoverState } from "@/lib/platform-handover";

const control = "min-h-11 rounded-lg border border-[#626b55] bg-[#232c20] px-4 py-2 disabled:opacity-50";
export default function TenantHandoverPage({ tenantId, actorId }: { tenantId: string; actorId: string }) {
  return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Przekazanie obiektu"><TenantHandover tenantId={tenantId} actorId={actorId} /></AdminShell>;
}
export function TenantHandover({ tenantId, actorId, onCompleted, onBusy, permittedRevision, onDirty, onSync }: { tenantId: string; actorId: string; permittedRevision?: string | null; onDirty?: (dirty: boolean) => void; onSync?: () => void; onCompleted?: () => void; onBusy?: (value: boolean) => void }) {
  const [data, setData] = useState<HandoverState | null>(null), [email, setEmail] = useState(""), [selected, setSelected] = useState<Account | null>(null);
  const [busy, setBusy] = useState(false), [denied, setDenied] = useState(false), [storageBroken, setStorageBroken] = useState(false), [error, setError] = useState("");
  const [pending, setPending] = useState<HandoverAttempt | null>(null), [confirmation, setConfirmation] = useState<HandoverAttempt | null>(null);
  const alive = useRef(true), flight = useRef(false), terminal = useRef(false), sequence = useRef(0), alert = useRef<HTMLParagraphElement>(null);
  const key = handoverStorageKey(actorId, tenantId);
  const read = useCallback(async () => {
    const r = await supabase.rpc("platform_get_tenant_handover_v1", { p_tenant_id: tenantId });
    if (r.error) throw { ...r.error, status: r.status };
    const value = readHandover(r.data, tenantId); if (!value) throw new Error("INVALID_HANDOVER_STATE"); return value;
  }, [tenantId]);
  const deny = useCallback(() => { terminal.current = true; setDenied(true); setData(null); setSelected(null); setConfirmation(null); setPending(null); }, []);
  const load = useCallback(async () => {
    if (!alive.current || flight.current || terminal.current) return;
    const current = ++sequence.current; setBusy(true); setData(null);
    try { const fresh = await read(); if (!alive.current || current !== sequence.current) return; setData(fresh); if (fresh.receipt) { sessionStorage.removeItem(key); setPending(null); setConfirmation(null); } }
    catch (e) { if (alive.current && current === sequence.current) { const issue = handoverError(e as { code?: string; status?: number }); setError(issue.message); if (issue.kind === "denied") deny(); } }
    finally { if (alive.current && current === sequence.current) setBusy(false); }
  }, [read, key, deny]);
  useEffect(() => {
    alive.current = true; sequence.current++;
    const timer = setTimeout(() => { try { const raw = sessionStorage.getItem(key); if (raw) { const a = parseHandoverAttempt(raw, tenantId); if (a) setPending(a); else setStorageBroken(true); } } catch { setStorageBroken(true); } void load(); }, 0);
    const focus = () => { if (document.visibilityState === "visible") void load(); };
    window.addEventListener("focus", focus); document.addEventListener("visibilitychange", focus);
    const listener = supabase.auth.onAuthStateChange((_event, session) => { if (!session || session.user.id !== actorId) { alive.current = false; sequence.current++; deny(); } });
    return () => { alive.current = false; clearTimeout(timer); listener.data.subscription.unsubscribe(); window.removeEventListener("focus", focus); document.removeEventListener("visibilitychange", focus); };
  }, [actorId, tenantId, key, load, deny]);
  useEffect(() => { if (error) alert.current?.focus(); }, [error]);
  useEffect(() => { if (!pending && !busy) return; const before = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ""; }; window.addEventListener("beforeunload", before); return () => window.removeEventListener("beforeunload", before); }, [pending, busy]);
  async function find() {
    if (busy || denied || flight.current || pending) return;
    const current = ++sequence.current; setBusy(true); setSelected(null); setError("");
    try { const r = await supabase.rpc("platform_lookup_tenant_admin_candidate_v1", { p_tenant_id: tenantId, p_email: email.trim() }); if (r.error) throw { ...r.error, status: r.status }; if (!alive.current || current !== sequence.current) return; const account = readAccount(r.data); if (!account || account.email.toLowerCase() !== email.trim().toLowerCase() || r.data?.membership?.exists !== false) setError("Wybierz istniejące, potwierdzone konto, które nie ma jeszcze dostępu do tego obiektu."); else setSelected(account); }
    catch (e) { if (alive.current) { const issue = handoverError(e as { code?: string; status?: number }); setError(issue.message); if (issue.kind === "denied") deny(); } }
    finally { if (alive.current && current === sequence.current) setBusy(false); }
  }
  async function submit(attempt: HandoverAttempt) {
    if (!alive.current || flight.current || denied || storageBroken) return;
    try { sessionStorage.setItem(key, JSON.stringify(attempt)); } catch { setStorageBroken(true); return; }
    flight.current = true; sequence.current++; setBusy(true); onBusy?.(true); setPending(attempt); setData(null); setError("");
    try {
      const r = await supabase.rpc("platform_handover_tenant_v1", { p_tenant_id: tenantId, p_user_id: attempt.userId, p_expected_revision: attempt.revision, p_request_id: attempt.requestId });
      if (r.error) throw { ...r.error, status: r.status };
      const receipt = readHandoverReceipt(r.data, tenantId); if (!receipt || !matchesHandover(receipt, attempt, actorId)) throw new Error("INVALID_HANDOVER_RECEIPT");
      const fresh = await read(); if (!alive.current) return; if (!fresh.receipt || !matchesHandover(fresh.receipt, attempt, actorId)) throw new Error("UNCONFIRMED_HANDOVER");
      setData(fresh); sessionStorage.removeItem(key); setPending(null); setConfirmation(null); onCompleted?.();
    } catch (e) {
      if (!alive.current) return;
      const issue = handoverError(e as { code?: string; status?: number }); setError(issue.message); setConfirmation(null);
      if (issue.kind === "denied") deny();
      else {
        if (issue.kind === "conflict") onSync?.();
        if (issue.kind !== "uncertain") { sessionStorage.removeItem(key); setPending(null); setSelected(null); }
        try { const fresh = await read(); if (!alive.current) return; setData(fresh); if (fresh.receipt) { sessionStorage.removeItem(key); setPending(null); if (matchesHandover(fresh.receipt, attempt, actorId)) { setError(""); onCompleted?.(); } } }
        catch (readError) { if (alive.current && handoverError(readError as { code?: string; status?: number }).kind === "denied") deny(); }
      }
    } finally { flight.current = false; onBusy?.(false); if (alive.current) setBusy(false); }
  }
  useEffect(() => {
    onDirty?.(!!email || !!pending || !!confirmation);
    return () => onDirty?.(false);
  }, [email, pending, confirmation, onDirty]);
  useEffect(() => {
    if (permittedRevision) { const timer = setTimeout(() => void load(), 0); return () => clearTimeout(timer); }
  }, [permittedRevision, load]);
  const ready = (permittedRevision === undefined || (permittedRevision !== null && data?.readiness?.revision === permittedRevision)) && data?.readiness?.current && data.status === "dormant" && data.publicAccess === "coming_soon" && !data.isPublic && data.adminCount === 0 && !data.receipt;
  return <section aria-label="Przekazanie obiektu" className="space-y-4 rounded-lg border border-[#626b55] p-4">
    <h3 className="text-xl font-bold">Przekazanie obiektu</h3>
    {busy && <p role="status">Sprawdzanie danych…</p>}
    {error && <p role="alert" ref={alert} tabIndex={-1}>{error}</p>}
    {storageBroken && <p role="alert">Nie można bezpiecznie zachować próby w tej karcie. Sprawdź pamięć sesji przed przekazaniem.</p>}
    {denied ? <p role="alert">Dostęp do przekazania jest niedostępny.</p> : <>
      {data && <><p>Obiekt: <strong>{data.name}</strong></p><p className="break-all">Adres: /t/{data.slug}</p><p>Status: {data.status === "dormant" ? "W konfiguracji" : data.status === "archived" ? "Zarchiwizowany" : data.status === "active" ? "Aktywny" : "Zawieszony"} · {data.publicAccess === "coming_soon" ? "Dostępna wkrótce" : "Dostęp publiczny włączony"} · {data.isPublic ? "Opublikowany" : "Niepubliczny"}</p>
        {data.receipt ? <><p role="status" className="font-bold text-green-300">Obiekt przekazany administratorowi</p><p className="break-all">Administrator: {data.adminEmail ?? "Konto niedostępne"}</p><p>Przekazano: {new Date(data.receipt.handedAt).toLocaleString("pl-PL")}</p><p>Przekazanie nie publikuje obiektu. Dalsze zmiany konfiguracji nie odbierają nadanych uprawnień.</p><Link className={control + " inline-flex"} href={`/platform-admin/tenants/${tenantId}`}>Zarządzaj obiektem</Link></> : <>
          <p role="status">{data.readiness ? readinessNotice(data.readiness) : "Brak aktualnej walidacji"}</p><p>Ostatnia walidacja: {data.readiness?.validatedAt ? new Date(data.readiness.validatedAt).toLocaleString("pl-PL") : "Brak"}</p>
          <form className="space-y-3" onSubmit={e => { e.preventDefault(); void find(); }}><FieldGuide label="E-mail pierwszego administratora" help="Podaj dokładny e-mail istniejącego konta, które ma zarządzać tym obiektem." example="administrator@example.com" required><input className={control + " mt-1 w-full min-w-0 max-w-xl"} type="email" maxLength={254} required disabled={busy || !!pending || storageBroken} value={email} onChange={e => { sequence.current++; setEmail(e.target.value); setSelected(null); setConfirmation(null); }} /></FieldGuide><button className={control} disabled={busy || !!pending || storageBroken}>Znajdź administratora</button></form>
          {selected && <p className="break-all">Wybrany administrator: <strong>{selected.email}</strong></p>}
          <p>Wybrana osoba otrzyma lokalne uprawnienia administratora. Potwierdzenie oznacza, że sprawdzono konfigurację w prywatnym podglądzie. Obiekt pozostanie niepubliczny.</p>
          <button className={control} disabled={!ready || !selected || busy || !!pending || storageBroken || selected.email.toLowerCase() !== email.trim().toLowerCase()} onClick={() => { if (selected && data.readiness?.revision) setConfirmation({ tenantId, userId: selected.user_id, email: selected.email, revision: data.readiness.revision, requestId: crypto.randomUUID() }); }}>Przekaż administratorowi</button>
        </>}
      </>}
      {pending && !data?.receipt && <div className="space-y-3"><p className="break-all">Niepotwierdzona próba: {pending.email}. Ponowienie dotyczy tego samego obiektu, konta i sprawdzonych ustawień.</p><button className={control} disabled={busy || storageBroken} onClick={() => setConfirmation(pending)}>Sprawdź / ponów przekazanie</button></div>}
      <button className={control} disabled={busy} onClick={() => { onSync?.(); void load(); }}>Odśwież przekazanie</button>
      {!onCompleted && <div className="flex flex-wrap gap-3"><Link className="underline" href={`/platform-admin/tenants/${tenantId}/preview`}>Prywatny podgląd</Link><Link className="underline" href="/platform-admin">Lista obiektów</Link></div>}
      {confirmation && <HandoverConfirmation attempt={confirmation} name={data?.name ?? "Wybrany obiekt"} busy={busy} onCancel={() => setConfirmation(null)} onConfirm={() => void submit(confirmation)} />}
    </>}
  </section>;
}
function HandoverConfirmation({ attempt, name, busy, onCancel, onConfirm }: { attempt: HandoverAttempt; name: string; busy: boolean; onCancel: () => void; onConfirm: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { const element = dialog.current, target = document.activeElement as HTMLElement | null; element?.showModal(); return () => { element?.close(); if (target?.isConnected) target.focus(); }; }, []);
  return <dialog ref={dialog} aria-labelledby="handover-title" aria-describedby="handover-description" onCancel={e => { e.preventDefault(); if (!busy) onCancel(); }} className="m-auto max-h-[90dvh] w-[calc(100%-2rem)] max-w-xl overflow-y-auto rounded-2xl border border-[#626b55] bg-[#141814] p-5 text-[#f2efe4] backdrop:bg-black/70"><h2 id="handover-title" className="mb-4 text-xl font-bold">Przekazać obiekt administratorowi?</h2><div id="handover-description" className="space-y-3 break-words"><p>Obiekt: <strong>{name}</strong></p><p>Administrator: <strong>{attempt.email}</strong></p><p>Nadasz lokalne uprawnienia administratora. Obiekt nie stanie się publiczny automatycznie.</p></div><div className="mt-5 flex flex-wrap gap-3"><button autoFocus className={control} disabled={busy} onClick={onCancel}>Anuluj</button><button className={control} disabled={busy} onClick={onConfirm}>{busy ? "Przekazywanie…" : "Przekaż obiekt"}</button></div></dialog>;
}
