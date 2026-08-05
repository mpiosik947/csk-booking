const items = [
  { label: "Rezerwacja", symbol: "R", className: "border-[#55719a] bg-[#172235]" },
  { label: "Blokada", symbol: "B", className: "border-[#9a6648] bg-[#302118]" },
  { label: "Wpis historyczny", symbol: "H", className: "border-[#596057] bg-[#202420] opacity-70" },
  { label: "Event", symbol: "E", className: "border-[#806a32] bg-[#2b2618]" },
] as const;

export default function CalendarLegend() {
  return (
    <section aria-label="Legenda kalendarza" className="flex flex-wrap gap-2 text-xs text-[#c7cbbf]">
      {items.map((item) => (
        <div key={item.label} className={`flex items-center gap-2 rounded-lg border px-2.5 py-1.5 ${item.className}`}>
          <span aria-hidden="true" className="font-black">{item.symbol}</span>
          <span>{item.label}</span>
        </div>
      ))}
    </section>
  );
}
