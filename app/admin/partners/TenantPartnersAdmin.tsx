"use client";

import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import AdminShell from "../_components/AdminShell";
import TenantPartners from "@/app/_components/TenantPartners";
import { supabase } from "@/lib/supabase";
import { PARTNER_KINDS, PARTNER_FORMATS, PARTNER_STATUSES, partnerMediaUrl, readPartnerList, partnerValues, validPartnerValues, type PartnerValues, type AdminPartner, type PartnerList } from "@/lib/tenant-partners";

const empty: PartnerValues = { name: "", kind: "partner", display_format: "logo", target_url: null, short_description: null, is_active: false, display_order: 0, starts_at: null, ends_at: null };
const input = "mt-1 block w-full min-w-0 rounded-lg border border-[#536143] bg-[#090b09] p-2.5 text-[#f2efe4]";
const button = "min-h-11 rounded-lg border border-[#536143] px-3 py-2 text-sm hover:bg-[#26301f] disabled:opacity-50";
const localDate = (v: string | null) => { if (!v) return ""; const d = new Date(v); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16); };
const displayDate = (v: string | null) => v ? new Date(v).toLocaleString("pl-PL") : "bez ograniczenia";

export default function TenantPartnersAdmin({ tenantSlug }: { tenantSlug: string }) {
  const [list, setList] = useState<PartnerList | null>(null), [error, setError] = useState(""), [message, setMessage] = useState("");
  const [denied, setDenied] = useState(false), [busy, setBusy] = useState(false), [editing, setEditing] = useState<{ id: string; record: AdminPartner | null } | null>(null);
  const [values, setValues] = useState<PartnerValues>(empty), [file, setFile] = useState<File | null>(null);
  const [deleting, setDeleting] = useState<AdminPartner | null>(null);
  const deleteDialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    if (deleting) deleteDialog.current?.showModal();
    else deleteDialog.current?.close();
  }, [deleting]);
  const epoch = useRef(0), actor = useRef<string | null | undefined>(undefined), lock = useRef(false);
  const load = useCallback(async () => {
    const generation = ++epoch.current;
    try {
      const auth = await supabase.auth.getUser();
      if (generation !== epoch.current) return;
      if (auth.error || !auth.data.user) { setDenied(true); setList(null); return; }
      actor.current = auth.data.user.id;
      const response = await supabase.rpc("admin_get_tenant_partners_v1", { p_tenant_slug: tenantSlug });
      if (generation !== epoch.current) return;
      const next = readPartnerList(response.data);
      if (response.error || !next) { setList(null); setDenied(true); return; }
      setList(next); setDenied(false); setError("");
    } catch { if (generation === epoch.current) setError("Nie udało się wczytać partnerów. Odśwież listę."); }
  }, [tenantSlug]);
  useEffect(() => {
    const sessionEpoch = epoch;
    const task = window.setTimeout(() => void load(), 0);
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === "SIGNED_OUT" || (actor.current !== undefined && actor.current !== (session?.user.id ?? null))) {
        ++epoch.current; actor.current = session?.user.id ?? null;
        setDenied(true); setList(null); setEditing(null); setFile(null); setDeleting(null);
      }
    });
    return () => { ++sessionEpoch.current; clearTimeout(task); data.subscription.unsubscribe(); };
  }, [load]);
  function edit(record: AdminPartner | null) {
    setEditing({ id: record?.id ?? crypto.randomUUID(), record }); setValues(record ? partnerValues(record) : { ...empty }); setFile(null); setMessage(""); setError("");
  }
  async function save(record: { id: string; record: AdminPartner | null }, next: PartnerValues, image: File | null, archive = false) {
    if (lock.current || denied || !list) return;
    if (!validPartnerValues(next)) { setError("Sprawdź nazwę, adres HTTPS, kolejność i zakres dat publikacji."); return; }
    if (!record.record && !image) { setError("Wybierz grafikę partnera."); return; }
    lock.current = true; setBusy(true); setError(""); setMessage(""); const generation = epoch.current;
    try {
      const form = new FormData();
      form.set("payload", JSON.stringify({ id: record.id, revision: record.record?.revision ?? null, media_id: record.record?.media_id ?? null, values: next, archive }));
      if (image) form.set("image", image);
      const response = await fetch(`/api/tenant-partners/${tenantSlug}`, { method: "POST", body: form, signal: AbortSignal.timeout(30000) });
      if (generation !== epoch.current) return;
      if (response.status === 401 || response.status === 403) { setDenied(true); setList(null); setEditing(null); return; }
      if (response.status === 409) { setError("Dane zmieniły się w innej sesji. Odśwież listę i ponownie otwórz edycję."); return; }
      const data = await response.json(), result = readPartnerList(data);
      if (!response.ok || !result) {
        setError(data.error === "invalid_image" || response.status === 413 ? "Nieprawidłowa grafika. Wybierz nieanimowany PNG, JPG lub WebP do 4 MB (maks. 16 mln pikseli)." : "Nie udało się potwierdzić zapisu. Odśwież listę przed kolejną próbą."); return;
      }
      setList(result); setEditing(null); setFile(null); setMessage("Zapisano zmiany.");
    } catch { if (generation === epoch.current) setError("Nie udało się potwierdzić zapisu. Odśwież listę przed kolejną próbą."); }
    finally { lock.current = false; setBusy(false); }
  }
  function submit(event: FormEvent) { event.preventDefault(); if (editing) void save(editing, values, file); }
  async function permanentlyDelete() {
    if (!deleting?.archived_at || lock.current || denied || !list) return;
    lock.current = true; setBusy(true); setError(""); setMessage("");
    const generation = epoch.current, record = deleting;
    try {
      const response = await fetch(`/api/tenant-partners/${tenantSlug}/permanent-delete`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: record.id, revision: record.revision }), signal: AbortSignal.timeout(30000),
      });
      if (generation !== epoch.current) return;
      const data = await response.json();
      setDeleting(null);
      if (response.status === 401 || response.status === 403) { setDenied(true); setList(null); return; }
      if (!response.ok || data.deleted !== true) {
        setError(data.error === "media_shared" ? "Grafika jest używana także przez innego partnera. Usunięcie zostało zablokowane."
          : "Nie potwierdzono pełnego usunięcia. Odśwież listę. Jeśli wpis pozostał, ponów usunięcie; trwająca operacja może wymagać odczekania dwóch minut.");
        return;
      }
      await load();
      if (actor.current) setMessage("Trwale usunięto partnera i grafikę.");
    } catch { if (generation === epoch.current) { setDeleting(null); setError("Nie potwierdzono pełnego usunięcia. Odśwież listę przed ponowieniem."); } }
    finally { lock.current = false; setBusy(false); }
  }
  return <AdminShell eyebrow="Treści obiektu" title="Partnerzy i sponsorzy" description="Logotypy i banery widoczne pod informacjami o obiekcie."
    actions={<Link className={button} href={`/t/${tenantSlug}/admin/settings`}>Ustawienia publiczne</Link>}>
    {denied ? <p role="alert">Brak dostępu. Wymagane aktywne konto administratora tego obiektu.</p> : <>
      <div className="mb-4 flex flex-wrap gap-3"><button className={button} disabled={busy || !list} onClick={() => edit(null)}>Dodaj partnera</button>
        <button className={button} disabled={busy} onClick={() => { setEditing(null); void load(); }}>Odśwież listę</button>
        {list?.public_slug && <Link className={button} href={`/${list.public_slug}`}>Podgląd strony obiektu</Link>}</div>
      {error && <p role="alert" className="mb-4 text-red-300">{error}</p>}{message && <p role="status" className="mb-4 text-green-300">{message}</p>}
      {!list && !error && <p role="status">Wczytywanie…</p>}
      {list?.items.length === 0 && <p>Brak dodanych partnerów.</p>}
      {editing && <form onSubmit={submit} className="mb-7 rounded-xl border border-[#536143] p-4">
        <h2 className="mb-4 text-xl">{editing.record ? "Edytuj partnera" : "Nowy partner"}</h2>
        <fieldset disabled={busy} className="grid min-w-0 gap-4 sm:grid-cols-2">
          <label>Nazwa partnera<input className={input} required maxLength={120} value={values.name} onChange={e => setValues({ ...values, name: e.target.value })} /></label>
          <label>Rodzaj<select className={input} value={values.kind} onChange={e => setValues({ ...values, kind: e.target.value as PartnerValues["kind"] })}>{Object.entries(PARTNER_KINDS).map(([v, label]) => <option value={v} key={v}>{label}</option>)}</select></label>
          <label>Format<select className={input} value={values.display_format} onChange={e => setValues({ ...values, display_format: e.target.value as PartnerValues["display_format"] })}>{Object.entries(PARTNER_FORMATS).map(([v, label]) => <option value={v} key={v}>{label}</option>)}</select></label>
          <label>Grafika<input key={editing.id} type="file" className={input} accept="image/png,image/jpeg,image/webp" required={!editing.record} onChange={e => setFile(e.target.files?.[0] ?? null)} /><span className="text-xs text-[#a9ada4]">PNG, JPG, WebP do 4 MB. Bez animacji. Przy edycji pozostaw puste, aby zachować grafikę.</span></label>
          <label>Adres strony<input className={input} type="url" maxLength={1000} placeholder="https://" value={values.target_url ?? ""} onChange={e => setValues({ ...values, target_url: e.target.value || null })} /></label>
          <label>Kolejność<input className={input} type="number" min={0} max={9999} step={1} required value={values.display_order} onChange={e => setValues({ ...values, display_order: e.target.valueAsNumber })} /></label>
          <label className="sm:col-span-2">Krótki opis<textarea className={input} maxLength={300} value={values.short_description ?? ""} onChange={e => setValues({ ...values, short_description: e.target.value || null })} /></label>
          {(["starts_at", "ends_at"] as const).map(key => <label key={key}>{key === "starts_at" ? "Publikuj od" : "Publikuj do"}<input className={input} type="datetime-local" value={localDate(values[key])} onChange={e => setValues({ ...values, [key]: e.target.value ? new Date(e.target.value).toISOString() : null })} /></label>)}
          <p className="text-xs text-[#a9ada4] sm:col-span-2">Daty w strefie czasowej Twojej przeglądarki. Widoczność sprawdza serwer. Tryb „Dostępna wkrótce” nadal ogranicza stronę do uprawnionych osób.</p>
          <label className="flex min-h-11 items-center gap-2"><input type="checkbox" checked={values.is_active} onChange={e => setValues({ ...values, is_active: e.target.checked })} />Aktywny</label>
          <div className="flex flex-wrap gap-3 sm:col-span-2"><button className={button} type="submit">{busy ? "Zapisywanie…" : "Zapisz partnera"}</button><button className={button} type="button" onClick={() => setEditing(null)}>Anuluj</button></div>
        </fieldset>
      </form>}
      <ul className="grid gap-4">{list?.items.map(p => <li key={p.id} className="min-w-0 rounded-xl border border-[#343a31] p-4">
        <div className="flex min-w-0 items-start gap-3"><Image unoptimized width={96} height={72} loading="lazy" className="h-18 w-24 shrink-0 rounded bg-[#f4f3ef] object-contain p-1" src={partnerMediaUrl(p.media_id)} alt={`Grafika ${p.name}`} />
          <div className="min-w-0"><h2 className="break-words font-semibold">{p.name}</h2><p className="text-sm text-[#a9ada4]">{PARTNER_KINDS[p.kind]} · {PARTNER_FORMATS[p.display_format]}</p><p className="text-sm">{PARTNER_STATUSES[p.status]} · Kolejność: {p.display_order}</p></div></div>
        <p className="my-3 break-words text-sm text-[#a9ada4]">Od: {displayDate(p.starts_at)} · Do: {displayDate(p.ends_at)}</p>
        {!p.archived_at && <div className="flex flex-wrap gap-2"><button className={button} disabled={busy} onClick={() => edit(p)}>Edytuj</button>
          <button className={button} disabled={busy} onClick={() => void save({ id: p.id, record: p }, { ...partnerValues(p), is_active: !p.is_active }, null)}>{p.is_active ? "Wyłącz" : "Aktywuj"}</button>
          <button className={button} disabled={busy} onClick={() => { if (window.confirm(`Archiwizować partnera „${p.name}”? Zniknie ze strony publicznej.`)) void save({ id: p.id, record: p }, partnerValues(p), null, true); }}>Archiwizuj</button></div>}
        {p.archived_at && <button className={`${button} border-red-400 text-red-200`} disabled={busy} onClick={() => setDeleting(p)}>Usuń trwale</button>}
        <details className="mt-3"><summary className="cursor-pointer py-2">Podgląd grafiki i oznaczeń</summary><TenantPartners name="— podgląd" items={[p]} /></details>
      </li>)}</ul>
    </>}
    <dialog ref={deleteDialog} aria-labelledby="partner-delete-title" aria-describedby="partner-delete-description"
      className="m-auto w-[calc(100%-2rem)] max-w-lg rounded-xl border border-[#536143] bg-[#141914] p-5 text-white backdrop:bg-black/70"
      onCancel={event => { if (busy) event.preventDefault(); else setDeleting(null); }}>
      <h2 id="partner-delete-title" className="text-xl font-semibold">Trwale usunąć partnera?</h2>
      <p className="my-3 break-words">{deleting?.name}</p>
      <p id="partner-delete-description">Partner oraz powiązana z nim grafika zostaną usunięte. Tej operacji nie można cofnąć.</p>
      <div className="mt-5 flex flex-wrap gap-3">
        <button autoFocus className={button} disabled={busy} onClick={() => setDeleting(null)}>Anuluj</button>
        <button className={`${button} border-red-400 text-red-200`} disabled={busy} onClick={() => void permanentlyDelete()}>{busy ? "Usuwanie…" : "Usuń trwale"}</button>
      </div>
    </dialog>
  </AdminShell>;
}
