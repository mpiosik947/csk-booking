"use client";

import { useEffect, useState } from "react";
import { getPaymentStatusLabel } from "../../lib/payment-status";
import {
  RESERVATION_STATUS,
  getReservationStatusBadgeClass,
  getReservationStatusLabel,
} from "../../lib/reservation-status";
import { supabase } from "../../lib/supabase";

type Reservation = {
  id: string;
  reservation_date: string;
  start_time: string;
  end_time: string;
  price: number;
  reservation_status: string;
  payment_status: string;
  check_in_token: string | null;
  attendance_status?: string | null;
  checked_in_at?: string | null;
  shooting_lanes: {
    name: string;
  } | null;
};
function translateAttendanceStatus(status?: string | null) {
  if (status === "present") return "Obecny";
  if (status === "completed") return "Zakończona";
  if (status === "no_show") return "Nieobecny";
  return "Niepotwierdzony";
}
function getAttendanceClass(status?: string | null) {
  if (status === "present") {
    return "rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-300";
  }

  if (status === "completed") {
    return "rounded-full bg-blue-950 px-3 py-1 text-xs font-semibold text-blue-300";
  }

  if (status === "no_show") {
    return "rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300";
  }

  return "rounded-full bg-zinc-950 px-3 py-1 text-xs font-semibold text-zinc-300";
}

function getMessageClass(message: string) {
  if (message.includes("anulowana")) {
    return "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
  }

  return "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
}

function canCancelReservation(reservationDate: string, startTime: string) {
  const reservationDateTime = new Date(`${reservationDate}T${startTime}`);
  const now = new Date();

  const differenceInMilliseconds =
    reservationDateTime.getTime() - now.getTime();

  const differenceInHours = differenceInMilliseconds / (1000 * 60 * 60);

  return differenceInHours > 12;
}

function getCheckInUrl(token: string) {
  if (typeof window === "undefined") {
    return "";
  }

 const siteUrl =
  "https://csk-booking-5nwh-git-main-mpiosik94-9167s-projects.vercel.app";

return `${siteUrl}/admin/check-in?token=${token}`;
}

export default function MyReservationsPage() {
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [userId, setUserId] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    async function loadReservations() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setIsLoggedIn(false);
        setLoading(false);
        return;
      }

      setIsLoggedIn(true);
      setUserId(user.id);

      const { data, error } = await supabase
        .from("reservations")
        .select(
          `
          id,
          reservation_date,
          start_time,
          end_time,
          price,
          reservation_status,
          payment_status,
          check_in_token,
          attendance_status,
          checked_in_at,
          shooting_lanes (
            name
          )
        `
        )
        .eq("user_id", user.id)
        .order("reservation_date", { ascending: false })
        .order("start_time", { ascending: false });

      if (error) {
        setMessage(`Błąd pobierania rezerwacji: ${error.message}`);
        setLoading(false);
        return;
      }

      setReservations((data as any) ?? []);
      setLoading(false);
    }

    loadReservations();
  }, []);

  async function cancelReservation(reservation: Reservation) {
    setMessage("");

    const allowedToCancel = canCancelReservation(
      reservation.reservation_date,
      reservation.start_time
    );

    if (!allowedToCancel) {
      setMessage(
        "Nie można anulować rezerwacji później niż 12 godzin przed terminem. Skontaktuj się z obsługą strzelnicy."
      );
      return;
    }

    const confirmed = window.confirm(
      "Czy na pewno chcesz anulować tę rezerwację?"
    );

    if (!confirmed) {
      return;
    }

    const { error } = await supabase
      .from("reservations")
      .update({
        reservation_status: RESERVATION_STATUS.CANCELLED,
      })
      .eq("id", reservation.id)
      .eq("user_id", userId);

    if (error) {
      setMessage(`Błąd anulowania rezerwacji: ${error.message}`);
      return;
    }

    setReservations((currentReservations) =>
      currentReservations.map((item) =>
        item.id === reservation.id
          ? { ...item, reservation_status: RESERVATION_STATUS.CANCELLED }
          : item
      )
    );

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (user?.email) {
      await fetch("/api/send-reservation-cancellation", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          customerEmail: user.email,
          customerName: String(user.user_metadata?.full_name ?? user.email),
          reservationDate: reservation.reservation_date,
          startTime: reservation.start_time,
          endTime: reservation.end_time,
          laneName: reservation.shooting_lanes?.name ?? "Brak osi",
          cancelledBy: "user",
        }),
      }).catch(() => null);
    }

    setMessage("Rezerwacja została anulowana.");
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-5xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-3 text-3xl font-bold">Moje rezerwacje</h1>

        <p className="mb-8 text-zinc-400">
          Tutaj widzisz rezerwacje przypisane do Twojego konta. Rezerwację
          możesz anulować samodzielnie najpóźniej 12 godzin przed terminem.
        </p>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie rezerwacji...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="rounded-2xl border border-red-800 bg-red-950 p-8 text-center">
            <h2 className="mb-3 text-2xl font-bold text-red-200">
              Logowanie wymagane
            </h2>

            <p className="mx-auto mb-6 max-w-xl text-red-100">
              Aby zobaczyć swoje rezerwacje, musisz najpierw zalogować się na
              konto użytkownika albo utworzyć nowe konto.
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
          <div className={getMessageClass(message)}>{message}</div>
        )}

        {!loading && isLoggedIn && reservations.length === 0 && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Nie masz jeszcze żadnych rezerwacji.
          </div>
        )}

        {!loading && isLoggedIn && reservations.length > 0 && (
          <div className="space-y-4">
            {reservations.map((reservation) => {
              const allowedToCancel = canCancelReservation(
                reservation.reservation_date,
                reservation.start_time
              );

              const isActiveReservation =
                reservation.reservation_status === RESERVATION_STATUS.CONFIRMED;

              const checkInUrl = reservation.check_in_token
                ? getCheckInUrl(reservation.check_in_token)
                : "";

              const qrUrl = checkInUrl
                ? `https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=${encodeURIComponent(
                    checkInUrl
                  )}`
                : "";

              return (
                <div
                  key={reservation.id}
                  className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
                >
                  <div className="grid gap-6 md:grid-cols-[1fr_220px] md:items-start">
                    <div>
                      <span className="mb-3 inline-block rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400">
                        {reservation.shooting_lanes?.name ?? "Brak osi"}
                      </span>

                      <h2 className="text-xl font-semibold">
                        {reservation.reservation_date} |{" "}
                        {reservation.start_time.slice(0, 5)}–
                        {reservation.end_time.slice(0, 5)}
                      </h2>

                      <p className="mt-2 text-sm text-zinc-400">
                        Cena:{" "}
                        <span className="font-semibold text-green-500">
                          {Number(reservation.price).toFixed(0)} zł
                        </span>
                      </p>

                      <p className="mt-1 text-sm text-zinc-400">
                        Płatność:{" "}
                        <span className="font-semibold text-green-500">
                          {getPaymentStatusLabel(reservation.payment_status)}
                        </span>
                      </p>

                      <div className="mt-4 flex flex-wrap gap-2">
                        <span
                        className={`rounded-full border px-3 py-1 text-xs font-semibold ${getReservationStatusBadgeClass(
  reservation.reservation_status
)}`}
                        >
                         {getReservationStatusLabel(
  reservation.reservation_status
)}
                        </span>

                        <span
                          className={getAttendanceClass(
                            reservation.attendance_status
                          )}
                        >
                          {translateAttendanceStatus(
                            reservation.attendance_status
                          )}
                        </span>
                      </div>

                      {reservation.reservation_status === RESERVATION_STATUS.CONFIRMED &&
                        !allowedToCancel && (
                          <p className="mt-3 text-sm text-yellow-300">
                            Samodzielne anulowanie nie jest już możliwe —
                            zostało mniej niż 12 godzin do terminu.
                          </p>
                        )}

                      {reservation.checked_in_at && (
                        <p className="mt-3 text-xs text-zinc-500">
                          Check-in:{" "}
                          {new Date(reservation.checked_in_at).toLocaleString(
                            "pl-PL"
                          )}
                        </p>
                      )}

                      <div className="mt-5 flex flex-wrap gap-3">
                        {reservation.reservation_status === RESERVATION_STATUS.CONFIRMED &&
                          allowedToCancel && (
                            <button
                              type="button"
                              onClick={() => cancelReservation(reservation)}
                              className="rounded-xl border border-red-800 px-4 py-2 text-sm font-semibold text-red-400 transition hover:bg-red-950"
                            >
                              Anuluj rezerwację
                            </button>
                          )}

                        <a
                          href="/booking"
                          className="rounded-xl border border-zinc-700 px-4 py-2 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-950"
                        >
                          Nowa rezerwacja
                        </a>
                      </div>
                    </div>

                    <div className="rounded-2xl border border-zinc-800 bg-zinc-950 p-4 text-center">
                      {isActiveReservation && qrUrl ? (
                        <>
                          <p className="mb-3 text-xs font-semibold uppercase tracking-[0.2em] text-cyan-300">
                            QR Check-in
                          </p>

                          <img
                            src={qrUrl}
                            alt="Kod QR check-in"
                            className="mx-auto rounded-xl bg-white p-2"
                          />

                          <p className="mt-3 text-xs text-zinc-500">
                            Pokaż ten kod pracownikowi strzelnicy przy wejściu.
                          </p>

                          <a
                            href={checkInUrl}
                            className="mt-3 inline-block text-xs text-cyan-300 hover:text-cyan-200"
                          >
                            Otwórz link check-in
                          </a>
                        </>
                      ) : (
                        <div className="text-sm text-zinc-500">
                          QR dostępny tylko dla aktywnych rezerwacji.
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        <div className="mt-8 flex gap-4 text-sm text-zinc-400">
          <a href="/booking" className="hover:text-white">
            + Nowa rezerwacja
          </a>

          <a href="/dashboard" className="hover:text-white">
            ← Panel klienta
          </a>
        </div>
      </section>
    </main>
  );
}

