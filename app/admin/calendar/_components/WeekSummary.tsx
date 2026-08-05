import type { CalendarWeekDay } from "../calendar-ui";

const FLAG_LABELS: Record<string, string> = {
  full_day: "Pełny dzień",
  full_lane_block: "Pełna blokada osi",
  overlapping_blocks: "Nakładające się blokady",
  outside_opening_hours: "Wpis poza godzinami",
  missing_lane_metadata: "Brak danych osi",
};

function formatDay(date: string, weekday: "long" | "short" = "long") {
  const [year, month, day] = date.split("-").map(Number);
  return new Intl.DateTimeFormat("pl-PL", {
    timeZone: "Europe/Warsaw",
    weekday,
    day: "numeric",
    month: "long",
  }).format(new Date(Date.UTC(year, month - 1, day, 12)));
}

export default function WeekSummary({
  days,
  laneId,
  today,
  onSelectDay,
}: {
  days: CalendarWeekDay[];
  laneId: string | "all";
  today: string;
  onSelectDay: (date: string) => void;
}) {
  return (
    <section aria-label="Podsumowanie tygodnia" className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      {days.map((day) => {
        const percent = day.summary.occupancyPercent;
        const laneEntries = day.entries.filter((entry) => entry.type !== "event");
        const events = day.entries.filter((entry) => entry.type === "event");
        const previewEntries = laneId === "all" ? [] : laneEntries.slice(0, 3);
        const hiddenCount = laneEntries.length - previewEntries.length;
        return (
          <button
            key={day.date}
            type="button"
            onClick={() => onSelectDay(day.date)}
            className="group min-w-0 rounded-2xl border border-[#30372c] bg-[#191e19] p-4 text-left transition hover:border-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
            aria-label={`Otwórz dzień ${formatDay(day.date)}`}
          >
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="font-bold capitalize text-[#f2efe4]">{formatDay(day.date)}</p>
                {day.date === today && <p className="mt-1 text-xs font-bold uppercase tracking-[0.14em] text-[#d7c895]">Dzisiaj</p>}
              </div>
              <span className="text-xl font-black tabular-nums text-[#d7c895]">{percent === null ? "—" : `${percent}%`}</span>
            </div>

            <div className="mt-3 h-2 overflow-hidden rounded-full bg-[#0d100d]" aria-label={`Obłożenie ${percent === null ? "niedostępne" : `${percent}%`}`}>
              <div className="h-full rounded-full bg-[#78865f]" style={{ width: `${percent ?? 0}%` }} />
            </div>
            <p className="mt-2 text-xs text-[#a9ada4]">{day.summary.occupiedMinutes} / {day.summary.availableMinutes} zajętych minut</p>

            <dl className="mt-3 grid grid-cols-3 gap-2 text-center text-xs">
              <div className="rounded-lg bg-[#111511] p-2"><dt className="text-[#858c7f]">Rezerwacje</dt><dd className="mt-1 font-bold text-[#f2efe4]">{day.summary.reservationCount}</dd></div>
              <div className="rounded-lg bg-[#111511] p-2"><dt className="text-[#858c7f]">Blokady</dt><dd className="mt-1 font-bold text-[#f2efe4]">{day.summary.blockCount}</dd></div>
              <div className="rounded-lg bg-[#111511] p-2"><dt className="text-[#858c7f]">Eventy</dt><dd className="mt-1 font-bold text-[#f2efe4]">{day.summary.eventCount}</dd></div>
            </dl>

            {day.summary.isFull && <p className="mt-3 text-xs font-bold uppercase tracking-[0.12em] text-[#e0a0a0]">Pełne obłożenie</p>}
            {day.summary.flags.length > 0 && (
              <div className="mt-3 flex flex-wrap gap-1.5">
                {day.summary.flags.map((flag) => <span key={flag} className="rounded-md border border-[#806a32] bg-[#2b2618] px-2 py-1 text-[10px] text-[#e1c477]">{FLAG_LABELS[flag] ?? flag}</span>)}
              </div>
            )}

            {previewEntries.length > 0 && (
              <div className="mt-3 space-y-2 border-t border-[#30372c] pt-3">
                {previewEntries.map((entry) => (
                  <div key={entry.id} className="min-w-0 text-xs text-[#c7cbbf]">
                    <p className="font-bold">{entry.startTime}–{entry.endTime} · {entry.type === "reservation" ? "Rezerwacja" : "Blokada"}</p>
                    <p className="truncate text-[#a9ada4]">{entry.label}{entry.isHistorical ? " · historyczny" : ""}</p>
                  </div>
                ))}
                {hiddenCount > 0 && <p className="text-xs font-semibold text-[#d7c895]">+ {hiddenCount} kolejnych</p>}
              </div>
            )}

            {events.length > 0 && <p className="mt-3 text-xs font-semibold text-[#e1c477]">E · {events.length} wydarzeń tego dnia</p>}
          </button>
        );
      })}
    </section>
  );
}
