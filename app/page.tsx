import Image from "next/image";
import Link from "next/link";
import { getPublicTenantDirectory } from "@/lib/server/public-tenant-directory";

function SearchIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" className="h-5 w-5">
      <circle cx="11" cy="11" r="7" />
      <path d="m16.5 16.5 4 4" />
    </svg>
  );
}

function ArrowIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" className="h-5 w-5">
      <path d="m9 18 6-6-6-6" />
    </svg>
  );
}

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2)
    .map((part) => part[0]?.toUpperCase()).join("");
}

export default async function Home({
  searchParams,
}: Readonly<{ searchParams: Promise<{ q?: string | string[] }> }>) {
  const query = (await searchParams).q;
  const directory = await getPublicTenantDirectory(
    typeof query === "string" ? query : "",
  );

  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-8 text-[#f2efe4] sm:px-6 sm:py-12">
      <div className="mx-auto w-full max-w-6xl">
        <header className="text-center">
          <Link
            href="/"
            aria-label="StrzelajTu.pl — strona główna"
            className="inline-flex items-center gap-3 rounded-xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861]"
          >
            <span aria-hidden="true" className="flex h-12 w-12 items-center justify-center rounded-full border border-[#b89545] bg-[#2b2416] text-xl font-black text-[#f0d17b]">
              ST
            </span>
            <span className="text-2xl font-black tracking-tight text-[#f5f1e8] sm:text-3xl">
              StrzelajTu<span className="text-[#c5a861]">.pl</span>
            </span>
          </Link>
          <h1 className="mx-auto mt-8 max-w-3xl text-3xl font-black leading-tight text-[#f5f1e8] sm:text-5xl">
            Znajdź strzelnicę i zarezerwuj termin online
          </h1>
          <p className="mx-auto mt-4 max-w-2xl text-base leading-7 text-[#aeb4a8] sm:text-lg">
            Wybierz obiekt, sprawdź dostępność i przejdź do rezerwacji w jego bezpiecznym panelu.
          </p>
        </header>

        <section aria-labelledby="directory-heading" className="mt-10 rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/30 sm:p-8">
          <form action="/" method="get" role="search" className="mx-auto flex max-w-3xl flex-col gap-3 sm:flex-row">
            <label htmlFor="tenant-search" className="sr-only">
              Wyszukaj strzelnicę lub miejscowość
            </label>
            <div className="flex min-w-0 flex-1 items-center gap-3 rounded-xl border border-[#46503e] bg-[#0e110e] px-4 focus-within:border-[#a49358] focus-within:ring-2 focus-within:ring-[#a49358]/30">
              <SearchIcon />
              <input
                id="tenant-search"
                name="q"
                type="search"
                maxLength={80}
                defaultValue={directory.search}
                placeholder="Wyszukaj strzelnicę lub miejscowość"
                className="min-h-12 min-w-0 flex-1 bg-transparent py-3 text-base text-[#f2efe4] outline-none placeholder:text-[#777f73]"
              />
            </div>
            <button type="submit" className="min-h-12 rounded-xl border border-[#b89545] bg-[#342b1b] px-6 font-bold text-[#f0d17b] transition hover:bg-[#41351f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d2b66f] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]">
              Znajdź strzelnicę
            </button>
          </form>

          <div className="mt-10 flex flex-wrap items-end justify-between gap-3">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-[#b89545]">
                Publiczny katalog
              </p>
              <h2 id="directory-heading" className="mt-2 text-2xl font-bold text-[#f2efe4]">
                Strzelnice
              </h2>
            </div>
            {directory.ok && (
              <p className="text-sm text-[#8f968b]">Wyniki: {directory.items.length}</p>
            )}
          </div>

          {!directory.ok ? (
            <div role="alert" className="mt-6 rounded-2xl border border-[#644747] bg-[#241919] p-5 text-[#e2b4b4]">
              Nie udało się pobrać katalogu. Odśwież stronę i spróbuj ponownie.
            </div>
          ) : directory.items.length === 0 ? (
            <div className="mt-6 rounded-2xl border border-[#343a31] bg-[#1a1e1a] p-6 text-center text-[#aeb4a8]">
              {directory.search
                ? "Nie znaleźliśmy strzelnicy pasującej do wyszukiwania."
                : "Brak opublikowanych strzelnic."}
            </div>
          ) : (
            <ul className="mt-6 grid gap-4 sm:grid-cols-2">
              {directory.items.map((tenant) => (
                <li key={tenant.publicSlug} className="min-w-0">
                  <Link
                    href={`/${tenant.publicSlug}`}
                    className="group flex min-h-36 items-center gap-4 rounded-2xl border border-[#3d4638] bg-[#1a1f19] p-4 transition hover:-translate-y-0.5 hover:border-[#778462] hover:bg-[#20261e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] sm:p-5"
                  >
                    <span className="flex h-20 w-20 shrink-0 items-center justify-center overflow-hidden rounded-xl border border-[#4f5947] bg-[#0f120f] text-xl font-black text-[#d7c895]">
                      {tenant.logoPath ? (
                        <Image src={tenant.logoPath} alt="" width={160} height={160} className="h-full w-full object-contain" />
                      ) : initials(tenant.name)}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block text-lg font-bold leading-snug text-[#f2efe4]">
                        {tenant.name}
                      </span>
                      <span className="mt-2 block text-sm text-[#aeb4a8]">{tenant.city}</span>
                    </span>
                    <span className="shrink-0 text-[#9da88b] transition group-hover:translate-x-1">
                      <ArrowIcon />
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </section>

        <footer className="mt-8 flex flex-wrap items-center justify-center gap-x-5 gap-y-2 text-sm text-[#8f968b]">
          <span>Masz konto?</span>
          <Link href="/login" className="font-semibold text-[#d7c895] underline-offset-4 hover:underline">
            Zaloguj się
          </Link>
          <Link href="/register" className="font-semibold text-[#d7c895] underline-offset-4 hover:underline">
            Załóż konto
          </Link>
          <span aria-hidden="true" className="text-[#596055]">•</span>
          <Link href="/privacy" className="underline-offset-4 hover:text-[#d7c895] hover:underline">
            Polityka prywatności
          </Link>
          <Link href="/terms" className="underline-offset-4 hover:text-[#d7c895] hover:underline">
            Regulamin
          </Link>
        </footer>
      </div>
    </main>
  );
}
