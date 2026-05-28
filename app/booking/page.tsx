"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import BookingForm from "./BookingForm";

type Lane = {
  id: string;
  name: string;
  price_per_hour: number;
};

export default function BookingPage() {
  const [lanes, setLanes] = useState<Lane[]>([]);
  const [loading, setLoading] = useState(true);
  const [message, setMessage] = useState("");

  useEffect(() => {
    async function loadLanes() {
      setLoading(true);
      setMessage("");

      const { data, error } = await supabase
        .from("shooting_lanes")
        .select("id, name, price_per_hour")
        .eq("is_active", true)
        .order("name");

      setLoading(false);

      if (error) {
        setMessage(`Błąd pobierania osi: ${error.message}`);
        return;
      }

      setLanes((data ?? []) as Lane[]);
    }

    loadLanes();
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

        {!loading && lanes.length === 0 && !message && (
          <div className="mb-6 rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-yellow-200">
            Brak aktywnych osi do rezerwacji.
          </div>
        )}

        <BookingForm lanes={lanes} />

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