"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { supabase } from "../../../lib/supabase";

function CheckInContent() {
  const params = useSearchParams();
  const token = params.get("token");

  const [reservation, setReservation] = useState<any>(null);
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    async function load() {
      if (!token) return;

      const { data, error } = await supabase
        .from("reservations")
        .select(
          `
          *,
          shooting_lanes(name)
        `
        )
        .eq("check_in_token", token)
        .single();

      if (error) {
        setMessage("Nie znaleziono rezerwacji dla tego kodu QR.");
        return;
      }

      setReservation(data);
    }

    load();
  }, [token]);

  async function confirm() {
    if (!reservation) return;

    setLoading(true);
    setMessage("");

    const now = new Date().toISOString();

    const { error } = await supabase
      .from("reservations")
      .update({
        attendance_status: "present",
        reservation_status: "confirmed",
        checked_in_at: now,
      })
      .eq("id", reservation.id);

    setLoading(false);

    if (error) {
      setMessage(`Błąd check-in: ${error.message}`);
      return;
    }

    setReservation({
      ...reservation,
      attendance_status: "present",
      checked_in_at: now,
    });

    setMessage("Klient oznaczony jako obecny.");
  }

  return (
    <div className="mx-auto max-w-xl">
      <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
        CSK Booking
      </p>

      <h1 className="mb-6 text-3xl font-bold">Check-in QR</h1>

      {!token && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
          Zeskanuj kod QR klienta albo otwórz link z tokenem check-in.
        </div>
      )}

      {reservation && (
        <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
          <h2 className="text-2xl font-bold">{reservation.customer_name}</h2>

          <div className="mt-4 grid gap-3 rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm">
            <p>
              <span className="text-zinc-500">Oś: </span>
              <span className="font-semibold">
                {reservation.shooting_lanes?.name ?? "Brak osi"}
              </span>
            </p>

            <p>
              <span className="text-zinc-500">Data: </span>
              <span className="font-semibold">
                {reservation.reservation_date}
              </span>
            </p>

            <p>
              <span className="text-zinc-500">Godzina: </span>
              <span className="font-semibold">
                {reservation.start_time?.slice(0, 5)}–
                {reservation.end_time?.slice(0, 5)}
              </span>
            </p>

            <p>
              <span className="text-zinc-500">Status obecności: </span>
              <span className="font-semibold">
                {reservation.attendance_status === "present"
                  ? "Obecny"
                  : "Niepotwierdzony"}
              </span>
            </p>
          </div>

          <button
            type="button"
            onClick={confirm}
            disabled={loading || reservation.attendance_status === "present"}
            className="mt-6 rounded-xl bg-green-700 px-5 py-3 font-bold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {loading
              ? "Zapisywanie..."
              : reservation.attendance_status === "present"
                ? "Klient już oznaczony jako obecny"
                : "Potwierdź obecność"}
          </button>
        </div>
      )}

      {message && (
        <div className="mt-4 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300">
          {message}
        </div>
      )}

      <a
        href="/admin"
        className="mt-6 inline-block rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
      >
        ← Panel admina
      </a>
    </div>
  );
}

export default function CheckInPage() {
  return (
    <main className="min-h-screen bg-zinc-950 p-8 text-white">
      <Suspense
        fallback={
          <div className="mx-auto max-w-xl rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie check-in...
          </div>
        }
      >
        <CheckInContent />
      </Suspense>
    </main>
  );
}