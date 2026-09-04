"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import AdminShell from "../_components/AdminShell";
import {
  getPaymentStatusBadgeClass,
  getPaymentStatusLabel,
  isPaidPaymentStatus,
} from "../../../lib/payment-status";
import {
  getReservationStatusBadgeClass,
  getReservationStatusLabel,
  isCancelledReservationStatus,
  RESERVATION_STATUS,
} from "../../../lib/reservation-status";
import { supabase } from "../../../lib/supabase";
import { getLaneRelationDisplay } from "../../../lib/admin/lane-relation-display";
import {
  calculateHierarchyUtilization,
  fetchCompleteReportDataset,
  REPORT_PAGE_SIZE,
  type ReportLane,
} from "../../../lib/admin/reports";
import { reportClientError } from "../../../lib/safe-client-error";

type ReportMode = "day" | "week" | "month" | "year";

type Reservation = {
  id: string;
  customer_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  reservation_date: string;
  start_time: string;
  end_time: string;
  duration_minutes: number | null;
  price: number | null;
  reservation_status: string;
  payment_status: string;
  lane_id: string | null;
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

function addDays(date: Date, days: number) {
  const copy = new Date(date);
  copy.setDate(copy.getDate() + days);
  return copy;
}

function formatDateInput(date: Date) {
  return date.toISOString().slice(0, 10);
}

function getDateRange(mode: ReportMode, selectedDate: string) {
  const start = new Date(`${selectedDate}T12:00:00`);

  if (mode === "day") {
    return {
      startDate: formatDateInput(start),
      endDate: formatDateInput(start),
      label: selectedDate,
    };
  }

  if (mode === "week") {
    const day = start.getDay();
    const diffToMonday = day === 0 ? -6 : 1 - day;
    const monday = addDays(start, diffToMonday);
    const sunday = addDays(monday, 6);

    return {
      startDate: formatDateInput(monday),
      endDate: formatDateInput(sunday),
      label: `${formatDateInput(monday)} - ${formatDateInput(sunday)}`,
    };
  }

  if (mode === "month") {
    const firstDay = new Date(start.getFullYear(), start.getMonth(), 1, 12);
    const lastDay = new Date(start.getFullYear(), start.getMonth() + 1, 0, 12);

    return {
      startDate: formatDateInput(firstDay),
      endDate: formatDateInput(lastDay),
      label: `${String(start.getMonth() + 1).padStart(2, "0")}.${start.getFullYear()}`,
    };
  }

  const firstDay = new Date(start.getFullYear(), 0, 1, 12);
  const lastDay = new Date(start.getFullYear(), 11, 31, 12);

  return {
    startDate: formatDateInput(firstDay),
    endDate: formatDateInput(lastDay),
    label: `${start.getFullYear()}`,
  };
}

function getBadgeClass(baseClass: string) {
  return `rounded-full border px-3 py-1 text-xs font-semibold ${baseClass}`;
}

function formatTimeRange(startTime: string, endTime: string) {
  return `${startTime.slice(0, 5)}-${endTime.slice(0, 5)}`;
}

export default function AdminReportsPage() {
  const today = new Date().toISOString().slice(0, 10);

  const [reportMode, setReportMode] = useState<ReportMode>("day");
  const [selectedDate, setSelectedDate] = useState(today);
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [reportLanes, setReportLanes] = useState<ReportLane[]>([]);
  const [loading, setLoading] = useState(true);
  const [hasAccess, setHasAccess] = useState(false);
  const [reportReady, setReportReady] = useState(false);
  const [message, setMessage] = useState("");
  const reportRequestRef = useRef(0);

  const range = getDateRange(reportMode, selectedDate);

  const loadReport = useCallback(async () => {
    const requestId = ++reportRequestRef.current;
    setLoading(true);
    setMessage("");
    setHasAccess(false);
    setReportReady(false);

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (requestId !== reportRequestRef.current) return;

    if (!user) {
      setMessage("Musisz być zalogowany jako administrator.");
      setLoading(false);
      return;
    }

    const { data: roleData, error: roleError } = await supabase.rpc(
      "get_my_role",
    );

    if (requestId !== reportRequestRef.current) return;

    if (roleError) {
      reportClientError("Admin reports role read failed", roleError);
      setMessage("Nie udało się sprawdzić uprawnień. Spróbuj ponownie.");
      setLoading(false);
      return;
    }

    if (roleData !== "admin") {
      setMessage("Brak dostępu do raportów administratora.");
      setLoading(false);
      return;
    }

    setHasAccess(true);

    const { count: expectedLanesCount, error: lanesCountError } = await supabase
      .from("shooting_lanes")
      .select("id", { count: "exact", head: true });

    if (requestId !== reportRequestRef.current) return;

    if (lanesCountError || expectedLanesCount === null) {
      setMessage("Nie udało się pobrać kompletnego zestawu danych raportu.");
      setLoading(false);
      return;
    }

    const completeLanes = await fetchCompleteReportDataset<ReportLane>(
      expectedLanesCount,
      async (from, to) => {
        const { data, error } = await supabase
          .from("shooting_lanes")
          .select(
            "id,name,resource_kind,parent_lane_id,display_order,is_active,whole_lane_bookable,positions_bookable,lane_booking_rules(online_bookable)",
          )
          .order("display_order", { ascending: true })
          .order("id", { ascending: true })
          .range(from, to);

        return error ? null : ((data as unknown as ReportLane[]) ?? []);
      },
      REPORT_PAGE_SIZE,
    );

    if (requestId !== reportRequestRef.current) return;

    if (!completeLanes.ok) {
      setMessage("Nie udało się pobrać kompletnego zestawu danych raportu.");
      setLoading(false);
      return;
    }

    const reservationSelect = `
        id,
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
      `;

    const { count: expectedCount, error: countError } = await supabase
      .from("reservations")
      .select("id", { count: "exact", head: true })
      .gte("reservation_date", range.startDate)
      .lte("reservation_date", range.endDate);

    if (requestId !== reportRequestRef.current) return;

    if (countError || expectedCount === null) {
      setMessage("Nie udało się pobrać kompletnego zestawu danych raportu.");
      setLoading(false);
      return;
    }

    const completeDataset = await fetchCompleteReportDataset<Reservation>(
      expectedCount,
      async (from, to) => {
        const { data, error } = await supabase
          .from("reservations")
          .select(reservationSelect)
          .gte("reservation_date", range.startDate)
          .lte("reservation_date", range.endDate)
          .order("reservation_date", { ascending: true })
          .order("start_time", { ascending: true })
          .order("id", { ascending: true })
          .range(from, to);

        return error ? null : ((data as unknown as Reservation[]) ?? []);
      },
      REPORT_PAGE_SIZE,
    );

    if (requestId !== reportRequestRef.current) return;

    if (!completeDataset.ok) {
      setMessage("Nie udało się pobrać kompletnego zestawu danych raportu.");
      setLoading(false);
      return;
    }

    setReportLanes(completeLanes.rows);
    setReservations(completeDataset.rows);
    setReportReady(true);
    setLoading(false);
  }, [range.endDate, range.startDate]);

  useEffect(() => {
    // Report data is an external Supabase resource synchronized to the selected range.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadReport();
  }, [loadReport]);


  const activeReservations = reservations.filter(
    (reservation) =>
      !isCancelledReservationStatus(reservation.reservation_status) &&
      reservation.reservation_status !== RESERVATION_STATUS.NO_SHOW,
  );

  const paidReservations = activeReservations.filter((reservation) =>
    isPaidPaymentStatus(reservation.payment_status),
  );

  const cancelledReservations = reservations.filter((reservation) =>
    isCancelledReservationStatus(reservation.reservation_status),
  );

  const noShowReservations = reservations.filter(
    (reservation) => reservation.reservation_status === RESERVATION_STATUS.NO_SHOW,
  );

  const totalRevenue = activeReservations.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0,
  );

  const paidRevenue = paidReservations.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0,
  );

  const unpaidRevenue = activeReservations
    .filter((reservation) => !isPaidPaymentStatus(reservation.payment_status))
    .reduce((sum, reservation) => sum + Number(reservation.price ?? 0), 0);

  const daysInRange =
    (new Date(`${range.endDate}T12:00:00`).getTime() -
      new Date(`${range.startDate}T12:00:00`).getTime()) /
      (1000 * 60 * 60 * 24) +
    1;

  const utilization = calculateHierarchyUtilization(
    reportLanes,
    activeReservations,
    daysInRange,
  );
  const occupancy = utilization.ok ? utilization.utilizationPercent : 0;

  const bestDay = Object.entries(
    activeReservations.reduce<Record<string, number>>((acc, reservation) => {
      acc[reservation.reservation_date] =
        (acc[reservation.reservation_date] ?? 0) +
        Number(reservation.price ?? 0);
      return acc;
    }, {}),
  ).sort((a, b) => b[1] - a[1])[0];

  const topLane = Object.entries(
    activeReservations.reduce<Record<string, number>>((acc, reservation) => {
      const laneName = getLaneName(reservation);
      acc[laneName] = (acc[laneName] ?? 0) + 1;
      return acc;
    }, {}),
  ).sort((a, b) => b[1] - a[1])[0];

  return (
    <AdminShell
      eyebrow="CSK Booking"
      title="Raport"
      description="Rezerwacje, przychód i szacowane obłożenie osi."
      actions={
        <Link href="/admin" className="inline-flex min-h-11 w-full items-center justify-center rounded-xl border border-[#495044] px-5 py-3 text-sm font-semibold text-[#d8dbd3] transition hover:border-[#8b986f] hover:bg-[#1b211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] sm:w-auto">
          ← Wróć do panelu
        </Link>
      }
    >

        <section aria-labelledby="report-range-heading" className="mb-8 rounded-[1.5rem] border border-[#30372c] bg-[#101310] p-4 sm:p-6">
          <div className="mb-5">
            <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">Parametry raportu</p>
            <h2 id="report-range-heading" className="mt-2 text-xl font-bold">Zakres raportu</h2>
          </div>
          <div className="grid gap-5 md:grid-cols-2">
          <div>
            <label htmlFor="report-mode" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
              Zakres raportu
            </label>

            <select
              id="report-mode"
              value={reportMode}
              onChange={(event) =>
                setReportMode(event.target.value as ReportMode)
              }
              className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
            >
              <option value="day">Dzień</option>
              <option value="week">Tydzień</option>
              <option value="month">Miesiąc</option>
              <option value="year">Rok</option>
            </select>
          </div>

          <div>
            <label htmlFor="report-date" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
              Data odniesienia
            </label>

            <input
              id="report-date"
              type="date"
              value={selectedDate}
              onChange={(event) => setSelectedDate(event.target.value)}
              className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
            />
          </div>

          <div className="rounded-xl border border-[#30372c] bg-[#090b09] p-4 text-sm text-[#a9ada4] md:col-span-2">
            Wybrany zakres:{" "}
            <span className="font-semibold text-[#c7d6b2]">
              {range.startDate} - {range.endDate}
            </span>
          </div>
          </div>
        </section>

        {loading && (
          <div className="rounded-xl border border-[#30372c] bg-[#101310] p-6 text-[#a9ada4]">
            Ładowanie raportu...
          </div>
        )}

        {!loading && message && (
          <div role="alert" className="rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]">
            {message}
          </div>
        )}

        {!loading && hasAccess && reportReady && !utilization.ok && (
          <div role="alert" className="rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]">
            Nie udało się pobrać kompletnego zestawu danych raportu.
          </div>
        )}

        {!loading && hasAccess && reportReady && utilization.ok && (
          <>
            <section aria-labelledby="report-kpi-heading" className="mb-8">
              <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">Podsumowanie</p>
              <h2 id="report-kpi-heading" className="mb-4 mt-2 text-xl font-bold">Kluczowe wskaźniki</h2>
              <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
              <div className="rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Rezerwacje aktywne</p>
                <p className="mt-3 text-3xl font-bold">
                  {activeReservations.length}
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#36523a] bg-[#111b13] p-5">
                <p className="text-sm text-[#a9ada4]">Przychód planowany</p>
                <p className="mt-3 text-3xl font-bold text-[#a9c58f]">
                  {totalRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#36523a] bg-[#111b13] p-5">
                <p className="text-sm text-[#a9ada4]">Przychód opłacony</p>
                <p className="mt-3 text-3xl font-bold text-[#a9c58f]">
                  {paidRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Obłożenie osi</p>
                <p className="mt-3 text-3xl font-bold text-[#d7c895]">
                  {occupancy}%
                </p>
              </div>
              <div className="rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Nieopłacone / na miejscu</p>
                <p className="mt-3 text-3xl font-bold text-[#d7c895]">
                  {unpaidRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#603d3d] bg-[#211515] p-5">
                <p className="text-sm text-[#a9ada4]">Anulowane</p>
                <p className="mt-3 text-3xl font-bold text-[#d99b9b]">
                  {cancelledReservations.length}
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Nieobecności</p>
                <p className="mt-3 text-3xl font-bold text-[#d7c895]">
                  {noShowReservations.length}
                </p>
              </div>

              <div className="min-w-0 rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Najczęściej używana oś</p>
                <p className="mt-3 break-words text-xl font-bold">{topLane ? topLane[0] : "Brak"}</p>
                {topLane ? <p className="mt-2 text-sm text-[#858b82]">{topLane[1]} rez.</p> : null}
              </div>
              </div>
            </section>

            <div className="mb-8 grid gap-4 md:grid-cols-2">
              <div className="rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Najlepszy dzień</p>
                <p className="mt-3 text-xl font-bold">
                  {bestDay
                    ? `${bestDay[0]} / ${bestDay[1].toFixed(0)} zł`
                    : "Brak"}
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Założenie obłożenia</p>
                <p className="mt-3 text-xl font-bold">
                  {utilization.ok ? utilization.effectiveCapacity : 0} efektywnych jednostek zasobu x 16h dziennie x {daysInRange} dni
                </p>
              </div>
            </div>

            <section aria-labelledby="report-table-heading" className="rounded-[1.5rem] border border-[#30372c] bg-[#101310] p-4 sm:p-6">
              <div className="mb-5 border-b border-[#30372c] pb-5">
                <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">Szczegóły</p>
                <h2 id="report-table-heading" className="mt-2 text-2xl font-bold">Rezerwacje w okresie</h2>
              </div>

              {reservations.length === 0 ? (
                <div className="rounded-xl border border-[#30372c] bg-[#090b09] p-6 text-center">
                  <p className="font-semibold text-[#d8dbd3]">Brak rezerwacji w wybranym okresie.</p>
                  <p className="mt-2 text-sm text-[#858b82]">Wybierz inny zakres raportu albo datę odniesienia.</p>
                </div>
              ) : (
                <div className="max-w-full overflow-x-auto overscroll-x-contain rounded-xl border border-[#30372c]" tabIndex={0} aria-label="Tabela rezerwacji w okresie">
                  <table className="w-full min-w-[1100px] text-left text-sm">
                    <thead className="bg-[#090b09]">
                      <tr className="border-b border-[#30372c] text-[#a9ada4]">
                        <th className="py-3 pr-4">Data</th>
                        <th className="py-3 pr-4">Godzina</th>
                        <th className="py-3 pr-4">Oś</th>
                        <th className="py-3 pr-4">Klient</th>
                        <th className="py-3 pr-4">Email</th>
                        <th className="py-3 pr-4">Telefon</th>
                        <th className="py-3 pr-4">Cena</th>
                        <th className="py-3 pr-4">Status</th>
                        <th className="py-3 pr-4">Płatność</th>
                      </tr>
                    </thead>

                    <tbody>
                      {reservations.map((reservation) => (
                        <tr
                          key={reservation.id}
                          className="border-b border-[#30372c] text-[#d8dbd3] transition last:border-0 hover:bg-[#181d18]"
                        >
                          <td className="py-4 pr-4 font-medium text-[#f2efe4]">
                            {reservation.reservation_date}
                          </td>

                          <td className="py-4 pr-4 font-semibold">
                            {formatTimeRange(
                              reservation.start_time,
                              reservation.end_time,
                            )}
                          </td>

                          <td className="py-4 pr-4">
                            {getLaneName(reservation)}
                          </td>

                          <td className="py-4 pr-4 font-semibold">
                            {reservation.customer_name ?? "-"}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.customer_email ?? "-"}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.customer_phone ?? "-"}
                          </td>

                          <td className="py-4 pr-4 text-right font-semibold text-[#a9c58f]">
                            {Number(reservation.price ?? 0).toFixed(0)} zł
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
                              className={getBadgeClass(
                                getPaymentStatusBadgeClass(
                                  reservation.payment_status,
                                ),
                              )}
                            >
                              {getPaymentStatusLabel(
                                reservation.payment_status,
                              )}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          </>
        )}
    </AdminShell>
  );
}

