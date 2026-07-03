"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { supabase } from "../../../lib/supabase";
import {
  RESERVATION_STATUS,
  getReservationStatusLabel,
  getReservationStatusBadgeClass,
} from "../../../lib/reservation-status";

import {
  PAYMENT_STATUS,
  getPaymentStatusLabel,
  getPaymentStatusBadgeClass,
} from "../../../lib/payment-status";
import {
  cancelReservation,
  completeReservation,
  markNoShow,
  markPaid,
} from "../../../lib/reservation-actions";

type ReservationSort = "newest" | "oldest" | "lane" | "status" | "payment";

type Reservation = {
  id: string;
  user_id: string | null;
  lane_id: string | null;
  customer_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  reservation_date: string | null;
  start_time: string | null;
  end_time: string | null;
  duration_minutes: number | null;
  price: number | null;
  reservation_status: string | null;
  payment_status: string | null;
  created_at: string | null;
  shooting_lanes?:
    | {
        name: string | null;
      }
    | {
        name: string | null;
      }[]
    | null;
};

const DEFAULT_SORT: ReservationSort = "newest";

const sortOptions: { label: string; value: ReservationSort }[] = [
  { label: "Najnowsze", value: "newest" },
  { label: "Najstarsze", value: "oldest" },
  { label: "Oś", value: "lane" },
  { label: "Status", value: "status" },
  { label: "Płatność", value: "payment" },
];

const statusOptions = [
  { label: "Wszystkie", value: "all" },
  { label: "Potwierdzone", value: RESERVATION_STATUS.CONFIRMED },
  { label: "Zakończone", value: RESERVATION_STATUS.COMPLETED },
  { label: "No-show", value: RESERVATION_STATUS.NO_SHOW },
  { label: "Anulowane", value: RESERVATION_STATUS.CANCELLED },
];

function normalizeTime(time: string | null) {
  if (!time) return "";
  return time.slice(0, 5);
}

function getLaneName(reservation: Reservation) {
  const lanes = reservation.shooting_lanes;

  if (Array.isArray(lanes)) {
    return lanes[0]?.name || "Nieznana oś";
  }

  return lanes?.name || "Nieznana oś";
}

function isReservationSort(value: string | null): value is ReservationSort {
  return (
    value === "newest" ||
    value === "oldest" ||
    value === "lane" ||
    value === "status" ||
    value === "payment"
  );
}

function sanitizeSearchPhrase(value: string) {
  return value
    .trim()
    .replace(/[,%]/g, " ")
    .replace(/\s+/g, " ")
    .slice(0, 80);
}

function buildUrlParams(params: {
  search: string;
  statusFilter: string;
  dateFilter: string;
  sort: ReservationSort;
}) {
  const urlParams = new URLSearchParams();

  if (params.search.trim()) {
    urlParams.set("search", params.search.trim());
  }

  if (params.statusFilter !== "all") {
    urlParams.set("status", params.statusFilter);
  }

  if (params.dateFilter) {
    urlParams.set("date", params.dateFilter);
  }

  if (params.sort !== DEFAULT_SORT) {
    urlParams.set("sort", params.sort);
  }

  return urlParams.toString();
}

function formatCsvValue(value: string | number | null | undefined) {
  if (value === null || value === undefined) return "";

  const csvText = String(value).replace(/\r?\n|\r/g, " ").trim();

  if (csvText.includes(";") || csvText.includes('"') || csvText.includes(",")) {
    return '"' + csvText.replace(/"/g, '""') + '"';
  }

  return csvText;
}

function formatCsvDate(dateString: string | null) {
  if (!dateString) return "";

  const [year, month, day] = dateString.split("-");

  if (!year || !month || !day) {
    return dateString;
  }

  return day + "." + month + "." + year;
}

function formatCsvPrice(price: number | null) {
  if (price === null || price === undefined) return "";

  return price.toFixed(2).replace(".", ",");
}

function formatCsvDateTime(dateString: string | null) {
  if (!dateString) return "";

  const date = new Date(dateString);

  if (Number.isNaN(date.getTime())) {
    return dateString;
  }

  return new Intl.DateTimeFormat("pl-PL", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function formatCsvTextForExcel(value: string | null) {
  if (!value) return "";

  return `="${value.replace(/"/g, "\"\"")}"`;
}

export default function AdminReservationsPage() {
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [loading, setLoading] = useState(false);
  const [savingReservationId, setSavingReservationId] = useState<string | null>(
    null
  );
  const [message, setMessage] = useState("");

  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [dateFilter, setDateFilter] = useState("");
  const [sort, setSort] = useState<ReservationSort>(DEFAULT_SORT);
  const [urlParamsLoaded, setUrlParamsLoaded] = useState(false);

  const activeSortLabel = useMemo(() => {
    return (
      sortOptions.find((option) => option.value === sort)?.label || "Najnowsze"
    );
  }, [sort]);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);

    const searchParam = params.get("search") || "";
    const statusParam = params.get("status") || "all";
    const dateParam = params.get("date") || "";
    const sortParam = params.get("sort");

    setSearch(searchParam);
    setStatusFilter(statusParam);
    setDateFilter(dateParam);

    if (isReservationSort(sortParam)) {
      setSort(sortParam);
    } else {
      setSort(DEFAULT_SORT);
    }

    setUrlParamsLoaded(true);
  }, []);

  const loadReservations = useCallback(async () => {
    setLoading(true);
    setMessage("");

    const phrase = sanitizeSearchPhrase(search);

    let matchingLaneIds: string[] = [];

    if (phrase) {
      const { data: laneData, error: laneError } = await supabase
        .from("shooting_lanes")
        .select("id")
        .ilike("name", `%${phrase}%`);

      if (!laneError && laneData) {
        matchingLaneIds = laneData
          .map((lane) => String(lane.id))
          .filter(Boolean);
      }
    }

    let query = supabase.from("reservations").select(
      `
        id,
        user_id,
        lane_id,
        customer_name,
        customer_email,
        customer_phone,
        reservation_date,
        start_time,
        end_time,
        duration_minutes,
        price,
        reservation_status,
        payment_status,
        created_at,
        shooting_lanes (
          name
        )
      `
    );

    if (phrase) {
      const searchParts = [
        `customer_name.ilike.%${phrase}%`,
        `customer_email.ilike.%${phrase}%`,
        `customer_phone.ilike.%${phrase}%`,
        `reservation_status.ilike.%${phrase}%`,
        `payment_status.ilike.%${phrase}%`,
      ];

      if (matchingLaneIds.length > 0) {
        searchParts.push(`lane_id.in.(${matchingLaneIds.join(",")})`);
      }

      query = query.or(searchParts.join(","));
    }

    if (statusFilter !== "all") {
      if (statusFilter === RESERVATION_STATUS.CANCELLED) {
        query = query.in("reservation_status", [
          RESERVATION_STATUS.CANCELLED,
          RESERVATION_STATUS.CANCELED,
          RESERVATION_STATUS.CANCELLED_BY_USER,
          RESERVATION_STATUS.CANCELLED_BY_ADMIN,
        ]);
      } else {
        query = query.eq("reservation_status", statusFilter);
      }
    }

    if (dateFilter) {
      query = query.eq("reservation_date", dateFilter);
    }

    switch (sort) {
      case "newest":
        query = query
          .order("created_at", { ascending: false })
          .order("reservation_date", { ascending: false })
          .order("start_time", { ascending: false });
        break;

      case "oldest":
        query = query
          .order("created_at", { ascending: true })
          .order("reservation_date", { ascending: true })
          .order("start_time", { ascending: true });
        break;

      case "lane":
        query = query
          .order("name", {
            ascending: true,
            referencedTable: "shooting_lanes",
          } as any)
          .order("reservation_date", { ascending: false })
          .order("start_time", { ascending: false });
        break;

      case "status":
        query = query
          .order("reservation_status", { ascending: true })
          .order("reservation_date", { ascending: false })
          .order("start_time", { ascending: false });
        break;

      case "payment":
        query = query
          .order("payment_status", { ascending: true })
          .order("reservation_date", { ascending: false })
          .order("start_time", { ascending: false });
        break;

      default:
        query = query
          .order("created_at", { ascending: false })
          .order("reservation_date", { ascending: false })
          .order("start_time", { ascending: false });
        break;
    }

    const { data, error } = await query;

    setLoading(false);

    if (error) {
      setMessage(`Błąd pobierania rezerwacji: ${error.message}`);
      return;
    }

    setReservations((data ?? []) as unknown as Reservation[]);
  }, [search, statusFilter, dateFilter, sort]);

  useEffect(() => {
    if (!urlParamsLoaded) return;

    const params = buildUrlParams({
      search,
      statusFilter,
      dateFilter,
      sort,
    });

    const nextUrl = params
      ? `${window.location.pathname}?${params}`
      : window.location.pathname;

    window.history.replaceState(null, "", nextUrl);
  }, [search, statusFilter, dateFilter, sort, urlParamsLoaded]);

  useEffect(() => {
    if (!urlParamsLoaded) return;

    const timeout = window.setTimeout(() => {
      loadReservations();
    }, 250);

    return () => {
      window.clearTimeout(timeout);
    };
  }, [loadReservations, urlParamsLoaded]);

  async function updateReservation(
    reservation: Reservation,
    changes: Partial<Pick<Reservation, "reservation_status" | "payment_status">>
  ) {
    setSavingReservationId(reservation.id);
    setMessage("");

    let result:
      | {
          data: {
            reservation_status: string | null;
            payment_status: string | null;
          } | null;
          error: string | null;
        }
      | null = null;

    if (changes.reservation_status === RESERVATION_STATUS.COMPLETED) {
      result = await completeReservation(supabase, {
        reservationId: reservation.id,
      });
    } else if (changes.reservation_status === RESERVATION_STATUS.NO_SHOW) {
      result = await markNoShow(supabase, {
        reservationId: reservation.id,
      });
    } else if (changes.reservation_status === RESERVATION_STATUS.CANCELLED_BY_ADMIN) {
      result = await cancelReservation(supabase, {
        reservationId: reservation.id,
      });
    } else if (changes.payment_status === PAYMENT_STATUS.PAID) {
      result = await markPaid(supabase, {
        reservationId: reservation.id,
      });
    }

    if (!result) {
      const { data, error } = await supabase
        .from("reservations")
        .update(changes)
        .eq("id", reservation.id)
        .select("reservation_status, payment_status")
        .single();

      result = {
        data,
        error: error ? error.message : null,
      };
    }

    setSavingReservationId(null);

    if (result.error) {
      setMessage(`Błąd zapisu rezerwacji: ${result.error}`);
      return;
    }

    const nextChanges = {
      ...changes,
      ...(result.data?.reservation_status !== undefined
        ? { reservation_status: result.data.reservation_status }
        : {}),
      ...(result.data?.payment_status !== undefined
        ? { payment_status: result.data.payment_status }
        : {}),
    };

    setReservations((currentReservations) =>
      currentReservations.map((item) =>
        item.id === reservation.id ? { ...item, ...nextChanges } : item
      )
    );

    if (changes.reservation_status === RESERVATION_STATUS.CANCELLED_BY_ADMIN) {
      if (!reservation.customer_email) {
        setMessage("Rezerwacja anulowana, ale klient nie ma zapisanego adresu email.");
        return;
      }

      const emailResponse = await fetch("/api/send-reservation-cancellation", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          customerEmail: reservation.customer_email,
          customerName: reservation.customer_name,
          reservationDate: reservation.reservation_date,
          startTime: reservation.start_time,
          endTime: reservation.end_time,
          laneName: Array.isArray(reservation.shooting_lanes)
            ? reservation.shooting_lanes[0]?.name ?? "Brak osi"
            : reservation.shooting_lanes?.name ?? "Brak osi",
          cancelledBy: "admin",
        }),
      });

      if (!emailResponse.ok) {
        const emailResult = await emailResponse.json().catch(() => null);
        setMessage(
          `Rezerwacja anulowana, ale email nie został wysłany: ${emailResult?.error ?? "nieznany błąd"}`
        );
        return;
      }

      setMessage("Rezerwacja została anulowana. Email anulowania został wysłany.");
      return;
    }

    setMessage("Zapisano zmiany w rezerwacji.");
  }

  function resetFilters() {
    setSearch("");
    setStatusFilter("all");
    setDateFilter("");
    setSort(DEFAULT_SORT);
  }

  function downloadReservationsCsv() {
    const headers = [
      "Data rezerwacji",
      "Godzina od",
      "Godzina do",
      "Czas trwania (min)",
      "Oś",
      "Klient",
      "E-mail",
      "Telefon",
      "Status rezerwacji",
      "Status płatności",
      "Cena",
      "Data utworzenia",
    ];

    const rows = reservations.map((reservation) => [
      formatCsvDate(reservation.reservation_date),
      normalizeTime(reservation.start_time),
      normalizeTime(reservation.end_time),
      reservation.duration_minutes,
      getLaneName(reservation),
      reservation.customer_name ?? "",
      reservation.customer_email ?? "",
      formatCsvTextForExcel(reservation.customer_phone),
      getReservationStatusLabel(reservation.reservation_status),
      getPaymentStatusLabel(reservation.payment_status),
      formatCsvPrice(reservation.price),
      formatCsvDateTime(reservation.created_at),
    ]);

    const csvContent = [headers, ...rows]
      .map((row) => row.map(formatCsvValue).join(";"))
      .join("\r\n");

    const blob = new Blob(["\uFEFF" + csvContent], {
      type: "text/csv;charset=utf-8;",
    });

    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    const today = new Date().toISOString().slice(0, 10);

    link.href = url;
    link.download = "rezerwacje-" + today + ".csv";

    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);

    URL.revokeObjectURL(url);

    setMessage("Wyeksportowano " + reservations.length + " rezerwacji do CSV.");
  }

  return (
    <main className="min-h-screen bg-zinc-950 px-6 py-10 text-white">
      <section className="mx-auto max-w-7xl">
        <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-3 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="text-4xl font-bold">Rezerwacje</h1>

            <p className="mt-3 max-w-2xl text-zinc-400">
              Podgląd rezerwacji klientów, statusów płatności i obsługa wizyt.
            </p>
          </div>

          <Link
            href="/admin"
            className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
          >
            Wróć do panelu
          </Link>
        </div>

        <div className="mb-6 grid gap-4 rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
          <div className="grid gap-4 md:grid-cols-[1fr_auto_auto_auto_auto] md:items-end">
            <div>
              <label className="mb-2 block text-sm font-semibold text-zinc-300">
                Szukaj rezerwacji
              </label>

              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Imię, e-mail, telefon, oś, płatność, status..."
                className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition focus:border-green-600"
              />
            </div>

            <div>
              <label className="mb-2 block text-sm font-semibold text-zinc-300">
                Data
              </label>

              <input
                type="date"
                value={dateFilter}
                onChange={(event) => setDateFilter(event.target.value)}
                className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition focus:border-green-600"
              />
            </div>

            <div>
              <label className="mb-2 block text-sm font-semibold text-zinc-300">
                Sortowanie
              </label>

              <select
                value={sort}
                onChange={(event) =>
                  setSort(event.target.value as ReservationSort)
                }
                className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition focus:border-green-600"
              >
                {sortOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
            </div>

            <button
              type="button"
              onClick={loadReservations}
              disabled={loading || !urlParamsLoaded}
              className="rounded-xl bg-green-700 px-5 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {loading ? "Odświeżanie..." : "Odśwież"}
            </button>

            <button
              type="button"
              onClick={resetFilters}
              className="rounded-xl border border-zinc-700 px-5 py-3 font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
            >
              Wyczyść filtry
            </button>
          </div>

          <div>
            <p className="mb-3 text-sm font-semibold text-zinc-300">
              Status rezerwacji
            </p>

            <div className="flex flex-wrap gap-2">
              {statusOptions.map((status) => (
                <button
                  key={status.value}
                  type="button"
                  onClick={() => setStatusFilter(status.value)}
                  className={
                    statusFilter === status.value
                      ? "rounded-xl border border-green-600 bg-green-900 px-4 py-2 text-sm font-semibold text-white"
                      : "rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-2 text-sm font-semibold text-zinc-400 transition hover:border-green-700 hover:text-white"
                  }
                >
                  {status.label}
                </button>
              ))}
            </div>
          </div>

          <div className="rounded-xl border border-zinc-800 bg-zinc-950 px-4 py-3 text-sm text-zinc-400">
            Aktywne sortowanie:{" "}
            <span className="font-bold text-white">{activeSortLabel}</span>
          </div>
        </div>

        {message && (
          <div className="mb-6 rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200">
            {message}
          </div>
        )}

        <div className="overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900">
          <div className="flex flex-col gap-3 border-b border-zinc-800 px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-sm text-zinc-400">
              Liczba rezerwacji w widoku:{" "}
              <span className="font-bold text-white">
                {reservations.length}
              </span>
            </p>

            <button
              type="button"
              onClick={downloadReservationsCsv}
              disabled={!urlParamsLoaded || loading || reservations.length === 0}
              className="rounded-xl border border-green-700 bg-green-950 px-4 py-2 text-sm font-semibold text-green-300 transition hover:bg-green-900 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Eksport CSV
            </button>
          </div>

          {!urlParamsLoaded || loading ? (
            <div className="p-8 text-zinc-400">Ładowanie rezerwacji...</div>
          ) : reservations.length === 0 ? (
            <div className="p-8 text-zinc-400">
              Brak rezerwacji do wyświetlenia.
            </div>
          ) : (
            <div className="grid gap-4 p-4">
              {reservations.map((reservation) => {
                const isSaving = savingReservationId === reservation.id;

                return (
                  <article
                    key={reservation.id}
                    className="rounded-2xl border border-zinc-800 bg-zinc-950 p-5"
                  >
                    <div className="grid gap-5 xl:grid-cols-[1.1fr_0.8fr_0.8fr_1fr_auto] xl:items-start">
                      <div>
                        <div className="mb-3 flex flex-wrap gap-2">
                          <span
                            className={`rounded-full border px-3 py-1 text-xs font-bold ${getReservationStatusBadgeClass(
                              reservation.reservation_status
                            )}`}
                          >
                            {getReservationStatusLabel(
                              reservation.reservation_status
                            )}
                          </span>

                          <span
                            className={`rounded-full border px-3 py-1 text-xs font-bold ${getPaymentStatusBadgeClass(
                              reservation.payment_status
                            )}`}
                          >
                            {getPaymentStatusLabel(reservation.payment_status)}
                          </span>
                        </div>

                        <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Klient
                        </p>

                        <h2 className="mt-2 text-lg font-bold">
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

                        <p className="mt-1 text-sm text-zinc-500">
                          {reservation.duration_minutes ?? 0} min
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
                      </div>

                      <div className="grid gap-4">
                        <div>
                          <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                            Status rezerwacji
                          </label>

                          <select
                            value={
                              reservation.reservation_status || RESERVATION_STATUS.CONFIRMED
                            }
                            disabled={isSaving}
                            onChange={(event) =>
                              updateReservation(reservation, {
                                reservation_status: event.target.value,
                              })
                            }
                            className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                          >
                            <option value={RESERVATION_STATUS.CONFIRMED}>Potwierdzona</option>
                            <option value={RESERVATION_STATUS.COMPLETED}>Zakończona</option>
                            <option value={RESERVATION_STATUS.NO_SHOW}>No-show</option>
                            <option value={RESERVATION_STATUS.CANCELLED_BY_ADMIN}>
                              Anulowana przez admina
                            </option>
                          </select>
                        </div>

                        <div>
                          <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                            Status płatności
                          </label>

                          <select
                            value={
                              reservation.payment_status || PAYMENT_STATUS.PAY_ON_SITE
                            }
                            disabled={isSaving}
                            onChange={(event) =>
                              updateReservation(reservation, {
                                payment_status: event.target.value,
                              })
                            }
                            className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                          >
                            <option value={PAYMENT_STATUS.PAY_ON_SITE}>
                              Płatność na miejscu
                            </option>
                            <option value={PAYMENT_STATUS.PAID}>Opłacona</option>
                            <option value={PAYMENT_STATUS.UNPAID}>Nieopłacona</option>
                            <option value={PAYMENT_STATUS.FREE}>Darmowa</option>
                            <option value={PAYMENT_STATUS.VOUCHER}>Voucher</option>
                          </select>
                        </div>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-sm">
                        <p className="text-zinc-500">Utworzono</p>

                        <p className="mt-1 text-xs text-zinc-300">
                          {reservation.created_at
                            ? new Date(reservation.created_at).toLocaleString(
                                "pl-PL"
                              )
                            : "brak danych"}
                        </p>

                        {isSaving && (
                          <p className="mt-4 text-xs font-semibold text-yellow-400">
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
      </section>
    </main>
  );
}


