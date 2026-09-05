"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
  getReportDateRange,
  getWarsawToday,
  parseAdminReservationReport,
  REPORT_DETAIL_PAGE_SIZE,
  type AdminReservationReport,
  type ReportDetail,
  type ReportMode,
} from "../../../lib/admin/reports";
import { reportClientError } from "../../../lib/safe-client-error";

function getBadgeClass(baseClass: string) {
  return `rounded-full border px-3 py-1 text-xs font-semibold ${baseClass}`;
}

function formatTimeRange(startTime: string, endTime: string) {
  return `${startTime.slice(0, 5)}-${endTime.slice(0, 5)}`;
}

export default function AdminReportsPage() {
  const today = getWarsawToday();

  const [reportMode, setReportMode] = useState<ReportMode>("day");
  const [selectedDate, setSelectedDate] = useState(today);
  const [report, setReport] = useState<AdminReservationReport | null>(null);
  const [detailOffset, setDetailOffset] = useState(0);
  const [loading, setLoading] = useState(true);
  const [hasAccess, setHasAccess] = useState(false);
  const [reportReady, setReportReady] = useState(false);
  const [message, setMessage] = useState("");
  const reportRequestRef = useRef(0);

  const range = useMemo(
    () => getReportDateRange(reportMode, selectedDate),
    [reportMode, selectedDate],
  );

  const loadReport = useCallback(async () => {
    const requestId = ++reportRequestRef.current;
    setLoading(true);
    setMessage("");
    setHasAccess(false);
    setReportReady(false);
    setReport(null);

    if (!range) {
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
      "admin_get_reservation_report_v1",
      {
        p_start_date: range.startDate,
        p_end_date: range.endDate,
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
    if (!parsedReport) {
      setMessage("Nie udało się pobrać kompletnego zestawu danych raportu.");
      setLoading(false);
      return;
    }

    setReport(parsedReport);
    setReportReady(true);
    setLoading(false);
  }, [detailOffset, range]);

  useEffect(() => {
    // Report data is an external Supabase resource synchronized to the selected range.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadReport();
  }, [loadReport]);


  const reservations: ReportDetail[] = report?.details ?? [];
  const summary = report?.summary ?? null;
  const hasPreviousPage = Boolean(report && report.pagination.offset > 0);
  const hasNextPage = Boolean(
    report &&
      report.pagination.offset + report.details.length < report.pagination.total,
  );

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
              onChange={(event) => {
                setDetailOffset(0);
                setReportMode(event.target.value as ReportMode);
              }}
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
              onChange={(event) => {
                setDetailOffset(0);
                setSelectedDate(event.target.value);
              }}
              className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-[#f2efe4] outline-none focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
            />
          </div>

          <div className="rounded-xl border border-[#30372c] bg-[#090b09] p-4 text-sm text-[#a9ada4] md:col-span-2">
            Wybrany zakres:{" "}
            <span className="font-semibold text-[#c7d6b2]">
              {range ? `${range.startDate} - ${range.endDate}` : "Nieprawidłowy"}
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

        {!loading && hasAccess && reportReady && report && summary && (
          <>
            <section aria-labelledby="report-kpi-heading" className="mb-8">
              <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">Podsumowanie</p>
              <h2 id="report-kpi-heading" className="mb-4 mt-2 text-xl font-bold">Kluczowe wskaźniki</h2>
              <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
              <div className="rounded-[1.25rem] border border-[#30372c] bg-[#101310] p-5">
                <p className="text-sm text-[#a9ada4]">Rezerwacje aktywne</p>
                <p className="mt-3 text-3xl font-bold">
                  {summary.activeReservationCount}
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#36523a] bg-[#111b13] p-5">
                <p className="text-sm text-[#a9ada4]">Przychód planowany</p>
                <p className="mt-3 text-3xl font-bold text-[#a9c58f]">
                  {summary.plannedRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#36523a] bg-[#111b13] p-5">
                <p className="text-sm text-[#a9ada4]">Przychód opłacony</p>
                <p className="mt-3 text-3xl font-bold text-[#a9c58f]">
                  {summary.paidRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Obłożenie osi</p>
                <p className="mt-3 text-3xl font-bold text-[#d7c895]">
                  {summary.occupancyPercent}%
                </p>
              </div>
              <div className="rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Nieopłacone / na miejscu</p>
                <p className="mt-3 text-3xl font-bold text-[#d7c895]">
                  {summary.outstandingRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#603d3d] bg-[#211515] p-5">
                <p className="text-sm text-[#a9ada4]">Anulowane</p>
                <p className="mt-3 text-3xl font-bold text-[#d99b9b]">
                  {summary.cancelledReservationCount}
                </p>
              </div>

              <div className="rounded-[1.25rem] border border-[#5b5335] bg-[#1d1a10] p-5">
                <p className="text-sm text-[#a9ada4]">Nieobecności</p>
                <p className="mt-3 text-3xl font-bold text-[#d7c895]">
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
                            {reservation.reservationDate}
                          </td>

                          <td className="py-4 pr-4 font-semibold">
                            {formatTimeRange(
                              reservation.startTime,
                              reservation.endTime,
                            )}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.laneDisplayName}
                          </td>

                          <td className="py-4 pr-4 font-semibold">
                            {reservation.customerName ?? "-"}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.customerEmail ?? "-"}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.customerPhone ?? "-"}
                          </td>

                          <td className="py-4 pr-4 text-right font-semibold text-[#a9c58f]">
                            {reservation.totalPrice.toFixed(0)} zł
                          </td>

                          <td className="py-4 pr-4">
                            <span
                              className={getBadgeClass(
                                getReservationStatusBadgeClass(
                                  reservation.reservationStatus,
                                ),
                              )}
                            >
                              {getReservationStatusLabel(
                                reservation.reservationStatus,
                              )}
                            </span>
                          </td>

                          <td className="py-4 pr-4">
                            <span
                              className={getBadgeClass(
                                getPaymentStatusBadgeClass(
                                  reservation.paymentStatus,
                                ),
                              )}
                            >
                              {getPaymentStatusLabel(
                                reservation.paymentStatus,
                              )}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              {report.pagination.total > 0 ? (
                <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                  <p className="text-sm text-[#a9ada4]">
                    Wyniki {report.pagination.offset + 1}–
                    {Math.min(
                      report.pagination.offset + report.details.length,
                      report.pagination.total,
                    )} z {report.pagination.total}
                  </p>
                  <div className="flex gap-3">
                    <button
                      type="button"
                      disabled={!hasPreviousPage || loading}
                      onClick={() =>
                        setDetailOffset((offset) =>
                          Math.max(0, offset - REPORT_DETAIL_PAGE_SIZE),
                        )
                      }
                      className="min-h-11 rounded-xl border border-[#495044] px-4 py-2 text-sm font-semibold disabled:cursor-not-allowed disabled:opacity-50"
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
                      className="min-h-11 rounded-xl border border-[#495044] px-4 py-2 text-sm font-semibold disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      Następna
                    </button>
                  </div>
                </div>
              ) : null}
            </section>
          </>
        )}
    </AdminShell>
  );
}

