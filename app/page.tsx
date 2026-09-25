import PlatformBrand from "@/app/_components/PlatformBrand";
import DirectorySearchInput from "@/app/_components/DirectorySearchInput";
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
    <main className="platform-ui min-h-screen bg-[#080B09] px-4 py-8 text-[#F4F3EE] sm:px-6 sm:py-12">
      <div className="mx-auto w-full max-w-6xl">
        <header className="text-center">
          <div className="flex flex-col items-center justify-between gap-4 sm:flex-row sm:text-left">
            <PlatformBrand />
            <nav aria-label="Konto StrzelajTu.pl" className="flex items-center gap-3">
              <Link href="/login" className="rounded-xl border border-[#556333] px-4 py-3 text-sm font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#182019]">
                Zaloguj się
              </Link>
              <Link href="/register" className="rounded-xl border border-[#697A2F] bg-[#303B1C] px-4 py-3 text-sm font-semibold text-[#F4F3EE] transition hover:bg-[#435225]">
                Załóż konto
              </Link>
            </nav>
          </div>
          <h1 className="mx-auto mt-7 max-w-3xl text-[26px] font-bold leading-tight text-[#f5f1e8] sm:text-[42px]">
            Znajdź strzelnicę i zarezerwuj termin online
          </h1>
          <p className="mx-auto mt-4 max-w-2xl text-base leading-7 text-[#aeb4a8] sm:text-lg">
            Wybierz obiekt, sprawdź dostępność i przejdź do rezerwacji w jego bezpiecznym panelu.
          </p>
        </header>

        <section aria-labelledby="directory-heading" className="mx-auto mt-8 max-w-4xl rounded-[2rem] border border-[#465332] bg-[#111712] p-4 shadow-2xl shadow-black/30 sm:p-6">
          <form action="/" method="get" role="search" className="mx-auto flex max-w-3xl flex-col gap-3 sm:flex-row">
            <label htmlFor="tenant-search" className="sr-only">
              Wyszukaj strzelnicę lub miejscowość
            </label>
            <div className="flex min-w-0 flex-1 items-center gap-3 rounded-xl border border-[#556333] bg-[#0e110e] px-4 focus-within:border-[#7A8D36] focus-within:ring-2 focus-within:ring-[#7A8D36]/30">
              <SearchIcon />
              <DirectorySearchInput search={directory.search} />
            </div>
            <button type="submit" className="platform-primary min-h-12 rounded-xl border border-[#b89545] bg-[#342b1b] px-6 font-bold text-[#f0d17b] transition hover:bg-[#41351f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d2b66f] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]">
              Znajdź strzelnicę
            </button>
          </form>

          <div className="mt-6 flex flex-wrap items-end justify-between gap-3">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-[#a4b778]">
                Publiczny katalog
              </p>
              <h2 id="directory-heading" className="mt-2 text-2xl font-bold text-[#F4F3EE]">
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
            <ul className={`mt-4 grid gap-4 ${directory.items.length === 1 ? "" : "sm:grid-cols-2"}`}>
              {directory.items.map((tenant) => (
                <li key={tenant.publicSlug} className="min-w-0">
                  <Link
                    href={`/${tenant.publicSlug}`}
                    className="group flex min-h-36 items-center gap-3 rounded-2xl border border-[#4c5b34] bg-[#1a1f19] p-3 transition hover:-translate-y-0.5 hover:border-[#7A8D36] hover:bg-[#222b1a] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] sm:gap-4 sm:p-5"
                  >
                    <span className="flex h-16 w-16 shrink-0 items-center justify-center overflow-hidden rounded-xl border border-[#556333] bg-[#0f120f] text-xl font-black text-[#a4b778] sm:h-24 sm:w-24">
                      {tenant.logoPath ? (
                        <Image src={tenant.logoPath} alt="" width={160} height={160} className="h-full w-full object-contain" />
                      ) : initials(tenant.name)}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block text-base font-bold leading-snug text-[#F4F3EE] sm:text-lg">
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

        <footer className="mt-8 flex flex-col flex-wrap items-center justify-center gap-x-5 gap-y-2 text-xs text-[#8f968b] sm:flex-row sm:text-sm">
          <div className="flex items-center justify-center gap-2 sm:contents">
          <span>Masz konto w StrzelajTu.pl?</span>
          <Link href="/login" className="font-semibold text-[#a4b778] underline-offset-4 hover:underline">
            Zaloguj się
          </Link>
          <Link href="/register" className="font-semibold text-[#a4b778] underline-offset-4 hover:underline">
            Załóż konto
          </Link>
          </div>
          <span aria-hidden="true" className="hidden text-[#596055] sm:inline">•</span>
          <div className="flex items-center justify-center gap-5 sm:contents">
          <Link href="/privacy" className="underline-offset-4 hover:text-[#F5A900] hover:underline">
            Polityka prywatności
          </Link>
          <Link href="/terms" className="underline-offset-4 hover:text-[#F5A900] hover:underline">
            Regulamin
          </Link>
          </div>
        </footer>
      </div>
    </main>
  );
}
