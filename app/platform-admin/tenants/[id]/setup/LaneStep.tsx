import type { Configuration } from "@/lib/platform-draft-configuration";

type Props = { lanes: Configuration["lanes"]; booking: boolean; onCreate: () => void; onEdit: (id: string) => void };
export default function LaneStep({ lanes, booking, onCreate, onEdit }: Props) {
  return <section className="space-y-4">
    <p>{booking ? "Czasy, stawki i tryby rezerwacji ustawiasz osobno dla osi i stanowisk. Obecne okno rezerwacji to 08:00–20:00." :
      "Oś zapisujesz razem z jej stanowiskami, czasami i stawkami."}</p>
    <button type="button" className="min-h-11 rounded-lg border px-4" onClick={onCreate}>Dodaj oś</button>
    {!lanes.families.length && <p>Nie dodano jeszcze osi.</p>}
    {lanes.families.map(f => <article key={f.root_lane_id} className="min-w-0 space-y-3 rounded-lg border border-[#626b55] p-4">
      <h3 className="break-words text-xl font-bold">{f.root.name}</h3>
      <p>Stanowiska: {f.children.length} · Rezerwacja stanowisk: {f.root.positions_bookable ? "tak" : "nie"} · Cała oś: {f.root.whole_lane_bookable ? "tak" : "nie"}</p>
      <div className="space-y-2">{f.resources.map(r => {
        const prices = r.pricing.filter(p => p.is_active).map(p => p.hourly_price);
        const min = prices.length ? Math.min(...prices) : null;
        const max = prices.length ? Math.max(...prices) : null;
        return <div key={r.lane_id} className="break-words border-t border-[#47503e] pt-2 text-sm">
          <strong>{r.resource_kind === "lane" ? "Cała oś" : "Stanowisko"} · {r.name}</strong>
          <p>{min === null ? "Brak aktywnych stawek" : `Stawki: ${min}${min === max ? "" : "–" + max} ${r.currency_code}/h (zależnie od dnia i liczby osób)`}</p>
          {booking && <p>{r.is_active ? "W użyciu" : "Wyłączone"} · Rezerwacje online: {r.online_bookable ? "tak" : "nie"}
            {" "}· Maks. osób: {r.max_people_online} · Odstęp rozpoczęcia: {r.booking_step_minutes} min
            {" "}· Długości: {r.durations.filter(d => d.is_active).map(d => d.duration_minutes + " min").join(", ") || "brak"}</p>}
        </div>;
      })}</div>
      <button type="button" className="min-h-11 rounded-lg border px-4" onClick={() => onEdit(f.root_lane_id)}>
        {booking ? "Edytuj rezerwacje i ceny" : "Edytuj oś i stanowiska"}
      </button>
    </article>)}
  </section>;
}
