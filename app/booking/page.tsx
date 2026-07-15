"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { RESERVATION_STATUS } from "../../lib/reservation-status";
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
            .in("reservation_status", [RESERVATION_STATUS.CONFIRMED]);

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
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto max-w-5xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/20 sm:p-8">
        <header>
          <p className="mb-3 text-xs font-semibold uppercase tracking-[0.22em] text-[#d7c895]">
            CSK BOOKING
          </p>

          <h1 className="text-3xl font-bold sm:text-4xl">Zarezerwuj oś</h1>

          <p className="mt-3 max-w-3xl leading-7 text-[#a9ada4]">
            Wybierz datę, oś strzelecką, godzinę oraz czas rezerwacji. Płatność
            odbywa się na miejscu.
          </p>
        </header>

        <div className="mt-6 rounded-2xl border border-[#30372c] bg-[#191e19] px-4 py-3 text-sm leading-6 text-[#a9ada4] sm:px-5">
          Wybierz oś → datę → godzinę → potwierdź rezerwację
        </div>

        {loading && (
          <div
            role="status"
            aria-live="polite"
            className="mt-6 rounded-xl border border-[#30372c] bg-[#191e19] p-4 text-[#a9ada4]"
          >
            Ładowanie dostępnych osi...
          </div>
        )}

        {message && (
          <div
            role="alert"
            className="mt-6 rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-[#e0a0a0]"
          >
            {message}
          </div>
        )}

        {!loading && blockingMessage && (
          <div
            role="status"
            className="mt-6 rounded-xl border border-[#806a32] bg-[#2b2618] p-5 text-[#e1c477]"
          >
            <p className="mb-2 font-bold text-[#e1c477]">
              Konto oczekuje na weryfikację
            </p>

            <p className="text-sm">{blockingMessage}</p>

            <p className="mt-3 text-sm text-[#cbb873]">
              Przyjedź na umówioną rezerwację. Pracownik recepcji sprawdzi dane,
              zweryfikuje konto i po tej weryfikacji będziesz mógł wykonywać
              kolejne rezerwacje.
            </p>
          </div>
        )}

        {!loading && lanes.length === 0 && !message && (
          <div
            role="status"
            className="mt-6 rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-[#e1c477]"
          >
            Brak aktywnych osi do rezerwacji.
          </div>
        )}

        {!loading && canBook && (
          <section aria-label="Formularz rezerwacji" className="mt-8 w-full">
            <BookingForm lanes={lanes} />
          </section>
        )}

        <nav
          aria-label="Nawigacja strony rezerwacji"
          className="mt-8 border-t border-[#30372c] pt-6"
        >
          <a
            href="/"
            className="inline-flex min-h-11 items-center rounded-xl border border-[#30372c] px-5 py-3 text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Wróć na stronę główną
          </a>
        </nav>
      </section>
    </main>
  );
}
