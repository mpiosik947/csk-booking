"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
  completeReservation,
  markNoShow,
  updateReservationPayment,
} from "../../../lib/reservation-actions";
import { getLaneRelationDisplay } from "../../../lib/admin/lane-relation-display";
import AdminShell from "../_components/AdminShell";

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
        id: string;
        name: string | null;
        resource_kind: string | null;
        parent_lane_id: string | null;
        display_order: number | null;
        is_active: boolean | null;
        parent_lane?: unknown;
      }
    | {
        id: string;
        name: string | null;
        resource_kind: string | null;
        parent_lane_id: string | null;
        display_order: number | null;
        is_active: boolean | null;
        parent_lane?: unknown;
      }[]
    | null;
};

type CancelReservationRpcResult = {
  changed: boolean;
  new_status?: string | null;
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
  return (
    getLaneRelationDisplay(reservation.shooting_lanes)?.displayName ??
    "Nieznana oś"
  );
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

function parseCancelReservationRpcResult(
  data: unknown
): CancelReservationRpcResult | null {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return null;
  }

  const result = data as Record<string, unknown>;

  if (typeof result.changed !== "boolean") {
    return null;
  }

  return {
    changed: result.changed,
    new_status:
      typeof result.new_status === "string" || result.new_status === null
        ? result.new_status
        : undefined,
  };
}

function getCancellationErrorMessage(error: {
  code?: string | null;
  message?: string | null;
}) {
  const code = error.code?.trim().toUpperCase() ?? "";

  if (code === "42501") {
    return "Nie masz uprawnień do anulowania tej rezerwacji.";
  }

  if (code === "P0002") {
    return "Nie znaleziono rezerwacji.";
  }

  if (code === "55000") {
    return "Rezerwacji w tym statusie nie można anulować.";
  }

  return "Nie udało się anulować rezerwacji. Spróbuj ponownie.";
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
  const cancellationInProgressRef = useRef<string | null>(null);
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
        .select(`
          id,
          name,
          resource_kind,
          parent_lane_id,
          display_order,
          is_active,
          parent_lane:shooting_lanes!parent_lane_id (
            id,
            name,
            resource_kind,
            parent_lane_id,
            display_order,
            is_active
          )
        `);

      if (!laneError && laneData) {
        matchingLaneIds = laneData
          .filter((lane) =>
            getLaneRelationDisplay(lane)
              ?.displayName.toLocaleLowerCase("pl")
              .includes(phrase.toLocaleLowerCase("pl"))
          )
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
          id,
          name,
          resource_kind,
          parent_lane_id,
          display_order,
          is_active,
          parent_lane:shooting_lanes!parent_lane_id (
            id,
            name,
            resource_kind,
            parent_lane_id,
            display_order,
            is_active
          )
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

  async function cancelReservationWithRpc(reservation: Reservation) {
    if (cancellationInProgressRef.current) {
      return;
    }

    cancellationInProgressRef.current = reservation.id;
    setSavingReservationId(reservation.id);
    setMessage("");

    try {
      const { data, error } = await supabase.rpc("cancel_reservation", {
        p_reservation_id: reservation.id,
      });

      if (error) {
        console.error("Admin reservation cancellation RPC failed", error);
        setMessage(getCancellationErrorMessage(error));
        return;
      }

      const result = parseCancelReservationRpcResult(data);

      if (!result) {
        console.error("Invalid cancel_reservation RPC response", data);
        setMessage("Nie udało się anulować rezerwacji. Spróbuj ponownie.");
        return;
      }

      await loadReservations();

      if (!result.changed) {
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
      } catch (emailError) {
        console.error("Reservation cancellation email failed", emailError);
        setMessage(
          "Rezerwacja została anulowana, ale nie udało się wysłać wiadomości e-mail."
        );
        return;
      }

      setMessage(
        "Rezerwacja została anulowana. Email anulowania został wysłany."
      );
    } catch (unexpectedError) {
      console.error(
        "Unexpected admin reservation cancellation error",
        unexpectedError
      );
      setMessage("Nie udało się anulować rezerwacji. Spróbuj ponownie.");
    } finally {
      cancellationInProgressRef.current = null;
      setSavingReservationId(null);
    }
  }

  async function updateReservation(
    reservation: Reservation,
    changes: Partial<Pick<Reservation, "reservation_status" | "payment_status">>
  ) {
    if (
      changes.reservation_status ===
      RESERVATION_STATUS.CANCELLED_BY_ADMIN
    ) {
      await cancelReservationWithRpc(reservation);
      return;
    }

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
    } else if (typeof changes.payment_status === "string") {
      result = await updateReservationPayment(supabase, {
        reservationId: reservation.id,
        paymentStatus: changes.payment_status,
      });
    }

    if (!result) {
      setSavingReservationId(null);
      setMessage(
        "Ta zmiana statusu nie jest dostępna w bieżącym stanie rezerwacji."
      );
      return;
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
    <AdminShell
      eyebrow="CSK Booking"
      title="Rezerwacje"
      description="Podgląd rezerwacji klientów, statusów płatności i obsługa wizyt."
      actions={
        <Link
          href="/admin"
          className="inline-flex min-h-11 w-full items-center justify-center rounded-xl border border-[#495044] px-5 py-3 text-sm font-semibold text-[#d8dbd3] transition hover:border-[#8b986f] hover:bg-[#1b211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] sm:w-auto"
        >
          ← Wróć do panelu
        </Link>
      }
    >
        <section
          aria-labelledby="reservation-filters-heading"
          className="mb-8 rounded-[1.5rem] border border-[#30372c] bg-[#101310] p-4 sm:p-6"
        >
          <div className="mb-5">
            <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">
              Widok operacyjny
            </p>
            <h2 id="reservation-filters-heading" className="mt-2 text-xl font-bold text-[#f2efe4]">
              Filtry rezerwacji
            </h2>
          </div>

          <div className="grid gap-4 lg:grid-cols-[minmax(16rem,1fr)_auto_auto_auto_auto] lg:items-end">
            <div>
              <label htmlFor="reservation-search" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
                Szukaj rezerwacji
              </label>

              <input
                id="reservation-search"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Imię, e-mail, telefon, oś, płatność, status..."
                className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none transition placeholder:text-[#70766d] focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
              />
            </div>

            <div>
              <label htmlFor="reservation-date" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
                Data
              </label>

              <input
                id="reservation-date"
                type="date"
                value={dateFilter}
                onChange={(event) => setDateFilter(event.target.value)}
                className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none transition focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
              />
            </div>

            <div>
              <label htmlFor="reservation-sort" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
                Sortowanie
              </label>

              <select
                id="reservation-sort"
                value={sort}
                onChange={(event) =>
                  setSort(event.target.value as ReservationSort)
                }
                className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none transition focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
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
              className="min-h-11 w-full rounded-xl bg-[#66724f] px-5 py-3 font-semibold text-white transition hover:bg-[#78865d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60 lg:w-auto"
            >
              {loading ? "Odświeżanie..." : "Odśwież"}
            </button>

            <button
              type="button"
              onClick={resetFilters}
              className="min-h-11 w-full rounded-xl border border-[#495044] px-5 py-3 font-semibold text-[#d8dbd3] transition hover:border-[#8b986f] hover:bg-[#1b211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] lg:w-auto"
            >
              Wyczyść filtry
            </button>
          </div>

          <div className="mt-6 border-t border-[#30372c] pt-5">
            <p id="reservation-status-filter-label" className="mb-3 text-sm font-semibold text-[#d8dbd3]">
              Status rezerwacji
            </p>

            <div className="flex flex-wrap gap-2" aria-labelledby="reservation-status-filter-label">
              {statusOptions.map((status) => (
                <button
                  key={status.value}
                  type="button"
                  onClick={() => setStatusFilter(status.value)}
                  aria-pressed={statusFilter === status.value}
                  className={
                    statusFilter === status.value
                      ? "min-h-11 rounded-full border border-[#8b986f] bg-[#313a29] px-4 py-2 text-sm font-semibold text-[#f2efe4] shadow-[inset_0_0_0_1px_rgba(215,200,149,0.12)]"
                      : "min-h-11 rounded-full border border-[#3b4237] bg-[#090b09] px-4 py-2 text-sm font-semibold text-[#a9ada4] transition hover:border-[#66724f] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                  }
                >
                  {status.label}
                </button>
              ))}
            </div>
          </div>

          <div className="mt-5 rounded-xl border border-[#30372c] bg-[#090b09] px-4 py-3 text-sm text-[#a9ada4]">
            Aktywne sortowanie:{" "}
            <span className="font-bold text-[#f2efe4]">{activeSortLabel}</span>
          </div>
        </section>

        {message && (
          <div role="status" className="mb-6 rounded-xl border border-[#495044] bg-[#1b211b] p-4 text-sm font-semibold text-[#d8dbd3]">
            {message}
          </div>
        )}

        <section aria-labelledby="reservation-list-heading" className="overflow-hidden rounded-[1.5rem] border border-[#30372c] bg-[#101310]">
          <div className="flex flex-col gap-4 border-b border-[#30372c] px-4 py-5 sm:flex-row sm:items-center sm:justify-between sm:px-6">
            <div>
              <h2 id="reservation-list-heading" className="text-xl font-bold text-[#f2efe4]">Lista rezerwacji</h2>
              <p className="mt-1 text-sm text-[#a9ada4]">
              Liczba rezerwacji w widoku:{" "}
              <span className="font-bold text-[#f2efe4]">
                {reservations.length}
              </span>
              </p>
            </div>

            <button
              type="button"
              onClick={downloadReservationsCsv}
              disabled={!urlParamsLoaded || loading || reservations.length === 0}
              className="min-h-11 w-full rounded-xl border border-[#66724f] bg-[#20281c] px-4 py-2 text-sm font-semibold text-[#c7d6b2] transition hover:bg-[#2b3525] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
            >
              Eksport CSV
            </button>
          </div>

          {!urlParamsLoaded || loading ? (
            <div className="p-8 text-center text-[#a9ada4]">Ładowanie rezerwacji...</div>
          ) : reservations.length === 0 ? (
            <div className="p-8 text-center">
              <p className="font-semibold text-[#d8dbd3]">Brak rezerwacji do wyświetlenia.</p>
              <p className="mt-2 text-sm text-[#858b82]">Zmień filtry albo wybierz inną datę.</p>
            </div>
          ) : (
            <div className="grid gap-4 p-3 sm:p-5">
              {reservations.map((reservation, index) => {
                const isSaving = savingReservationId === reservation.id;

                return (
                  <article
                    key={reservation.id}
                    className={`rounded-[1.25rem] border border-[#30372c] p-4 transition hover:border-[#485043] sm:p-5 ${
                      index % 2 === 0 ? "bg-[#090b09]" : "bg-[#141814]"
                    }`}
                  >
                    <div className="mb-5 flex flex-wrap gap-2 border-b border-[#30372c] pb-4">
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

                    <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-[1.15fr_0.8fr_0.9fr_1.05fr] xl:items-start">
                      <div className="min-w-0">

                        <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#858b82]">
                          Klient
                        </p>

                        <h3 className="mt-2 break-words text-lg font-bold text-[#f2efe4]">
                          {reservation.customer_name || "Brak danych"}
                        </h3>

                        <p className="mt-1 break-all text-sm text-[#b7bbb2]">
                          {reservation.customer_email || "Brak e-maila"}
                        </p>

                        <p className="mt-1 text-sm text-[#858b82]">
                          Tel.: {reservation.customer_phone || "brak"}
                        </p>
                      </div>

                      <div>
                        <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#858b82]">
                          Termin
                        </p>

                        <p className="mt-2 text-lg font-bold text-[#f2efe4]">
                          {reservation.reservation_date || "Brak daty"}
                        </p>

                        <p className="mt-1 text-sm text-[#b7bbb2]">
                          {normalizeTime(reservation.start_time)}–
                          {normalizeTime(reservation.end_time)}
                        </p>

                        <p className="mt-1 text-sm text-[#858b82]">
                          {reservation.duration_minutes ?? 0} min
                        </p>
                      </div>

                      <div className="min-w-0">
                        <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#858b82]">
                          Oś
                        </p>

                        <p className="mt-2 break-words text-lg font-bold text-[#f2efe4]">
                          {getLaneName(reservation)}
                        </p>

                        <p className="mt-1 text-sm font-semibold text-[#a9c58f]">
                          {Number(reservation.price ?? 0).toFixed(0)} zł
                        </p>
                      </div>

                      <div className="grid gap-4 rounded-xl border border-[#30372c] bg-[#101310] p-4 md:col-span-2 xl:col-span-1">
                        <div>
                          <label className="mb-2 block text-xs font-bold uppercase tracking-[0.2em] text-[#858b82]">
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
                            className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-sm text-[#f2efe4] outline-none transition focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30 disabled:opacity-60"
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
                          <label className="mb-2 block text-xs font-bold uppercase tracking-[0.2em] text-[#858b82]">
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
                            className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-sm text-[#f2efe4] outline-none transition focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30 disabled:opacity-60"
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

                      <div className="md:col-span-2 xl:col-span-4 xl:flex xl:items-center xl:justify-between xl:border-t xl:border-[#30372c] xl:pt-4">
                        <p className="text-xs text-[#858b82]">
                          Utworzono:{" "}
                          <span className="text-[#b7bbb2]">
                          {reservation.created_at
                            ? new Date(reservation.created_at).toLocaleString(
                                "pl-PL"
                              )
                            : "brak danych"}
                          </span>
                        </p>

                        {isSaving && (
                          <p className="mt-2 text-xs font-semibold text-[#d7c895] xl:mt-0">
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
        </section>
    </AdminShell>
  );
}
