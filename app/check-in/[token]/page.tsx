import Link from "next/link";
import { createClient } from "@supabase/supabase-js";
import {
  getReservationStatusLabel,
  getReservationStatusBadgeClass,
} from "../../../lib/reservation-status";
import {
  getPaymentStatusLabel,
  getPaymentStatusBadgeClass,
} from "../../../lib/payment-status";

type CheckInPageProps = {
  params: Promise<{
    token: string;
  }>;
};

type LaneRelation = {
  name?: string | null;
};

type CheckInReservation = {
  id: string;
  customer_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  reservation_date: string | null;
  start_time: string | null;
  end_time: string | null;
  reservation_status: string | null;
  payment_status: string | null;
  checked_in_at: string | null;
  lanes: LaneRelation | LaneRelation[] | null;
};

function getAdminSupabaseClient() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error("Brak konfiguracji Supabase service role.");
  }

  return createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}

function formatDate(date?: string | null) {
  if (!date) {
    return "-";
  }

  try {
    return new Intl.DateTimeFormat("pl-PL", {
      year: "numeric",
      month: "long",
      day: "2-digit",
    }).format(new Date(date));
  } catch {
    return date;
  }
}

function formatTime(time?: string | null) {
  if (!time) {
    return "-";
  }

  return time.slice(0, 5);
}

export default async function CheckInPage({ params }: CheckInPageProps) {
  const { token } = await params;

  let reservation: CheckInReservation | null = null;

  try {
    const supabase = getAdminSupabaseClient();

    const { data, error } = await supabase
      .from("reservations")
      .select(
        `
          id,
          customer_name,
          customer_email,
          customer_phone,
          reservation_date,
          start_time,
          end_time,
          reservation_status,
          payment_status,
          checked_in_at,
          lanes:shooting_lanes (
            name
          )
        `
      )
      .eq("check_in_token", token)
      .maybeSingle();

    if (!error && data) {
      reservation = data as CheckInReservation;
    }
  } catch {
    reservation = null;
  }

  if (!reservation) {
    return (
      <main className="min-h-screen bg-zinc-950 px-4 py-10 text-zinc-100">
        <section className="mx-auto max-w-2xl rounded-2xl border border-red-900 bg-red-950/40 p-6">
          <p className="mb-3 text-xs font-bold uppercase tracking-[0.35em] text-red-300">
            CSK Booking
          </p>
          <h1 className="mb-3 text-2xl font-bold text-white">
            Nie znaleziono rezerwacji
          </h1>
          <p className="text-sm leading-6 text-red-100">
            Link check-in jest nieprawidłowy albo rezerwacja nie istnieje.
          </p>
          <Link
            href="/"
            className="mt-6 inline-flex rounded-lg bg-zinc-100 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-white"
          >
            Wróć na stronę główną
          </Link>
        </section>
      </main>
    );
  }

  const lanes = reservation.lanes;

  const laneName = Array.isArray(lanes) ? lanes[0]?.name : lanes?.name;

  const isCheckedIn = Boolean(reservation.checked_in_at);

  return (
    <main className="min-h-screen bg-zinc-950 px-4 py-10 text-zinc-100">
      <section className="mx-auto max-w-2xl rounded-2xl border border-zinc-800 bg-zinc-900 p-6 shadow-2xl">
        <p className="mb-3 text-xs font-bold uppercase tracking-[0.35em] text-green-400">
          CSK Booking
        </p>

        <h1 className="mb-3 text-2xl font-bold text-white">
          Check-in rezerwacji
        </h1>

        <p className="mb-6 text-sm leading-6 text-zinc-400">
          Pokaż ten ekran obsłudze. Pracownik lub instruktor potwierdzi obecność
          w panelu check-in.
        </p>

        <div className="mb-6 rounded-xl border border-zinc-700 bg-zinc-950 p-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <p className="text-xs uppercase tracking-wider text-zinc-500">
                Klient
              </p>
              <p className="mt-1 font-semibold text-white">
                {reservation.customer_name ?? "-"}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-zinc-500">
                Telefon
              </p>
              <p className="mt-1 font-semibold text-white">
                {reservation.customer_phone ?? "-"}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-zinc-500">
                Email
              </p>
              <p className="mt-1 break-all font-semibold text-white">
                {reservation.customer_email ?? "-"}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-zinc-500">
                Oś
              </p>
              <p className="mt-1 font-semibold text-white">
                {laneName ?? "-"}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-zinc-500">
                Data
              </p>
              <p className="mt-1 font-semibold text-white">
                {formatDate(reservation.reservation_date)}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-zinc-500">
                Godzina
              </p>
              <p className="mt-1 font-semibold text-white">
                {formatTime(reservation.start_time)} -{" "}
                {formatTime(reservation.end_time)}
              </p>
            </div>
          </div>
        </div>

        <div className="mb-6 grid gap-3 sm:grid-cols-2">
          <div className="rounded-xl border border-zinc-700 bg-zinc-950 p-4">
            <p className="mb-2 text-xs uppercase tracking-wider text-zinc-500">
              Status rezerwacji
            </p>
            <span
              className={`inline-flex rounded-full px-3 py-1 text-xs font-semibold ${getReservationStatusBadgeClass(
                reservation.reservation_status
              )}`}
            >
              {getReservationStatusLabel(reservation.reservation_status)}
            </span>
          </div>

          <div className="rounded-xl border border-zinc-700 bg-zinc-950 p-4">
            <p className="mb-2 text-xs uppercase tracking-wider text-zinc-500">
              Status płatności
            </p>
            <span
              className={`inline-flex rounded-full px-3 py-1 text-xs font-semibold ${getPaymentStatusBadgeClass(
                reservation.payment_status
              )}`}
            >
              {getPaymentStatusLabel(reservation.payment_status)}
            </span>
          </div>
        </div>

        {isCheckedIn ? (
          <div className="rounded-xl border border-green-800 bg-green-950/50 p-4 text-sm text-green-100">
            Obecność została już potwierdzona.
          </div>
        ) : (
          <div className="rounded-xl border border-yellow-800 bg-yellow-950/50 p-4 text-sm leading-6 text-yellow-100">
            Ten ekran nie potwierdza obecności automatycznie. Obsługa musi
            potwierdzić wizytę w panelu administracyjnym.
          </div>
        )}

        <div className="mt-6">
          <Link
            href="/"
            className="inline-flex rounded-lg border border-zinc-700 px-4 py-2 text-sm font-semibold text-zinc-200 hover:bg-zinc-800"
          >
            Wróć na stronę główną
          </Link>
        </div>
      </section>
    </main>
  );
}