import Image from "next/image";
import Link from "next/link";
import { createClient } from "@supabase/supabase-js";
import { getReservationStatusLabel } from "../../../lib/reservation-status";
import { getPaymentStatusLabel } from "../../../lib/payment-status";
import { getLaneRelationDisplay } from "../../../lib/admin/lane-relation-display";

type CheckInPageProps = {
  params: Promise<{
    token: string;
  }>;
};

type LaneRelation = {
  id: string;
  name: string;
  resource_kind: "lane" | "position";
  parent_lane_id: string | null;
  parent_lane: LaneRelation | LaneRelation[] | null;
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
          lanes:shooting_lanes!reservations_lane_id_fkey (
            id,
            name,
            resource_kind,
            parent_lane_id,
            parent_lane:shooting_lanes!shooting_lanes_parent_lane_id_fkey (
              id,
              name,
              resource_kind,
              parent_lane_id
            )
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
      <main className="flex min-h-screen items-center bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
        <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl shadow-black/20 sm:p-9">
          <Image
            src="/login-brand.png"
            alt="Centrum Szkolenia Krutla"
            width={1536}
            height={1024}
            className="mx-auto h-auto w-full max-w-[260px] sm:max-w-[300px]"
            priority
          />

          <h1 className="mt-6 text-center text-3xl font-bold sm:text-4xl">
            Nie znaleziono rezerwacji
          </h1>

          <div
            role="alert"
            className="mt-6 rounded-2xl border border-[#744545] bg-[#2a1b1b] p-5 text-sm leading-6 text-[#e0a0a0]"
          >
            Link check-in jest nieprawidłowy albo rezerwacja nie istnieje.
          </div>

          <Link
            href="/"
            className="mt-6 inline-flex min-h-12 w-full items-center justify-center rounded-xl bg-[#536143] px-5 py-3 text-center text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:w-auto"
          >
            Wróć na stronę główną
          </Link>
        </section>
      </main>
    );
  }

  const laneName =
    getLaneRelationDisplay(reservation.lanes)?.displayName ?? "Nieznana oś";

  const isCheckedIn = Boolean(reservation.checked_in_at);

  return (
    <main className="flex min-h-screen items-center bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl shadow-black/20 sm:p-9">
        <Image
          src="/login-brand.png"
          alt="Centrum Szkolenia Krutla"
          width={1536}
          height={1024}
          className="mx-auto h-auto w-full max-w-[260px] sm:max-w-[300px]"
          priority
        />

        <h1 className="mt-6 text-center text-3xl font-bold sm:text-4xl">
          Check-in rezerwacji
        </h1>

        <p className="mx-auto mt-4 max-w-xl text-center text-sm leading-6 text-[#a9ada4] sm:text-base">
          Pokaż ten ekran obsłudze. Pracownik lub instruktor potwierdzi obecność
          w panelu check-in.
        </p>

        <div className="mt-7 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <p className="text-xs uppercase tracking-wider text-[#858c7f]">
                Klient
              </p>
              <p className="mt-1 break-words font-semibold text-[#f2efe4]">
                {reservation.customer_name ?? "-"}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-[#858c7f]">
                Telefon
              </p>
              <p className="mt-1 break-words font-semibold text-[#f2efe4]">
                {reservation.customer_phone ?? "-"}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-[#858c7f]">
                Email
              </p>
              <p className="mt-1 break-all font-semibold text-[#f2efe4]">
                {reservation.customer_email ?? "-"}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-[#858c7f]">
                Oś
              </p>
              <p className="mt-1 break-words font-semibold text-[#f2efe4]">
                {laneName}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-[#858c7f]">
                Data
              </p>
              <p className="mt-1 font-semibold text-[#f2efe4]">
                {formatDate(reservation.reservation_date)}
              </p>
            </div>

            <div>
              <p className="text-xs uppercase tracking-wider text-[#858c7f]">
                Godzina
              </p>
              <p className="mt-1 font-semibold text-[#f2efe4]">
                {formatTime(reservation.start_time)} -{" "}
                {formatTime(reservation.end_time)}
              </p>
            </div>
          </div>
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4">
            <p className="mb-2 text-xs uppercase tracking-wider text-[#858c7f]">
              Status rezerwacji
            </p>
            <span
              className="inline-flex rounded-full border border-[#536143] bg-[#20251d] px-3 py-1 text-xs font-semibold text-[#d7c895]"
            >
              {getReservationStatusLabel(reservation.reservation_status)}
            </span>
          </div>

          <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4">
            <p className="mb-2 text-xs uppercase tracking-wider text-[#858c7f]">
              Status płatności
            </p>
            <span
              className="inline-flex rounded-full border border-[#536143] bg-[#20251d] px-3 py-1 text-xs font-semibold text-[#d7c895]"
            >
              {getPaymentStatusLabel(reservation.payment_status)}
            </span>
          </div>
        </div>

        {isCheckedIn ? (
          <div
            role="status"
            aria-live="polite"
            className="mt-4 rounded-2xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm leading-6 text-[#a9d4ad]"
          >
            Obecność została już potwierdzona.
          </div>
        ) : (
          <div
            role="status"
            aria-live="polite"
            className="mt-4 rounded-2xl border border-[#806a32] bg-[#2b2618] p-4 text-sm leading-6 text-[#e1c477]"
          >
            Ten ekran nie potwierdza obecności automatycznie. Obsługa musi
            potwierdzić wizytę w panelu administracyjnym.
          </div>
        )}

        <div className="mt-6">
          <Link
            href="/"
            className="inline-flex min-h-11 w-full items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:w-auto"
          >
            Wróć na stronę główną
          </Link>
        </div>
      </section>
    </main>
  );
}
