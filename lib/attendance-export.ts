import { quoteCsvCell } from "./admin/reports.ts";
import type { InstructorEvent, InstructorParticipant } from "./instructor-contracts";

export const ATTENDANCE_EXPORT_LIMIT = 100;
export type AttendanceExport = { tenant: string; event: InstructorEvent; rows: InstructorParticipant[] };
const status = { registered: "Zapisany", approved: "Zatwierdzony", reserve: "Rezerwa" };
const attendance = { unmarked: "Nieoznaczony", present: "Obecny", no_show: "Nieobecny" };
const columns = ["LP", "Uczestnik", "Status zapisu", "Status obecności"];
function cells(data: AttendanceExport) {
  if (data.rows.length > ATTENDANCE_EXPORT_LIMIT || data.rows.some(r => !["registered", "approved"].includes(r.registration_status))) throw Error("Invalid export rows");
  return data.rows.map((r, i) => [i + 1, r.display_name, status[r.registration_status], attendance[r.attendance_status]]);
}
export function attendanceFilename(event: InstructorEvent) {
  // No event name or internal identifier enters Content-Disposition.
  const date = /^\d{4}-\d{2}-\d{2}$/.test(event.event_date) ? event.event_date : "wydarzenie";
  return `lista-obecnosci-${date}.csv`;
}
export function attendanceCsv(data: AttendanceExport) {
  const metadata = [["Obiekt", data.tenant], ["Wydarzenie", data.event.title], ["Data", data.event.event_date],
    ["Godzina (Europe/Warsaw)", `${data.event.start_time}–${data.event.end_time}`], ["Miejsce", data.event.location ?? ""]];
  return "\uFEFF" + [...metadata, [], columns, ...cells(data)].map(row => row.map(quoteCsvCell).join(";")).join("\r\n") + "\r\n";
}
const html = (s: string | number) => String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
export function attendancePrint(data: AttendanceExport) {
  return `<!doctype html><html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Lista obecności</title><style>
  *{box-sizing:border-box}body{font:16px system-ui;margin:16px;color:#111;background:white}main{max-width:900px;margin:auto}h1,h2,p,th,td{overflow-wrap:anywhere}table{width:100%;border-collapse:collapse;table-layout:fixed}th,td{border:1px solid #888;padding:8px;text-align:left}th:first-child{width:9%}th:nth-child(2){width:43%}thead{display:table-header-group}tr{break-inside:avoid}@media print{.print-help{display:none}body{margin:0;font-size:11pt}@page{margin:15mm}}
  </style></head><body><main><p class="print-help">Użyj menu przeglądarki „Drukuj” (Ctrl+P). Lista zawiera tylko zapisanych i zatwierdzonych uczestników, bez rezerwy.</p><h1>${html(data.tenant)} — Lista obecności</h1><h2>${html(data.event.title)}</h2><p>${html(data.event.event_date)} · ${html(data.event.start_time)}–${html(data.event.end_time)} (Europe/Warsaw)</p><p>${html(data.event.location ?? "")}</p><table><thead><tr>${columns.map(c => `<th scope="col">${html(c)}</th>`).join("")}</tr></thead><tbody>${cells(data).map(row => `<tr>${row.map(c => `<td>${html(c)}</td>`).join("")}</tr>`).join("")}</tbody></table></main></body></html>`;
}
