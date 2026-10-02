"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import AdminShell from "@/app/admin/_components/AdminShell";
import { supabase } from "@/lib/supabase";
import { readAttempt, readDetail, storageKey, type Detail } from "@/lib/platform-wizard";

const button = "inline-flex min-h-12 items-center rounded-lg border border-[#626b55] px-4 py-2 disabled:opacity-50";
const readinessLabels: Record<string, string> = { identity_ready: "Dane obiektu", slug_ready: "Adresy", settings_ready: "Ustawienia", plan_ready: "Plan", admin_ready: "Administrator", lanes_ready: "Osie" };

export default function TenantDetail({ id, actorId, initial }: { id: string; actorId: string; initial: Detail | null }) {
  const [detail, setDetail] = useState(initial), [busy, setBusy] = useState(false), [error, setError] = useState("");
  useEffect(() => {
    if (!detail) return;
    try {
      const key = storageKey(actorId), raw = sessionStorage.getItem(key), attempt = raw ? readAttempt(raw) : null;
      if (attempt?.state === "confirmed" && attempt.tenantId === id) sessionStorage.removeItem(key);
    } catch { /* A preserved receipt remains safe to reopen if session storage is unavailable. */ }
  }, [actorId, detail, id]);
  async function refresh() {
    if (busy) return;
    setBusy(true); setError("");
    try {
      const { data, error } = await supabase.rpc("platform_get_tenant_onboarding_detail_v1", { p_tenant_id: id });
      const current = error ? null : readDetail(data, id);
      if (!current) { setDetail(null); setError("Nie udało się odczytać bieżącego stanu. Sprawdź dostęp i ponów odczyt."); }
      else setDetail(current);
    } catch { setDetail(null); setError("Nie udało się połączyć. Ponów odczyt bieżącego stanu."); }
    finally { setBusy(false); }
  }
  return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title={detail?.tenant.name ?? "Bieżący stan obiektu"} description="Stan pochodzi z aktualnego odczytu konfiguracji obiektu.">
    <div className="flex flex-wrap gap-3"><Link href="/platform-admin" className={button}>Lista obiektów</Link><button className={button} disabled={busy} onClick={() => void refresh()}>Odśwież stan</button></div>
    {error && <p role="alert" className="my-4">{error}</p>}
    {!detail ? <p className="my-4">Bieżący stan jest niedostępny. Ponów odczyt.</p> : <div className="my-6 space-y-6 break-words">
      <section className="space-y-3"><h2 className="text-xl font-bold">Obiekt</h2><p className="break-all">UUID: {id}</p><p>Status: {detail.tenant.status} · {detail.public_profile?.is_public ? "Opublikowany" : "Niepubliczny"}</p><p>Miejscowość: {detail.public_profile?.city ?? "Brak profilu"}</p><p className="break-all">Adres techniczny: /t/{detail.tenant.technical_slug}</p><p className="break-all">Adres publiczny: {detail.public_profile ? `https://strzelajtu.pl/${detail.public_profile.public_slug}` : "Brak profilu"}</p></section>
      <section><h2 className="text-xl font-bold">Bieżący plan</h2>{detail.plan ? <><p>{detail.plan.plan_key} · {detail.plan.status} · przypisanie: {detail.plan.assignment_status}</p><p>Możliwości: {detail.plan.enabled_feature_keys.join(", ") || "Brak"}</p></> : <p>Brak przypisanego planu.</p>}</section>
      <section><h2 className="text-xl font-bold">Aktywni administratorzy</h2>{detail.admins.length ? <ul className="space-y-2">{detail.admins.map(admin => <li key={admin.user_id} className="break-all">{admin.email ?? "Adres e-mail niedostępny"} · {admin.user_id}</li>)}</ul> : <p>Brak aktywnych administratorów.</p>}</section>
      <section className="space-y-2"><h2 className="text-xl font-bold">Gotowość techniczna</h2><ul>{[["Utworzenie", detail.readiness.create_ready], ["Aktywacja", detail.readiness.activation_ready], ["Publikacja", detail.readiness.public_ready], ["Rezerwacje", detail.readiness.booking_ready]].map(([label, ready]) => <li key={String(label)}>{label}: {ready ? "Gotowe" : "Wymaga konfiguracji"}</li>)}</ul><ul>{Object.entries(detail.readiness.checks).map(([key, ready]) => <li key={key}>{readinessLabels[key] ?? key}: {ready ? "Gotowe" : "Wymaga konfiguracji"}</li>)}</ul><p>Gotowość techniczna nie potwierdza gotowości prawnej. Formalna bramka prawna pozostaje odroczona.</p>{!detail.readiness.publication_gate_enforced && <p>Raport gotowości nie stanowi jeszcze egzekwowanej bramki publikacji.</p>}</section>
      <div className="flex flex-wrap gap-3"><Link className={button} href={`/tenant-setup/${detail.tenant.technical_slug}`}>Ustawienia — wymagany tenant admin</Link><Link className={button} href={`/platform-admin/tenants/${id}/preview`}>Prywatny podgląd</Link></div>
    </div>}
  </AdminShell>;
}
