"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import QRCode from "react-qr-code";
import { getPaymentStatusLabel } from "../../lib/payment-status";
import {
  RESERVATION_STATUS,
  getReservationStatusLabel,
} from "../../lib/reservation-status";
import { supabase } from "../../lib/supabase";
import {
  getMyReservationLaneDisplayName,
  loadAllMyReservations,
  type MyReservation as Reservation,
} from "../../lib/my-reservations";
import { reportClientError } from "../../lib/safe-client-error";

type CancelReservationRpcResult = {
  changed: boolean;
  new_status?: string | null;
};

const WARSAW_TIME_ZONE = "Europe/Warsaw";
const CONFIGURED_SITE_URL = (process.env.NEXT_PUBLIC_SITE_URL ?? "").replace(
  /\/+$/,
  ""
);

const ACTIVE_RESERVATION_STATUSES = new Set<string>([
  RESERVATION_STATUS.CONFIRMED,
  "scheduled",
]);

const TERMINAL_RESERVATION_STATUSES = new Set<string>([
  RESERVATION_STATUS.COMPLETED,
  RESERVATION_STATUS.NO_SHOW,
  RESERVATION_STATUS.CANCELLED,
  RESERVATION_STATUS.CANCELED,
  RESERVATION_STATUS.CANCELLED_BY_USER,
  RESERVATION_STATUS.CANCELLED_BY_ADMIN,
]);

const warsawDateTimeFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: WARSAW_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
  numberingSystem: "latn",
});

function normalizeReservationStatus(status?: string | null) {
  return status?.trim().toLowerCase() ?? "";
}

function getWarsawDateTimeKey(date: Date) {
  const parts = warsawDateTimeFormatter.formatToParts(date);
  const getPart = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value;

  const year = getPart("year");
  const month = getPart("month");
  const day = getPart("day");
  const hour = getPart("hour");
  const minute = getPart("minute");
  const second = getPart("second");

  if (!year || !month || !day || !hour || !minute || !second) {
    return null;
  }

  return `${year}-${month}-${day}T${hour}:${minute}:${second}`;
}

function getReservationDateTimeKey(
  reservationDate?: string | null,
  reservationTime?: string | null
) {
  const dateMatch = reservationDate?.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  const timeMatch = reservationTime?.match(
    /^(\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?$/
  );

  if (!dateMatch || !timeMatch) {
    return null;
  }

  const [, year, month, day] = dateMatch;
  const [, hour, minute, matchedSecond] = timeMatch;
  const second = matchedSecond ?? "00";
  const yearNumber = Number(year);
  const monthNumber = Number(month);
  const dayNumber = Number(day);
  const hourNumber = Number(hour);
  const minuteNumber = Number(minute);
  const secondNumber = Number(second);
  const validatedDate = new Date(
    Date.UTC(yearNumber, monthNumber - 1, dayNumber)
  );

  const isValidDate =
    validatedDate.getUTCFullYear() === yearNumber &&
    validatedDate.getUTCMonth() === monthNumber - 1 &&
    validatedDate.getUTCDate() === dayNumber;

  const isValidTime =
    hourNumber >= 0 &&
    hourNumber <= 23 &&
    minuteNumber >= 0 &&
    minuteNumber <= 59 &&
    secondNumber >= 0 &&
    secondNumber <= 59;

  if (!isValidDate || !isValidTime) {
    return null;
  }

  return `${year}-${month}-${day}T${hour}:${minute}:${second}`;
}

function isActiveReservation(
  reservation: Reservation,
  warsawNowKey: string | null
) {
  const status = normalizeReservationStatus(reservation.reservation_status);
  const reservationStartKey = getReservationDateTimeKey(
    reservation.reservation_date,
    reservation.start_time
  );
  const reservationEndKey = getReservationDateTimeKey(
    reservation.reservation_date,
    reservation.end_time
  );

  return Boolean(
    warsawNowKey &&
      reservationStartKey &&
      reservationEndKey &&
      ACTIVE_RESERVATION_STATUSES.has(status) &&
      !TERMINAL_RESERVATION_STATUSES.has(status) &&
      reservationEndKey > reservationStartKey &&
      reservationEndKey > warsawNowKey
  );
}

function getHistoryStatusLabel(
  reservation: Reservation,
  warsawNowKey: string | null
) {
  const status = normalizeReservationStatus(reservation.reservation_status);

  if (status === RESERVATION_STATUS.COMPLETED) return "Zakończona";
  if (status === RESERVATION_STATUS.NO_SHOW) return "Nieobecność";

  if (
    status === RESERVATION_STATUS.CANCELLED ||
    status === RESERVATION_STATUS.CANCELED
  ) {
    return "Anulowana";
  }

  if (status === RESERVATION_STATUS.CANCELLED_BY_USER) {
    return "Anulowana przez Ciebie";
  }

  if (status === RESERVATION_STATUS.CANCELLED_BY_ADMIN) {
    return "Anulowana przez obsługę";
  }

  const reservationEndKey = getReservationDateTimeKey(
    reservation.reservation_date,
    reservation.end_time
  );

  if (
    warsawNowKey &&
    reservationEndKey &&
    ACTIVE_RESERVATION_STATUSES.has(status) &&
    reservationEndKey <= warsawNowKey
  ) {
    return "Termin minął";
  }

  return "Archiwalna";
}

function translateAttendanceStatus(status?: string | null) {
  if (status === "present") return "Obecny";
  if (status === "completed") return "Zakończona";
  if (status === "no_show") return "Nieobecny";
  return "Niepotwierdzony";
}
function getAttendanceClass(status?: string | null) {
  if (status === "present") {
    return "rounded-full border border-[#3f6848] bg-[#1b2a1d] px-3 py-1 text-xs font-semibold text-[#a9d4ad]";
  }

  if (status === "completed") {
    return "rounded-full border border-[#343a31] bg-[#171a17] px-3 py-1 text-xs font-semibold text-[#858c7f]";
  }

  if (status === "no_show") {
    return "rounded-full border border-[#744545] bg-[#2a1b1b] px-3 py-1 text-xs font-semibold text-[#e0a0a0]";
  }

  return "rounded-full border border-[#806a32] bg-[#2b2618] px-3 py-1 text-xs font-semibold text-[#e1c477]";
}

function getMessageClass(message: string) {
  if (message.includes("anulowana")) {
    return "mb-6 rounded-xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm font-semibold text-[#a9d4ad]";
  }

  return "mb-6 rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]";
}

function getHistoryStatusClass(label: string) {
  if (
    label === "Nieobecność" ||
    label === "Anulowana" ||
    label === "Anulowana przez Ciebie" ||
    label === "Anulowana przez obsługę"
  ) {
    return "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]";
  }

  if (label === "Termin minął") {
    return "border-[#806a32] bg-[#2b2618] text-[#e1c477]";
  }

  return "border-[#343a31] bg-[#171a17] text-[#858c7f]";
}

function parseCancelReservationRpcResult(
  value: unknown
): CancelReservationRpcResult | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const result = value as Record<string, unknown>;

  if (typeof result.changed !== "boolean") {
    return null;
  }

  if (
    result.new_status !== undefined &&
    result.new_status !== null &&
    typeof result.new_status !== "string"
  ) {
    return null;
  }

  return {
    changed: result.changed,
    new_status:
      typeof result.new_status === "string" ? result.new_status : null,
  };
}

function getCancellationErrorMessage(error: {
  code?: string | null;
  message?: string | null;
}) {
  const code = error.code?.trim().toUpperCase() ?? "";
  const normalizedMessage = error.message?.trim().toLowerCase() ?? "";

  if (code === "55000") {
    if (normalizedMessage.includes("12 godzin")) {
      return "Rezerwację można anulować najpóźniej 12 godzin przed rozpoczęciem.";
    }

    return "Rezerwacji w tym statusie nie można anulować.";
  }

  if (code === "42501") {
    return "Nie masz uprawnień do anulowania tej rezerwacji.";
  }

  if (code === "P0002") {
    return "Nie znaleziono rezerwacji.";
  }

  return "Nie udało się anulować rezerwacji. Spróbuj ponownie.";
}

function getCheckInUrl(token: string, siteUrl: string) {
  if (!siteUrl) {
    return "";
  }

  return `${siteUrl}/admin/check-in?token=${token}`;
}

export default function MyReservationsPage() {
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [message, setMessage] = useState("");
  const [siteUrl, setSiteUrl] = useState(CONFIGURED_SITE_URL);
  const [cancellingReservationId, setCancellingReservationId] = useState<
    string | null
  >(null);
  const cancellationInProgressRef = useRef(false);

  useEffect(() => {
    const siteUrlTimer = window.setTimeout(() => {
      if (!CONFIGURED_SITE_URL) {
        setSiteUrl(window.location.origin.replace(/\/+$/, ""));
      }
    }, 0);

    return () => window.clearTimeout(siteUrlTimer);
  }, []);

  const loadReservations = useCallback(async () => {
    setLoading(true);

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setIsLoggedIn(false);
      setLoading(false);
      return;
    }

    setIsLoggedIn(true);

    const result = await loadAllMyReservations(async (from, to) => {
      const { data, error } = await supabase
        .rpc("get_my_reservations_v2")
        .range(from, to);

      return { data, error };
    });

    if (!result.ok) {
      setReservations([]);
      setMessage(
        "Nie udało się pobrać pełnej historii rezerwacji. Spróbuj ponownie."
      );
      setLoading(false);
      return;
    }

    setReservations(result.value);
    setLoading(false);
  }, []);

  useEffect(() => {
    const reservationsTimer = window.setTimeout(() => {
      void loadReservations();
    }, 0);

    return () => window.clearTimeout(reservationsTimer);
  }, [loadReservations]);

  async function cancelReservation(reservation: Reservation) {
    setMessage("");

    const confirmed = window.confirm(
      "Czy na pewno chcesz anulować tę rezerwację?"
    );

    if (!confirmed) {
      return;
    }

    if (cancellationInProgressRef.current) {
      return;
    }

    cancellationInProgressRef.current = true;
    setCancellingReservationId(reservation.id);

    try {
      const { data, error } = await supabase.rpc("cancel_reservation", {
        p_reservation_id: reservation.id,
      });

      if (error) {
        reportClientError("Reservation cancellation RPC failed", error);
        setMessage(getCancellationErrorMessage(error));
        return;
      }

      const cancellationResult = parseCancelReservationRpcResult(data);

      if (!cancellationResult) {
        console.error("Reservation cancellation RPC returned invalid data");
        await loadReservations();
        setMessage("Nie udało się anulować rezerwacji. Spróbuj ponownie.");
        return;
      }

      await loadReservations();

      if (!cancellationResult.changed) {
        setMessage("Rezerwacja była już anulowana.");
        return;
      }

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        setMessage(
          "Rezerwacja została anulowana, ale nie udało się wysłać wiadomości e-mail."
        );
        return;
      }

      try {
        const emailResponse = await fetch(
          "/api/send-reservation-cancellation",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${session.access_token}`,
            },
            body: JSON.stringify({
              reservationId: reservation.id,
            }),
          }
        );

        if (!emailResponse.ok) {
          setMessage(
            "Rezerwacja została anulowana, ale nie udało się wysłać wiadomości e-mail."
          );
          return;
        }
      } catch {
        reportClientError("Reservation cancellation email failed");
        setMessage(
          "Rezerwacja została anulowana, ale nie udało się wysłać wiadomości e-mail."
        );
        return;
      }

      setMessage("Rezerwacja została anulowana.");
    } catch {
      reportClientError("Reservation cancellation flow failed");
      setMessage(
        "Nie udało się anulować rezerwacji. Spróbuj ponownie."
      );
    } finally {
      cancellationInProgressRef.current = false;
      setCancellingReservationId(null);
    }
  }

  const warsawNowKey = getWarsawDateTimeKey(new Date());

  const activeReservations = reservations
    .filter((reservation) => isActiveReservation(reservation, warsawNowKey))
    .sort((firstReservation, secondReservation) => {
      const firstStartKey =
        getReservationDateTimeKey(
          firstReservation.reservation_date,
          firstReservation.start_time
        ) ?? "";
      const secondStartKey =
        getReservationDateTimeKey(
          secondReservation.reservation_date,
          secondReservation.start_time
        ) ?? "";

      return firstStartKey.localeCompare(secondStartKey);
    });

  const reservationHistory = reservations
    .filter((reservation) => !isActiveReservation(reservation, warsawNowKey))
    .sort((firstReservation, secondReservation) => {
      const firstEndKey =
        getReservationDateTimeKey(
          firstReservation.reservation_date,
          firstReservation.end_time
        ) ?? "";
      const secondEndKey =
        getReservationDateTimeKey(
          secondReservation.reservation_date,
          secondReservation.end_time
        ) ?? "";

      return secondEndKey.localeCompare(firstEndKey);
    });

  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto max-w-5xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/20 sm:p-8">
        <header>
          <p className="mb-3 text-xs font-semibold uppercase tracking-[0.22em] text-[#858c7f]">
            CSK Booking
          </p>

          <h1 className="text-3xl font-bold sm:text-4xl">Moje rezerwacje</h1>

          <p className="mt-3 max-w-3xl leading-7 text-[#a9ada4]">
            Tutaj widzisz rezerwacje przypisane do Twojego konta. Rezerwację
            możesz anulować samodzielnie najpóźniej 12 godzin przed terminem.
          </p>
        </header>

        {loading && (
          <div
            role="status"
            aria-live="polite"
            className="mt-8 rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]"
          >
            Ładowanie rezerwacji...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="mt-8 rounded-2xl border border-[#744545] bg-[#2a1b1b] p-6 text-center sm:p-8">
            <h2 className="text-2xl font-bold text-[#e0a0a0]">
              Logowanie wymagane
            </h2>

            <p role="alert" className="mx-auto mt-3 max-w-xl text-[#e0a0a0]">
              Aby zobaczyć swoje rezerwacje, musisz najpierw zalogować się na
              konto użytkownika albo utworzyć nowe konto.
            </p>

            <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="inline-flex min-h-12 items-center justify-center rounded-xl bg-[#536143] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="inline-flex min-h-12 items-center justify-center rounded-xl border border-[#744545] px-5 py-3 font-semibold text-[#e0a0a0] transition hover:bg-[#382323] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        )}

        {!loading && isLoggedIn && message && (
          <div
            role={message.includes("anulowana") ? "status" : "alert"}
            className={`mt-8 ${getMessageClass(message)}`}
          >
            {message}
          </div>
        )}

        {!loading && isLoggedIn && (
          <div className="mt-8">
            <h2 className="text-2xl font-bold">Aktywne rezerwacje</h2>

            {activeReservations.length === 0 ? (
              <div className="mt-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
                Nie masz obecnie aktywnych rezerwacji osi.
              </div>
            ) : (
              <div className="mt-4 space-y-4">
                {activeReservations.map((reservation) => {
                  const checkInUrl = reservation.check_in_token
                    ? getCheckInUrl(reservation.check_in_token, siteUrl)
                    : "";

                  return (
                    <article
                      key={reservation.id}
                      className="rounded-2xl border border-[#3b4436] bg-[#191e19] p-5 sm:p-6"
                    >
                      <div className="grid gap-6 md:grid-cols-[minmax(0,1fr)_220px] md:items-start">
                        <div className="min-w-0">
                          <span className="inline-flex max-w-full whitespace-normal break-words rounded-full border border-[#536143] bg-[#20251d] px-3 py-1 text-xs font-semibold text-[#d7c895]">
                            {getMyReservationLaneDisplayName(reservation)}
                          </span>

                          <h3 className="mt-3 break-words text-xl font-semibold text-[#f2efe4]">
                            {reservation.reservation_date} |{" "}
                            {reservation.start_time.slice(0, 5)}–
                            {reservation.end_time.slice(0, 5)}
                          </h3>

                          <dl className="mt-4 grid gap-3 sm:grid-cols-2">
                            <div className="rounded-xl border border-[#30372c] bg-[#171a17] p-3">
                              <dt className="text-xs uppercase tracking-[0.14em] text-[#858c7f]">
                                Cena
                              </dt>
                              <dd className="mt-1 font-semibold text-[#f2efe4]">
                                {Number(reservation.price).toFixed(0)} zł
                              </dd>
                            </div>

                            <div className="rounded-xl border border-[#30372c] bg-[#171a17] p-3">
                              <dt className="text-xs uppercase tracking-[0.14em] text-[#858c7f]">
                                Płatność
                              </dt>
                              <dd className="mt-1 font-semibold text-[#f2efe4]">
                                {getPaymentStatusLabel(
                                  reservation.payment_status
                                )}
                              </dd>
                            </div>
                          </dl>

                          <div className="mt-4 flex flex-wrap gap-2">
                            <span className="rounded-full border border-[#3f6848] bg-[#1b2a1d] px-3 py-1 text-xs font-semibold text-[#a9d4ad]">
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

                          {reservation.reservation_status ===
                            RESERVATION_STATUS.CONFIRMED && (
                              <p className="mt-4 rounded-xl border border-[#806a32] bg-[#2b2618] p-3 text-sm text-[#e1c477]">
                                Rezerwację można anulować najpóźniej 12 godzin
                                przed rozpoczęciem.
                              </p>
                            )}

                          {reservation.checked_in_at && (
                            <p className="mt-3 text-xs text-[#858c7f]">
                              Check-in:{" "}
                              {new Date(
                                reservation.checked_in_at
                              ).toLocaleString("pl-PL")}
                            </p>
                          )}

                          {reservation.reservation_status ===
                            RESERVATION_STATUS.CONFIRMED && (
                              <button
                                type="button"
                                onClick={() => cancelReservation(reservation)}
                                disabled={cancellingReservationId !== null}
                                className="mt-5 inline-flex min-h-11 items-center justify-center rounded-xl border border-[#744545] px-4 py-2 text-sm font-semibold text-[#e0a0a0] transition hover:bg-[#2a1b1b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:opacity-60"
                              >
                                {cancellingReservationId === reservation.id
                                  ? "Anulowanie…"
                                  : "Anuluj rezerwację"}
                              </button>
                            )}
                        </div>

                        <div className="rounded-2xl border border-[#30372c] bg-[#171a17] p-4 text-center">
                          {checkInUrl ? (
                            <>
                              <p className="mb-3 text-xs font-semibold uppercase tracking-[0.18em] text-[#d7c895]">
                                QR Check-in
                              </p>

                              <QRCode
                                value={checkInUrl}
                                size={180}
                                aria-label="Kod QR do zameldowania rezerwacji"
                                className="mx-auto h-auto max-w-full rounded-xl bg-white p-2"
                              />

                              <p className="mt-3 text-xs leading-5 text-[#858c7f]">
                                Pokaż ten kod pracownikowi strzelnicy przy
                                wejściu.
                              </p>

                              <a
                                href={checkInUrl}
                                className="mt-3 inline-flex min-h-11 items-center text-xs font-semibold text-[#d7c895] transition hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#171a17]"
                              >
                                Otwórz link check-in
                              </a>
                            </>
                          ) : (
                            <div className="text-sm text-[#858c7f]">
                              QR dostępny tylko dla aktywnych rezerwacji.
                            </div>
                          )}
                        </div>
                      </div>
                    </article>
                  );
                })}
              </div>
            )}

            {reservationHistory.length > 0 && (
              <section className="mt-10" aria-labelledby="history-heading">
                <h2 id="history-heading" className="text-2xl font-bold">
                  Historia rezerwacji
                </h2>

                <div className="mt-4 space-y-3">
                  {reservationHistory.map((reservation) => {
                    const historyStatusLabel = getHistoryStatusLabel(
                      reservation,
                      warsawNowKey
                    );

                    return (
                      <article
                        key={reservation.id}
                        className="flex flex-col gap-3 rounded-xl border border-[#30372c] bg-[#171a17] p-4 sm:flex-row sm:items-center sm:justify-between"
                      >
                        <div className="min-w-0">
                          <p className="break-words font-semibold text-[#f2efe4]">
                            {reservation.reservation_date || "Brak daty"} |{" "}
                            {reservation.start_time?.slice(0, 5) || "--:--"}–
                            {reservation.end_time?.slice(0, 5) || "--:--"}
                          </p>

                          <p className="mt-1 break-words text-sm text-[#858c7f]">
                            {getMyReservationLaneDisplayName(reservation)}
                          </p>
                        </div>

                        <span
                          className={`self-start rounded-full border px-3 py-1 text-xs font-semibold sm:self-auto ${getHistoryStatusClass(
                            historyStatusLabel
                          )}`}
                        >
                          {historyStatusLabel}
                        </span>
                      </article>
                    );
                  })}
                </div>
              </section>
            )}
          </div>
        )}

        <nav
          aria-label="Nawigacja rezerwacji"
          className="mt-8 flex flex-col gap-3 border-t border-[#30372c] pt-6 sm:flex-row"
        >
          <a
            href="/booking"
            className="inline-flex min-h-12 items-center justify-center rounded-xl bg-[#536143] px-5 py-3 text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Nowa rezerwacja
          </a>

          <a
            href="/dashboard"
            className="inline-flex min-h-12 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Panel klienta
          </a>
        </nav>
      </section>
    </main>
  );
}

