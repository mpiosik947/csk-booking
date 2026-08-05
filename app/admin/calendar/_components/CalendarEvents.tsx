import type { CalendarEventEntry } from "@/lib/admin/calendar/types";

export default function CalendarEvents({
  events,
  onSelectEntry,
}: {
  events: CalendarEventEntry[];
  onSelectEntry: (entry: CalendarEventEntry, activator: HTMLButtonElement) => void;
}) {
  if (events.length === 0) return null;

  return (
    <section className="mb-5 rounded-2xl border border-[#806a32] bg-[#211e15] p-4" aria-labelledby="calendar-events-title">
      <h2 id="calendar-events-title" className="text-sm font-bold uppercase tracking-[0.18em] text-[#e1c477]">
        Wydarzenia dnia
      </h2>
      <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {events.map((event) => (
          <button
            key={event.id}
            type="button"
            onClick={(clickEvent) => onSelectEntry(event, clickEvent.currentTarget)}
            className="cursor-pointer rounded-xl border border-[#5f522d] bg-[#2b2618] p-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e1c477]"
          >
            <p className="text-xs font-bold uppercase tracking-[0.12em] text-[#d7c895]">Event · {event.startTime}–{event.endTime}</p>
            <h3 className="mt-1 font-semibold text-[#f2efe4]">{event.label}</h3>
            <p className="mt-2 text-sm text-[#c7cbbf]">{event.location || "Lokalizacja niepodana"}</p>
            <p className="mt-1 text-xs text-[#a9ada4]">Limit uczestników: {event.maxParticipants}</p>
          </button>
        ))}
      </div>
    </section>
  );
}
