"use client";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { hasCompleteActiveSalesConfiguration, parseAdminLaneConfigurationSnapshot, type AdminLaneConfigurationSnapshot } from "@/lib/admin/lane-configuration";

export default function SetupChecklist({ tenantId, tenantSlug, dormant, booking, basic, contact }: {
  tenantId: string | null; tenantSlug: string; dormant: boolean; booking: boolean; basic: boolean; contact: boolean;
}) {
  const [snapshot, setSnapshot] = useState<AdminLaneConfigurationSnapshot | null>(null);
  const [failed, setFailed] = useState(false);
  const [loading, setLoading] = useState(false);
  const refresh = useCallback(async () => {
    if (!booking || !tenantId) return;
    setLoading(true); setFailed(false);
    try {
      const result = await supabase.rpc(dormant ? "tenant_setup_get_lane_configuration_v1" : "admin_get_lane_booking_configuration_v3", { p_tenant_id: tenantId });
      if (result.error) throw new Error("configuration_unavailable");
      setSnapshot(parseAdminLaneConfigurationSnapshot(result.data));
    } catch { setSnapshot(null); setFailed(true); }
    finally { setLoading(false); }
  }, [booking, tenantId, dormant]);
  useEffect(() => { const timer = window.setTimeout(() => void refresh(), 0); return () => window.clearTimeout(timer); }, [refresh]);
  const resources = snapshot?.resources.filter(r => r.is_active && (r.whole_lane_bookable || r.resource_kind === "position")) ?? [];
  const states = [
    { label: "Dane podstawowe", ready: basic, pending: "Do uzupełnienia" },
    { label: "Dane kontaktowe", ready: contact, pending: "Do uzupełnienia (opcjonalne)" },
    { label: "Profil publiczny", ready: basic, pending: "Do uzupełnienia" },
    { label: "Osie / stanowiska", ready: resources.length > 0, pending: "Do konfiguracji" },
    { label: "Czasy rezerwacji", ready: resources.length > 0 && resources.every(r => r.durations.some(d => d.is_active)), pending: "Do konfiguracji" },
    { label: "Cennik", ready: resources.length > 0 && resources.every(r => hasCompleteActiveSalesConfiguration(r)), pending: "Do konfiguracji" },
  ];
  const laneHref = dormant ? `/tenant-setup/${tenantSlug}/lanes` : `/t/${tenantSlug}/admin/lane-configuration`;
  return <section aria-label="Lista konfiguracji" className="mt-6 rounded-2xl border border-[#30372c] p-5">
    <h2 className="text-xl font-bold">Kolejne kroki konfiguracji</h2>
    <p className="mt-2 text-sm">Konfiguracja: {states.filter((s, i) => s.ready && (i < 3 || booking)).length} z {booking ? 6 : 3} sekcji uzupełnionych. Kontakt jest opcjonalny.</p>
    <ul className="mt-3 space-y-2 text-sm">{states.map((s, i) => <li key={s.label}>{s.label}: <strong>{i >= 3 && !booking ? "Niedostępne w planie" : s.ready ? "Gotowe" : s.pending}</strong></li>)}</ul>
    {loading && <p role="status" className="mt-3">Odczytywanie konfiguracji osi…</p>}
    {failed && <p role="alert" className="mt-3">Nie udało się odczytać konfiguracji osi. Stan tych sekcji nie został potwierdzony.</p>}
    <p className="mt-3 text-xs text-[#a9ada4]">Lista opisuje zapisane ustawienia i konfigurację odczytaną z serwera. Nie potwierdza gotowości do aktywacji ani publikacji.</p>
    <nav aria-label="Konfiguracja obiektu" className="mt-4 flex flex-wrap gap-3">
      <a href="#public-profile" className="min-h-11 rounded-xl border border-[#536143] px-4 py-3">Ustawienia</a>
      {booking && tenantId && <><Link href={laneHref} className="min-h-11 rounded-xl bg-[#697A2F] px-4 py-3 font-semibold">Przejdź do konfiguracji osi</Link><button type="button" onClick={() => void refresh()} disabled={loading} className="min-h-11 rounded-xl border border-[#536143] px-4 py-3">Odśwież konfigurację</button></>}
    </nav>
  </section>;
}
