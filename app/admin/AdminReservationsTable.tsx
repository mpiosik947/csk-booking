"use client";

import { useState } from "react";
import {
  cancelReservation,
  completeReservation,
  markNoShow,
  markPaid,
  markPresent,
  markScheduled,
  updateReservationNote,
} from "../../lib/reservation-actions";
import {
  getPaymentStatusBadgeClass,
  getPaymentStatusLabel,
  PAYMENT_STATUS,
} from "../../lib/payment-status";
import {
  getReservationStatusBadgeClass,
  getReservationStatusLabel,
  RESERVATION_STATUS,
} from "../../lib/reservation-status";
import { supabase } from "../../lib/supabase";
import { getLaneRelationDisplay } from "../../lib/admin/lane-relation-display";

type Reservation = {
  id: string;
  customer_name: string;
  customer_email: string;
  customer_phone: string;
  reservation_date: string;
  start_time: string;
  end_time: string;
  duration_minutes: number;
  price: number;
  reservation_status: string;
  payment_status: string;
  attendance_status?: string | null;
  admin_note?: string | null;
  checked_in_at?: string | null;
  completed_at?: string | null;
  shooting_lanes: {
    id: string;
    name: string;
    resource_kind: string;
    parent_lane_id: string | null;
    display_order: number;
    is_active: boolean;
    parent_lane?: unknown;
  } | null;
};

function getLaneName(reservation: Reservation) {
  return (
    getLaneRelationDisplay(reservation.shooting_lanes)?.displayName ?? "Brak osi"
  );
}

type AdminReservationsTableProps = {
  reservations: Reservation[];
};

function translateAttendanceStatus(status?: string | null) {
  if (status === "present") return "Obecny";
  if (status === "no_show") return "Nieobecny";
  if (status === "completed") return "Zakończona";
  return "Zaplanowana";
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

  return "rounded-full bg-zinc-900 px-3 py-1 text-xs font-semibold text-zinc-300";
}

function formatDateHeader(dateString: string) {
  const date = new Date(`${dateString}T12:00:00`);

  const weekday = new Intl.DateTimeFormat("pl-PL", {
    weekday: "long",
  }).format(date);

  const dayMonth = new Intl.DateTimeFormat("pl-PL", {
    day: "2-digit",
    month: "2-digit",
  }).format(date);

  return `${weekday.charAt(0).toUpperCase()}${weekday.slice(1)} ${dayMonth}`;
}

function groupReservationsByDate(reservations: Reservation[]) {
  const groups: Record<string, Reservation[]> = {};

  for (const reservation of reservations) {
    if (!groups[reservation.reservation_date]) {
      groups[reservation.reservation_date] = [];
    }

    groups[reservation.reservation_date].push(reservation);
  }

  return Object.entries(groups)
    .sort(([dateA], [dateB]) => dateA.localeCompare(dateB))
    .map(([date, items]) => ({
      date,
      items: items.sort((a, b) => a.start_time.localeCompare(b.start_time)),
    }));
}

function getBadgeClass(baseClass: string) {
  return `rounded-full border px-3 py-1 text-xs font-semibold ${baseClass}`;
}

export default function AdminReservationsTable({
  reservations,
}: AdminReservationsTableProps) {
  const [items, setItems] = useState(reservations);
  const [message, setMessage] = useState("");
  const [savingId, setSavingId] = useState("");

  const groupedReservations = groupReservationsByDate(items);

  async function handleCancelReservation(id: string) {
    setMessage("");
    setSavingId(id);

    const result = await cancelReservation(supabase, { reservationId: id });

    setSavingId("");

    if (result.error) {
      setMessage(`Błąd anulowania rezerwacji: ${result.error}`);
      return;
    }

    setItems((currentItems) =>
      currentItems.map((item) =>
        item.id === id
          ? {
              ...item,
              reservation_status: RESERVATION_STATUS.CANCELLED,
            }
          : item
      )
    );

    setMessage("Rezerwacja została anulowana.");
  }

  async function updateAttendanceStatus(
    id: string,
    attendanceStatus: "planned" | "present" | "no_show" | "completed",
  ) {
    setMessage("");
    setSavingId(id);

    if (attendanceStatus === "present") {
      const result = await markPresent(supabase, { reservationId: id });

      setSavingId("");

      if (result.error) {
        setMessage(`Błąd zmiany obecności: ${result.error}`);
        return;
      }

      const checkedInAt = result.data?.checked_in_at ?? new Date().toISOString();

      setItems((currentItems) =>
        currentItems.map((item) =>
          item.id === id
            ? {
                ...item,
                attendance_status: "present",
                reservation_status: RESERVATION_STATUS.CONFIRMED,
                checked_in_at: checkedInAt,
                completed_at: null,
              }
            : item,
        ),
      );

      setMessage("Klient oznaczony jako obecny.");
      return;
    }

    if (attendanceStatus === "planned") {
      const result = await markScheduled(supabase, { reservationId: id });

      setSavingId("");

      if (result.error) {
        setMessage(`Błąd zmiany obecności: ${result.error}`);
        return;
      }

      setItems((currentItems) =>
        currentItems.map((item) =>
          item.id === id
            ? {
                ...item,
                attendance_status: "planned",
                reservation_status: RESERVATION_STATUS.CONFIRMED,
                checked_in_at: null,
                completed_at: null,
              }
            : item,
        ),
      );

      setMessage("Rezerwacja przywrócona jako zaplanowana.");
      return;
    }

    if (attendanceStatus === "no_show") {
      const result = await markNoShow(supabase, { reservationId: id });

      setSavingId("");

      if (result.error) {
        setMessage(`Błąd zmiany obecności: ${result.error}`);
        return;
      }

      setItems((currentItems) =>
        currentItems.map((item) =>
          item.id === id
            ? {
                ...item,
                attendance_status: "no_show",
                reservation_status: RESERVATION_STATUS.NO_SHOW,
              }
            : item,
        ),
      );

      setMessage("Klient oznaczony jako nieobecny.");
      return;
    }

    if (attendanceStatus === "completed") {
      const result = await completeReservation(supabase, { reservationId: id });

      setSavingId("");

      if (result.error) {
        setMessage(`Błąd zmiany obecności: ${result.error}`);
        return;
      }

      const checkedInAt = result.data?.checked_in_at ?? new Date().toISOString();
      const completedAt = new Date().toISOString();

      setItems((currentItems) =>
        currentItems.map((item) =>
          item.id === id
            ? {
                ...item,
                attendance_status: "completed",
                reservation_status: RESERVATION_STATUS.COMPLETED,
                checked_in_at: item.checked_in_at ?? checkedInAt,
                completed_at: completedAt,
              }
            : item,
        ),
      );

      setMessage("Rezerwacja oznaczona jako zakończona.");
    }
  }

  async function markAsPaid(id: string) {
    setMessage("");
    setSavingId(id);

    const result = await markPaid(supabase, { reservationId: id });

    setSavingId("");

    if (result.error) {
      setMessage(`Błąd zmiany płatności: ${result.error}`);
      return;
    }

    setItems((currentItems) =>
      currentItems.map((item) =>
        item.id === id
          ? { ...item, payment_status: PAYMENT_STATUS.PAID }
          : item,
      ),
    );

    setMessage("Rezerwacja oznaczona jako opłacona.");
  }

  function updateLocalNote(id: string, note: string) {
    setItems((currentItems) =>
      currentItems.map((item) =>
        item.id === id ? { ...item, admin_note: note } : item,
      ),
    );
  }

  async function saveAdminNote(id: string, note: string) {
    setMessage("");
    setSavingId(id);

    const result = await updateReservationNote(supabase, {
      reservationId: id,
      note,
    });

    setSavingId("");

    if (result.error) {
      setMessage(`Błąd zapisu notatki: ${result.error}`);
      return;
    }

    setMessage("Notatka została zapisana.");
  }

  if (items.length === 0) {
    return (
      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-6 text-zinc-400">
        Brak rezerwacji w bazie.
      </div>
    );
  }

  return (
    <div>
      {message && (
        <div className="mb-4 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300">
          {message}
        </div>
      )}

      <div className="space-y-8">
        {groupedReservations.map((group) => (
          <div
            key={group.date}
            className="rounded-2xl border border-zinc-800 bg-zinc-950 p-5"
          >
            <div className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <h3 className="text-2xl font-bold text-white">
                {formatDateHeader(group.date)}
              </h3>

              <span className="rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400">
                {group.items.length} rezerwacje
              </span>
            </div>

            <div className="overflow-x-auto">
              <table className="w-full min-w-[1300px] border-collapse text-left text-sm">
                <thead>
                  <tr className="border-b border-zinc-800 text-zinc-400">
                    <th className="py-3 pr-4">Godzina</th>
                    <th className="py-3 pr-4">Oś</th>
                    <th className="py-3 pr-4">Klient</th>
                    <th className="py-3 pr-4">Telefon</th>
                    <th className="py-3 pr-4">E-mail</th>
                    <th className="py-3 pr-4">Cena</th>
                    <th className="py-3 pr-4">Status</th>
                    <th className="py-3 pr-4">Obecność</th>
                    <th className="py-3 pr-4">Płatność</th>
                    <th className="py-3 pr-4">Notatka</th>
                    <th className="py-3 pr-4">Akcje</th>
                  </tr>
                </thead>

                <tbody>
                  {group.items.map((reservation) => (
                    <tr key={reservation.id} className="border-b border-zinc-800">
                      <td className="py-4 pr-4 font-semibold">
                        {reservation.start_time.slice(0, 5)}–
                        {reservation.end_time.slice(0, 5)}
                      </td>

                      <td className="py-4 pr-4">
                        {getLaneName(reservation)}
                      </td>

                      <td className="py-4 pr-4">
                        <p className="font-semibold">
                          {reservation.customer_name}
                        </p>
                      </td>

                      <td className="py-4 pr-4 text-zinc-300">
                        {reservation.customer_phone}
                      </td>

                      <td className="py-4 pr-4 text-zinc-400">
                        {reservation.customer_email}
                      </td>

                      <td className="py-4 pr-4 font-semibold text-green-400">
                        {reservation.price} zł
                      </td>

                      <td className="py-4 pr-4">
                        <span
                          className={getBadgeClass(
                            getReservationStatusBadgeClass(
                              reservation.reservation_status,
                            ),
                          )}
                        >
                          {getReservationStatusLabel(
                            reservation.reservation_status,
                          )}
                        </span>
                      </td>

                      <td className="py-4 pr-4">
                        <span
                          className={getAttendanceClass(
                            reservation.attendance_status,
                          )}
                        >
                          {translateAttendanceStatus(
                            reservation.attendance_status,
                          )}
                        </span>
                      </td>

                      <td className="py-4 pr-4">
                        <span
                          className={getBadgeClass(
                            getPaymentStatusBadgeClass(
                              reservation.payment_status,
                            ),
                          )}
                        >
                          {getPaymentStatusLabel(reservation.payment_status)}
                        </span>
                      </td>

                      <td className="py-4 pr-4">
                        <div className="grid min-w-[220px] gap-2">
                          <textarea
                            value={reservation.admin_note ?? ""}
                            onChange={(event) =>
                              updateLocalNote(
                                reservation.id,
                                event.target.value,
                              )
                            }
                            rows={2}
                            placeholder="Notatka admina..."
                            className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-3 py-2 text-xs text-white outline-none focus:border-green-600"
                          />

                          <button
                            type="button"
                            onClick={() =>
                              saveAdminNote(
                                reservation.id,
                                reservation.admin_note ?? "",
                              )
                            }
                            disabled={savingId === reservation.id}
                            className="rounded-lg border border-zinc-700 px-3 py-2 text-xs font-semibold text-zinc-300 transition hover:bg-zinc-900 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            Zapisz notatkę
                          </button>
                        </div>
                      </td>

                      <td className="py-4 pr-4">
                        <div className="flex min-w-[360px] flex-wrap gap-2">
                          <button
                            type="button"
                            onClick={() =>
                              updateAttendanceStatus(reservation.id, "present")
                            }
                            disabled={savingId === reservation.id}
                            className="rounded-lg bg-green-700 px-3 py-2 text-xs font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            Obecny
                          </button>

                          <button
                            type="button"
                            onClick={() =>
                              updateAttendanceStatus(reservation.id, "no_show")
                            }
                            disabled={savingId === reservation.id}
                            className="rounded-lg border border-yellow-700 px-3 py-2 text-xs font-semibold text-yellow-300 transition hover:bg-yellow-950 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            Nieobecny
                          </button>

                          <button
                            type="button"
                            onClick={() =>
                              updateAttendanceStatus(
                                reservation.id,
                                "completed",
                              )
                            }
                            disabled={savingId === reservation.id}
                            className="rounded-lg border border-blue-700 px-3 py-2 text-xs font-semibold text-blue-300 transition hover:bg-blue-950 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            Zakończ
                          </button>

                          <button
                            type="button"
                            onClick={() =>
                              updateAttendanceStatus(reservation.id, "planned")
                            }
                            disabled={savingId === reservation.id}
                            className="rounded-lg border border-zinc-700 px-3 py-2 text-xs font-semibold text-zinc-300 transition hover:bg-zinc-900 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            Zaplanowana
                          </button>

                          <button
                            type="button"
                            onClick={() =>
                              handleCancelReservation(reservation.id)
                            }
                            disabled={
                              savingId === reservation.id ||
                              reservation.reservation_status ===
                                RESERVATION_STATUS.CANCELLED
                            }
                            className="rounded-lg border border-red-700 px-3 py-2 text-xs font-semibold text-red-300 transition hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            Anuluj
                          </button>

                          <button
                            type="button"
                            onClick={() => markAsPaid(reservation.id)}
                            disabled={
                              savingId === reservation.id ||
                              reservation.payment_status ===
                                PAYMENT_STATUS.PAID ||
                              reservation.payment_status ===
                                PAYMENT_STATUS.PAID_ON_SITE
                            }
                            className="rounded-lg border border-green-700 px-3 py-2 text-xs font-semibold text-green-300 transition hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            Opłacono
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
