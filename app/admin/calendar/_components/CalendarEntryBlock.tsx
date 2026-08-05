import type { CalendarPositionedEntry } from "../calendar-ui";

function statusLabel(status: string) {
  if (status === "completed") return "Zakończona";
  if (status === "no_show") return "No-show";
  if (status === "inactive") return "Historyczna";
  return null;
}

export default function CalendarEntryBlock({
  positioned,
}: {
  positioned: CalendarPositionedEntry;
}) {
  const { entry, geometry, columnIndex, columnCount } = positioned;
  const historicalStatus = statusLabel(entry.status);
  const isReservation = entry.type === "reservation";
  const left = (columnIndex / columnCount) * 100;
  const width = 100 / columnCount;

  return (
    <article
      aria-label={`${isReservation ? "Rezerwacja" : "Blokada"}: ${entry.startTime}–${entry.endTime}, ${entry.label}`}
      className={`absolute overflow-hidden rounded-lg border px-2 py-1.5 shadow-lg ${
        entry.isHistorical
          ? "border-[#596057] bg-[#202420]/95 text-[#b5baaf] opacity-75"
          : isReservation
            ? "border-[#55719a] bg-[#172235]/95 text-[#dce8ff]"
            : "border-[#9a6648] bg-[#302118]/95 text-[#f2d0b6]"
      }`}
      style={{
        top: geometry.top,
        height: geometry.height,
        left: `calc(${left}% + 3px)`,
        width: `calc(${width}% - 6px)`,
      }}
    >
      <p className="truncate text-[10px] font-black uppercase tracking-[0.1em]">
        {isReservation ? "R · Rezerwacja" : "B · Blokada"}
      </p>
      <p className="truncate text-xs font-bold">{entry.startTime}–{entry.endTime}</p>
      <p className="truncate text-xs">{entry.label}</p>
      {isReservation ? (
        <p className="truncate text-[10px] opacity-80">
          {entry.shootersCount} os.{historicalStatus ? ` · ${historicalStatus}` : ""}
        </p>
      ) : (
        <p className="truncate text-[10px] opacity-80">
          {entry.reason || "Bez podanego powodu"}{historicalStatus ? ` · ${historicalStatus}` : ""}
        </p>
      )}
      {geometry.isClipped && (
        <span className="mt-1 inline-block rounded border border-current px-1 text-[9px] font-bold uppercase">
          Poza godzinami
        </span>
      )}
    </article>
  );
}
