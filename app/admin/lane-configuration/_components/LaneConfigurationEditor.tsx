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
  copyLanePositionEditSettings,
  createLaneFamilyEditState,
  getLaneFamilyChanges,
  isLaneFamilyDirty,
  validateLaneFamilyEditState,
  type LaneConfigurationFamily,
  type LaneConfigurationResource,
  type LaneConfigurationWriteResult,
  type LaneFamilyEditState,
  type LaneFamilyPricingEdit,
  type LaneFamilyWriteResource,
} from "../../../../lib/admin/lane-configuration";

type EditorStep = "edit" | "review" | "confirmation" | "stale";
type EditorTab = "root" | "positions";

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

function updateResourceEdit(
  state: LaneFamilyEditState,
  laneId: string,
  update: (resource: LaneFamilyEditState["resources"][number]) => LaneFamilyEditState["resources"][number]
): LaneFamilyEditState {
  return {
    ...state,
    resources: state.resources.map((resource) =>
      resource.lane_id === laneId ? update(resource) : resource
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

function DurationEditor({
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
  const [newDuration, setNewDuration] = useState("");
  const [inputError, setInputError] = useState("");
  const edit = state.resources.find((candidate) => candidate.lane_id === resource.lane_id);
  if (!edit) return null;

  function addDuration() {
    const value = Number(newDuration);
    if (!/^[1-9][0-9]*$/.test(newDuration) || !Number.isSafeInteger(value) || value > 1440) {
      setInputError("Podaj pełną liczbę minut od 1 do 1440.");
      return;
    }
    if (value % resource.booking_step_minutes !== 0) {
      setInputError(`Czas musi być podzielny przez krok ${resource.booking_step_minutes} min.`);
      return;
    }
    if (edit!.durations_minutes.some((duration) => Number(duration) === value)) {
      setInputError("Ten czas rezerwacji jest już dodany.");
      return;
    }
    onChange(
      updateResourceEdit(state, resource.lane_id, (current) => ({
        ...current,
        durations_minutes: [...current.durations_minutes, String(value)].sort(
          (first, second) => Number(first) - Number(second)
        ),
      }))
    );
    setNewDuration("");
    setInputError("");
  }

  return (
    <section aria-labelledby={`durations-${resource.lane_id}`} className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-5">
      <h5 id={`durations-${resource.lane_id}`} className="font-semibold text-[#f2efe4]">
        Czasy rezerwacji
      </h5>
      <p className="mt-1 text-xs leading-5 text-[#92988c]">
        Krok rezerwacji: {resource.booking_step_minutes} min.
      </p>
      <div className="mt-3 flex flex-wrap gap-2">
        {edit.durations_minutes.length === 0 && (
          <span className="text-sm text-[#a9ada4]">Brak aktywnych czasów.</span>
        )}
        {edit.durations_minutes.map((duration) => (
          <span key={duration} className="inline-flex min-h-11 items-center gap-2 rounded-full border border-[#536143] bg-[#20271e] pl-3 text-sm text-[#d9e4cb]">
            {duration} min
            <button
              type="button"
              disabled={disabled}
              onClick={() =>
                onChange(
                  updateResourceEdit(state, resource.lane_id, (current) => ({
                    ...current,
                    durations_minutes: current.durations_minutes.filter(
                      (candidate) => candidate !== duration
                    ),
                  }))
                )
              }
              aria-label={`Usuń czas ${duration} min dla ${resource.name}`}
              className="min-h-11 min-w-11 rounded-full text-lg text-[#d9e4cb] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
            >
              ×
            </button>
          </span>
        ))}
      </div>
      <div className="mt-4 flex flex-col gap-2 sm:flex-row sm:items-end">
        <label className="min-w-0 flex-1" htmlFor={`new-duration-${resource.lane_id}`}>
          <span className="text-sm font-semibold text-[#e3dfd2]">Nowy czas (minuty)</span>
          <input
            id={`new-duration-${resource.lane_id}`}
            type="number"
            inputMode="numeric"
            min="1"
            max="1440"
            step={resource.booking_step_minutes}
            value={newDuration}
            disabled={disabled}
            onChange={(event) => {
              setNewDuration(event.target.value);
              setInputError("");
            }}
            className="mt-2 min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] outline-none focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25 disabled:opacity-50"
          />
        </label>
        <button
          type="button"
          disabled={disabled || newDuration === ""}
          onClick={addDuration}
          className="min-h-11 rounded-xl border border-[#665d45] px-4 font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
        >
          + Dodaj czas
        </button>
      </div>
      {inputError && <p role="alert" className="mt-2 text-sm text-[#e1c477]">{inputError}</p>}
      {resource.durations.some((duration) => !duration.is_active) && (
        <p className="mt-3 text-xs text-[#858c7f]">
          Historyczne nieaktywne czasy pozostają zachowane poza aktywnym snapshotem.
        </p>
      )}
    </section>
  );
}

function PricingEditor({
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
  const nextKeyRef = useRef(0);
  const edit = state.resources.find((candidate) => candidate.lane_id === resource.lane_id);
  if (!edit) return null;

  function updateRule(editKey: string, field: keyof Omit<LaneFamilyPricingEdit, "edit_key" | "day_group">, value: string) {
    onChange(
      updateResourceEdit(state, resource.lane_id, (current) => ({
        ...current,
        pricing: current.pricing.map((rule) =>
          rule.edit_key === editKey ? { ...rule, [field]: value } : rule
        ),
      }))
    );
  }

  function addRule(dayGroup: LaneFamilyPricingEdit["day_group"]) {
    const groupRules = edit!.pricing.filter((rule) => rule.day_group === dayGroup);
    const nextMin = Math.max(
      1,
      ...groupRules.map((rule) => Number(rule.max_shooters) + 1).filter(Number.isFinite)
    );
    const newRule: LaneFamilyPricingEdit = {
      edit_key: `${resource.lane_id}:${dayGroup}:new:${nextKeyRef.current++}`,
      day_group: dayGroup,
      min_shooters: String(nextMin),
      max_shooters: String(nextMin),
      label:
        nextMin === 1
          ? "1 osoba"
          : nextMin >= 2 && nextMin <= 4
            ? `${nextMin} osoby`
            : `${nextMin} osób`,
      hourly_price: "",
    };
    onChange(
      updateResourceEdit(state, resource.lane_id, (current) => ({
        ...current,
        pricing: [...current.pricing, newRule],
      }))
    );
  }

  function removeRule(editKey: string) {
    onChange(
      updateResourceEdit(state, resource.lane_id, (current) => ({
        ...current,
        pricing: current.pricing.filter(
          (candidate) => candidate.edit_key !== editKey
        ),
      }))
    );
  }

  const sortedRules = [...edit.pricing].sort(
    (first, second) =>
      (Number(first.min_shooters) || Number.MAX_SAFE_INTEGER) -
        (Number(second.min_shooters) || Number.MAX_SAFE_INTEGER) ||
      (Number(first.max_shooters) || Number.MAX_SAFE_INTEGER) -
        (Number(second.max_shooters) || Number.MAX_SAFE_INTEGER) ||
      first.day_group.localeCompare(second.day_group) ||
      first.edit_key.localeCompare(second.edit_key)
  );
  const monThuRules = sortedRules.filter((rule) => rule.day_group === "mon_thu");
  const friSunRules = sortedRules.filter((rule) => rule.day_group === "fri_sun");
  const pricingRows = Array.from(
    { length: Math.max(monThuRules.length, friSunRules.length) },
    (_, index) => ({
      monThu: monThuRules[index],
      friSun: friSunRules[index],
    })
  );

  function rangeLabel(rule: LaneFamilyPricingEdit) {
    if (rule.min_shooters === rule.max_shooters) {
      const peopleCount = Number(rule.min_shooters);
      if (peopleCount === 1) return "1 osoba";
      if (peopleCount >= 2 && peopleCount <= 4) return `${rule.min_shooters} osoby`;
      return `${rule.min_shooters} osób`;
    }
    return `${rule.min_shooters}–${rule.max_shooters} osób`;
  }

  function renderRuleCell(
    rule: LaneFamilyPricingEdit | undefined,
    dayGroup: LaneFamilyPricingEdit["day_group"]
  ) {
    const groupLabel = dayGroup === "mon_thu" ? "Pon–Czw" : "Pt–Nd";
    if (!rule) {
      return (
        <div className="rounded-xl border border-dashed border-[#3d4638] p-3 text-sm text-[#858c7f]">
          Brak progu {groupLabel}
        </div>
      );
    }
    const idBase = `${resource.lane_id}-${dayGroup}-${rule.edit_key.replace(
      /[^a-zA-Z0-9_-]/g,
      "-"
    )}`;
    return (
      <div className="min-w-0 rounded-xl border border-[#30372c] bg-[#101310] p-3">
        <label
          htmlFor={`${idBase}-price`}
          className="block min-w-0 text-sm font-semibold text-[#c7cbbf]"
        >
          <span className="md:sr-only">Cena {groupLabel}</span>
          <span className="flex min-h-11 items-center rounded-xl border border-[#3d4638] bg-[#161a16] px-3 focus-within:ring-2 focus-within:ring-[#d7c895]/25">
            <input
              id={`${idBase}-price`}
              type="text"
              inputMode="decimal"
              value={rule.hourly_price}
              disabled={disabled}
              onChange={(event) =>
                updateRule(rule.edit_key, "hourly_price", event.target.value)
              }
              className="min-w-0 flex-1 bg-transparent text-right text-[#f2efe4] outline-none disabled:opacity-50"
            />
            <span className="ml-2 shrink-0 text-xs text-[#92988c]">
              {resource.currency_code}/h
            </span>
          </span>
        </label>
        <p className="mt-2 truncate text-xs text-[#a9ada4]" title={rule.label}>
          {rule.label}
        </p>
        <details className="mt-2 rounded-lg border border-[#30372c] bg-[#161a16] px-3">
          <summary className="flex min-h-11 cursor-pointer items-center text-xs font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]">
            Edytuj zakres i opis
          </summary>
          <div className="space-y-3 pb-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <label
                htmlFor={`${idBase}-min`}
                className="text-xs text-[#c7cbbf]"
              >
                Liczba osób — od
                <input
                  id={`${idBase}-min`}
                  type="number"
                  inputMode="numeric"
                  min="1"
                  value={rule.min_shooters}
                  disabled={disabled}
                  onChange={(event) =>
                    updateRule(rule.edit_key, "min_shooters", event.target.value)
                  }
                  className="mt-1 min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] outline-none focus:ring-2 focus:ring-[#d7c895]/25 disabled:opacity-50"
                />
              </label>
              <label
                htmlFor={`${idBase}-max`}
                className="text-xs text-[#c7cbbf]"
              >
                Liczba osób — do
                <input
                  id={`${idBase}-max`}
                  type="number"
                  inputMode="numeric"
                  min="1"
                  value={rule.max_shooters}
                  disabled={disabled}
                  onChange={(event) =>
                    updateRule(rule.edit_key, "max_shooters", event.target.value)
                  }
                  className="mt-1 min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] outline-none focus:ring-2 focus:ring-[#d7c895]/25 disabled:opacity-50"
                />
              </label>
            </div>
            <label
              htmlFor={`${idBase}-label`}
              className="block text-xs text-[#c7cbbf]"
            >
              Opis / nazwa progu
              <input
                id={`${idBase}-label`}
                type="text"
                value={rule.label}
                disabled={disabled}
                onChange={(event) =>
                  updateRule(rule.edit_key, "label", event.target.value)
                }
                className="mt-1 min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] outline-none focus:ring-2 focus:ring-[#d7c895]/25 disabled:opacity-50"
              />
            </label>
            <button
              type="button"
              disabled={disabled}
              onClick={() => removeRule(rule.edit_key)}
              aria-label={`Usuń próg cennika ${groupLabel} dla ${resource.name}`}
              className="min-h-11 rounded-xl border border-[#704b3f] px-3 text-sm font-semibold text-[#e6b5a5] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e6b5a5] disabled:opacity-50"
            >
              Usuń próg
            </button>
          </div>
        </details>
      </div>
    );
  }

  return (
    <section
      aria-labelledby={`pricing-${resource.lane_id}`}
      className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-5"
    >
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h5
            id={`pricing-${resource.lane_id}`}
            className="font-semibold text-[#f2efe4]"
          >
            Cennik
          </h5>
          <p className="mt-1 text-xs leading-5 text-[#92988c]">
            Ceny godzinowe. Waluta: {resource.currency_code} — tylko odczyt.
          </p>
        </div>
      </div>
      <div className="mt-4 space-y-3">
        <div className="hidden grid-cols-[minmax(7rem,0.8fr)_minmax(0,1fr)_minmax(0,1fr)] gap-3 px-3 text-xs font-bold uppercase tracking-[0.12em] text-[#8f9589] md:grid">
          <span>Zakres osób</span>
          <span className="text-center">Pon–Czw</span>
          <span className="text-center">Pt–Nd</span>
        </div>
        {pricingRows.length === 0 && (
          <p className="rounded-xl border border-dashed border-[#3d4638] p-4 text-sm text-[#a9ada4]">
            Brak progów cenowych.
          </p>
        )}
        {pricingRows.map(({ monThu, friSun }) => {
          const representative = monThu ?? friSun!;
          const matchingRanges =
            !monThu ||
            !friSun ||
            (monThu.min_shooters === friSun.min_shooters &&
              monThu.max_shooters === friSun.max_shooters);
          return (
            <div
              key={`${monThu?.edit_key ?? "empty"}:${friSun?.edit_key ?? "empty"}`}
              className="grid min-w-0 gap-3 rounded-2xl border border-[#30372c] bg-[#161a16] p-3 md:grid-cols-[minmax(7rem,0.8fr)_minmax(0,1fr)_minmax(0,1fr)]"
            >
              <div className="flex items-center justify-between gap-3 md:block">
                <span className="text-sm font-bold text-[#f2efe4]">
                  {matchingRanges
                    ? rangeLabel(representative)
                    : `${rangeLabel(monThu!)} / ${rangeLabel(friSun!)}`}
                </span>
                <span className="text-xs text-[#858c7f] md:mt-1 md:block">
                  Zakres i opis są dostępne w ustawieniach progu
                </span>
              </div>
              <div>
                <p className="mb-1 text-xs font-bold uppercase tracking-[0.12em] text-[#8f9589] md:sr-only">
                  Pon–Czw
                </p>
                {renderRuleCell(monThu, "mon_thu")}
              </div>
              <div>
                <p className="mb-1 text-xs font-bold uppercase tracking-[0.12em] text-[#8f9589] md:sr-only">
                  Pt–Nd
                </p>
                {renderRuleCell(friSun, "fri_sun")}
              </div>
            </div>
          );
        })}
      </div>
      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <button
          type="button"
          disabled={disabled}
          onClick={() => addRule("mon_thu")}
          className="min-h-11 rounded-xl border border-[#665d45] px-3 text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
        >
          + Dodaj próg Pon–Czw
        </button>
        <button
          type="button"
          disabled={disabled}
          onClick={() => addRule("fri_sun")}
          className="min-h-11 rounded-xl border border-[#665d45] px-3 text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
        >
          + Dodaj próg Pt–Nd
        </button>
      </div>
      {resource.pricing.some((rule) => !rule.is_active) && (
        <p className="mt-3 text-xs text-[#858c7f]">
          Historyczne nieaktywne progi pozostają zachowane i nie są częścią aktywnego targetu.
        </p>
      )}
    </section>
  );
}

function ResourceConfigurationSections({
  resource,
  state,
  disabled,
  rootControls,
  onChange,
}: {
  resource: LaneConfigurationResource;
  state: LaneFamilyEditState;
  disabled: boolean;
  rootControls?: React.ReactNode;
  onChange: (state: LaneFamilyEditState) => void;
}) {
  return (
    <div className="space-y-5">
      <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-5">
        <h3 className="font-bold text-[#f2efe4]">
          {resource.resource_kind === "position" ? "Podstawowe" : "Rezerwacje"}
        </h3>
        <div className="mt-4">
          <LimitFields
            resource={resource}
            state={state}
            disabled={disabled}
            onChange={onChange}
          />
        </div>
        {rootControls && <div className="mt-5">{rootControls}</div>}
      </section>
      <DurationEditor
        resource={resource}
        state={state}
        disabled={disabled}
        onChange={onChange}
      />
      <PricingEditor
        resource={resource}
        state={state}
        disabled={disabled}
        onChange={onChange}
      />
    </div>
  );
}

function PositionList({
  positions,
  disabled,
  onConfigure,
}: {
  positions: LaneConfigurationResource[];
  disabled: boolean;
  onConfigure: (laneId: string) => void;
}) {
  return (
    <section aria-labelledby="positions-list-heading">
      <div className="mb-4">
        <h3 id="positions-list-heading" className="font-bold text-[#f2efe4]">
          Stanowiska
        </h3>
        <p className="mt-1 text-sm text-[#a9ada4]">
          Wybierz jedno stanowisko, aby edytować jego limity, czasy i cennik.
        </p>
      </div>
      <div className="grid gap-3">
        {positions.map((position) => (
          <article
            key={position.lane_id}
            className="flex min-w-0 flex-col gap-3 rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:flex-row sm:items-center sm:justify-between"
          >
            <div className="min-w-0">
              <h4 className="truncate font-semibold text-[#f2efe4]">
                {position.name}
              </h4>
              <p className="mt-1 text-sm text-[#a9ada4]">
                {position.is_active ? "Aktywne" : "Nieaktywne"} ·{" "}
                {position.online_bookable ? "Online" : "Offline"}
              </p>
            </div>
            <button
              type="button"
              disabled={disabled}
              onClick={() => onConfigure(position.lane_id)}
              className="min-h-11 shrink-0 rounded-xl border border-[#665d45] px-4 text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
            >
              Konfiguruj
            </button>
          </article>
        ))}
      </div>
    </section>
  );
}

function CopySettingsPanel({
  source,
  targets,
  selectedTargetIds,
  disabled,
  onToggleTarget,
  onSelectAll,
  onCancel,
  onCopy,
}: {
  source: LaneConfigurationResource;
  targets: LaneConfigurationResource[];
  selectedTargetIds: string[];
  disabled: boolean;
  onToggleTarget: (laneId: string) => void;
  onSelectAll: () => void;
  onCancel: () => void;
  onCopy: () => void;
}) {
  const selectedTargets = targets.filter((target) =>
    selectedTargetIds.includes(target.lane_id)
  );

  return (
    <section
      aria-labelledby="copy-position-settings-heading"
      className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-4 sm:p-5"
    >
      <h3
        id="copy-position-settings-heading"
        className="font-bold text-[#f2efe4]"
      >
        Skopiuj ustawienia do innych stanowisk
      </h3>
      <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-3">
        <div>
          <dt className="text-[#92988c]">Źródło</dt>
          <dd className="mt-1 font-semibold text-[#f2efe4]">{source.name}</dd>
        </div>
        <div>
          <dt className="text-[#92988c]">Do</dt>
          <dd className="mt-1 font-semibold text-[#f2efe4]">
            {selectedTargets.length > 0
              ? selectedTargets.map((target) => target.name).join(", ")
              : "Nie wybrano"}
          </dd>
        </div>
        <div>
          <dt className="text-[#92988c]">Kopiowane</dt>
          <dd className="mt-1 font-semibold text-[#f2efe4]">
            Limity, czasy i cennik
          </dd>
        </div>
      </dl>
      <div className="mt-5 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm font-semibold text-[#e1c477]">
          Wybierz stanowiska docelowe
        </p>
        <button
          type="button"
          disabled={disabled || targets.length === 0}
          onClick={onSelectAll}
          className="min-h-11 rounded-xl border border-[#806a32] px-3 text-sm font-semibold text-[#e1c477] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e1c477] disabled:opacity-50"
        >
          Zaznacz wszystkie pozostałe
        </button>
      </div>
      <div className="mt-3 grid gap-2 sm:grid-cols-2">
        {targets.map((target) => (
          <label
            key={target.lane_id}
            className="flex min-h-11 items-center gap-3 rounded-xl border border-[#4f462d] bg-[#211d14] px-3 text-sm text-[#f2efe4]"
          >
            <input
              type="checkbox"
              checked={selectedTargetIds.includes(target.lane_id)}
              disabled={disabled}
              onChange={() => onToggleTarget(target.lane_id)}
              className="h-5 w-5 accent-[#8b7b48] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e1c477]"
            />
            <span className="min-w-0 truncate">{target.name}</span>
          </label>
        ))}
      </div>
      <p className="mt-4 text-xs leading-5 text-[#b9ae8a]">
        Kopiowanie zmienia tylko lokalny formularz. Nie zmienia identyfikatorów,
        nazw, statusu, dostępności online ani wersji i nie wykonuje zapisu RPC.
      </p>
      <div className="mt-5 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
        <button
          type="button"
          disabled={disabled}
          onClick={onCancel}
          className="min-h-11 rounded-xl border border-[#665d45] px-4 font-semibold text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
        >
          Anuluj
        </button>
        <button
          type="button"
          disabled={disabled || selectedTargetIds.length === 0}
          onClick={onCopy}
          className="min-h-11 rounded-xl bg-[#d7c895] px-4 font-bold text-[#171a15] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4] disabled:opacity-40"
        >
          Skopiuj
        </button>
      </div>
    </section>
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
  const [activeTab, setActiveTab] = useState<EditorTab>("root");
  const [selectedPositionId, setSelectedPositionId] = useState<string | null>(
    null
  );
  const [copyPanelOpen, setCopyPanelOpen] = useState(false);
  const [copyTargetIds, setCopyTargetIds] = useState<string[]>([]);
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
  const selectedPosition =
    family.children.find((child) => child.lane_id === selectedPositionId) ?? null;
  const copyTargets = selectedPosition
    ? family.children.filter(
        (child) => child.lane_id !== selectedPosition.lane_id
      )
    : [];

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

  function openPositionEditor(laneId: string) {
    setSelectedPositionId(laneId);
    setCopyPanelOpen(false);
    setCopyTargetIds([]);
  }

  function returnToPositions() {
    setSelectedPositionId(null);
    setCopyPanelOpen(false);
    setCopyTargetIds([]);
  }

  function openCopyPanel() {
    setCopyPanelOpen(true);
    setCopyTargetIds([]);
  }

  function toggleCopyTarget(laneId: string) {
    setCopyTargetIds((current) =>
      current.includes(laneId)
        ? current.filter((candidate) => candidate !== laneId)
        : [...current, laneId]
    );
  }

  function applyPositionCopy() {
    if (!selectedPosition || copyTargetIds.length === 0) return;
    try {
      setState((current) =>
        copyLanePositionEditSettings(
          family,
          current,
          selectedPosition.lane_id,
          copyTargetIds
        )
      );
      setCopyPanelOpen(false);
      setCopyTargetIds([]);
      setMessage("Ustawienia skopiowano lokalnie. Zapisz rodzinę, aby je zatwierdzić.");
    } catch {
      setMessage("Nie udało się bezpiecznie skopiować ustawień stanowiska.");
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
            {family.children.length > 0 && (
              <div
                role="tablist"
                aria-label="Zakres konfiguracji rodziny"
                className="grid grid-cols-2 gap-2 rounded-2xl border border-[#30372c] bg-[#101310] p-2"
              >
                <button
                  type="button"
                  role="tab"
                  aria-selected={activeTab === "root"}
                  onClick={() => setActiveTab("root")}
                  className={`min-h-11 rounded-xl px-3 text-sm font-bold focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] ${
                    activeTab === "root"
                      ? "bg-[#d7c895] text-[#171a15]"
                      : "text-[#c7cbbf] hover:bg-[#1d211b]"
                  }`}
                >
                  Oś główna
                </button>
                <button
                  type="button"
                  role="tab"
                  aria-selected={activeTab === "positions"}
                  onClick={() => setActiveTab("positions")}
                  className={`min-h-11 rounded-xl px-3 text-sm font-bold focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] ${
                    activeTab === "positions"
                      ? "bg-[#d7c895] text-[#171a15]"
                      : "text-[#c7cbbf] hover:bg-[#1d211b]"
                  }`}
                >
                  Stanowiska
                </button>
              </div>
            )}

            {activeTab === "root" || family.children.length === 0 ? (
              <div role="tabpanel" aria-label="Oś główna" className="space-y-4">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <p className="text-xs font-bold uppercase tracking-[0.16em] text-[#d7c895]">
                      Oś główna
                    </p>
                    <h3 className="mt-1 text-lg font-bold text-[#f2efe4]">
                      {family.root.name}
                    </h3>
                  </div>
                  <span className="rounded-full border border-[#3d4638] px-3 py-1 text-xs font-semibold text-[#a9ada4]">
                    Status: {family.root.is_active ? "Aktywna" : "Nieaktywna"} — tylko odczyt
                  </span>
                </div>
                <ResourceConfigurationSections
                  resource={family.root}
                  state={state}
                  disabled={locked}
                  onChange={setState}
                  rootControls={
                    <div className="grid gap-3 sm:grid-cols-2">
                      <ToggleField
                        id={`online-${family.root_lane_id}`}
                        label="Rezerwacje online"
                        checked={state.root_online_bookable}
                        disabled={locked}
                        onChange={(checked) =>
                          setState((current) => ({
                            ...current,
                            root_online_bookable: checked,
                          }))
                        }
                      />
                      <ToggleField
                        id={`whole-${family.root_lane_id}`}
                        label="Rezerwacja całej osi"
                        checked={state.root_whole_lane_bookable}
                        disabled={locked}
                        onChange={(checked) =>
                          setState((current) => ({
                            ...current,
                            root_whole_lane_bookable: checked,
                          }))
                        }
                      />
                      <ToggleField
                        id={`positions-${family.root_lane_id}`}
                        label="Rezerwacja stanowisk"
                        checked={state.root_positions_bookable}
                        disabled={locked || family.children.length === 0}
                        onChange={(checked) =>
                          setState((current) => ({
                            ...current,
                            root_positions_bookable: checked,
                          }))
                        }
                      />
                    </div>
                  }
                />
              </div>
            ) : (
              <div role="tabpanel" aria-label="Stanowiska" className="space-y-5">
                {selectedPosition ? (
                  <>
                    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                      <button
                        type="button"
                        disabled={locked}
                        onClick={returnToPositions}
                        className="min-h-11 self-start rounded-xl border border-[#3d4638] px-4 text-sm font-semibold text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50"
                      >
                        ← Wróć do stanowisk
                      </button>
                      <span className="text-sm text-[#a9ada4]">
                        {selectedPosition.is_active ? "Aktywne" : "Nieaktywne"} ·{" "}
                        {selectedPosition.online_bookable ? "Online" : "Offline"} — tylko odczyt
                      </span>
                    </div>
                    <div>
                      <p className="text-xs font-bold uppercase tracking-[0.16em] text-[#d7c895]">
                        Konfiguracja stanowiska
                      </p>
                      <h3 className="mt-1 text-lg font-bold text-[#f2efe4]">
                        {selectedPosition.name}
                      </h3>
                    </div>
                    <ResourceConfigurationSections
                      resource={selectedPosition}
                      state={state}
                      disabled={locked}
                      onChange={setState}
                    />
                    {copyTargets.length > 0 && !copyPanelOpen && (
                      <button
                        type="button"
                        disabled={locked}
                        onClick={openCopyPanel}
                        className="min-h-11 w-full rounded-xl border border-[#665d45] px-4 font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-50 sm:w-auto"
                      >
                        Skopiuj ustawienia do innych stanowisk
                      </button>
                    )}
                    {copyPanelOpen && (
                      <CopySettingsPanel
                        source={selectedPosition}
                        targets={copyTargets}
                        selectedTargetIds={copyTargetIds}
                        disabled={locked}
                        onToggleTarget={toggleCopyTarget}
                        onSelectAll={() =>
                          setCopyTargetIds(copyTargets.map((target) => target.lane_id))
                        }
                        onCancel={() => {
                          setCopyPanelOpen(false);
                          setCopyTargetIds([]);
                        }}
                        onCopy={applyPositionCopy}
                      />
                    )}
                  </>
                ) : (
                  <PositionList
                    positions={family.children}
                    disabled={locked}
                    onConfigure={openPositionEditor}
                  />
                )}
              </div>
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
