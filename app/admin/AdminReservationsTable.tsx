"use client";

import { useState } from "react";
import { supabase } from "../../lib/supabase";

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
  shooting_lanes: {
    name: string;
  } | null;
};

type AdminReservationsTableProps = {
  reservations: Reservation[];
};

function translateReservationStatus(status: string) {
  if (status === "confirmed") return "Potwierdzona";
  if (status === "cancelled") return "Anulowana";
  if (status === "completed") return "Zrealizowana";
  if (status === "no_show") return "Nieobecny";
  return status;
}

function translatePaymentStatus(status: string) {
  if (status === "pay_on_site") return "Płatność na miejscu";
  if (status === "paid_on_site") return "Opłacone na miejscu";
  return status;
}

function getStatusClass(status: string) {
  if (status === "confirmed") {
    return "rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400";
  }

  if (status === "completed") {
    return "rounded-full bg-blue-950 px-3 py-1 text-xs font-semibold text-blue-300";
  }

  if (status === "cancelled") {
    return "rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300";
  }

  if (status === "no_show") {
    return "rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300";
  }

  return "rounded-full bg-zinc-950 px-3 py-1 text-xs font-semibold text-zinc-300";
}

export default function AdminReservationsTable({
  reservations,
}: AdminReservationsTableProps) {
  const [items, setItems] = useState(reservations);
  const [message, setMessage] = useState("");

  async function updateReservationStatus(id: string, status: string) {
    setMessage("");

    const { error } = await supabase
      .from("reservations")
      .update({ reservation_status: status })
      .eq("id", id);

    if (error) {
      setMessage(`Błąd zmiany statusu: ${error.message}`);
      return;
    }

    setItems((currentItems) =>
      currentItems.map((item) =>
        item.id === id ? { ...item, reservation_status: status } : item
      )
    );

    setMessage("Status rezerwacji został zaktualizowany.");
  }

  async function markAsPaid(id: string) {
    setMessage("");

    const { error } = await supabase
      .from("reservations")
      .update({ payment_status: "paid_on_site" })
      .eq("id", id);

    if (error) {
      setMessage(`Błąd zmiany płatności: ${error.message}`);
      return;
    }

    setItems((currentItems) =>
      currentItems.map((item) =>
        item.id === id ? { ...item, payment_status: "paid_on_site" } : item
      )
    );

    setMessage("Rezerwacja oznaczona jako opłacona.");
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

      <div className="overflow-x-auto">
        <table className="w-full min-w-[1150px] border-collapse text-left text-sm">
          <thead>
            <tr className="border-b border-zinc-800 text-zinc-400">
              <th className="py-3 pr-4">Data</th>
              <th className="py-3 pr-4">Godzina</th>
              <th className="py-3 pr-4">Oś</th>
              <th className="py-3 pr-4">Klient</th>
              <th className="py-3 pr-4">Telefon</th>
              <th className="py-3 pr-4">E-mail</th>
              <th className="py-3 pr-4">Cena</th>
              <th className="py-3 pr-4">Status</th>
              <th className="py-3 pr-4">Płatność</th>
              <th className="py-3 pr-4">Akcje</th>
            </tr>
          </thead>

          <tbody>
            {items.map((reservation) => (
              <tr key={reservation.id} className="border-b border-zinc-800">
                <td className="py-4 pr-4">
                  {reservation.reservation_date}
                </td>

                <td className="py-4 pr-4">
                  {reservation.start_time.slice(0, 5)}–
                  {reservation.end_time.slice(0, 5)}
                </td>

                <td className="py-4 pr-4">
                  <span className="rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400">
                    {reservation.shooting_lanes?.name ?? "Brak osi"}
                  </span>
                </td>

                <td className="py-4 pr-4 font-semibold">
                  {reservation.customer_name}
                </td>

                <td className="py-4 pr-4">
                  {reservation.customer_phone}
                </td>

                <td className="py-4 pr-4">
                  {reservation.customer_email}
                </td>

                <td className="py-4 pr-4">
                  {Number(reservation.price).toFixed(0)} zł
                </td>

                <td className="py-4 pr-4">
                  <span className={getStatusClass(reservation.reservation_status)}>
                    {translateReservationStatus(reservation.reservation_status)}
                  </span>
                </td>

                <td className="py-4 pr-4">
                  {translatePaymentStatus(reservation.payment_status)}
                </td>

                <td className="py-4 pr-4">
                  <div className="flex flex-wrap gap-2">
                    <button
                      type="button"
                      onClick={() => markAsPaid(reservation.id)}
                      className="rounded-lg border border-green-800 px-3 py-2 text-xs text-green-300 hover:bg-green-950"
                    >
                      Opłacona
                    </button>

                    <button
                      type="button"
                      onClick={() =>
                        updateReservationStatus(reservation.id, "completed")
                      }
                      className="rounded-lg border border-blue-800 px-3 py-2 text-xs text-blue-300 hover:bg-blue-950"
                    >
                      Zrealizowana
                    </button>

                    <button
                      type="button"
                      onClick={() =>
                        updateReservationStatus(reservation.id, "no_show")
                      }
                      className="rounded-lg border border-yellow-800 px-3 py-2 text-xs text-yellow-300 hover:bg-yellow-950"
                    >
                      Nieobecny
                    </button>

                    <button
                      type="button"
                      onClick={() =>
                        updateReservationStatus(reservation.id, "cancelled")
                      }
                      className="rounded-lg border border-red-800 px-3 py-2 text-xs text-red-300 hover:bg-red-950"
                    >
                      Anuluj
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}