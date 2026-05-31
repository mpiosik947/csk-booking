"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import BookingForm from "./BookingForm";

type Lane = {
  id: string;
  name: string;
  price_per_hour: number;
};

type Profile = {
  verification_status: string | null;
};

export default function BookingPage() {
  const [lanes, setLanes] = useState<Lane[]>([]);
  const [loading, setLoading] = useState(true);
  const [message, setMessage] = useState("");
  const [canBook, setCanBook] = useState(true);
  const [blockingMessage, setBlockingMessage] = useState("");

  useEffect(() => {
    async function loadPageData() {
      setLoading(true);
      setMessage("");
      setCanBook(true);
      setBlockingMessage("");

      const {
        data: { user },
      } = await supabase.auth.getUser();

      const { data: lanesData, error: lanesError } = await supabase
        .from("shooting_lanes")
        .select("id, name, price_per_hour")
        .eq("is_active", true)
        .order("name");

      if (lanesError) {
        setMessage(`Błąd pobierania osi: ${lanesError.message}`);
        setLoading(false);
        return;
      }

      setLanes((lanesData ?? []) as Lane[]);

      if (!user) {
        setLoading(false);
        return;
      }

      const { data: profileData, error: profileError } = await supabase
        .from("profiles")
        .select("verification_status")
        .eq("user_id", user.id)
        .maybeSingle();

      if (profileError) {
        setMessage(`Błąd pobierania profilu: ${profileError.message}`);
        setLoading(false);
        return;
      }

      const profile = profileData as Profile | null;
      const isVerified = profile?.verification_status === "verified";

      if (!isVerified) {
        const { data: activeReservations, error: reservationsError } =
          await supabase
            .from("reservations")
            .select("id")
            .eq("user_id", user.id)
            .in("reservation_status", ["confirmed"]);

        if (reservationsError) {
          setMessage(
            `Błąd sprawdzania aktywnych rezerwacji: ${reservationsError.message}`
          );
          setLoading(false);
          return;
        }

        if ((activeReservations ?? []).length >= 1) {
          setCanBook(false);
          setBlockingMessage(
            "Twoje konto oczekuje na weryfikację. Do czasu pierwszej wizyty i potwierdzenia danych przez pracownika możesz mieć tylko jedną aktywną rezerwację."
          );
        }
      }

      setLoading(false);
    }

    loadPageData();
  }, []);

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

        {loading && (
          <div className="mb-6 rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-zinc-400">
            Ładowanie dostępnych osi...
          </div>
        )}

        {message && (
          <div className="mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-red-300">
            {message}
          </div>
        )}

        {!loading && blockingMessage && (
          <div className="mb-6 rounded-xl border border-yellow-800 bg-yellow-950 p-5 text-yellow-100">
            <p className="mb-2 font-bold text-yellow-300">
              Konto oczekuje na weryfikację
            </p>

            <p className="text-sm">{blockingMessage}</p>

            <p className="mt-3 text-sm text-yellow-100/80">
              Przyjedź na umówioną rezerwację. Pracownik recepcji sprawdzi dane,
              zweryfikuje konto i po tej weryfikacji będziesz mógł wykonywać
              kolejne rezerwacje.
            </p>
          </div>
        )}

        {!loading && lanes.length === 0 && !message && (
          <div className="mb-6 rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-yellow-200">
            Brak aktywnych osi do rezerwacji.
          </div>
        )}

        {!loading && canBook && <BookingForm lanes={lanes} />}

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