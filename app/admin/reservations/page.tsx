"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { supabase } from "../../../lib/supabase";

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
  { label: "Potwierdzone", value: "confirmed" },
  { label: "Zakończone", value: "completed" },
  { label: "No-show", value: "no_show" },
  { label: "Anulowane", value: "cancelled" },
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

function getReservationStatusLabel(status: string | null) {
  switch (status) {
    case "confirmed":
      return "Potwierdzona";
    case "completed":
      return "Zakończona";
    case "no_show":
      return "No-show";
    case "cancelled":
    case "canceled":
    case "cancelled_by_user":
    case "cancelled_by_admin":
      return "Anulowana";
    default:
      return status || "Brak statusu";
  }
}

function getReservationStatusClass(status: string | null) {
  switch (status) {
    case "confirmed":
      return "border-green-700 bg-green-950 text-green-300";
    case "completed":
      return "border-blue-700 bg-blue-950 text-blue-300";
    case "no_show":
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case "cancelled":
    case "canceled":
    case "cancelled_by_user":
    case "cancelled_by_admin":
      return "border-red-700 bg-red-950 text-red-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
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

function getPaymentStatusClass(status: string | null) {
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
      if (statusFilter === "cancelled") {
        query = query.in("reservation_status", [
          "cancelled",
          "canceled",
          "cancelled_by_user",
          "cancelled_by_admin",
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

    const { error } = await supabase
      .from("reservations")
      .update(changes)
      .eq("id", reservation.id);

    setSavingReservationId(null);

    if (error) {
      setMessage(`Błąd zapisu rezerwacji: ${error.message}`);
      return;
    }

    setReservations((currentReservations) =>
      currentReservations.map((item) =>
        item.id === reservation.id ? { ...item, ...changes } : item
      )
    );

    setMessage("Zapisano zmiany w rezerwacji.");
  }

  function resetFilters() {
    setSearch("");
    setStatusFilter("all");
    setDateFilter("");
    setSort(DEFAULT_SORT);
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
          <div className="border-b border-zinc-800 px-5 py-4">
            <p className="text-sm text-zinc-400">
              Liczba rezerwacji w widoku:{" "}
              <span className="font-bold text-white">
                {reservations.length}
              </span>
            </p>
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
                            className={`rounded-full border px-3 py-1 text-xs font-bold ${getReservationStatusClass(
                              reservation.reservation_status
                            )}`}
                          >
                            {getReservationStatusLabel(
                              reservation.reservation_status
                            )}
                          </span>

                          <span
                            className={`rounded-full border px-3 py-1 text-xs font-bold ${getPaymentStatusClass(
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
                              reservation.reservation_status || "confirmed"
                            }
                            disabled={isSaving}
                            onChange={(event) =>
                              updateReservation(reservation, {
                                reservation_status: event.target.value,
                              })
                            }
                            className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                          >
                            <option value="confirmed">Potwierdzona</option>
                            <option value="completed">Zakończona</option>
                            <option value="no_show">No-show</option>
                            <option value="cancelled_by_admin">
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
                              reservation.payment_status || "pay_on_site"
                            }
                            disabled={isSaving}
                            onChange={(event) =>
                              updateReservation(reservation, {
                                payment_status: event.target.value,
                              })
                            }
                            className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                          >
                            <option value="pay_on_site">
                              Płatność na miejscu
                            </option>
                            <option value="paid">Opłacona</option>
                            <option value="unpaid">Nieopłacona</option>
                            <option value="free">Darmowa</option>
                            <option value="voucher">Voucher</option>
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