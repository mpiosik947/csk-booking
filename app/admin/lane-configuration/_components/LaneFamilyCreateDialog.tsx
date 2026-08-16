"use client";

import { useMemo, useState } from "react";
import {
  LANE_RESOURCE_NAME_MAX_LENGTH,
  addPositionToLaneFamilyCreateState,
  buildLaneFamilyCreatePayload,
  createInitialLaneFamilyCreateState,
  removePositionFromLaneFamilyCreateState,
  validateLaneFamilyCreateState,
  type LaneFamilyCreateResult,
  type LaneFamilyCreateResourceEdit,
  type LaneFamilyCreateState,
  type LaneFamilyCreateWritePayload,
  type LaneFamilyPricingEdit,
} from "../../../../lib/admin/lane-configuration";

type Props = {
  onClose: () => void;
  onCreate: (payload: LaneFamilyCreateWritePayload) => Promise<LaneFamilyCreateResult>;
  onCompleted: (message: string) => Promise<void>;
};

const inputClass =
  "min-h-11 w-full min-w-0 rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] outline-none focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25";
const INITIAL_CREATE_STATE_JSON = JSON.stringify(createInitialLaneFamilyCreateState());

function FieldLabel({ children }: { children: React.ReactNode }) {
  return <span className="mb-2 block text-sm font-semibold text-[#c7cbbf]">{children}</span>;
}

function BooleanField({
  label,
  checked,
  onChange,
  help,
}: {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  help?: string;
}) {
  return (
    <label className="flex min-h-11 items-start gap-3 rounded-xl border border-[#3d4638] bg-[#141814] p-3">
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        className="mt-1 h-4 w-4 accent-[#d7c895]"
      />
      <span className="min-w-0">
        <strong className="block text-sm text-[#f2efe4]">{label}</strong>
        {help && <span className="mt-1 block text-xs text-[#858c7f]">{help}</span>}
      </span>
    </label>
  );
}

function PricingEditor({
  resource,
  onChange,
}: {
  resource: LaneFamilyCreateResourceEdit;
  onChange: (resource: LaneFamilyCreateResourceEdit) => void;
}) {
  function updateRule(editKey: string, patch: Partial<LaneFamilyPricingEdit>) {
    onChange({
      ...resource,
      pricing: resource.pricing.map((rule) =>
        rule.edit_key === editKey ? { ...rule, ...patch } : rule
      ),
    });
  }

  function addRule(dayGroup: LaneFamilyPricingEdit["day_group"]) {
    const nextNumber =
      resource.pricing.reduce((highest, rule) => {
        const match = /:(\d+)$/.exec(rule.edit_key);
        return match ? Math.max(highest, Number(match[1])) : highest;
      }, 0) + 1;
    onChange({
      ...resource,
      pricing: [
        ...resource.pricing,
        {
          edit_key: `${resource.edit_key}:pricing:${dayGroup}:${nextNumber}`,
          day_group: dayGroup,
          min_shooters: "",
          max_shooters: "",
          label: "",
          hourly_price: "",
        },
      ],
    });
  }

  return (
    <div className="space-y-4">
      {(["mon_thu", "fri_sun"] as const).map((dayGroup) => {
        const groupLabel = dayGroup === "mon_thu" ? "Pon–Czw" : "Pt–Nd";
        const rules = resource.pricing.filter((rule) => rule.day_group === dayGroup);
        return (
          <section
            key={dayGroup}
            className="rounded-2xl border border-[#30372c] bg-[#101310] p-3 sm:p-4"
          >
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h4 className="font-semibold text-[#d7c895]">{groupLabel}</h4>
              <button
                type="button"
                onClick={() => addRule(dayGroup)}
                className="min-h-11 rounded-xl border border-[#536143] px-3 py-2 text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
              >
                + Dodaj próg
              </button>
            </div>
            <div className="mt-3 space-y-3">
              {rules.map((rule) => (
                <div
                  key={rule.edit_key}
                  className="grid min-w-0 gap-3 rounded-xl border border-[#30372c] bg-[#171b17] p-3 md:grid-cols-[minmax(5rem,0.65fr)_minmax(5rem,0.65fr)_minmax(0,1.4fr)_minmax(6rem,0.8fr)_auto]"
                >
                  <label className="min-w-0">
                    <FieldLabel>Od osób</FieldLabel>
                    <input
                      value={rule.min_shooters}
                      inputMode="numeric"
                      onChange={(event) =>
                        updateRule(rule.edit_key, { min_shooters: event.target.value })
                      }
                      className={inputClass}
                    />
                  </label>
                  <label className="min-w-0">
                    <FieldLabel>Do osób</FieldLabel>
                    <input
                      value={rule.max_shooters}
                      inputMode="numeric"
                      onChange={(event) =>
                        updateRule(rule.edit_key, { max_shooters: event.target.value })
                      }
                      className={inputClass}
                    />
                  </label>
                  <label className="min-w-0">
                    <FieldLabel>Opis progu</FieldLabel>
                    <input
                      value={rule.label}
                      onChange={(event) =>
                        updateRule(rule.edit_key, { label: event.target.value })
                      }
                      className={inputClass}
                    />
                  </label>
                  <label className="min-w-0">
                    <FieldLabel>Cena PLN/h</FieldLabel>
                    <input
                      value={rule.hourly_price}
                      inputMode="decimal"
                      onChange={(event) =>
                        updateRule(rule.edit_key, { hourly_price: event.target.value })
                      }
                      className={inputClass}
                    />
                  </label>
                  <button
                    type="button"
                    aria-label={`Usuń próg ${groupLabel}`}
                    onClick={() =>
                      onChange({
                        ...resource,
                        pricing: resource.pricing.filter(
                          (candidate) => candidate.edit_key !== rule.edit_key
                        ),
                      })
                    }
                    className="min-h-11 self-end rounded-xl border border-[#744545] px-3 text-sm text-[#edb1b1] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#edb1b1]"
                  >
                    Usuń
                  </button>
                </div>
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}

function ResourceCreateFields({
  resource,
  kind,
  onChange,
}: {
  resource: LaneFamilyCreateResourceEdit;
  kind: "lane" | "position";
  onChange: (resource: LaneFamilyCreateResourceEdit) => void;
}) {
  return (
    <div className="space-y-5">
      <div className="grid min-w-0 gap-4 sm:grid-cols-2">
        <label className="min-w-0 sm:col-span-2">
          <FieldLabel>{kind === "lane" ? "Nazwa osi" : "Nazwa stanowiska"}</FieldLabel>
          <input
            value={resource.name}
            maxLength={LANE_RESOURCE_NAME_MAX_LENGTH}
            onChange={(event) => onChange({ ...resource, name: event.target.value })}
            className={inputClass}
          />
        </label>
        <label className="min-w-0">
          <FieldLabel>{kind === "lane" ? "Pojemność osi" : "Pojemność stanowiska"}</FieldLabel>
          <input
            value={resource.max_shooters}
            inputMode="numeric"
            onChange={(event) =>
              onChange({ ...resource, max_shooters: event.target.value })
            }
            className={inputClass}
          />
        </label>
        <label className="min-w-0">
          <FieldLabel>Maks. osób w jednej rezerwacji</FieldLabel>
          <input
            value={resource.max_people_online}
            inputMode="numeric"
            onChange={(event) =>
              onChange({ ...resource, max_people_online: event.target.value })
            }
            className={inputClass}
          />
        </label>
        <label className="min-w-0">
          <FieldLabel>Krok rezerwacji (min)</FieldLabel>
          <input
            value={resource.booking_step_minutes}
            inputMode="numeric"
            onChange={(event) =>
              onChange({ ...resource, booking_step_minutes: event.target.value })
            }
            className={inputClass}
          />
        </label>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <BooleanField
          label="Aktywny zasób"
          checked={resource.is_active}
          onChange={(checked) => onChange({ ...resource, is_active: checked })}
          help="Nowe zasoby domyślnie pozostają nieaktywne."
        />
        <BooleanField
          label="Rezerwacje online"
          checked={resource.online_bookable}
          onChange={(checked) => onChange({ ...resource, online_bookable: checked })}
          help="Wymaga aktywnego zasobu i kompletnej konfiguracji sprzedaży."
        />
      </div>

      <section>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h4 className="font-semibold text-[#f2efe4]">Czasy rezerwacji</h4>
          <button
            type="button"
            onClick={() =>
              onChange({
                ...resource,
                durations_minutes: [...resource.durations_minutes, ""],
              })
            }
            className="min-h-11 rounded-xl border border-[#536143] px-3 py-2 text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            + Dodaj czas
          </button>
        </div>
        <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {resource.durations_minutes.map((duration, index) => (
            <div key={`${resource.edit_key}:duration:${index}`} className="flex min-w-0 gap-2">
              <label className="min-w-0 flex-1">
                <span className="sr-only">Czas rezerwacji w minutach</span>
                <input
                  value={duration}
                  inputMode="numeric"
                  onChange={(event) =>
                    onChange({
                      ...resource,
                      durations_minutes: resource.durations_minutes.map((value, itemIndex) =>
                        itemIndex === index ? event.target.value : value
                      ),
                    })
                  }
                  className={inputClass}
                />
              </label>
              <button
                type="button"
                aria-label={`Usuń czas ${duration || index + 1}`}
                onClick={() =>
                  onChange({
                    ...resource,
                    durations_minutes: resource.durations_minutes.filter(
                      (_, itemIndex) => itemIndex !== index
                    ),
                  })
                }
                className="min-h-11 rounded-xl border border-[#744545] px-3 text-[#edb1b1] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#edb1b1]"
              >
                ×
              </button>
            </div>
          ))}
        </div>
      </section>

      <section>
        <h4 className="mb-3 font-semibold text-[#f2efe4]">Cennik</h4>
        <PricingEditor resource={resource} onChange={onChange} />
      </section>
    </div>
  );
}

function CreationReview({ state }: { state: LaneFamilyCreateState }) {
  const resources = [state.root, ...state.positions];
  return (
    <div className="space-y-4">
      <div className="rounded-2xl border border-[#536143] bg-[#20271e] p-4 text-sm text-[#b9c9a5]">
        Zostanie utworzona jedna rodzina: oś główna i {state.positions.length} stanowisk.
        Zapis nastąpi atomowo w jednym wywołaniu RPC.
      </div>
      {resources.map((resource, index) => (
        <section
          key={resource.edit_key}
          className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4"
        >
          <p className="text-xs font-bold uppercase tracking-[0.16em] text-[#d7c895]">
            {index === 0 ? "Oś główna" : `Stanowisko ${index}`}
          </p>
          <h3 className="mt-1 break-words text-lg font-bold text-[#f2efe4]">
            {resource.name.trim()}
          </h3>
          <dl className="mt-3 grid gap-2 text-sm sm:grid-cols-2">
            <div><dt className="text-[#858c7f]">Status</dt><dd className="text-[#f2efe4]">{resource.is_active ? "Aktywny" : "Nieaktywny"}</dd></div>
            <div><dt className="text-[#858c7f]">Online</dt><dd className="text-[#f2efe4]">{resource.online_bookable ? "Włączone" : "Wyłączone"}</dd></div>
            <div><dt className="text-[#858c7f]">Pojemność</dt><dd className="text-[#f2efe4]">{resource.max_shooters}</dd></div>
            <div><dt className="text-[#858c7f]">Maks. osób w rezerwacji</dt><dd className="text-[#f2efe4]">{resource.max_people_online}</dd></div>
            <div><dt className="text-[#858c7f]">Czasy</dt><dd className="break-words text-[#f2efe4]">{resource.durations_minutes.join(", ")} min</dd></div>
            <div><dt className="text-[#858c7f]">Progi cenowe</dt><dd className="text-[#f2efe4]">{resource.pricing.length}</dd></div>
          </dl>
        </section>
      ))}
      <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 text-sm">
        <h3 className="font-semibold text-[#f2efe4]">Tryby osi</h3>
        <p className="mt-2 text-[#a9ada4]">Rezerwacja całej osi: <strong className="text-[#f2efe4]">{state.root_whole_lane_bookable ? "Włączona" : "Wyłączona"}</strong></p>
        <p className="mt-1 text-[#a9ada4]">Rezerwacja stanowisk: <strong className="text-[#f2efe4]">{state.root_positions_bookable ? "Włączona" : "Wyłączona"}</strong></p>
      </section>
    </div>
  );
}

export default function LaneFamilyCreateDialog({ onClose, onCreate, onCompleted }: Props) {
  const [state, setState] = useState(createInitialLaneFamilyCreateState);
  const [step, setStep] = useState<"edit" | "review">("edit");
  const [saving, setSaving] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");
  const validation = useMemo(() => validateLaneFamilyCreateState(state), [state]);
  const dirty = JSON.stringify(state) !== INITIAL_CREATE_STATE_JSON;

  function requestClose() {
    if (dirty && !window.confirm("Masz niezapisany formularz nowej osi. Czy go odrzucić?")) {
      return;
    }
    onClose();
  }

  function updatePosition(editKey: string, resource: LaneFamilyCreateResourceEdit) {
    setState((current) => ({
      ...current,
      positions: current.positions.map((position) =>
        position.edit_key === editKey ? resource : position
      ),
    }));
  }

  async function submit() {
    if (saving) return;
    setSaving(true);
    setErrorMessage("");
    try {
      const payload = buildLaneFamilyCreatePayload(state);
      const result = await onCreate(payload);
      if (result.code === "created") {
        await onCompleted("Nowa rodzina osi została utworzona.");
        return;
      }
      setErrorMessage(
        result.code === "not_allowed"
          ? "Brak uprawnień do utworzenia osi."
          : "Nie udało się utworzyć osi. Sprawdź pełną konfigurację i spróbuj ponownie."
      );
    } catch {
      setErrorMessage("Nie udało się bezpiecznie utworzyć osi.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/75 p-0 sm:items-center sm:p-5"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) requestClose();
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="lane-family-create-title"
        className="max-h-[94vh] w-full overflow-y-auto overflow-x-hidden rounded-t-3xl border border-[#3d4638] bg-[#141814] p-4 shadow-2xl sm:max-w-5xl sm:rounded-3xl sm:p-7"
      >
        <header className="flex items-start justify-between gap-4 border-b border-[#30372c] pb-5">
          <div className="min-w-0">
            <p className="text-xs font-bold uppercase tracking-[0.2em] text-[#d7c895]">
              {step === "edit" ? "Nowa rodzina osi" : "Potwierdzenie utworzenia"}
            </p>
            <h2 id="lane-family-create-title" className="mt-2 text-2xl font-bold text-[#f2efe4]">
              {step === "edit" ? "Dodaj nową oś" : "Sprawdź pełną konfigurację"}
            </h2>
          </div>
          <button
            type="button"
            onClick={requestClose}
            aria-label="Zamknij formularz nowej osi"
            className="min-h-11 min-w-11 rounded-xl border border-[#3d4638] text-xl text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            ×
          </button>
        </header>

        {errorMessage && (
          <div role="alert" className="mt-5 rounded-2xl border border-[#744545] bg-[#2a1b1b] p-4 text-[#edb1b1]">
            {errorMessage}
          </div>
        )}

        <div className="mt-6">
          {step === "review" ? (
            <CreationReview state={state} />
          ) : (
            <div className="space-y-6">
              <p className="rounded-2xl border border-[#3d4638] bg-[#191e19] p-4 text-sm text-[#a9ada4]">
                Nowa rodzina startuje bezpiecznie jako nieaktywna i offline. Nazwa jest etykietą prezentacyjną; techniczne UUID wygeneruje baza.
              </p>
              <fieldset className="rounded-2xl border border-[#3d4638] bg-[#191e19] p-4 sm:p-5">
                <legend className="px-1 text-sm font-bold text-[#f2efe4]">Rodzaj</legend>
                <div className="mt-2 grid min-w-0 gap-3 sm:grid-cols-2">
                  <label className="flex min-h-11 items-start gap-3 rounded-xl border border-[#3d4638] bg-[#141814] p-3">
                    <input
                      type="radio"
                      name="lane-family-kind"
                      checked={state.positions.length === 0}
                      onChange={() => {
                        if (
                          state.positions.length === 0 ||
                          window.confirm(
                            "Zmiana na oś samodzielną usunie przygotowane stanowiska. Kontynuować?"
                          )
                        ) {
                          setState((current) => ({ ...current, positions: [] }));
                        }
                      }}
                      className="mt-1 h-4 w-4 accent-[#d7c895]"
                    />
                    <span className="min-w-0">
                      <strong className="block text-sm text-[#f2efe4]">Samodzielna</strong>
                      <span className="mt-1 block text-xs text-[#858c7f]">
                        Jedna oś bez zasobów podrzędnych.
                      </span>
                    </span>
                  </label>
                  <label className="flex min-h-11 items-start gap-3 rounded-xl border border-[#3d4638] bg-[#141814] p-3">
                    <input
                      type="radio"
                      name="lane-family-kind"
                      checked={state.positions.length > 0}
                      onChange={() => {
                        if (state.positions.length === 0) {
                          setState(addPositionToLaneFamilyCreateState);
                        }
                      }}
                      className="mt-1 h-4 w-4 accent-[#d7c895]"
                    />
                    <span className="min-w-0">
                      <strong className="block text-sm text-[#f2efe4]">Ze stanowiskami</strong>
                      <span className="mt-1 block text-xs text-[#858c7f]">
                        Oś główna z dowolną liczbą edytowalnych stanowisk.
                      </span>
                    </span>
                  </label>
                </div>
              </fieldset>
              <section className="rounded-2xl border border-[#3d4638] bg-[#191e19] p-4 sm:p-5">
                <h3 className="mb-5 text-lg font-bold text-[#f2efe4]">Oś główna</h3>
                <ResourceCreateFields
                  resource={state.root}
                  kind="lane"
                  onChange={(root) => setState((current) => ({ ...current, root }))}
                />
                <div className="mt-5 grid gap-3 sm:grid-cols-2">
                  <BooleanField
                    label="Rezerwacja całej osi"
                    checked={state.root_whole_lane_bookable}
                    onChange={(checked) =>
                      setState((current) => ({
                        ...current,
                        root_whole_lane_bookable: checked,
                      }))
                    }
                  />
                  <BooleanField
                    label="Rezerwacja stanowisk"
                    checked={state.root_positions_bookable}
                    onChange={(checked) =>
                      setState((current) => ({
                        ...current,
                        root_positions_bookable: checked,
                      }))
                    }
                  />
                </div>
              </section>

              <section className="rounded-2xl border border-[#3d4638] bg-[#191e19] p-4 sm:p-5">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <h3 className="text-lg font-bold text-[#f2efe4]">Stanowiska</h3>
                    <p className="mt-1 text-sm text-[#a9ada4]">
                      Opcjonalne; każde ma własne limity, czasy i cennik.
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => setState(addPositionToLaneFamilyCreateState)}
                    className="min-h-11 rounded-xl bg-[#d7c895] px-4 py-2 text-sm font-bold text-[#171a15] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4]"
                  >
                    + Dodaj stanowisko
                  </button>
                </div>
                {state.positions.length === 0 ? (
                  <p className="mt-4 rounded-xl border border-[#30372c] bg-[#141814] p-4 text-sm text-[#858c7f]">
                    Brak stanowisk — zostanie utworzona samodzielna oś.
                  </p>
                ) : (
                  <div className="mt-5 space-y-5">
                    {state.positions.map((position, index) => (
                      <section
                        key={position.edit_key}
                        className="rounded-2xl border border-[#30372c] bg-[#141814] p-4"
                      >
                        <div className="mb-5 flex flex-wrap items-center justify-between gap-2">
                          <h4 className="font-bold text-[#f2efe4]">Stanowisko {index + 1}</h4>
                          <button
                            type="button"
                            onClick={() =>
                              setState((current) =>
                                removePositionFromLaneFamilyCreateState(
                                  current,
                                  position.edit_key
                                )
                              )
                            }
                            className="min-h-11 rounded-xl border border-[#744545] px-3 text-sm text-[#edb1b1] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#edb1b1]"
                          >
                            Usuń stanowisko
                          </button>
                        </div>
                        <ResourceCreateFields
                          resource={position}
                          kind="position"
                          onChange={(resource) =>
                            updatePosition(position.edit_key, resource)
                          }
                        />
                      </section>
                    ))}
                  </div>
                )}
              </section>

              {!validation.valid && (
                <section role="alert" className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-4 text-[#e1c477]">
                  <h3 className="font-bold">Uzupełnij konfigurację przed podsumowaniem:</h3>
                  <ul className="mt-2 list-disc space-y-1 pl-5 text-sm">
                    {validation.errors.map((error) => <li key={error}>{error}</li>)}
                  </ul>
                </section>
              )}
            </div>
          )}
        </div>

        <footer className="mt-7 flex flex-col-reverse gap-3 border-t border-[#30372c] pt-5 sm:flex-row sm:justify-end">
          <button
            type="button"
            onClick={() => (step === "review" ? setStep("edit") : requestClose())}
            disabled={saving}
            className="min-h-11 rounded-xl border border-[#3d4638] px-4 py-2 font-semibold text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
          >
            {step === "review" ? "← Wróć do formularza" : "Anuluj"}
          </button>
          {step === "edit" ? (
            <button
              type="button"
              onClick={() => {
                if (validation.valid) setStep("review");
              }}
              disabled={!validation.valid}
              className="min-h-11 rounded-xl bg-[#d7c895] px-4 py-2 font-bold text-[#171a15] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4] disabled:cursor-not-allowed disabled:opacity-50"
            >
              Przejdź do podsumowania
            </button>
          ) : (
            <button
              type="button"
              onClick={() => void submit()}
              disabled={saving}
              className="min-h-11 rounded-xl bg-[#d7c895] px-4 py-2 font-bold text-[#171a15] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4] disabled:cursor-not-allowed disabled:opacity-50"
            >
              {saving ? "Tworzenie…" : "Utwórz rodzinę osi"}
            </button>
          )}
        </footer>
      </section>
    </div>
  );
}
