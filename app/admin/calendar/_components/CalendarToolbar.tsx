import type {
  CalendarEntryType,
  CalendarLane,
} from "@/lib/admin/calendar/types";
import type { CalendarView } from "../calendar-ui";
import CalendarViewSwitch from "./CalendarViewSwitch";

const TYPE_OPTIONS: Array<{ value: CalendarEntryType; label: string }> = [
  { value: "reservation", label: "Rezerwacje" },
  { value: "lane_block", label: "Blokady" },
  { value: "event", label: "Eventy" },
];

type CalendarToolbarProps = {
  date: string;
  view: CalendarView;
  periodLabel: string;
  laneId: string | "all";
  lanes: CalendarLane[];
  types: CalendarEntryType[];
  includeHistoricalStatuses: boolean;
  disabled?: boolean;
  onDateChange: (date: string) => void;
  onViewChange: (view: CalendarView) => void;
  onPreviousDay: () => void;
  onNextDay: () => void;
  onToday: () => void;
  onLaneChange: (laneId: string) => void;
  onTypeToggle: (type: CalendarEntryType) => void;
  onHistoricalStatusesChange: (enabled: boolean) => void;
};

const controlClass =
  "min-h-11 rounded-xl border border-[#3a4236] bg-[#111511] px-3 text-sm text-[#f2efe4] outline-none transition focus-visible:border-[#d7c895] focus-visible:ring-2 focus-visible:ring-[#d7c895]/40 disabled:cursor-not-allowed disabled:opacity-60";

export default function CalendarToolbar({
  date,
  view,
  periodLabel,
  laneId,
  lanes,
  types,
  includeHistoricalStatuses,
  disabled = false,
  onDateChange,
  onViewChange,
  onPreviousDay,
  onNextDay,
  onToday,
  onLaneChange,
  onTypeToggle,
  onHistoricalStatusesChange,
}: CalendarToolbarProps) {
  return (
    <section
      aria-label="Sterowanie kalendarzem"
      className="mb-5 rounded-2xl border border-[#30372c] bg-[#191e19] p-4"
    >
      <div className="mb-4 flex flex-col gap-3 border-b border-[#30372c] pb-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="hidden md:block">
          <CalendarViewSwitch view={view} onChange={onViewChange} />
        </div>
        <p className="text-sm font-semibold text-[#d7c895]">
          {periodLabel}
        </p>
      </div>
      <div className="grid gap-4 xl:grid-cols-[auto_minmax(180px,1fr)_minmax(210px,1fr)]">
        <div className="flex flex-wrap items-end gap-2">
          <button
            type="button"
            className={controlClass}
            onClick={onPreviousDay}
            disabled={disabled}
            aria-label={
              view === "day"
                ? "Poprzedni dzień"
                : view === "week"
                  ? "Poprzedni tydzień"
                  : "Poprzedni miesiąc"
            }
          >
            ←
          </button>
          <button
            type="button"
            className={controlClass}
            onClick={onToday}
            disabled={disabled}
          >
            Dzisiaj
          </button>
          <button
            type="button"
            className={controlClass}
            onClick={onNextDay}
            disabled={disabled}
            aria-label={
              view === "day"
                ? "Następny dzień"
                : view === "week"
                  ? "Następny tydzień"
                  : "Następny miesiąc"
            }
          >
            →
          </button>
          <label className="flex min-w-44 flex-1 flex-col gap-1 text-xs font-semibold uppercase tracking-[0.16em] text-[#858c7f] sm:flex-none">
            Data
            <input
              type="date"
              value={date}
              onChange={(event) => onDateChange(event.target.value)}
              disabled={disabled}
              className={`${controlClass} w-full [color-scheme:dark]`}
            />
          </label>
        </div>

        <label className="flex flex-col gap-1 text-xs font-semibold uppercase tracking-[0.16em] text-[#858c7f]">
          Oś
          <select
            value={laneId}
            onChange={(event) => onLaneChange(event.target.value)}
            disabled={disabled || lanes.length === 0}
            className={controlClass}
          >
            <option value="all">Wszystkie osie</option>
            {lanes.map((lane) => (
              <option key={lane.id} value={lane.id}>
                {lane.name}{lane.isActive ? "" : " (historyczna)"}
              </option>
            ))}
          </select>
        </label>

        <fieldset>
          <legend className="mb-1 text-xs font-semibold uppercase tracking-[0.16em] text-[#858c7f]">
            Typy wpisów
          </legend>
          <div className="flex flex-wrap gap-2">
            {TYPE_OPTIONS.map((option) => {
              const selected = types.includes(option.value);
              return (
                <button
                  key={option.value}
                  type="button"
                  aria-pressed={selected}
                  disabled={disabled}
                  onClick={() => onTypeToggle(option.value)}
                  className={`${controlClass} ${
                    selected
                      ? "border-[#78865f] bg-[#293225] text-[#f2efe4]"
                      : "text-[#858c7f]"
                  }`}
                >
                  {selected ? "✓ " : ""}{option.label}
                </button>
              );
            })}
          </div>
        </fieldset>
      </div>

      <label className="mt-4 flex min-h-11 cursor-pointer items-center gap-3 rounded-xl border border-[#30372c] px-3 text-sm text-[#c7cbbf] focus-within:ring-2 focus-within:ring-[#d7c895]/40">
        <input
          type="checkbox"
          checked={includeHistoricalStatuses}
          disabled={disabled}
          onChange={(event) => onHistoricalStatusesChange(event.target.checked)}
          className="h-4 w-4 accent-[#78865f]"
        />
        Pokaż zakończone, no-show i historyczne blokady
      </label>
    </section>
  );
}
