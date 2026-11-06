import Link from "next/link";
import type { ReactNode } from "react";
import { planName } from "@/lib/platform-management";
import { configurationLabel, lifecycleLabel, primaryAction, type ListTenant, type CardFacts } from "@/lib/platform-tenant-list";

const focus = "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-amber-300";
const secondary = "flex min-h-11 items-center rounded-md px-3 py-2 text-left underline " + focus;

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return <div className="min-w-0"><dt className="text-xs text-[#c2c8bb]">{label}</dt><dd className="mt-1 [overflow-wrap:anywhere]">{children}</dd></div>;
}

export default function TenantListCard({ tenant: t, facts: f, onOperations, children }: {
  tenant: ListTenant; facts: CardFacts | null | undefined; onOperations: () => void; children?: ReactNode;
}) {
  const base = `/platform-admin/tenants/${t.id}`;
  const action = primaryAction(t, f);
  const unknown = f === undefined ? "Wczytywanie…" : "Odczyt niedostępny";
  const name = t.name ?? f?.internalName ?? t.slug;
  const admin = !f ? unknown : f.admins === 0 ? (t.draft ? "Nie przekazano" : "Brak aktywnego administratora")
    : f.admins === 1 ? f.email ?? "1 administrator" : `Aktywni administratorzy: ${f.admins}`;
  const pageState = !f ? unknown : f.access === null ? "Odczyt niedostępny" : f.access === "coming_soon" ? "Dostępna wkrótce" :
    t.status === "active" && t.published ? "Dostępna" : "Tryb otwarty · strona niedostępna";
  return <article aria-labelledby={`name-${t.id}`} className={`flex min-w-0 flex-col gap-4 rounded-xl border p-4 sm:p-5 ${t.status === "archived" ? "border-dashed border-[#626b55]" : "border-[#48523c] bg-[#191f17]"}`}>
    <div className="flex min-w-0 items-start gap-3">
      <span className="grid size-10 shrink-0 place-items-center rounded-lg border border-[#59634f] bg-[#26301f] font-bold" aria-hidden="true">{name.match(/[\p{L}\p{N}]/u)?.[0].toLocaleUpperCase("pl") ?? "•"}</span>
      <div className="min-w-0"><h3 id={`name-${t.id}`} className="text-lg font-bold [overflow-wrap:anywhere]">{name}</h3>
        <p className="text-sm text-[#c2c8bb] [overflow-wrap:anywhere]">{[t.city, t.publicSlug ? "/" + t.publicSlug : "/t/" + t.slug].filter(Boolean).join(" · ")}</p></div>
    </div>
    <span className="max-w-full self-start rounded-full border border-[#68765a] px-3 py-1 text-sm">{lifecycleLabel(t, f)}</span>
    <dl className="grid min-w-0 gap-3 sm:grid-cols-2">
      <Fact label="Konfiguracja">{f ? configurationLabel(t, f) : unknown}</Fact>
      <Fact label="Pakiet">{t.plan ? planName(t.plan) + (f?.planActive === false ? " · nieaktywny" : "") : "Brak przypisanego pakietu"}</Fact>
      <Fact label="Administrator lokalny">{admin}</Fact>
      <Fact label="Publicznie">{t.published === true ? "Tak" : t.published === false ? "Nie" : "Brak profilu publicznego"}</Fact>
      <Fact label="Status strony">{pageState}</Fact>
    </dl>
    <div className="mt-auto flex min-w-0 flex-col gap-2 border-t border-[#48523c] pt-3 sm:flex-row sm:flex-wrap sm:items-start">
      {t.draft && t.status === "dormant" && f === undefined ? <span className="py-2">Ustalanie następnego kroku…</span> : <Link href={action.href} className={"inline-flex min-h-11 items-center justify-center rounded-lg bg-[#e1cd91] px-4 py-2 text-center font-semibold text-[#181b14] " + focus}>{action.label}</Link>}
      <details className="min-w-0" onKeyDown={e => {
        if (e.key === "Escape" && e.currentTarget.open) { e.currentTarget.open = false; e.currentTarget.querySelector("summary")?.focus(); }
      }}>
        <summary className={"min-h-11 cursor-pointer rounded-lg px-3 py-2 " + focus}>Więcej<span className="sr-only"> — {name}</span></summary>
        <div className="flex min-w-0 flex-col">
          {t.status === "archived" ? <><Link className={secondary} href={base}>Podgląd danych</Link><Link className={secondary} href={base + "#strefa-niebezpieczna"}>Strefa niebezpieczna</Link></> : <>
            {t.publicSlug && <Link className={secondary} href={base + "/preview"}>Prywatny podgląd</Link>}
            {action.label === "Przekaż administratorowi" && <Link className={secondary} href={base + "/setup"}>Konfiguruj</Link>}
            <Link className={secondary} href={base + "#pakiet"}>Zmień pakiet</Link>
            {!t.draft && <Link className={secondary} href={base + "#administratorzy"}>Administratorzy</Link>}
            <Link className={secondary} href={base + "#archiwizacja"}>Archiwizuj</Link>
            <button type="button" className={secondary} onClick={onOperations}>Publikacja i domeny</button>
          </>}
        </div>
      </details>
    </div>
    {children}
  </article>;
}
