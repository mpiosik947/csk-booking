"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import AdminShell from "../_components/AdminShell";
import {
  getPaymentStatusBadgeClass,
  getPaymentStatusLabel,
} from "../../../lib/payment-status";
import {
  getReservationStatusBadgeClass,
  getReservationStatusLabel,
} from "../../../lib/reservation-status";
import { supabase } from "../../../lib/supabase";
import {
  buildAdminReservationCsv,
  buildReportSearchParams,
  countReportDaysInclusive,
  getWarsawToday,
  parseAdminReservationReport,
  parseAdminReservationExport,
  parseReportFiltersFromSearchParams,
  reportFiltersEqual,
  REPORT_DETAIL_PAGE_SIZE,
  REPORT_EXPORT_MAX_ROWS,
  type AdminReportFilters,
  type AdminReservationReport,
  type ReportDetail,
} from "../../../lib/admin/reports";
import { reportClientError } from "../../../lib/safe-client-error";

function getBadgeClass(baseClass: string) {
  return `rounded-full border px-3 py-1 text-xs font-semibold ${baseClass}`;
}

function formatTimeRange(startTime: string, endTime: string) {
  return `${startTime.slice(0, 5)}-${endTime.slice(0, 5)}`;
}

function getBookingTypeLabel(resourceKind: ReportDetail["resourceKind"]) {
  return resourceKind === "position" ? "Pojedyncze stanowisko" : "Cała oś";
}

export default function AdminReportsPage() {
  const today = getWarsawToday();

  const [filters, setFilters] = useState<AdminReportFilters>({
    startDate: today,
    endDate: today,
    resourceId: null,
    reservationStatus: null,
    paymentStatus: null,
    bookingType: null,
  });
  const [filtersReady, setFiltersReady] = useState(false);
  const [report, setReport] = useState<AdminReservationReport | null>(null);
  const [detailOffset, setDetailOffset] = useState(0);
  const [loading, setLoading] = useState(true);
  const [exporting, setExporting] = useState(false);
  const [hasAccess, setHasAccess] = useState(false);
  const [reportReady, setReportReady] = useState(false);
  const [message, setMessage] = useState("");
  const [exportMessage, setExportMessage] = useState("");
  const reportRequestRef = useRef(0);

  useEffect(() => {
    const applyUrlFilters = () => {
      const parsed = parseReportFiltersFromSearchParams(
        new URLSearchParams(window.location.search),
        today,
      );
      if (!parsed.ok) {
        setMessage("Nieprawidłowe filtry raportu w adresie strony.");
        setLoading(false);
        setFiltersReady(false);
        return;
      }
      setDetailOffset(0);
      setFilters(parsed.filters);
      setFiltersReady(true);
    };
    applyUrlFilters();
    window.addEventListener("popstate", applyUrlFilters);
    return () => window.removeEventListener("popstate", applyUrlFilters);
  }, [today]);

  const updateFilters = (changes: Partial<AdminReportFilters>) => {
    setDetailOffset(0);
    setExportMessage("");
    const next = { ...filters, ...changes };
    const query = buildReportSearchParams(next).toString();
    window.history.pushState(null, "", `${window.location.pathname}?${query}`);
    setFilters(next);
  };

  const loadReport = useCallback(async () => {
    const requestId = ++reportRequestRef.current;
    setLoading(true);
    setMessage("");
    setHasAccess(false);
    setReportReady(false);

    const days = countReportDaysInclusive(filters.startDate, filters.endDate);
    if (days === null || days > 366) {
      setMessage("Nieprawidłowy zakres raportu.");
      setLoading(false);
      return;
    }

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

    const { data, error } = await supabase.rpc(
      "admin_get_reservation_report_v2",
      {
        p_start_date: filters.startDate,
        p_end_date: filters.endDate,
        p_resource_id: filters.resourceId,
        p_reservation_status: filters.reservationStatus,
        p_payment_status: filters.paymentStatus,
        p_booking_type: filters.bookingType,
        p_detail_limit: REPORT_DETAIL_PAGE_SIZE,
        p_detail_offset: detailOffset,
      },
    );

    if (requestId !== reportRequestRef.current) return;

    if (error) {
      reportClientError("Admin reservation report read failed", error);
      setMessage("Nie udało się pobrać kompletnego zestawu danych raportu.");
      setLoading(false);
      return;
    }

    const parsedReport = parseAdminReservationReport(data);
    if (!parsedReport || !reportFiltersEqual(parsedReport.filters, filters)) {
      setMessage("Nie udało się pobrać kompletnego zestawu danych raportu.");
      setLoading(false);
      return;
    }

    setReport(parsedReport);
    setReportReady(true);
    setLoading(false);
  }, [detailOffset, filters]);

  useEffect(() => {
    // Report data is an external Supabase resource synchronized to the selected range.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (filtersReady) void loadReport();
  }, [filtersReady, loadReport]);

  const exportCsv = async () => {
    const exportFilters = filters;
    setExporting(true);
    setExportMessage("");
    const { data, error } = await supabase.rpc(
      "admin_get_reservation_report_export_v1",
      {
        p_start_date: exportFilters.startDate,
        p_end_date: exportFilters.endDate,
        p_resource_id: exportFilters.resourceId,
        p_reservation_status: exportFilters.reservationStatus,
        p_payment_status: exportFilters.paymentStatus,
        p_booking_type: exportFilters.bookingType,
      },
    );
    if (error) {
      reportClientError("Admin reservation report export failed", error);
      setExportMessage("Nie udało się przygotować eksportu CSV.");
      setExporting(false);
      return;
    }
    const parsed = parseAdminReservationExport(data);
    if (!parsed) {
      setExportMessage("Nie udało się przygotować eksportu CSV.");
      setExporting(false);
      return;
    }
    if (!parsed.ok) {
      setExportMessage(
        `Eksport obejmuje ${parsed.total} rekordów. Zawęź filtry do maksymalnie ${REPORT_EXPORT_MAX_ROWS}.`,
      );
      setExporting(false);
      return;
    }
    const blob = new Blob([buildAdminReservationCsv(parsed.export.rows)], {
      type: "text/csv;charset=utf-8",
    });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `rezerwacje-${exportFilters.startDate}-${exportFilters.endDate}.csv`;
    anchor.click();
    URL.revokeObjectURL(url);
    setExportMessage(`Wyeksportowano ${parsed.export.total} rekordów.`);
    setExporting(false);
  };


  const reservations: ReportDetail[] = report?.details ?? [];
  const summary = report?.summary ?? null;
  const hasPreviousPage = Boolean(report && report.pagination.offset > 0);
  const hasNextPage = Boolean(
    report &&
      report.pagination.offset + report.details.length < report.pagination.total,
  );
  const currentPage = report
    ? Math.floor(report.pagination.offset / REPORT_DETAIL_PAGE_SIZE) + 1
    : 1;
  const totalPages = report
    ? Math.max(1, Math.ceil(report.pagination.total / REPORT_DETAIL_PAGE_SIZE))
    : 1;
  const hasExportableRows = Boolean(
    reportReady && report && report.pagination.total > 0,
  );
  const retryableError = message.startsWith("Nie udało się");

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
          <div className="grid min-w-0 gap-5 md:grid-cols-2 xl:grid-cols-3">
          <div>
            <label htmlFor="report-from" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
              Data od
            </label>
            <input
              id="report-from"
              type="date"
              value={filters.startDate}
              onChange={(event) => {
                updateFilters({ startDate: event.target.value });
              }}
              className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
            />
          </div>

          <div>
            <label htmlFor="report-to" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
              Data do
            </label>
            <input
              id="report-to"
              type="date"
              value={filters.endDate}
              onChange={(event) => {
                updateFilters({ endDate: event.target.value });
              }}
              className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
            />
          </div>

          <div>
            <label htmlFor="report-resource" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">Oś lub stanowisko</label>
            <select id="report-resource" value={filters.resourceId ?? ""} onChange={(event) => updateFilters({ resourceId: event.target.value || null })} className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4]">
              <option value="">Wszystkie zasoby</option>
              {report?.filterOptions.resources.map((resource) => (
                <option key={resource.id} value={resource.id}>{resource.displayName}</option>
              ))}
            </select>
          </div>

          <div>
            <label htmlFor="report-status" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">Status rezerwacji</label>
            <select id="report-status" value={filters.reservationStatus ?? ""} onChange={(event) => updateFilters({ reservationStatus: (event.target.value || null) as AdminReportFilters["reservationStatus"] })} className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4]">
              <option value="">Wszystkie statusy</option>
              <option value="confirmed">Potwierdzone</option><option value="completed">Zakończone</option><option value="cancelled">Anulowane</option><option value="no_show">Nieobecności</option>
            </select>
          </div>

          <div>
            <label htmlFor="report-payment" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">Status płatności</label>
            <select id="report-payment" value={filters.paymentStatus ?? ""} onChange={(event) => updateFilters({ paymentStatus: (event.target.value || null) as AdminReportFilters["paymentStatus"] })} className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4]">
              <option value="">Wszystkie płatności</option>
              <option value="paid">Opłacone</option><option value="paid_on_site">Opłacone na miejscu</option><option value="unpaid">Nieopłacone</option><option value="pay_on_site">Płatność na miejscu</option><option value="free">Gratis</option><option value="voucher">Voucher</option>
            </select>
          </div>

          <div>
            <label htmlFor="report-type" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">Typ rezerwacji</label>
            <select id="report-type" value={filters.bookingType ?? ""} onChange={(event) => updateFilters({ bookingType: (event.target.value || null) as AdminReportFilters["bookingType"] })} className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4]">
              <option value="">Wszystkie typy</option><option value="whole_lane">Cała oś</option><option value="single_position">Pojedyncze stanowisko</option>
            </select>
          </div>

          <div className="flex flex-col gap-3 md:col-span-2 sm:flex-row xl:col-span-3">
            <button type="button" onClick={() => updateFilters({ startDate: today, endDate: today, resourceId: null, reservationStatus: null, paymentStatus: null, bookingType: null })} className="min-h-11 w-full rounded-xl border border-[#495044] px-5 py-3 text-sm font-semibold transition hover:border-[#8b986f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] sm:w-auto">Wyczyść filtry</button>
            <button type="button" aria-describedby={!hasExportableRows && reportReady ? "report-export-empty" : undefined} disabled={!hasExportableRows || exporting} onClick={() => void exportCsv()} className="min-h-11 w-full rounded-xl border border-[#8b986f] bg-[#1b211b] px-5 py-3 text-sm font-semibold text-[#e8eddc] transition hover:bg-[#242c23] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto">{exporting ? "Przygotowywanie CSV..." : "Eksportuj CSV"}</button>
          </div>

          {reportReady && report?.pagination.total === 0 ? <p id="report-export-empty" className="text-sm text-[#a9ada4] md:col-span-2 xl:col-span-3">Brak danych do eksportu dla aktywnych filtrów.</p> : null}
          {exportMessage ? <p role="status" className="text-sm text-[#c7d6b2] md:col-span-2 xl:col-span-3">{exportMessage}</p> : null}
          </div>
        </section>

        {loading && (
          <div role="status" aria-live="polite" className="flex min-h-24 items-center gap-3 rounded-xl border border-[#30372c] bg-[#101310] p-6 text-[#d8dbd3]">
            <span aria-hidden="true" className="size-5 animate-spin rounded-full border-2 border-[#495044] border-t-[#d7c895]" />
            <span>Ładowanie raportu...</span>
          </div>
        )}

        {!loading && message && (
          <div role="alert" className="rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm text-[#e0a0a0]">
            <p className="font-semibold">{message}</p>
            {retryableError ? (
              <button type="button" onClick={() => void loadReport()} className="mt-4 min-h-11 w-full rounded-xl border border-[#a86f6f] px-4 py-2 font-semibold transition hover:bg-[#3a2222] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] sm:w-auto">
                Spróbuj ponownie
              </button>
            ) : null}
          </div>
        )}

        {!loading && hasAccess && reportReady && report && summary && (
          <>
            <section aria-labelledby="report-kpi-heading" className="mb-8">
              <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">Podsumowanie</p>
              <h2 id="report-kpi-heading" className="mb-4 mt-2 text-xl font-bold">Kluczowe wskaźniki</h2>
              <div className="grid min-w-0 gap-4 sm:grid-cols-2 xl:grid-cols-4">
              <div className="min-w-0 rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Rezerwacje aktywne</p>
                <p className="mt-3 break-words text-2xl font-bold tabular-nums sm:text-3xl">
                  {summary.activeReservationCount}
                </p>
              </div>

              <div className="min-w-0 rounded-[1.25rem] border border-[#36523a] bg-[#111b13] p-5">
                <p className="text-sm text-[#a9ada4]">Przychód planowany</p>
                <p className="mt-3 break-words text-2xl font-bold tabular-nums text-[#a9c58f] sm:text-3xl">
                  {summary.plannedRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="min-w-0 rounded-[1.25rem] border border-[#36523a] bg-[#111b13] p-5">
                <p className="text-sm text-[#a9ada4]">Przychód opłacony</p>
                <p className="mt-3 break-words text-2xl font-bold tabular-nums text-[#a9c58f] sm:text-3xl">
                  {summary.paidRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="min-w-0 rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Obłożenie osi</p>
                <p className="mt-3 break-words text-2xl font-bold tabular-nums text-[#d7c895] sm:text-3xl">
                  {summary.occupancyPercent}%
                </p>
              </div>
              <div className="min-w-0 rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Nieopłacone / na miejscu</p>
                <p className="mt-3 break-words text-2xl font-bold tabular-nums text-[#d7c895] sm:text-3xl">
                  {summary.outstandingRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="min-w-0 rounded-[1.25rem] border border-[#603d3d] bg-[#211515] p-5">
                <p className="text-sm text-[#a9ada4]">Anulowane</p>
                <p className="mt-3 break-words text-2xl font-bold tabular-nums text-[#d99b9b] sm:text-3xl">
                  {summary.cancelledReservationCount}
                </p>
              </div>

              <div className="min-w-0 rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Nieobecności</p>
                <p className="mt-3 break-words text-2xl font-bold tabular-nums text-[#d7c895] sm:text-3xl">
                  {summary.noShowReservationCount}
                </p>
              </div>

              <div className="min-w-0 rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Najczęściej używana oś</p>
                <p className="mt-3 break-words text-xl font-bold">
                  {summary.topResource?.laneName ?? "Brak"}
                </p>
                {summary.topResource ? (
                  <p className="mt-2 text-sm text-[#858b82]">
                    {summary.topResource.reservationCount} rez.
                  </p>
                ) : null}
              </div>
              </div>
            </section>

            <div className="mb-8 grid gap-4 md:grid-cols-2">
              <div className="rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Najlepszy dzień</p>
                <p className="mt-3 text-xl font-bold">
                  {summary.bestDay
                    ? `${summary.bestDay.date} / ${summary.bestDay.plannedRevenue.toFixed(0)} zł`
                    : "Brak"}
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Założenie obłożenia</p>
                <p className="mt-3 text-xl font-bold">
                  {summary.effectiveCapacity} efektywnych jednostek zasobu x 12h dziennie x {report.range.days} dni
                </p>
                <p className="mt-2 text-sm text-[#858b82]">
                  Historyczne obłożenie jest szacowane według aktualnej konfiguracji zasobów.
                  Nazwy zasobów pochodzą ze snapshotów rezerwacji; dla stanowiska prefiks osi nadrzędnej jest aktualny.
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
                  <p className="font-semibold text-[#d8dbd3]">Brak rezerwacji zgodnych z aktywnymi filtrami.</p>
                  <p className="mt-2 text-sm text-[#a9ada4]">Zmień zakres lub wyczyść filtry, aby zobaczyć inne wyniki.</p>
                </div>
              ) : (
                <>
                  <div className="grid gap-4 xl:hidden" aria-label="Rezerwacje w okresie — widok kart">
                    {reservations.map((reservation) => (
                      <article key={reservation.id} className="min-w-0 rounded-xl border border-[#3b4237] bg-[#090b09] p-4">
                        <div className="flex min-w-0 flex-col gap-1 border-b border-[#30372c] pb-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
                          <div className="min-w-0">
                            <p className="font-bold text-[#f2efe4]">{reservation.reservationDate}</p>
                            <p className="mt-1 font-semibold tabular-nums text-[#d8dbd3]">{formatTimeRange(reservation.startTime, reservation.endTime)}</p>
                          </div>
                          <p className="break-words text-sm font-semibold text-[#a9c58f] sm:text-right">{reservation.totalPrice.toFixed(0)} zł</p>
                        </div>
                        <dl className="mt-4 grid min-w-0 gap-4 text-sm sm:grid-cols-2">
                          <div className="min-w-0">
                            <dt className="text-[#a9ada4]">Zasób</dt>
                            <dd className="mt-1 break-words font-semibold text-[#f2efe4]">{reservation.laneDisplayName}</dd>
                          </div>
                          <div>
                            <dt className="text-[#a9ada4]">Typ</dt>
                            <dd className="mt-1 font-semibold text-[#d8dbd3]">{getBookingTypeLabel(reservation.resourceKind)}</dd>
                          </div>
                          <div>
                            <dt className="mb-2 text-[#a9ada4]">Status</dt>
                            <dd><span className={getBadgeClass(getReservationStatusBadgeClass(reservation.reservationStatus))}>{getReservationStatusLabel(reservation.reservationStatus)}</span></dd>
                          </div>
                          <div>
                            <dt className="mb-2 text-[#a9ada4]">Płatność</dt>
                            <dd><span className={getBadgeClass(getPaymentStatusBadgeClass(reservation.paymentStatus))}>{getPaymentStatusLabel(reservation.paymentStatus)}</span></dd>
                          </div>
                        </dl>
                      </article>
                    ))}
                  </div>

                  <div className="hidden max-w-full overflow-x-auto overscroll-x-contain rounded-xl border border-[#30372c] xl:block" tabIndex={0} aria-label="Tabela rezerwacji w okresie">
                    <table className="w-full min-w-[1180px] text-left text-sm">
                      <thead className="bg-[#090b09]">
                        <tr className="border-b border-[#30372c] text-[#a9ada4]">
                          <th className="py-3 pl-4 pr-4">Data</th>
                          <th className="py-3 pr-4">Godzina</th>
                          <th className="py-3 pr-4">Zasób</th>
                          <th className="py-3 pr-4">Typ</th>
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
                          <tr key={reservation.id} className="border-b border-[#30372c] text-[#d8dbd3] transition last:border-0 hover:bg-[#181d18]">
                            <td className="py-4 pl-4 pr-4 font-medium text-[#f2efe4]">{reservation.reservationDate}</td>
                            <td className="py-4 pr-4 font-semibold tabular-nums">{formatTimeRange(reservation.startTime, reservation.endTime)}</td>
                            <td className="py-4 pr-4">{reservation.laneDisplayName}</td>
                            <td className="py-4 pr-4">{getBookingTypeLabel(reservation.resourceKind)}</td>
                            <td className="py-4 pr-4 font-semibold">{reservation.customerName ?? "-"}</td>
                            <td className="py-4 pr-4">{reservation.customerEmail ?? "-"}</td>
                            <td className="py-4 pr-4">{reservation.customerPhone ?? "-"}</td>
                            <td className="py-4 pr-4 text-right font-semibold text-[#a9c58f]">{reservation.totalPrice.toFixed(0)} zł</td>
                            <td className="py-4 pr-4"><span className={getBadgeClass(getReservationStatusBadgeClass(reservation.reservationStatus))}>{getReservationStatusLabel(reservation.reservationStatus)}</span></td>
                            <td className="py-4 pr-4"><span className={getBadgeClass(getPaymentStatusBadgeClass(reservation.paymentStatus))}>{getPaymentStatusLabel(reservation.paymentStatus)}</span></td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </>
              )}

              {report.pagination.total > 0 ? (
                <nav aria-label="Stronicowanie raportu" className="mt-5 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                  <p className="text-sm text-[#a9ada4]">
                    Wyniki {report.pagination.offset + 1}–
                    {Math.min(
                      report.pagination.offset + report.details.length,
                      report.pagination.total,
                    )} z {report.pagination.total}. <span className="font-semibold text-[#d8dbd3]">Strona {currentPage} z {totalPages}</span>
                  </p>
                  <div className="grid grid-cols-2 gap-3 sm:flex">
                    <button
                      type="button"
                      disabled={!hasPreviousPage || loading}
                      onClick={() =>
                        setDetailOffset((offset) =>
                          Math.max(0, offset - REPORT_DETAIL_PAGE_SIZE),
                        )
                      }
                      aria-label="Poprzednia strona raportu"
                      className="min-h-11 w-full rounded-xl border border-[#495044] px-4 py-2 text-sm font-semibold transition hover:border-[#8b986f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
                    >
                      Poprzednia
                    </button>
                    <button
                      type="button"
                      disabled={!hasNextPage || loading}
                      onClick={() =>
                        setDetailOffset((offset) =>
                          offset + REPORT_DETAIL_PAGE_SIZE,
                        )
                      }
                      aria-label="Następna strona raportu"
                      className="min-h-11 w-full rounded-xl border border-[#495044] px-4 py-2 text-sm font-semibold transition hover:border-[#8b986f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
                    >
                      Następna
                    </button>
                  </div>
                </nav>
              ) : null}
            </section>
          </>
        )}
    </AdminShell>
  );
}

