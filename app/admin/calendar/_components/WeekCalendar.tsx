import type { CalendarEventEntry, CalendarLaneOccupyingEntry } from "@/lib/admin/calendar/types";
import { calendarTimeToMinutes } from "@/lib/admin/calendar/time";
import type { CalendarWeekDay } from "../calendar-ui";
import { CALENDAR_HOUR_HEIGHT, layoutCalendarLaneEntries } from "../calendar-ui";
import CalendarEntryBlock from "./CalendarEntryBlock";

function shortDay(date: string) {
  const [year, month, day] = date.split("-").map(Number);
  return new Intl.DateTimeFormat("pl-PL", {
    timeZone: "Europe/Warsaw",
    weekday: "short",
    day: "2-digit",
    month: "2-digit",
  }).format(new Date(Date.UTC(year, month - 1, day, 12)));
}

function getHourLabels(openingStart: string, openingEnd: string) {
  const start = calendarTimeToMinutes(openingStart);
  const end = calendarTimeToMinutes(openingEnd);
  if (start === null || end === null || start >= end) return [];
  const labels: string[] = [];
  for (let minutes = start; minutes <= end; minutes += 60) {
    labels.push(`${String(Math.floor(minutes / 60)).padStart(2, "0")}:00`);
  }
  return labels;
}

function WeekEvents({
  days,
  onSelectEntry,
}: {
  days: CalendarWeekDay[];
  onSelectEntry: (entry: CalendarEventEntry, activator: HTMLButtonElement) => void;
}) {
  const eventDays = days
    .map((day) => ({
      date: day.date,
      events: day.entries.filter(
        (entry): entry is CalendarEventEntry => entry.type === "event" && !entry.isLaneProjection
      ),
    }))
    .filter((day) => day.events.length > 0);
  if (eventDays.length === 0) return null;

  return (
    <section className="mb-4 rounded-2xl border border-[#806a32] bg-[#211e15] p-4" aria-labelledby="week-events-title">
      <h2 id="week-events-title" className="text-sm font-bold uppercase tracking-[0.18em] text-[#e1c477]">Wydarzenia tygodnia</h2>
      <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        {eventDays.map((day) => (
          <div key={day.date} className="rounded-xl border border-[#5f522d] bg-[#2b2618] p-3">
            <p className="text-xs font-bold capitalize text-[#d7c895]">{shortDay(day.date)}</p>
            {day.events.map((event) => (
              <button
                key={event.id}
                type="button"
                onClick={(clickEvent) => onSelectEntry(event, clickEvent.currentTarget)}
                className="mt-2 block w-full cursor-pointer border-t border-[#5f522d] pt-2 text-left first:border-0 first:pt-0 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e1c477]"
              >
                <p className="text-xs font-bold text-[#f2efe4]">E · {event.startTime}–{event.endTime}</p>
                <p className="truncate text-sm text-[#c7cbbf]">{event.label}</p>
                <p className="truncate text-xs text-[#a9ada4]">{event.location || "Lokalizacja niepodana"} · limit {event.maxParticipants}</p>
                <p className="mt-1 line-clamp-2 text-xs text-[#d7c895]">
                  {event.resources.length === 0
                    ? "Event globalny — nie blokuje osi"
                    : event.resources
                        .map(
                          (resource) =>
                            `${resource.displayName} · ${resource.isPosition ? "Stanowisko" : "Cała oś"}`
                        )
                        .join("; ")}
                </p>
              </button>
            ))}
          </div>
        ))}
      </div>
    </section>
  );
}

export default function WeekCalendar({
  days,
  laneIds,
  openingStart,
  openingEnd,
  today,
  onSelectDay,
  onSelectEntry,
}: {
  days: CalendarWeekDay[];
  laneIds: string[];
  openingStart: string;
  openingEnd: string;
  today: string;
  onSelectDay: (date: string) => void;
  onSelectEntry: (
    entry: CalendarWeekDay["entries"][number],
    activator: HTMLButtonElement
  ) => void;
}) {
  const start = calendarTimeToMinutes(openingStart) ?? 0;
  const end = calendarTimeToMinutes(openingEnd) ?? start;
  const height = ((end - start) / 60) * CALENDAR_HOUR_HEIGHT;
  const hourLabels = getHourLabels(openingStart, openingEnd);
  const dayMinWidth = 145;

  return (
    <>
      <WeekEvents days={days} onSelectEntry={onSelectEntry} />
      <div className="max-h-[72vh] overflow-auto rounded-2xl border border-[#30372c] bg-[#111511]">
        <div
          className="relative grid min-w-full"
          style={{
            gridTemplateColumns: `72px repeat(7, minmax(${dayMinWidth}px, 1fr))`,
            width: `max(100%, ${72 + 7 * dayMinWidth}px)`,
          }}
        >
          <div className="sticky left-0 top-0 z-30 h-[4.5rem] border-b border-r border-[#30372c] bg-[#191e19]" />
          {days.map((day) => (
            <button
              key={day.date}
              type="button"
              onClick={() => onSelectDay(day.date)}
              className={`sticky top-0 z-20 h-[4.5rem] border-b border-r border-[#30372c] bg-[#191e19] px-2 text-sm font-bold capitalize text-[#f2efe4] hover:bg-[#232a22] focus-visible:z-30 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[#d7c895] ${day.date === today ? "text-[#d7c895]" : ""}`}
            >
              {shortDay(day.date)}
              {day.date === today && <span className="mt-1 block text-[10px] uppercase tracking-[0.12em]">Dzisiaj</span>}
            </button>
          ))}

          <div className="sticky left-0 z-10 border-r border-[#30372c] bg-[#151915]" style={{ height }} aria-hidden="true">
            {hourLabels.map((label, index) => (
              <span
                key={label}
                className={`absolute right-3 text-xs font-semibold tabular-nums text-[#858c7f] ${index === 0 || index === hourLabels.length - 1 ? "" : "-translate-y-1/2"}`}
                style={index === 0 ? { top: 8 } : index === hourLabels.length - 1 ? { bottom: 8 } : { top: index * CALENDAR_HOUR_HEIGHT }}
              >{label}</span>
            ))}
          </div>

          {days.map((day) => {
            const entries = day.entries.filter(
              (entry): entry is CalendarLaneOccupyingEntry =>
                (entry.type !== "event" || entry.isLaneProjection) && laneIds.includes(entry.laneId)
            );
            const positioned = layoutCalendarLaneEntries(entries, openingStart, openingEnd);
            return (
              <section
                key={day.date}
                aria-label={`Harmonogram ${shortDay(day.date)}`}
                className="relative border-r border-[#30372c]"
                style={{
                  height,
                  backgroundImage: "repeating-linear-gradient(to bottom, transparent 0, transparent 71px, rgba(66,75,63,0.65) 71px, rgba(66,75,63,0.65) 72px)",
                }}
              >
                {positioned.map((item) => (
                  <CalendarEntryBlock
                    key={item.entry.id}
                    positioned={item}
                    onSelectEntry={onSelectEntry}
                  />
                ))}
              </section>
            );
          })}
        </div>
      </div>
    </>
  );
}
