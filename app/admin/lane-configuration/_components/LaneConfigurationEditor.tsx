"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  buildLaneFamilyWritePayload,
  createLaneFamilyEditState,
  getLaneFamilyChanges,
  isLaneFamilyDirty,
  validateLaneFamilyEditState,
  type LaneConfigurationFamily,
  type LaneConfigurationResource,
  type LaneConfigurationWriteResult,
  type LaneFamilyEditState,
  type LaneFamilyWriteResource,
} from "../../../../lib/admin/lane-configuration";

type EditorStep = "edit" | "review" | "confirmation" | "stale";

type PendingWrite = {
  expectedVersion: number;
  payload: LaneFamilyWriteResource[];
};

type Props = {
  family: LaneConfigurationFamily;
  onClose: () => void;
  onDirtyChange: (dirty: boolean) => void;
  onWrite: (
    rootLaneId: string,
    expectedVersion: number,
    payload: LaneFamilyWriteResource[],
    acknowledgeFutureObligations: boolean
  ) => Promise<LaneConfigurationWriteResult>;
  onCompleted: (message: string) => Promise<void>;
};

const CONTROLLED_RESULT_MESSAGES: Record<string, string> = {
  not_allowed: "Nie masz uprawnień do zmiany konfiguracji osi.",
  family_not_found: "Nie znaleziono wskazanej rodziny zasobów.",
  invalid_payload: "Nie udało się przygotować bezpiecznego zestawu zmian.",
  invalid_hierarchy: "Hierarchia osi zmieniła się. Odśwież dane przed ponowną edycją.",
  invalid_configuration: "Konfiguracja nie spełnia wymagań systemu rezerwacji.",
  reservation_capacity_conflict:
    "Nie można obniżyć pojemności, ponieważ istnieje przyszła rezerwacja wymagająca większej liczby miejsc.",
};

function updateResourceLimit(
  state: LaneFamilyEditState,
  laneId: string,
  field: "max_shooters" | "max_people_online",
  value: string
): LaneFamilyEditState {
  return {
    ...state,
    resources: state.resources.map((resource) =>
      resource.lane_id === laneId ? { ...resource, [field]: value } : resource
    ),
  };
}

function ToggleField({
  id,
  label,
  checked,
  disabled,
  onChange,
}: {
  id: string;
  label: string;
  checked: boolean;
  disabled: boolean;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label
      htmlFor={id}
      className="flex min-h-11 items-center justify-between gap-4 rounded-xl border border-[#3d4638] bg-[#101310] px-4 py-3"
    >
      <span className="text-sm font-semibold text-[#e3dfd2]">{label}</span>
      <input
        id={id}
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(event) => onChange(event.target.checked)}
        className="h-6 w-6 accent-[#8b7b48] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-50"
      />
    </label>
  );
}

function LimitFields({
  resource,
  state,
  disabled,
  onChange,
}: {
  resource: LaneConfigurationResource;
  state: LaneFamilyEditState;
  disabled: boolean;
  onChange: (state: LaneFamilyEditState) => void;
}) {
  const edit = state.resources.find((candidate) => candidate.lane_id === resource.lane_id);
  if (!edit) return null;
  const isPosition = resource.resource_kind === "position";
  const capacityLabel = isPosition ? "Pojemność stanowiska" : "Pojemność osi";
  const capacityDescription = isPosition
    ? "Maksymalna liczba osób, które mogą jednocześnie korzystać z tego stanowiska."
    : "Maksymalna liczba osób, które mogą jednocześnie korzystać z tej osi.";

  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <label className="block">
        <span className="text-sm font-semibold text-[#e3dfd2]">{capacityLabel}</span>
        <input
          type="number"
          inputMode="numeric"
          min="1"
          step="1"
          value={edit.max_shooters}
          disabled={disabled}
          onChange={(event) =>
            onChange(
              updateResourceLimit(
                state,
                resource.lane_id,
                "max_shooters",
                event.target.value
              )
            )
          }
          className="mt-2 min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] outline-none focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25 disabled:cursor-not-allowed disabled:opacity-60"
        />
        <span className="mt-2 block text-xs leading-5 text-[#92988c]">
          {capacityDescription}
        </span>
      </label>
      <label className="block">
        <span className="text-sm font-semibold text-[#e3dfd2]">
          Maks. osób w jednej rezerwacji
        </span>
        <input
          type="number"
          inputMode="numeric"
          min="1"
          step="1"
          value={edit.max_people_online}
          disabled={disabled}
          onChange={(event) =>
            onChange(
              updateResourceLimit(
                state,
                resource.lane_id,
                "max_people_online",
                event.target.value
              )
            )
          }
          className="mt-2 min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] outline-none focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25 disabled:cursor-not-allowed disabled:opacity-60"
        />
        <span className="mt-2 block text-xs leading-5 text-[#92988c]">
          Największa liczba osób, którą klient może wskazać w jednej nowej rezerwacji
          online.
        </span>
      </label>
    </div>
  );
}

function ReadOnlySalesConfiguration({
  resource,
}: {
  resource: LaneConfigurationResource;
}) {
  const activeDurations = resource.durations.filter((duration) => duration.is_active);
  const activePricing = resource.pricing.filter((rule) => rule.is_active);
  return (
    <div className="mt-4 rounded-xl border border-[#30372c] bg-[#161a16] p-3">
      <p className="text-xs font-bold uppercase tracking-[0.12em] text-[#8f9589]">
        Czasy i cennik — tylko odczyt
      </p>
      <p className="mt-2 text-sm text-[#c7cbbf]">
        Czasy: {activeDurations.length > 0
          ? activeDurations.map((duration) => `${duration.duration_minutes} min`).join(", ")
          : "brak"}
      </p>
      <p className="mt-1 text-sm text-[#c7cbbf]">
        Aktywne progi cenowe: {activePricing.length}
      </p>
      {(resource.durations.some((duration) => !duration.is_active) ||
        resource.pricing.some((rule) => !rule.is_active)) && (
        <p className="mt-2 text-xs text-[#858c7f]">
          Historyczne nieaktywne wpisy pozostają widoczne w szczegółach zasobu.
        </p>
      )}
    </div>
  );
}

function ChangeSummary({
  family,
  state,
}: {
  family: LaneConfigurationFamily;
  state: LaneFamilyEditState;
}) {
  const changes = getLaneFamilyChanges(family, state);
  return (
    <div className="space-y-3">
      {changes.map((change) => (
        <div
          key={`${change.resourceName}-${change.label}`}
          className="rounded-xl border border-[#3d4638] bg-[#101310] p-4"
        >
          <p className="text-xs font-semibold uppercase tracking-[0.12em] text-[#8f9589]">
            {change.resourceName}
          </p>
          <p className="mt-1 text-sm font-semibold text-[#f2efe4]">{change.label}</p>
          <p className="mt-2 text-sm text-[#d7c895]">
            <span className="text-[#a9ada4]">{change.before}</span>
            <span aria-hidden="true" className="px-2">→</span>
            <strong>{change.after}</strong>
          </p>
        </div>
      ))}
    </div>
  );
}

export default function LaneConfigurationEditor({
  family,
  onClose,
  onDirtyChange,
  onWrite,
  onCompleted,
}: Props) {
  const [state, setState] = useState(() => createLaneFamilyEditState(family));
  const [step, setStep] = useState<EditorStep>("edit");
  const [pendingWrite, setPendingWrite] = useState<PendingWrite | null>(null);
  const [confirmationResult, setConfirmationResult] =
    useState<LaneConfigurationWriteResult | null>(null);
  const [message, setMessage] = useState("");
  const [saving, setSaving] = useState(false);
  const dialogRef = useRef<HTMLElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const primaryActionRef = useRef<HTMLButtonElement>(null);
  const dirtyRef = useRef(false);
  const dirty = isLaneFamilyDirty(family, state);
  const validation = useMemo(
    () => validateLaneFamilyEditState(family, state),
    [family, state]
  );
  const locked = saving || step === "confirmation" || step === "stale";

  useEffect(() => {
    dirtyRef.current = dirty;
    onDirtyChange(dirty);
  }, [dirty, onDirtyChange]);

  const requestClose = useCallback(() => {
    if (
      dirtyRef.current &&
      !window.confirm(
        "Masz niezapisane zmiany. Czy na pewno chcesz zamknąć edycję?"
      )
    ) {
      return;
    }
    onClose();
  }, [onClose]);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    window.setTimeout(() => closeButtonRef.current?.focus(), 0);

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.preventDefault();
        requestClose();
        return;
      }
      if (event.key !== "Tab") return;
      const focusable = dialogRef.current?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), a[href], summary, [tabindex]:not([tabindex="-1"])'
      );
      if (!focusable?.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      document.removeEventListener("keydown", handleKeyDown);
      onDirtyChange(false);
    };
  }, [onDirtyChange, requestClose]);

  useEffect(() => {
    if (step === "edit") return;
    window.setTimeout(
      () => (primaryActionRef.current ?? closeButtonRef.current)?.focus(),
      0
    );
  }, [step]);

  function openReview() {
    setMessage("");
    if (!dirty || !validation.valid) return;
    try {
      setPendingWrite({
        expectedVersion: family.configuration_version,
        payload: buildLaneFamilyWritePayload(family, state),
      });
      setStep("review");
    } catch {
      setMessage("Nie udało się przygotować bezpiecznego zestawu zmian.");
    }
  }

  async function submit(acknowledgeFutureObligations: boolean) {
    if (!pendingWrite || saving) return;
    setSaving(true);
    setMessage("");
    try {
      const result = await onWrite(
        family.root_lane_id,
        pendingWrite.expectedVersion,
        pendingWrite.payload,
        acknowledgeFutureObligations
      );
      if (result.code === "updated") {
        await onCompleted("Konfiguracja została zapisana.");
        return;
      }
      if (result.code === "no_change") {
        await onCompleted("Konfiguracja nie wymagała zmian.");
        return;
      }
      if (result.code === "confirmation_required") {
        setConfirmationResult(result);
        setStep("confirmation");
        return;
      }
      if (result.code === "stale_configuration") {
        setStep("stale");
        setMessage(
          "Konfiguracja została w międzyczasie zmieniona. Odśwież dane przed ponowną edycją."
        );
        return;
      }
      setMessage(
        CONTROLLED_RESULT_MESSAGES[result.code] ??
          "Nie udało się bezpiecznie zapisać konfiguracji."
      );
      setStep("edit");
    } catch {
      setMessage("Nie udało się bezpiecznie zapisać konfiguracji.");
      setStep("edit");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center overflow-x-hidden bg-black/75 p-0 sm:items-center sm:p-5"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) requestClose();
      }}
    >
      <section
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="lane-configuration-editor-title"
        className="max-h-[94vh] w-full overflow-y-auto overflow-x-hidden rounded-t-3xl border border-[#3d4638] bg-[#141814] p-4 shadow-2xl sm:max-w-4xl sm:rounded-3xl sm:p-7"
      >
        <header className="flex items-start justify-between gap-4 border-b border-[#30372c] pb-5">
          <div className="min-w-0">
            <p className="text-xs font-bold uppercase tracking-[0.2em] text-[#d7c895]">
              {step === "edit"
                ? "Edycja rodziny"
                : step === "review"
                  ? "Podsumowanie zmian"
                  : step === "confirmation"
                    ? "Wymagane potwierdzenie"
                    : "Nieaktualna konfiguracja"}
            </p>
            <h2
              id="lane-configuration-editor-title"
              className="mt-2 break-words text-xl font-bold text-[#f2efe4] sm:text-2xl"
            >
              {family.root.name}
            </h2>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            onClick={requestClose}
            aria-label="Zamknij edycję konfiguracji"
            disabled={saving}
            className="min-h-11 min-w-11 rounded-xl border border-[#3d4638] text-xl text-[#c7cbbf] transition hover:bg-[#20241f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-50"
          >
            ×
          </button>
        </header>

        {message && (
          <div role="alert" className="mt-5 rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]">
            {message}
          </div>
        )}

        {step === "edit" && (
          <div className="mt-6 space-y-6">
            <section aria-labelledby="root-settings-heading" className="rounded-2xl border border-[#3d4638] bg-[#191e19] p-4 sm:p-5">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <h3 id="root-settings-heading" className="font-bold text-[#f2efe4]">ROOT</h3>
                <span className="rounded-full border border-[#3d4638] px-3 py-1 text-xs font-semibold text-[#a9ada4]">
                  Status: {family.root.is_active ? "Aktywna" : "Nieaktywna"} — tylko odczyt
                </span>
              </div>
              <div className="mt-5">
                <LimitFields
                  resource={family.root}
                  state={state}
                  disabled={locked}
                  onChange={setState}
                />
              </div>
              <div className="mt-5 grid gap-3 sm:grid-cols-2">
                <ToggleField
                  id={`online-${family.root_lane_id}`}
                  label="Rezerwacja online"
                  checked={state.root_online_bookable}
                  disabled={locked}
                  onChange={(checked) => setState((current) => ({ ...current, root_online_bookable: checked }))}
                />
                <ToggleField
                  id={`whole-${family.root_lane_id}`}
                  label="Rezerwacja całej osi"
                  checked={state.root_whole_lane_bookable}
                  disabled={locked}
                  onChange={(checked) => setState((current) => ({ ...current, root_whole_lane_bookable: checked }))}
                />
                <ToggleField
                  id={`positions-${family.root_lane_id}`}
                  label="Rezerwacja stanowisk"
                  checked={state.root_positions_bookable}
                  disabled={locked || family.children.length === 0}
                  onChange={(checked) => setState((current) => ({ ...current, root_positions_bookable: checked }))}
                />
              </div>
              <ReadOnlySalesConfiguration resource={family.root} />
            </section>

            {family.children.length > 0 && (
              <section aria-labelledby="position-settings-heading" className="rounded-2xl border border-[#3d4638] bg-[#191e19] p-4 sm:p-5">
                <h3 id="position-settings-heading" className="font-bold text-[#f2efe4]">STANOWISKA</h3>
                <p className="mt-2 text-sm text-[#a9ada4]">
                  Status i dostępność online stanowisk są w tym etapie tylko do odczytu.
                </p>
                <div className="mt-5 space-y-4">
                  {family.children.map((child) => (
                    <article key={child.lane_id} className="rounded-2xl border border-[#30372c] bg-[#141814] p-4">
                      <div className="flex flex-wrap items-start justify-between gap-3">
                        <h4 className="font-semibold text-[#f2efe4]">{child.name}</h4>
                        <span className="text-xs font-semibold text-[#a9ada4]">
                          {child.is_active ? "Aktywne" : "Nieaktywne"} · {child.online_bookable ? "Online" : "Offline"}
                        </span>
                      </div>
                      <div className="mt-4">
                        <LimitFields resource={child} state={state} disabled={locked} onChange={setState} />
                      </div>
                      <ReadOnlySalesConfiguration resource={child} />
                    </article>
                  ))}
                </div>
              </section>
            )}

            {!validation.valid && (
              <div role="alert" className="rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]">
                <p className="font-semibold">Popraw konfigurację przed zapisem:</p>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {validation.errors.map((error) => <li key={error}>{error}</li>)}
                </ul>
              </div>
            )}
          </div>
        )}

        {step === "review" && (
          <div className="mt-6">
            <p className="mb-4 text-sm text-[#a9ada4]">
              Sprawdź wyłącznie pola, które faktycznie się zmienią.
            </p>
            <ChangeSummary family={family} state={state} />
          </div>
        )}

        {step === "confirmation" && confirmationResult && (
          <div className="mt-6 space-y-5">
            <div className="rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-[#e1c477]">
              <p className="font-semibold">
                Ta zmiana wpłynie na istniejące przyszłe zobowiązania.
              </p>
              <dl className="mt-4 grid gap-3 sm:grid-cols-3">
                <div><dt className="text-xs">Przyszłe rezerwacje</dt><dd className="text-2xl font-bold">{confirmationResult.futureReservationsCount}</dd></div>
                <div><dt className="text-xs">Blokady osi</dt><dd className="text-2xl font-bold">{confirmationResult.futureLaneBlocksCount}</dd></div>
                <div><dt className="text-xs">Eventy</dt><dd className="text-2xl font-bold">{confirmationResult.futureEventsCount}</dd></div>
              </dl>
            </div>
            <ChangeSummary family={family} state={state} />
          </div>
        )}

        {step === "stale" && (
          <p className="mt-6 text-sm text-[#c7cbbf]">
            Zamknij edytor i użyj przycisku „Odśwież”, aby pobrać aktualny snapshot.
          </p>
        )}

        <footer className="mt-7 flex flex-col-reverse gap-3 border-t border-[#30372c] pt-5 sm:flex-row sm:justify-end">
          {step === "review" ? (
            <button type="button" onClick={() => setStep("edit")} disabled={saving} className="min-h-11 rounded-xl border border-[#3d4638] px-4 py-2 font-semibold text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50">Wróć do edycji</button>
          ) : (
            <button type="button" onClick={requestClose} disabled={saving} className="min-h-11 rounded-xl border border-[#3d4638] px-4 py-2 font-semibold text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50">Anuluj</button>
          )}
          {step === "edit" && (
            <button type="button" onClick={openReview} disabled={!dirty || !validation.valid || saving} className="min-h-11 rounded-xl bg-[#d7c895] px-5 py-2 font-bold text-[#171a15] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4] disabled:cursor-not-allowed disabled:opacity-40">Zapisz zmiany</button>
          )}
          {step === "review" && (
            <button ref={primaryActionRef} type="button" onClick={() => void submit(false)} disabled={saving} className="min-h-11 rounded-xl bg-[#d7c895] px-5 py-2 font-bold text-[#171a15] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4] disabled:cursor-not-allowed disabled:opacity-50">{saving ? "Zapisywanie…" : "Potwierdź zapis"}</button>
          )}
          {step === "confirmation" && (
            <button ref={primaryActionRef} type="button" onClick={() => void submit(true)} disabled={saving} className="min-h-11 rounded-xl bg-[#d7c895] px-5 py-2 font-bold text-[#171a15] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4] disabled:cursor-not-allowed disabled:opacity-50">{saving ? "Zapisywanie…" : "Potwierdzam zmianę"}</button>
          )}
        </footer>
      </section>
    </div>
  );
}
