"use client";

import { Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { supabase } from "../../../lib/supabase";

type Reservation = {
  id: string;
  check_in_token: string | null;
  user_id: string | null;
  customer_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  reservation_date: string | null;
  start_time: string | null;
  end_time: string | null;
  reservation_status: string | null;
  attendance_status: string | null;
  payment_status: string | null;
  checked_in_at: string | null;
  price: number | null;
  shooting_lanes?: {
    name: string | null;
  }[] | null;
};

function todayISODate() {
  return new Date().toISOString().slice(0, 10);
}

function normalizeTime(time: string | null) {
  if (!time) return "";
  return time.slice(0, 5);
}

function getLaneName(reservation: Reservation) {
  return reservation.shooting_lanes?.[0]?.name || "Nieznana oś";
}

function getReservationStatusLabel(status: string | null) {
  switch (status) {
    case "confirmed":
      return "Potwierdzona";
    case "completed":
      return "Zakończona";
    case "no_show":
      return "No-show";
    case "cancelled_by_admin":
    case "cancelled_by_user":
    case "cancelled":
    case "canceled":
      return "Anulowana";
    default:
      return status || "Brak statusu";
  }
}

function getPaymentStatusLabel(status: string | null) {
  switch (status) {
    case "pay_on_site":
      return "Płatność na miejscu";
    case "paid":
      return "Opłacona";
    case "unpaid":
      return "Nieopłacona";
    case "free":
      return "Darmowa";
    case "voucher":
      return "Voucher";
    default:
      return status || "Brak statusu";
  }
}

function getStatusClass(status: string | null) {
  switch (status) {
    case "completed":
      return "border-blue-700 bg-blue-950 text-blue-300";
    case "confirmed":
      return "border-green-700 bg-green-950 text-green-300";
    case "no_show":
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case "cancelled_by_admin":
    case "cancelled_by_user":
    case "cancelled":
    case "canceled":
      return "border-red-700 bg-red-950 text-red-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }
}

function getPaymentClass(status: string | null) {
  switch (status) {
    case "paid":
      return "border-green-700 bg-green-950 text-green-300";
    case "pay_on_site":
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case "unpaid":
      return "border-red-700 bg-red-950 text-red-300";
    case "free":
      return "border-blue-700 bg-blue-950 text-blue-300";
    case "voucher":
      return "border-purple-700 bg-purple-950 text-purple-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }
}

function CheckInContent() {
  const params = useSearchParams();
  const token = params.get("token");

  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [selectedReservation, setSelectedReservation] =
    useState<Reservation | null>(null);

  const [dateFilter, setDateFilter] = useState(todayISODate());
  const [search, setSearch] = useState("");

  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const [savingId, setSavingId] = useState<string | null>(null);

  async function loadReservations() {
    setLoading(true);
    setMessage("");

    let query = supabase
      .from("reservations")
      .select(
        `
        id,
        check_in_token,
        user_id,
        customer_name,
        customer_email,
        customer_phone,
        reservation_date,
        start_time,
        end_time,
        reservation_status,
        attendance_status,
        payment_status,
        checked_in_at,
        price,
        shooting_lanes (
          name
        )
      `
      )
      .order("start_time", { ascending: true });

    if (dateFilter) {
      query = query.eq("reservation_date", dateFilter);
    }

    const { data, error } = await query;

    setLoading(false);

    if (error) {
      setMessage(`Błąd pobierania rezerwacji: ${error.message}`);
      return;
    }

    setReservations((data ?? []) as unknown as Reservation[]);
  }

  async function loadReservationByToken(checkInToken: string) {
    setLoading(true);
    setMessage("");

    const { data, error } = await supabase
      .from("reservations")
      .select(
        `
        id,
        check_in_token,
        user_id,
        customer_name,
        customer_email,
        customer_phone,
        reservation_date,
        start_time,
        end_time,
        reservation_status,
        attendance_status,
        payment_status,
        checked_in_at,
        price,
        shooting_lanes (
          name
        )
      `
      )
      .eq("check_in_token", checkInToken)
      .single();

    setLoading(false);

    if (error) {
      setMessage("Nie znaleziono rezerwacji dla tego kodu QR.");
      return;
    }

    setSelectedReservation(data as unknown as Reservation);
  }

  useEffect(() => {
    if (token) {
      loadReservationByToken(token);
      return;
    }

    loadReservations();
  }, [token, dateFilter]);

  const filteredReservations = useMemo(() => {
    const phrase = search.trim().toLowerCase();

    if (!phrase) {
      return reservations;
    }

    return reservations.filter((reservation) => {
      const name = reservation.customer_name?.toLowerCase() ?? "";
      const email = reservation.customer_email?.toLowerCase() ?? "";
      const phone = reservation.customer_phone?.toLowerCase() ?? "";
      const lane = getLaneName(reservation).toLowerCase();
      const status = reservation.reservation_status?.toLowerCase() ?? "";
      const payment = reservation.payment_status?.toLowerCase() ?? "";

      return (
        name.includes(phrase) ||
        email.includes(phrase) ||
        phone.includes(phrase) ||
        lane.includes(phrase) ||
        status.includes(phrase) ||
        payment.includes(phrase)
      );
    });
  }, [reservations, search]);

  async function updateReservation(
    reservation: Reservation,
    changes: Partial<
      Pick<
        Reservation,
        | "reservation_status"
        | "attendance_status"
        | "payment_status"
        | "checked_in_at"
      >
    >
  ) {
    setSavingId(reservation.id);
    setMessage("");

    const { error } = await supabase
      .from("reservations")
      .update(changes)
      .eq("id", reservation.id);

    setSavingId(null);

    if (error) {
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id ? { ...item, ...changes } : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation({
        ...selectedReservation,
        ...changes,
      });
    }

    setMessage("Zapisano zmianę.");
  }

  async function markCompleted(reservation: Reservation) {
    const now = new Date().toISOString();

    await updateReservation(reservation, {
      attendance_status: "present",
      reservation_status: "completed",
      checked_in_at: now,
    });
  }

  async function markNoShow(reservation: Reservation) {
    await updateReservation(reservation, {
      attendance_status: "no_show",
      reservation_status: "no_show",
    });
  }

  async function cancelByAdmin(reservation: Reservation) {
    await updateReservation(reservation, {
      reservation_status: "cancelled_by_admin",
    });
  }

  const mainList = token && selectedReservation
    ? [selectedReservation]
    : filteredReservations;

  return (
    <div className="mx-auto max-w-7xl">
      <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            CSK Booking
          </p>

          <h1 className="text-4xl font-bold">
            Check-in i obsługa wizyt
          </h1>

          <p className="mt-3 max-w-2xl text-zinc-400">
            Obsługa dzisiejszych rezerwacji, obecności, no-show, płatności i
            zakończonych wizyt.
          </p>
        </div>

        <a
          href="/admin"
          className="rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
        >
          ← Panel admina
        </a>
      </div>

      {!token && (
        <div className="mb-6 grid gap-4 rounded-2xl border border-zinc-800 bg-zinc-900 p-5 md:grid-cols-[auto_1fr_auto] md:items-end">
          <div>
            <label className="mb-2 block text-sm font-semibold text-zinc-300">
              Data wizyt
            </label>

            <input
              type="date"
              value={dateFilter}
              onChange={(event) => setDateFilter(event.target.value)}
              className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />
          </div>

          <div>
            <label className="mb-2 block text-sm font-semibold text-zinc-300">
              Szukaj
            </label>

            <input
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Imię, e-mail, telefon, oś, status..."
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />
          </div>

          <button
            type="button"
            onClick={loadReservations}
            disabled={loading}
            className="rounded-xl bg-green-700 px-5 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {loading ? "Odświeżanie..." : "Odśwież"}
          </button>
        </div>
      )}

      {message && (
        <div className="mb-6 rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200">
          {message}
        </div>
      )}

      {loading ? (
        <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-zinc-400">
          Ładowanie check-in...
        </div>
      ) : mainList.length === 0 ? (
        <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-zinc-400">
          Brak rezerwacji do obsługi dla wybranego dnia.
        </div>
      ) : (
        <div className="grid gap-4">
          {mainList.map((reservation) => {
            const isSaving = savingId === reservation.id;

            return (
              <article
                key={reservation.id}
                className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5"
              >
                <div className="grid gap-5 xl:grid-cols-[1.1fr_0.8fr_0.9fr_1fr_auto] xl:items-start">
                  <div>
                    <div className="mb-3 flex flex-wrap gap-2">
                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getStatusClass(
                          reservation.reservation_status
                        )}`}
                      >
                        {getReservationStatusLabel(
                          reservation.reservation_status
                        )}
                      </span>

                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getPaymentClass(
                          reservation.payment_status
                        )}`}
                      >
                        {getPaymentStatusLabel(reservation.payment_status)}
                      </span>
                    </div>

                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Klient
                    </p>

                    <h2 className="mt-2 text-xl font-bold">
                      {reservation.customer_name || "Brak danych"}
                    </h2>

                    <p className="mt-1 text-sm text-zinc-400">
                      {reservation.customer_email || "Brak e-maila"}
                    </p>

                    <p className="mt-1 text-sm text-zinc-500">
                      Tel.: {reservation.customer_phone || "brak"}
                    </p>
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Termin
                    </p>

                    <p className="mt-2 text-lg font-bold">
                      {reservation.reservation_date || "Brak daty"}
                    </p>

                    <p className="mt-1 text-sm text-zinc-400">
                      {normalizeTime(reservation.start_time)}–
                      {normalizeTime(reservation.end_time)}
                    </p>
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Oś
                    </p>

                    <p className="mt-2 text-lg font-bold">
                      {getLaneName(reservation)}
                    </p>

                    <p className="mt-1 text-sm text-green-400">
                      {Number(reservation.price ?? 0).toFixed(0)} zł
                    </p>

                    <p className="mt-4 text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Check-in
                    </p>

                    <p className="mt-1 text-sm text-zinc-300">
                      {reservation.checked_in_at
                        ? new Date(reservation.checked_in_at).toLocaleString(
                            "pl-PL"
                          )
                        : "brak"}
                    </p>
                  </div>

                  <div className="grid gap-3">
                    <div>
                      <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                        Płatność
                      </label>

                      <select
                        value={reservation.payment_status || "pay_on_site"}
                        disabled={isSaving}
                        onChange={(event) =>
                          updateReservation(reservation, {
                            payment_status: event.target.value,
                          })
                        }
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-sm text-white outline-none focus:border-green-600 disabled:opacity-60"
                      >
                        <option value="pay_on_site">Płatność na miejscu</option>
                        <option value="paid">Opłacona</option>
                        <option value="unpaid">Nieopłacona</option>
                        <option value="free">Darmowa</option>
                        <option value="voucher">Voucher</option>
                      </select>
                    </div>

                    <div>
                      <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                        Status wizyty
                      </label>

                      <select
                        value={reservation.reservation_status || "confirmed"}
                        disabled={isSaving}
                        onChange={(event) =>
                          updateReservation(reservation, {
                            reservation_status: event.target.value,
                          })
                        }
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-sm text-white outline-none focus:border-green-600 disabled:opacity-60"
                      >
                        <option value="confirmed">Potwierdzona</option>
                        <option value="completed">Zakończona</option>
                        <option value="no_show">No-show</option>
                        <option value="cancelled_by_admin">
                          Anulowana przez admina
                        </option>
                      </select>
                    </div>
                  </div>

                  <div className="grid gap-2">
                    <button
                      type="button"
                      disabled={isSaving}
                      onClick={() => markCompleted(reservation)}
                      className="rounded-xl border border-green-700 px-4 py-3 text-sm font-bold text-green-300 transition hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      Klient był / zakończ
                    </button>

                    <button
                      type="button"
                      disabled={isSaving}
                      onClick={() => markNoShow(reservation)}
                      className="rounded-xl border border-yellow-700 px-4 py-3 text-sm font-bold text-yellow-300 transition hover:bg-yellow-950 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      No-show
                    </button>

                    <button
                      type="button"
                      disabled={isSaving}
                      onClick={() => cancelByAdmin(reservation)}
                      className="rounded-xl border border-red-700 px-4 py-3 text-sm font-bold text-red-300 transition hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      Anuluj
                    </button>

                    {isSaving && (
                      <p className="text-xs font-semibold text-yellow-400">
                        Zapisywanie...
                      </p>
                    )}
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      )}
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