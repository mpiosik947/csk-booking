"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { PLATFORM_BASE_URL } from "@/lib/platform-domain";
import { getSafeLoginRedirect } from "@/lib/safe-login-redirect";

/** Presentation of the existing global identity, never tenant authorization. */
export default function PublicAuthControls({ returnPath = "/", variant = "platform", preview = false, customDomain = false }: {
  returnPath?: string;
  variant?: "platform" | "tenant" | "footer";
  preview?: boolean;
  customDomain?: boolean;
}) {
  const [identity, setIdentity] = useState<{ firstName: string | null } | null>(null);
  const [ready, setReady] = useState(customDomain || preview);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(false);

  useEffect(() => {
    // Never copy the platform session to a tenant's registrable domain.
    if (customDomain || preview) return;
    let active = true;
    let revision = 0;
    const refresh = async () => {
      const current = ++revision;
      const { data: { user }, error: userError } = await supabase.auth.getUser();
      if (!active || current !== revision) return;
      if (!user || userError) {
        setIdentity(null);
        setReady(true);
        return;
      }
      setIdentity({ firstName: null });
      setReady(true);
      const { data } = await supabase.from("profiles").select("first_name").eq("user_id", user.id).maybeSingle();
      if (active && current === revision) setIdentity({ firstName: data?.first_name?.trim() || null });
    };
    const safelyRefresh = () => { void refresh().catch(() => { if (active) setReady(true); }); };
    safelyRefresh();
    let timer: ReturnType<typeof setTimeout>;
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT") {
        ++revision;
        setIdentity(null);
        setReady(true);
      } else {
        clearTimeout(timer);
        timer = setTimeout(safelyRefresh, 0);
      }
    });
    return () => { active = false; ++revision; clearTimeout(timer); subscription.unsubscribe(); };
  }, [customDomain, preview]);

  async function logout() {
    setPending(true);
    setError(false);
    try {
      const { error: signOutError } = await supabase.auth.signOut({ scope: "local" });
      if (signOutError) throw signOutError;
      setIdentity(null);
      window.location.assign(`${PLATFORM_BASE_URL}/`);
    } catch {
      setError(true);
      setPending(false);
    }
  }

  const base = customDomain ? PLATFORM_BASE_URL : "";
  const path = getSafeLoginRedirect(returnPath);
  const loginHref = `${base}/login?redirectTo=${encodeURIComponent(path)}`;
  const compact = variant !== "platform";
  const control = compact
    ? "inline-flex min-h-11 items-center font-semibold text-[#d7c895] underline-offset-4 hover:underline"
    : "inline-flex min-h-11 items-center rounded-xl border border-[#556333] px-4 py-3 text-sm font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#182019]";
  const link = (href: string, label: string, secondary = false) => preview
    ? <span className={control} aria-disabled="true">{label}</span>
    : <Link href={href} className={`${control}${secondary && !compact ? " bg-[#303B1C]" : ""}`}>{label}</Link>;

  return <div data-testid={`public-auth-${variant}`} aria-busy={!ready} className="flex max-w-full flex-wrap items-center justify-center gap-x-3 gap-y-2">
    {!ready ? <span role="status" className="inline-flex min-h-11 items-center text-sm text-[#a9ada4]">Ładowanie konta…</span>
      : identity ? <>
        <span className="max-w-full break-words font-semibold text-[#f2efe4]">{identity.firstName ? `Witaj, ${identity.firstName}` : "Witaj"}</span>
        {link(`${base}/account`, "Moje konto")}
        <button type="button" onClick={logout} disabled={pending} className={`${control} disabled:opacity-60`}>{pending ? "Wylogowywanie…" : "Wyloguj"}</button>
      </> : <>
        {variant === "footer" && <span>Masz konto w StrzelajTu.pl?</span>}
        {link(loginHref, "Zaloguj się")}
        {link(`${base}/register`, variant === "tenant" ? "Rejestracja" : "Załóż konto", true)}
      </>}
    {error && <p role="alert" className="w-full text-center text-sm">Nie udało się wylogować. Spróbuj ponownie.</p>}
  </div>;
}
