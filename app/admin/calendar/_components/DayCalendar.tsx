import type {
  CalendarLane,
  CalendarLaneOccupyingEntry,
} from "@/lib/admin/calendar/types";
import { calendarTimeToMinutes } from "@/lib/admin/calendar/time";
import {
  CALENDAR_HOUR_HEIGHT,
  getCalendarLaneFamilies,
  layoutCalendarLaneEntries,
} from "../calendar-ui";
import { ResourceTypeBadge } from "../../_components/HierarchyResourcePresentation";
import CalendarEntryBlock from "./CalendarEntryBlock";

type DayCalendarProps = {
  lanes: CalendarLane[];
  entries: CalendarLaneOccupyingEntry[];
  openingStart: string;
  openingEnd: string;
  onSelectEntry: (
    entry: CalendarLaneOccupyingEntry,
    activator: HTMLButtonElement
  ) => void;
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
  onSelectEntry,
  mobile = false,
}: DayCalendarProps & { mobile?: boolean }) {
  const start = calendarTimeToMinutes(openingStart) ?? 0;
  const end = calendarTimeToMinutes(openingEnd) ?? start;
  const height = ((end - start) / 60) * CALENDAR_HOUR_HEIGHT;
  const hourLabels = getHourLabels(openingStart, openingEnd);
  const laneMinWidth = 220;
  const template = `72px repeat(${lanes.length}, minmax(${laneMinWidth}px, 1fr))`;
  const families = getCalendarLaneFamilies(lanes);

  if (!families) {
    return (
      <div className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-5 text-sm text-[#e0a0a0]">
        Nie udało się poprawnie wyświetlić hierarchii zasobów.
      </div>
    );
  }

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
        <div
          className="sticky left-0 top-0 z-40 h-28 border-b border-r border-[#30372c] bg-[#191e19]"
          style={{ gridRow: "1 / span 2" }}
        />
        {families.map((family) => (
          <header
            key={family.id}
            className="sticky top-0 z-30 flex h-11 min-w-0 items-center border-b border-r border-[#3d4638] bg-[#202620] px-3"
            style={{ gridColumn: `span ${family.resources.length}` }}
          >
            <h2 className="min-w-0 break-words text-sm font-black text-[#d7c895]">
              {family.displayName}
            </h2>
          </header>
        ))}
        {lanes.map((lane) => (
          <header
            key={lane.id}
            aria-label={lane.displayName}
            className="sticky top-11 z-20 flex h-17 min-w-0 items-center border-b border-r border-[#30372c] bg-[#191e19] px-3"
          >
            <div className="min-w-0">
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                {lane.isPosition ? (
                  <span aria-hidden="true" className="shrink-0 text-[#78865f]">
                    ↳
                  </span>
                ) : null}
                <p className="min-w-0 break-words text-sm font-bold text-[#f2efe4]">
                  {lane.isPosition ? lane.name : "Cała oś"}
                </p>
                <ResourceTypeBadge isPosition={lane.isPosition} />
              </div>
              <p className="mt-1 text-xs text-[#858c7f]">
                {lane.isActive ? "Aktywne" : "Zasób historyczny"}
              </p>
              <span className="sr-only">{lane.displayName}</span>
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
            (entry) => entry.laneId === lane.id
          );
          const positioned = layoutCalendarLaneEntries(
            laneEntries,
            openingStart,
            openingEnd
          );
          return (
            <section
              key={lane.id}
              aria-label={`Harmonogram: ${lane.displayName}`}
              className="relative border-r border-[#30372c]"
              style={{
                height,
                backgroundImage:
                  "repeating-linear-gradient(to bottom, transparent 0, transparent 71px, rgba(66,75,63,0.65) 71px, rgba(66,75,63,0.65) 72px)",
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
