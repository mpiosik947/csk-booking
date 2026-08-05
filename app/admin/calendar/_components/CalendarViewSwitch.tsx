import type { CalendarView } from "../calendar-ui";

export default function CalendarViewSwitch({
  view,
  onChange,
}: {
  view: CalendarView;
  onChange: (view: CalendarView) => void;
}) {
  return (
    <div
      role="group"
      aria-label="Widok kalendarza"
      className="flex w-full rounded-xl border border-[#3a4236] bg-[#111511] p-1 md:inline-flex md:w-auto"
    >
      {(["day", "week"] as const).map((option) => {
        const active = view === option;
        return (
          <button
            key={option}
            type="button"
            aria-pressed={active}
            onClick={() => onChange(option)}
            className={`min-h-10 flex-1 rounded-lg px-4 text-sm font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] md:flex-none ${
              active
                ? "bg-[#536143] text-[#f2efe4]"
                : "text-[#a9ada4] hover:text-[#f2efe4]"
            }`}
          >
            {option === "day" ? "Dzień" : "Tydzień"}
            {active && <span className="sr-only"> (aktywny widok)</span>}
          </button>
        );
      })}
    </div>
  );
}
