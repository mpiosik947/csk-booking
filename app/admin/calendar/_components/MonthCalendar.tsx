import type { CalendarDayFlag } from "@/lib/admin/calendar/types";
import type { CalendarMonthDay } from "../calendar-ui";

const WEEKDAYS = [
  { short: "Pon", full: "Poniedziałek" },
  { short: "Wt", full: "Wtorek" },
  { short: "Śr", full: "Środa" },
  { short: "Czw", full: "Czwartek" },
  { short: "Pt", full: "Piątek" },
  { short: "Sob", full: "Sobota" },
  { short: "Niedz", full: "Niedziela" },
] as const;

const FLAG_LABELS: Record<CalendarDayFlag, string> = {
  full_day: "pełny dzień",
  full_lane_block: "pełna blokada osi",
  overlapping_blocks: "nakładające się blokady",
  outside_opening_hours: "wpis poza godzinami otwarcia",
  missing_lane_metadata: "brak danych osi",
};

function calendarDate(date: string) {
  const [year, month, day] = date.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day, 12));
}

function formatFullDate(date: string) {
  return new Intl.DateTimeFormat("pl-PL", {
    timeZone: "Europe/Warsaw",
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  }).format(calendarDate(date));
}

function buildDayLabel(day: CalendarMonthDay, today: string) {
  const summary = day.summary;
  const percent =
    summary.occupancyPercent === null
      ? "Obłożenie niedostępne"
      : `Obłożenie ${summary.occupancyPercent} procent`;
  const special = [
    day.date === today ? "Dzisiaj" : null,
    summary.isFull ? "Pełny dzień" : null,
    summary.flags.length > 0
      ? `Uwagi: ${summary.flags.map((flag) => FLAG_LABELS[flag]).join(", ")}`
      : null,
  ].filter(Boolean);
  const activity = [
    summary.reservationCount > 0 ? `${summary.reservationCount} rezerwacji` : null,
    summary.blockCount > 0 ? `${summary.blockCount} blokad` : null,
    summary.eventCount > 0 ? `${summary.eventCount} wydarzeń` : null,
  ].filter(Boolean);
  return `${formatFullDate(day.date)}. ${percent}.${activity.length > 0 ? ` ${activity.join(", ")}.` : ""}${special.length > 0 ? ` ${special.join(". ")}.` : ""}`;
}

export function MonthCalendarSkeleton({ dayCount }: { dayCount: 35 | 42 }) {
  return (
    <div
      role="status"
      aria-label="Ładowanie widoku miesiąca"
      className="overflow-hidden rounded-2xl border border-[#30372c] bg-[#151915] p-1 sm:p-2"
    >
      <div className="grid grid-cols-7 gap-1 sm:gap-2">
        {Array.from({ length: dayCount }, (_, index) => (
          <div
            key={index}
            className="min-h-20 animate-pulse rounded-lg bg-[#202620] sm:min-h-28"
          />
        ))}
      </div>
    </div>
  );
}

export default function MonthCalendar({
  days,
  anchorDate,
  today,
  onSelectDay,
}: {
  days: CalendarMonthDay[];
  anchorDate: string;
  today: string;
  onSelectDay: (date: string) => void;
}) {
  const currentMonth = anchorDate.slice(0, 7);

  return (
    <section
      aria-label="Kalendarz miesięczny"
      className="overflow-hidden rounded-2xl border border-[#30372c] bg-[#111511] p-1 sm:p-2"
    >
      <div className="grid grid-cols-7 gap-1 sm:gap-2" aria-label="Dni tygodnia">
        {WEEKDAYS.map((weekday) => (
          <div
            key={weekday.short}
            aria-label={weekday.full}
            className="min-w-0 py-2 text-center text-[10px] font-bold uppercase tracking-wide text-[#858c7f] sm:text-xs"
          >
            {weekday.short}
          </div>
        ))}
      </div>

      <div className="grid grid-cols-7 gap-1 sm:gap-2">
        {days.map((day) => {
          const summary = day.summary;
          const isCurrentMonth = day.date.startsWith(currentMonth);
          const isToday = day.date === today;
          const percent = summary.occupancyPercent;
          const hasActivityCounts =
            summary.reservationCount > 0 ||
            summary.blockCount > 0 ||
            summary.eventCount > 0;
          return (
            <button
              key={day.date}
              type="button"
              onClick={() => onSelectDay(day.date)}
              aria-label={buildDayLabel(day, today)}
              className={`min-h-20 min-w-0 overflow-hidden rounded-lg border p-1 text-left transition focus-visible:z-10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] sm:min-h-32 sm:rounded-xl sm:p-2 ${
                isToday
                  ? "border-[#d7c895] bg-[#252b20]"
                  : isCurrentMonth
                    ? "border-[#30372c] bg-[#191e19] hover:border-[#78865f]"
                    : "border-[#252b24] bg-[#121612] text-[#6f756b] opacity-65 hover:opacity-90"
              }`}
            >
              <div className="flex items-start justify-between gap-1">
                <span className={`text-base font-black leading-none tabular-nums sm:text-lg ${isToday ? "text-[#d7c895]" : "text-[#f2efe4]"}`}>
                  {Number(day.date.slice(8, 10))}
                </span>
                <span className="text-[10px] font-black tabular-nums text-[#d7c895] sm:text-sm">
                  {percent === null ? "—" : `${percent}%`}
                </span>
              </div>

              {isToday && (
                <span className="mt-0.5 block truncate text-[8px] font-bold uppercase text-[#d7c895] sm:text-[10px]">
                  Dzisiaj
                </span>
              )}

              <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-[#0d100d]">
                <div
                  className="h-full rounded-full bg-[#78865f]"
                  style={{ width: `${percent ?? 0}%` }}
                />
              </div>
              {hasActivityCounts && (
                <p className="mt-1 flex flex-wrap gap-x-2 gap-y-0.5 text-[8px] font-bold leading-tight text-[#c7cbbf] sm:text-[10px]">
                  {summary.reservationCount > 0 && <span>R {summary.reservationCount}</span>}
                  {summary.blockCount > 0 && <span>B {summary.blockCount}</span>}
                  {summary.eventCount > 0 && <span>E {summary.eventCount}</span>}
                </p>
              )}

              {summary.isFull && (
                <span className="mt-1 block text-[8px] font-black uppercase leading-tight text-[#e0a0a0] sm:text-[10px]">
                  <span className="sm:hidden">Pełny</span>
                  <span className="hidden sm:inline">Pełny dzień</span>
                </span>
              )}
              {summary.flags.length > 0 && (
                <span className="mt-1 block text-[8px] font-bold leading-tight text-[#e1c477] sm:text-[10px]">
                  Uwaga {summary.flags.length}
                </span>
              )}
            </button>
          );
        })}
      </div>
    </section>
  );
}
