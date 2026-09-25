"use client";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { supabase } from "@/lib/supabase";

type Domain = { id: string; hostname: string; status: string; is_primary: boolean };
const control = "min-h-11 rounded-lg border border-[#626b55] bg-[#161c14] px-3 py-2 disabled:opacity-40";
export default function TenantDomains({ tenantId }: { tenantId: string }) {
  const [domains, setDomains] = useState<Domain[]>([]);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [challenge, setChallenge] = useState<{ txt_name: string; txt_value: string; verification_version: number } | null>(null);
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("platform_list_tenant_domains_v1", { p_tenant_id: tenantId });
    if (error || !Array.isArray(data)) { setDomains([]); setMessage("Nie udało się pobrać domen."); return; }
    setDomains(data);
  }, [tenantId]);
  useEffect(() => { const timer = setTimeout(() => { void load(); }, 0); return () => clearTimeout(timer); }, [load]);
  async function act(action: string, domainId: string | null, hostname: string | null = null) {
    if (busy) return;
    setBusy(true); setMessage(""); setChallenge(null);
    try {
      const { data, error } = await supabase.rpc("platform_manage_tenant_domain_v1", {
        p_tenant_id: tenantId, p_action: action, p_domain_id: domainId, p_hostname: hostname,
      });
      if (error) { setMessage("Operacja odrzucona. Sprawdź status, weryfikację, unikalność domeny i uprawnienia."); return; }
      if (action === "start_verification") setChallenge(data);
      setMessage("Zmiana zapisana w audycie."); await load();
    } catch { setMessage("Brak połączenia. Odśwież stan przed ponowną próbą."); }
    finally { setBusy(false); }
  }
  function add(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); void act("add", null, String(new FormData(event.currentTarget).get("hostname")));
  }
  return <section className="space-y-3 rounded-lg border border-[#48523c] p-4">
    <h3 className="font-bold">Domeny publiczne</h3>
    <p>Domena własna obsługuje tylko publiczne treści. Logowanie i operacje pozostają na StrzelajTu.pl.</p>
    <form onSubmit={add} className="flex flex-wrap gap-2"><label>Hostname bez protokołu i ścieżki<input name="hostname" required maxLength={253} className={control} /></label><button disabled={busy} className={control}>Dodaj jako pending</button></form>
    {message && <p role="status">{message}</p>}
    {challenge && <div className="break-all"><p>Ustaw TXT (ważny 24 godziny):</p><code>{challenge.txt_name}</code><pre className="whitespace-pre-wrap">{challenge.txt_value}</pre><p>Wersja {challenge.verification_version}. Operator musi niezależnie potwierdzić DNS oraz konfigurację Vercel/TLS. Ten ekran nie zatwierdza weryfikacji.</p></div>}
    {domains.map(domain => <div key={domain.id} className="space-y-2 border-t border-[#48523c] pt-3"><p>{domain.hostname} · {domain.status}{domain.is_primary ? " · primary" : ""}</p><div className="flex flex-wrap gap-2">
      {domain.status !== "active" && <button disabled={busy} className={control} onClick={() => void act("start_verification", domain.id)}>Wygeneruj DNS challenge</button>}
      {domain.status === "verified" && <button disabled={busy} className={control} onClick={() => void act("activate", domain.id)}>Aktywuj zweryfikowaną domenę</button>}
      {domain.status === "active" && !domain.is_primary && <button disabled={busy} className={control} onClick={() => void act("set_primary", domain.id)}>Ustaw primary</button>}
      {domain.status !== "disabled" && <button disabled={busy} className={control} onClick={() => void act("disable", domain.id)}>Wyłącz</button>}
    </div></div>)}
  </section>;
}
