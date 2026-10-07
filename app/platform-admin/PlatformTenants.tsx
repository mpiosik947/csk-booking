"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import AdminShell from "../admin/_components/AdminShell";
import TenantDomains from "./TenantDomains";

type Tenant = { id: string; name: string; tenant_slug: string; public_slug: string; city: string;
  status: string; is_public: boolean; plan_key: string | null; created_at: string; readiness: Record<string, boolean> };
const control = "min-h-12 rounded-lg border border-[#626b55] bg-[#161c14] px-3 py-2 disabled:opacity-40";

export default function PlatformTenants() {
  const [items, setItems] = useState<Tenant[]>([]);
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [selected, setSelected] = useState<string | null>(null);
  const load = useCallback(async () => {
    try {
    const { data, error } = await supabase.rpc("platform_list_tenants_v1", { p_page: page });
    if (error || !data || !Array.isArray(data.items)) { setItems([]); setMessage("Nie udało się pobrać obiektów. Sprawdź uprawnienia i spróbuj ponownie."); return; }
    setItems(data.items); setTotal(data.total);
    } catch { setItems([]); setMessage("Nie udało się połączyć. Spróbuj ponownie."); }
  }, [page]);
  useEffect(() => { const timer = setTimeout(() => void load(), 0); return () => clearTimeout(timer); }, [load]);
  async function mutate(rpc: string, params: Record<string, unknown>) {
    if (busy) return;
    setBusy(true); setMessage("");
    try {
      const { error } = await supabase.rpc(rpc, params);
      if (error) setMessage("Operacja odrzucona. Sprawdź kompletność konfiguracji, status, unikalność identyfikatorów i uprawnienia.");
      else { setMessage("Zmiana zapisana i zarejestrowana w audycie."); await load(); }
    } catch { setMessage("Nie udało się połączyć. Odśwież stan przed ponowną próbą."); }
    finally { setBusy(false); }
  }
  return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Obiekty i onboarding"
    description="Zarządzanie konfiguracją platformy nie daje dostępu do rezerwacji ani danych klientów obiektu.">
    <Link href="/account" className="underline">Moje konto</Link>
    {message && <p role="status" className="my-4 rounded-lg border border-[#807144] p-4">{message}</p>}
    <Link href="/platform-admin/tenants/new" className="my-6 inline-flex min-h-12 items-center rounded-lg border border-[#626b55] px-4 py-2">Dodaj nową strzelnicę</Link>
    <div className="grid gap-4">
      {items.map(tenant => <section key={tenant.id} className="min-w-0 rounded-xl border border-[#48523c] p-4">
        <h2 className="break-words text-xl font-bold">{tenant.name}</h2>
        <p className="break-all">{tenant.tenant_slug} / {tenant.public_slug}</p>
        <p>{tenant.city} · {tenant.status} · {tenant.is_public ? "Opublikowany" : "Niepubliczny"}</p>
        <p>Plan: {tenant.plan_key ?? "Nieprzypisany"} · Utworzono: {new Date(tenant.created_at).toLocaleDateString("pl-PL")}</p>
        <p className="my-2">Gotowość: {Object.values(tenant.readiness).every(Boolean) ? "Kompletna" : Object.entries(tenant.readiness).filter(([, ready]) => !ready).map(([key]) => ({ identity_ready: "nazwa", slug_ready: "identyfikatory", settings_ready: "ustawienia", plan_ready: "plan", admin_ready: "admin" })[key] ?? key).join(", ")}</p>
        <div className="flex flex-wrap gap-2">
          <Link className={control} href={`/platform-admin/tenants/${tenant.id}`}>Zarządzaj obiektem</Link>
          <Link className={control} href={`/platform-admin/tenants/${tenant.id}/preview`}>Prywatny podgląd</Link>
          <Link className={control} href={`/tenant-setup/${tenant.tenant_slug}`}>Ustawienia (wymagany tenant admin)</Link>
          <button disabled={busy} className={control} onClick={() => { setSelected(selected === tenant.id ? null : tenant.id); }}>Konfiguruj</button>
        </div>
        {selected === tenant.id && <div className="mt-4 space-y-4">
          <TenantDomains tenantId={tenant.id} />
          <p>Planem i administratorami zarządzaj na stronie <Link className="underline" href={`/platform-admin/tenants/${tenant.id}`}>szczegółów obiektu</Link>.</p>
          <p>Aktywacja nie publikuje obiektu. Zawieszenie wyłącza nowy biznes, ale zachowuje historię i obsługę istniejących zobowiązań.</p>
          <div className="flex flex-wrap gap-2">

            {(tenant.status === "dormant" || tenant.status === "suspended") && <button disabled={busy} className={control} onClick={() => void mutate("platform_set_tenant_state_v1", { p_tenant_id: tenant.id, p_action: "activate" })}>Aktywuj po sprawdzeniu gotowości</button>}
            {tenant.status === "active" && <><button disabled={busy} className={control} onClick={() => void mutate("platform_set_tenant_state_v1", { p_tenant_id: tenant.id, p_action: tenant.is_public ? "unpublish" : "publish" })}>{tenant.is_public ? "Wycofaj publikację" : "Opublikuj"}</button><button disabled={busy} className={control} onClick={() => { if (window.confirm("Zawiesić nowy biznes tego obiektu i wycofać publikację?")) void mutate("platform_set_tenant_state_v1", { p_tenant_id: tenant.id, p_action: "suspend" }); }}>Zawieś</button></>}
          </div>
        </div>}
      </section>)}
    </div>
    <nav aria-label="Strony obiektów" className="mt-5 flex flex-wrap items-center gap-3">
      <button className={control} disabled={page === 1 || busy} onClick={() => setPage(page - 1)}>Poprzednia</button>
      <span>Strona {page}</span><button className={control} disabled={page * 25 >= total || busy} onClick={() => setPage(page + 1)}>Następna</button>
      <button className={control} onClick={() => void load()}>Odśwież</button>
    </nav>
  </AdminShell>;
}
