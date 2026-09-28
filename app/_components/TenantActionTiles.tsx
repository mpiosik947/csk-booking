"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { loadTenantActionTiles } from "@/lib/tenant-action-tiles";

export default function TenantActionTiles({ tenantSlug, disabled = false }: { tenantSlug: string; disabled?: boolean }) {
  const [state, setState] = useState<{ slug: string; clientHref: string; staffHref: string | null } | null>(null);
  useEffect(() => {
    if (disabled) return;
    let active = true;
    let revision = 0;
    let timer: ReturnType<typeof setTimeout>;
    const refresh = async () => {
      const current = ++revision;
      try {
        const result = await loadTenantActionTiles(supabase, tenantSlug);
        if (active && current === revision) setState(result ? { slug: tenantSlug, ...result } : null);
      } catch { if (active && current === revision) setState(null); }
    };
    void refresh();
    const { data: { subscription } } = supabase.auth.onAuthStateChange(() => {
      ++revision;
      setState(null);
      clearTimeout(timer);
      timer = setTimeout(() => { void refresh(); }, 0);
    });
    return () => { active = false; ++revision; clearTimeout(timer); subscription.unsubscribe(); };
  }, [tenantSlug, disabled]);
  if (disabled || !state || state.slug !== tenantSlug) return null;
  const tiles = [
    { href: state.clientHref, title: "Panel klienta", description: "Twoje rezerwacje, wydarzenia i konto." },
    ...(state.staffHref ? [{ href: state.staffHref, title: "Panel obsługi", description: "Zarządzaj obiektem, rezerwacjami i wydarzeniami." }] : []),
  ];
  return <nav aria-label="Twoje panele" data-testid="tenant-action-tiles" className="mb-6 grid min-w-0 gap-3 md:grid-cols-2">
    {tiles.map(tile => <Link key={tile.title} href={tile.href} className="flex min-h-24 min-w-0 items-center gap-3 rounded-xl border border-[#46513b] bg-[#1c241b] px-4 py-3 transition hover:border-[#8b986f] hover:bg-[#26301f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]">
      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" className="h-5 w-5 shrink-0 text-[#aab58f]"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>
      <span className="min-w-0 flex-1"><span className="block text-base font-semibold text-[#e5dfc9]">{tile.title}</span><span className="mt-1 block text-sm leading-5 text-[#a9ada4]">{tile.description}</span></span>
      <span aria-hidden="true" className="shrink-0 text-xl text-[#bca266]">›</span>
    </Link>)}
  </nav>;
}
