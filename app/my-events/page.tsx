"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type EventRegistration = {
  id: string;
  registration_status: string;
  payment_status: string;
  created_at: string;
  events: {
    title: string;
    description: string;
    event_date: string;
    start_time: string;
    end_time: string;
    location: string;
    price: number;
  } | null;
};

function translateStatus(status: string) {
  if (status === "registered") return "Zapisany";
  if (status === "approved") return "Zatwierdzony";
  if (status === "reserve") return "Rezerwowy";
  if (status === "cancelled") return "Anulowany";
  return status;
}

function translatePayment(status: string) {
  if (status === "pay_on_site") return "Płatność na miejscu";
  if (status === "paid_on_site") return "Opłacone";
  return status;
}

function getStatusClass(status: string) {
  if (status === "approved") {
    return "rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400";
  }

  if (status === "registered") {
    return "rounded-full bg-blue-950 px-3 py-1 text-xs font-semibold text-blue-300";
  }

  if (status === "reserve") {
    return "rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300";
  }

  if (status === "cancelled") {
    return "rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300";
  }

  return "rounded-full bg-zinc-950 px-3 py-1 text-xs font-semibold text-zinc-300";
}

export default function MyEventsPage() {
  const [items, setItems] = useState<EventRegistration[]>([]);
  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    async function loadMyEvents() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setIsLoggedIn(false);
        setLoading(false);
        return;
      }

      setIsLoggedIn(true);

      const { data, error } = await supabase
        .from("event_registrations")
        .select(
          `
          id,
          registration_status,
          payment_status,
          created_at,
          events (
            title,
            description,
            event_date,
            start_time,
            end_time,
            location,
            price
          )
        `
        )
        .eq("user_id", user.id)
        .order("created_at", { ascending: false });

      if (error) {
        setMessage(`Błąd pobierania szkoleń: ${error.message}`);
        setLoading(false);
        return;
      }

      setItems((data as any) ?? []);
      setLoading(false);
    }

    loadMyEvents();
  }, []);

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-5xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-3 text-3xl font-bold">Moje szkolenia</h1>

        <p className="mb-8 text-zinc-400">
          Tutaj widzisz szkolenia i eventy, na które jesteś zapisany.
        </p>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie szkoleń...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="rounded-2xl border border-red-800 bg-red-950 p-8 text-center">
            <h2 className="mb-3 text-2xl font-bold text-red-200">
              Logowanie wymagane
            </h2>

            <p className="mx-auto mb-6 max-w-xl text-red-100">
              Aby zobaczyć swoje szkolenia, musisz najpierw zalogować się na
              konto użytkownika.
            </p>

            <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="rounded-xl border border-red-300 px-5 py-3 font-semibold text-red-100 transition hover:bg-red-900"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        )}

        {!loading && isLoggedIn && message && (
          <div className="mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300">
            {message}
          </div>
        )}

        {!loading && isLoggedIn && !message && items.length === 0 && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Nie jesteś jeszcze zapisany na żadne szkolenie.
          </div>
        )}

        {!loading && isLoggedIn && items.length > 0 && (
          <div className="space-y-4">
            {items.map((item) => (
              <div
                key={item.id}
                className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
              >
                <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
                  <div>
                    <span className={getStatusClass(item.registration_status)}>
                      {translateStatus(item.registration_status)}
                    </span>

                    <h2 className="mt-4 text-2xl font-bold">
                      {item.events?.title ?? "Brak danych szkolenia"}
                    </h2>

                    <p className="mt-2 text-zinc-400">
                      {item.events?.description}
                    </p>

                    <div className="mt-5 grid gap-3 text-sm text-zinc-400 md:grid-cols-2">
                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-1 text-zinc-500">Data</p>
                        <p className="font-semibold text-white">
                          {item.events?.event_date}
                        </p>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-1 text-zinc-500">Godzina</p>
                        <p className="font-semibold text-white">
                          {item.events?.start_time?.slice(0, 5)} -{" "}
                          {item.events?.end_time?.slice(0, 5)}
                        </p>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-1 text-zinc-500">Miejsce</p>
                        <p className="font-semibold text-white">
                          {item.events?.location}
                        </p>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-1 text-zinc-500">Cena / płatność</p>
                        <p className="font-semibold text-green-500">
                          {Number(item.events?.price ?? 0).toFixed(0)} zł —{" "}
                          {translatePayment(item.payment_status)}
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/dashboard"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel klienta
          </a>

          <a
            href="/events"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Zobacz szkolenia
          </a>
        </div>
      </section>
    </main>
  );
}