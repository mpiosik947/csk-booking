"use client";

import Link from "next/link";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { supabase } from "@/lib/supabase";
import AdminShell from "../admin/_components/AdminShell";

type Resource = { id: string; kind: "reservation" | "event_registration"; tenant_name: string;
 tenant_status: string; title: string; date: string; start_time: string; status: string; payment_status: string;
 deadline: string; can_cancel: boolean;
 settlements: { id: string; kind: string; amount: number; currency: string; recorded_at: string }[] };
type Tenant = { id: string; name: string; status: string };
const control = "min-h-12 rounded-lg border border-[#667052] bg-[#171d15] px-3 py-2 disabled:opacity-40";

export default function ContinuityPanel() {
  const [items, setItems] = useState<Resource[]>([]);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [staffTenant, setStaffTenant] = useState("");
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [settlement, setSettlement] = useState<Resource | null>(null);
  const [requestKey, setRequestKey] = useState<string | null>(null);
  const load = useCallback(async () => {
    try {
    const { data, error } = await supabase.rpc("get_my_continuity_v1", { p_page: page, p_staff_tenant: staffTenant || null });
    if (error || !data || !Array.isArray(data.items)) { setItems([]); setMessage("Nie udało się pobrać historii. Spróbuj ponownie."); return; }
    setItems(data.items); setTotal(data.total); setTenants(data.staff_tenants ?? []);
    } catch { setItems([]); setMessage("Nie udało się połączyć. Spróbuj ponownie."); }
  }, [page, staffTenant]);
  useEffect(() => { const timer = setTimeout(() => void load(), 0); return () => clearTimeout(timer); }, [load]);
  async function cancel(resource: Resource) {
    if (busy || !window.confirm("Anulować to istniejące zobowiązanie?")) return;
    setBusy(true); setMessage("");
    try {
      const { error } = await supabase.rpc("cancel_continuity_resource_v1", { p_kind: resource.kind, p_resource_id: resource.id });
      if (error) setMessage(error.code === "55000" ? "Anulowanie jest niedostępne ze względu na termin lub stan zobowiązania." : "Nie można anulować tego zobowiązania.");
      else { setMessage("Anulowano. Nie utworzono nowego zobowiązania ani promocji z listy rezerwowej."); await load(); }
    } catch { setMessage("Nie udało się potwierdzić anulowania. Odśwież historię przed ponowną próbą."); }
    finally { setBusy(false); }
  }
  async function record(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!settlement || !requestKey || busy) return;
    const form = new FormData(event.currentTarget); setBusy(true);
    try {
      const { error } = await supabase.rpc("record_external_settlement_v1", {
        p_kind: form.get("kind"), p_resource_kind: settlement.kind, p_resource_id: settlement.id,
        p_amount: Number(form.get("amount")), p_currency: form.get("currency"), p_reference: form.get("reference"), p_idempotency_key: requestKey,
      });
      if (error) setMessage("Zapis odrzucony. Sprawdź uprawnienia i dane. Ponowna próba tego formularza nie tworzy duplikatu.");
      else { setMessage("Odnotowano działanie wykonane poza systemem. Aplikacja nie przesłała pieniędzy ani nie zmieniła statusu płatności."); setSettlement(null); setRequestKey(null); await load(); }
    } catch { setMessage("Nie udało się potwierdzić zapisu. Ponów ten sam formularz, aby uniknąć duplikatu."); }
    finally { setBusy(false); }
  }
  return <AdminShell eyebrow="Istniejące zobowiązania" title="Historia i rozliczenia"
    description="Historia pozostaje dostępna również przy zawieszeniu obiektu. Nie tworzysz tutaj rezerwacji, płatności ani nowych obciążeń.">
    <Link href="/account" className="underline">Moje konto</Link>
    <label className="my-4 grid max-w-lg gap-2">Zakres<select className={control} value={staffTenant} onChange={event => { setStaffTenant(event.target.value); setPage(1); setSettlement(null); }}>
      <option value="">Moja historia</option>{tenants.map(tenant => <option key={tenant.id} value={tenant.id}>Obsługa: {tenant.name} ({tenant.status})</option>)}
    </select></label>
    {message && <p role="status" className="my-3 rounded-lg border border-[#807144] p-3">{message}</p>}
    {items.length === 0 && <p>Brak zobowiązań w wybranym zakresie.</p>}
    <div className="grid gap-4">{items.map(resource => <section key={`${resource.kind}-${resource.id}`} className="min-w-0 rounded-xl border border-[#48523c] p-4">
      <h2 className="break-words text-xl font-bold">{resource.title}</h2>
      <p>{resource.tenant_name} · {resource.date} {resource.start_time.slice(0, 5)}</p>
      <p>Status: {resource.status} · Płatność: {resource.payment_status}</p>
      {resource.tenant_status === "suspended" && <p className="text-amber-200">Obiekt zawieszony — dostępna tylko obsługa istniejących zobowiązań.</p>}
      <div className="my-3 flex flex-wrap gap-2">
        {resource.can_cancel && <button className={control} disabled={busy} onClick={() => void cancel(resource)}>Anuluj</button>}
        {staffTenant && <button className={control} disabled={busy} onClick={() => { setSettlement(resource); setRequestKey(crypto.randomUUID()); }}>Odnotuj rozliczenie zewnętrzne</button>}
      </div>
      {resource.settlements.map(item => <p key={item.id}>{item.kind === "external_refund" ? "Odnotowany zwrot zewnętrzny" : "Odnotowane uzgodnienie zewnętrzne"}: {item.amount} {item.currency} · {new Date(item.recorded_at).toLocaleString("pl-PL", { timeZone: "Europe/Warsaw" })}</p>)}
    </section>)}</div>
    {settlement && <form onSubmit={record} className="my-6 grid gap-3 rounded-xl border border-amber-700 p-4 sm:grid-cols-2">
      <h2 className="text-xl font-bold sm:col-span-2">Zapis zdarzenia wykonanego poza systemem</h2>
      <p className="sm:col-span-2">To nie wykonuje zwrotu ani płatności. „Nieopłacone” nie oznacza zwrotu. Nie wpisuj danych osobowych w referencji.</p>
      <label className="grid gap-1">Rodzaj<select name="kind" className={control}><option value="external_reconciliation">Rozliczenie / uzgodnienie zewnętrzne</option><option value="external_refund">Zwrot wykonany zewnętrznie</option></select></label>
      <label className="grid gap-1">Kwota<input name="amount" type="number" min="0.01" step="0.01" required className={control} /></label>
      <label className="grid gap-1">Waluta<input name="currency" pattern="[A-Z]{3}" maxLength={3} defaultValue="PLN" required className={control} /></label>
      <label className="grid gap-1">Referencja operacyjna (bez PII)<input name="reference" maxLength={100} required className={control} /></label>
      <label className="sm:col-span-2"><input type="checkbox" required /> Potwierdzam, że działanie zostało wykonane poza aplikacją.</label>
      <button className={control} disabled={busy}>Zapisz w historii i audycie</button>
      <button type="button" className={control} onClick={() => setSettlement(null)}>Zamknij</button>
    </form>}
    <nav aria-label="Strony historii" className="mt-5 flex flex-wrap items-center gap-3">
      <button className={control} disabled={page === 1 || busy} onClick={() => setPage(page - 1)}>Poprzednia</button><span>Strona {page}</span>
      <button className={control} disabled={page * 25 >= total || busy} onClick={() => setPage(page + 1)}>Następna</button>
      <button className={control} onClick={() => void load()}>Odśwież</button>
    </nav>
  </AdminShell>;
}
