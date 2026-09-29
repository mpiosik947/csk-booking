import type { InstructorOption } from "@/lib/admin/events/instructor-assignments";
export default function InstructorSelector({ options, selected, onChange, disabled, loading, error }: {
  options: InstructorOption[]; selected: string[]; onChange: (next: string[]) => void;
  disabled?: boolean; loading?: boolean; error?: boolean;
}) {
  const rows = [...options, ...selected.filter(id => !options.some(row => row.user_id === id)).map(id => ({ user_id: id, display_name: "Przypisany instruktor nie jest już dostępny — usuń przypisanie" }))];
  return <fieldset disabled={disabled || loading || error} className="my-4 min-w-0 rounded-xl border border-[#3d4638] bg-[#191e19] p-4">
    <legend className="px-2 font-semibold">Instruktorzy</legend>
    <p className="mb-3 text-sm text-[#a9ada4]">Wybierz dowolną liczbę instruktorów. Brak przypisania jest dozwolony.</p>
    {loading ? <p role="status">Ładowanie instruktorów…</p> : error ? <p role="alert">Nie udało się pobrać obsady. Odśwież dane przed zapisem.</p> : !rows.length ? <p>Brak aktywnych instruktorów w tym obiekcie.</p> :
      <div className="grid gap-2 sm:grid-cols-2">{rows.map(row => <label key={row.user_id} className="flex min-w-0 items-start gap-3 rounded-lg border border-[#343d2e] p-3">
        <input type="checkbox" className="mt-1" checked={selected.includes(row.user_id)} onChange={e => onChange(e.target.checked ? [...selected,row.user_id] : selected.filter(id=>id!==row.user_id))} />
        <span className="[overflow-wrap:anywhere]">{row.display_name}</span>
      </label>)}</div>}
  </fieldset>;
}
