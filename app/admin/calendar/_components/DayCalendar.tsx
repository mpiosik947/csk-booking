import type {
  CalendarEntry,
  CalendarLane,
} from "@/lib/admin/calendar/types";
import { calendarTimeToMinutes } from "@/lib/admin/calendar/time";
import {
  CALENDAR_HOUR_HEIGHT,
  layoutCalendarLaneEntries,
} from "../calendar-ui";
import CalendarEntryBlock from "./CalendarEntryBlock";

type DayCalendarProps = {
  lanes: CalendarLane[];
  entries: CalendarEntry[];
  openingStart: string;
  openingEnd: string;
};

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

function CalendarGrid({
  lanes,
  entries,
  openingStart,
  openingEnd,
  mobile = false,
}: DayCalendarProps & { mobile?: boolean }) {
  const start = calendarTimeToMinutes(openingStart) ?? 0;
  const end = calendarTimeToMinutes(openingEnd) ?? start;
  const height = ((end - start) / 60) * CALENDAR_HOUR_HEIGHT;
  const hourLabels = getHourLabels(openingStart, openingEnd);
  const laneMinWidth = 220;
  const template = `72px repeat(${lanes.length}, minmax(${laneMinWidth}px, 1fr))`;

  return (
    <div className="max-h-[72vh] overflow-auto rounded-2xl border border-[#30372c] bg-[#111511]">
      <div
        className="relative grid min-w-full"
        style={{
          gridTemplateColumns: template,
          width: mobile
            ? "100%"
            : `max(100%, ${72 + lanes.length * laneMinWidth}px)`,
        }}
      >
        <div className="sticky left-0 top-0 z-30 h-16 border-b border-r border-[#30372c] bg-[#191e19]" />
        {lanes.map((lane) => (
          <header key={lane.id} className="sticky top-0 z-20 flex h-16 items-center border-b border-r border-[#30372c] bg-[#191e19] px-3">
            <div>
              <h2 className="text-sm font-bold text-[#f2efe4]">{lane.name}</h2>
              <p className="text-xs text-[#858c7f]">{lane.isActive ? "Aktywna" : "Oś historyczna"}</p>
            </div>
          </header>
        ))}

        <div className="sticky left-0 z-10 border-r border-[#30372c] bg-[#151915]" style={{ height }} aria-hidden="true">
          {hourLabels.map((label, index) => (
            <span
              key={label}
              className={`absolute right-3 text-xs font-semibold tabular-nums text-[#858c7f] ${
                index === 0 || index === hourLabels.length - 1
                  ? ""
                  : "-translate-y-1/2"
              }`}
              style={
                index === 0
                  ? { top: 8 }
                  : index === hourLabels.length - 1
                    ? { bottom: 8 }
                    : { top: index * CALENDAR_HOUR_HEIGHT }
              }
            >
              {label}
            </span>
          ))}
        </div>

        {lanes.map((lane) => {
          const laneEntries = entries.filter(
            (entry) => entry.type !== "event" && entry.laneId === lane.id
          );
          const positioned = layoutCalendarLaneEntries(
            laneEntries,
            openingStart,
            openingEnd
          );
          return (
            <section
              key={lane.id}
              aria-label={`Harmonogram: ${lane.name}`}
              className="relative border-r border-[#30372c]"
              style={{
                height,
                backgroundImage:
                  "repeating-linear-gradient(to bottom, transparent 0, transparent 71px, rgba(66,75,63,0.65) 71px, rgba(66,75,63,0.65) 72px)",
              }}
            >
              {positioned.map((item) => (
                <CalendarEntryBlock key={item.entry.id} positioned={item} />
              ))}
            </section>
          );
        })}
      </div>
    </div>
  );
}

export default function DayCalendar(props: DayCalendarProps) {
  return (
    <>
      <div className="hidden md:block">
        <CalendarGrid {...props} />
      </div>
      <div className="md:hidden">
        <CalendarGrid {...props} mobile />
      </div>
    </>
  );
}
