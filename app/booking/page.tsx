import { supabase } from "../../lib/supabase";
import BookingForm from "./BookingForm";

export default async function BookingPage() {
  const { data: lanes, error } = await supabase
    .from("shooting_lanes")
    .select("id, name, price_per_hour")
    .eq("is_active", true)
    .order("name");

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-4xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-3 text-3xl font-bold">Zarezerwuj oś</h1>

        <p className="mb-8 text-zinc-400">
          Wybierz datę, oś strzelecką, godzinę oraz czas rezerwacji. Płatność
          odbywa się na miejscu.
        </p>

        {error && (
          <div className="mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-red-300">
            Błąd połączenia z bazą: {error.message}
          </div>
        )}

        <BookingForm lanes={lanes ?? []} />

        <a
          href="/"
          className="mt-6 inline-block text-sm text-zinc-400 hover:text-white"
        >
          ← Wróć na stronę główną
        </a>
      </section>
    </main>
  );
}