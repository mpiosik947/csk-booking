"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import { cardFacts, groups, matchesTenant, readTenantPage, type CardFacts, type ListTenant } from "@/lib/platform-tenant-list";
import type { TenantStatus } from "@/lib/platform-management";
import AdminShell from "../admin/_components/AdminShell";
import TenantListCard from "./TenantListCard";
import TenantDomains from "./TenantDomains";

const control = "min-h-11 rounded-lg border border-[#626b55] bg-[#20271b] px-3 py-2 focus-visible:outline-2 focus-visible:outline-amber-300 disabled:opacity-50";
const createLink = "inline-flex min-h-12 items-center justify-center rounded-lg bg-[#e1cd91] px-5 py-2 font-semibold text-[#181b14] focus-visible:outline-2 focus-visible:outline-amber-300";
const orderedGroups: TenantStatus[] = ["active", "dormant", "suspended", "archived"];

export default function PlatformTenants({ actorId }: { actorId: string }) {
  const [items, setItems] = useState<ListTenant[]>([]);
  const [facts, setFacts] = useState<Record<string, CardFacts | null>>({});
  const [query, setQuery] = useState(""), [filter, setFilter] = useState<TenantStatus | "all">("all");
  const [page, setPage] = useState(1), [loading, setLoading] = useState(true);
  const [error, setError] = useState(""), [denied, setDenied] = useState(false);
  const [message, setMessage] = useState(""), [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const sequence = useRef(0), lostAccess = useRef(false), writing = useRef(false);
  const invalidate = useCallback(() => { sequence.current++; }, []);
  const deny = useCallback(() => {
    invalidate(); lostAccess.current = true; setDenied(true); setItems([]); setFacts({}); setSelected(null);
  }, [invalidate]);
  const load = useCallback(async () => {
    if (lostAccess.current) return;
    const version = ++sequence.current;
    const current = () => version === sequence.current;
    setLoading(true); setError(""); setFacts({});
    const read = async (name: string, args: Record<string, unknown>) => {
      const result = await supabase.rpc(name, args).abortSignal(AbortSignal.timeout(20000));
      if (!current()) throw Error("OBSOLETE");
      if ([401,403].includes(result.status) || result.error?.code === "42501") { deny(); throw Error("DENIED"); }
      if (result.error) throw Error("READER");
      return result.data;
    };
    try {
      // Read the existing 25-row pages before applying global search, filters and local pagination.
      const first = readTenantPage(await read("platform_list_tenants_v1", { p_page:1 }), 1);
      if (!first) throw Error("LIST");
      const rows = first.items;
      for (let n = 2; n <= Math.ceil(first.total / 25); n++) {
        const next = readTenantPage(await read("platform_list_tenants_v1", { p_page:n }), n);
        if (!next || next.total !== first.total) throw Error("LIST_CHANGED");
        rows.push(...next.items);
      }
      if (rows.length !== first.total || new Set(rows.map(t => t.id)).size !== first.total) throw Error("LIST_CHANGED");
      rows.sort((a,b) => Date.parse(b.createdAt) - Date.parse(a.createdAt) || a.id.localeCompare(b.id));
      setItems(rows);
      for (let i = 0; i < rows.length && current(); i += 4) {
        const entries = await Promise.all(rows.slice(i,i+4).map(async t => {
          try { return [t.id, await cardFacts(t, (name,id) => read(name, { p_tenant_id:id }))] as const; }
          catch { return [t.id, null] as const; }
        }));
        if (current()) setFacts(old => ({...old, ...Object.fromEntries(entries)}));
      }
    } catch {
      if (current()) { setItems([]); setFacts({}); setError("Nie można odczytać pełnej listy obiektów. Odśwież listę, aby ponowić odczyt."); }
    } finally { if (current()) setLoading(false); }
  }, [deny]);
  useEffect(() => {
    const timer = setTimeout(() => void load(), 0);
    const listener = supabase.auth.onAuthStateChange((_event, session) => {
      if (!session || session.user.id !== actorId) deny();
    });
    window.addEventListener("focus",load);
    return () => { invalidate(); clearTimeout(timer); listener.data.subscription.unsubscribe(); window.removeEventListener("focus",load); };
  }, [load, actorId, deny, invalidate]);

  async function mutate(rpc: string, params: Record<string, unknown>) {
    if (writing.current || lostAccess.current) return;
    writing.current = true; setBusy(true); setMessage("Zapisywanie zmiany…");
    try {
      const r = await supabase.rpc(rpc, params);
      if (lostAccess.current) return;
      if (r.status === 401 || r.status === 403 || r.error?.code === "42501") { deny(); return; }
      if (r.error) setMessage("Operacja odrzucona. Sprawdź gotowość i uprawnienia w szczegółach obiektu.");
      else { setMessage("Zmiana zapisana i zarejestrowana w audycie."); await load(); }
    } catch { setMessage("Nie potwierdzono wyniku. Odśwież listę przed ponowną próbą."); }
    finally { writing.current = false; setBusy(false); }
  }
  if (denied) return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Brak dostępu"><p role="alert">Zaloguj się jako administrator platformy, aby wyświetlić listę obiektów.</p></AdminShell>;
  const hasMissing = items.some(t => facts[t.id] === null || facts[t.id]?.access === null);
  const matches = items.filter(t => (filter === "all" || filter === t.status) && matchesTenant(t, facts[t.id], query));
  const pages = Math.max(1, Math.ceil(matches.length / 25)), visiblePage = Math.min(page,pages);
  const visible = matches.slice((visiblePage-1)*25,visiblePage*25);
  const empty = !loading && !error && items.length === 0;
  return <AdminShell eyebrow="StrzelajTu.pl · Platforma" title="Obiekty"
    description="Twórz, konfiguruj i zarządzaj obiektami dostępnymi w StrzelajTu.pl."
    actions={<Link href="/platform-admin/tenants/new" className={createLink}><span aria-hidden="true" className="mr-2">+</span>{empty ? "Dodaj pierwszy obiekt" : "Dodaj nowy obiekt"}</Link>}>
    <Link href="/account" className="underline">Moje konto</Link>
    {message && <p role="status" className="my-4">{message}</p>}
    <div className="my-5 flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end">
      <label className="min-w-0 flex-1 font-semibold">Szukaj obiektu
        <input type="search" className={control + " mt-1 block w-full font-normal"} placeholder="Nazwa lub adres obiektu" value={query} onChange={e => { setQuery(e.target.value); setPage(1); }} />
      </label>
      <label className="min-w-0 font-semibold">Stan obiektu
        <select className={control + " mt-1 block max-w-full font-normal"} value={filter} onChange={e => { setFilter(e.target.value as typeof filter); setPage(1); }}>
          <option value="all">Wszystkie</option>{orderedGroups.map(k => <option key={k} value={k}>{groups[k]}</option>)}
        </select>
      </label>
      <button className={control} disabled={busy || loading} onClick={() => void load()}>Odśwież listę</button>
    </div>
    {error && <p role="alert">{error}</p>}
    {hasMissing && <p role="status">Nie wszystkie dane kart są dostępne. Odśwież listę, aby je pobrać.</p>}
    <p role="status" className="mb-4 text-sm">{loading ? "Wczytywanie obiektów…" : !error && items.length > 0 ? `Liczba wyników: ${matches.length}` : ""}</p>
    {empty && <div><h2 className="text-xl font-bold">Nie masz jeszcze żadnego obiektu.</h2><p>Konfigurator przeprowadzi Cię przez dane obiektu, osie, rezerwacje i przekazanie administratorowi.</p></div>}
    {!loading && !error && !empty && !matches.length && <p>Brak obiektów spełniających kryteria. <button className="underline" onClick={() => {setQuery(""); setFilter("all"); setPage(1);}}>Wyczyść wyszukiwanie i filtr</button></p>}
    {orderedGroups.map(k => {
      const group = visible.filter(t => t.status === k);
      return group.length > 0 && <section key={k} aria-labelledby={"group-"+k} className="my-6">
        <h2 id={"group-"+k} className="mb-3 text-xl font-bold">{groups[k]}</h2>
        <div className="grid gap-4 lg:grid-cols-2">{group.map(tenant => <TenantListCard key={tenant.id} tenant={tenant} facts={facts[tenant.id]}
          onOperations={() => setSelected(selected === tenant.id ? null : tenant.id)}>
          {tenant.status !== "archived" && selected === tenant.id && <div className="space-y-4 border-t border-[#48523c] pt-3">
          <TenantDomains tenantId={tenant.id} />
          <p>Planem i administratorami zarządzaj na stronie <Link className="underline" href={`/platform-admin/tenants/${tenant.id}`}>szczegółów obiektu</Link>.</p>
          <p>Aktywacja nie publikuje obiektu. Zawieszenie wyłącza nowy biznes, ale zachowuje historię i obsługę istniejących zobowiązań.</p>
          <div className="flex flex-wrap gap-2">

            {!tenant.draft && (tenant.status === "dormant" || tenant.status === "suspended") && <button disabled={busy} className={control} onClick={() => void mutate("platform_set_tenant_state_v1", { p_tenant_id: tenant.id, p_action: "activate" })}>Aktywuj po sprawdzeniu gotowości</button>}
            {tenant.status === "active" && <><button disabled={busy} className={control} onClick={() => void mutate("platform_set_tenant_state_v1", { p_tenant_id: tenant.id, p_action: tenant.published ? "unpublish" : "publish" })}>{tenant.published ? "Wycofaj publikację" : "Opublikuj"}</button><button disabled={busy} className={control} onClick={() => { if (window.confirm("Zawiesić nowy biznes tego obiektu i wycofać publikację?")) void mutate("platform_set_tenant_state_v1", { p_tenant_id: tenant.id, p_action: "suspend" }); }}>Zawieś</button></>}
          </div>
          </div>}
        </TenantListCard>)}</div>
      </section>;
    })}
    {pages > 1 && <nav aria-label="Strony obiektów" className="mt-5 flex flex-wrap items-center gap-3">
      <button className={control} disabled={visiblePage === 1} onClick={() => setPage(visiblePage-1)}>Poprzednia</button>
      <span>Strona {visiblePage} z {pages}</span><button className={control} disabled={visiblePage === pages} onClick={() => setPage(visiblePage+1)}>Następna</button>
    </nav>}
  </AdminShell>;
}
