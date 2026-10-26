import Link from "next/link";
import PublicAuthControls from "./PublicAuthControls";

export default function TenantComingSoon({ name, unavailable = false, customDomain = false }: {
  name: string; unavailable?: boolean; customDomain?: boolean;
}) {
  return <main className="min-h-screen bg-[#090b09] px-4 py-10 text-[#f2efe4]">
    <section className="mx-auto max-w-3xl rounded-3xl border border-[#465332] bg-[#141814] p-6 sm:p-10">
      <p className="text-sm font-semibold tracking-widest text-[#d7c895]">WERSJA TESTOWA</p>
      <h1 className="mt-4 text-3xl font-bold">{name} — {unavailable ? "chwilowo niedostępna" : "Dostępna wkrótce"}</h1>
      <p className="mt-5 leading-7 text-[#aeb4a8]">{unavailable
        ? "Nie udało się sprawdzić dostępności obiektu. Spróbuj ponownie później."
        : "Trwają ostatnie przygotowania do uruchomienia rezerwacji."}</p>
      <div className="mt-6"><PublicAuthControls customDomain={customDomain} /></div>
      <Link href={customDomain ? "https://strzelajtu.pl/" : "/"} className="mt-6 inline-block underline">Wróć do katalogu</Link>
    </section>
  </main>;
}
