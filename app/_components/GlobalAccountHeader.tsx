"use client";

import { useState } from "react";
import { PLATFORM_BASE_URL } from "@/lib/platform-domain";
import { supabase } from "@/lib/supabase";

/** Global account presentation only; the name never supplies authority. */
export default function GlobalAccountHeader({ firstName }: { firstName?: string | null }) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(false);
  const name = firstName?.trim();

  async function logout() {
    setPending(true);
    setError(false);
    try {
      const { error: signOutError } = await supabase.auth.signOut({ scope: "local" });
      if (signOutError) throw signOutError;
      window.location.assign(`${PLATFORM_BASE_URL}/`);
    } catch {
      setError(true);
      setPending(false);
    }
  }

  return (
    <div className="mb-6 border-b border-[#303A2D] pb-5" data-testid="global-account-header">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="min-w-0 break-words text-xl font-semibold text-[#F4F3EE] sm:text-2xl">
          {name ? `Witaj, ${name}` : "Witaj"}
        </p>
        <button type="button" onClick={logout} disabled={pending}
          className="min-h-12 shrink-0 rounded-xl border border-[#536139] bg-[#28331F] px-5 py-3 text-sm font-semibold text-[#F4F3EE] transition hover:bg-[#35432A] focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-[#F5A900] disabled:opacity-60">
          {pending ? "Wylogowywanie…" : "Wyloguj"}
        </button>
      </div>
      {error && <p role="alert" className="mt-3 text-sm text-[#F4F3EE]">Nie udało się wylogować. Spróbuj ponownie.</p>}
    </div>
  );
}
