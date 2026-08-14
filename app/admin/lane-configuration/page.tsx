"use client";

import Link from "next/link";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type RefObject,
} from "react";
import { supabase } from "../../../lib/supabase";
import {
  buildLaneConfigurationHierarchy,
  filterLaneConfigurationHierarchy,
  getLaneConfigurationSummary,
  parseAdminLaneConfigurationSnapshot,
  parseLaneConfigurationWriteResult,
  type AdminLaneConfigurationSnapshot,
  type LaneConfigurationFamily,
  type LaneConfigurationPricingRule,
  type LaneConfigurationResource,
  type LaneFamilyWriteResource,
} from "../../../lib/admin/lane-configuration";
import AdminShell from "../_components/AdminShell";
import LaneConfigurationEditor from "./_components/LaneConfigurationEditor";

const CONTROLLED_READ_ERROR =
  "Nie udało się bezpiecznie odczytać konfiguracji osi.";

function StatusBadge({
  children,
  tone = "neutral",
}: {
  children: React.ReactNode;
  tone?: "positive" | "warning" | "neutral" | "olive";
}) {
  const className =
    tone === "positive"
      ? "border-[#536143] bg-[#20271e] text-[#b9c9a5]"
      : tone === "warning"
        ? "border-[#806a32] bg-[#2b2618] text-[#e1c477]"
        : tone === "olive"
          ? "border-[#665d45] bg-[#242119] text-[#d7c895]"
          : "border-[#3d4638] bg-[#191e19] text-[#a9ada4]";

  return (
    <span
      className={`inline-flex min-h-7 items-center rounded-full border px-2.5 py-1 text-xs font-semibold ${className}`}
    >
      {children}
    </span>
  );
}

function SummaryCard({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-5">
      <p className="text-sm text-[#a9ada4]">{label}</p>
      <p className="mt-2 text-3xl font-bold text-[#f2efe4]">{value}</p>
    </div>
  );
}

function BooleanIndicator({
  label,
  value,
}: {
  label: string;
  value: boolean;
}) {
  return (
    <div className="flex min-h-11 items-center justify-between gap-3 rounded-xl border border-[#30372c] bg-[#141814] px-3 py-2">
      <span className="text-sm text-[#a9ada4]">{label}</span>
      <span className="text-sm font-bold text-[#f2efe4]">{value ? "TAK" : "NIE"}</span>
    </div>
  );
}

function ResourceFacts({ resource }: { resource: LaneConfigurationResource }) {
  const capacityLabel =
    resource.resource_kind === "position" ? "Pojemność stanowiska" : "Pojemność osi";

  return (
    <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <div>
        <dt className="text-xs uppercase tracking-[0.12em] text-[#7f8679]">
          {capacityLabel}
        </dt>
        <dd className="mt-1 text-sm font-bold text-[#f2efe4]">
          {resource.max_shooters}
        </dd>
      </div>
      <div>
        <dt className="text-xs uppercase tracking-[0.12em] text-[#7f8679]">
          Maks. osób w jednej rezerwacji
        </dt>
        <dd className="mt-1 text-sm font-bold text-[#f2efe4]">
          {resource.max_people_online}
        </dd>
      </div>
      <div>
        <dt className="text-xs uppercase tracking-[0.12em] text-[#7f8679]">
          Krok rezerwacji
        </dt>
        <dd className="mt-1 text-sm font-bold text-[#f2efe4]">
          {resource.booking_step_minutes} min
        </dd>
      </div>
      <div>
        <dt className="text-xs uppercase tracking-[0.12em] text-[#7f8679]">
          Waluta
        </dt>
        <dd className="mt-1 text-sm font-bold text-[#f2efe4]">
          {resource.currency_code}
        </dd>
      </div>
    </dl>
  );
}

function ResourceBadges({ resource }: { resource: LaneConfigurationResource }) {
  return (
    <div className="flex flex-wrap gap-2">
      <StatusBadge tone="olive">
        {resource.resource_kind === "lane" ? "Oś" : "Stanowisko"}
      </StatusBadge>
      <StatusBadge tone={resource.is_active ? "positive" : "neutral"}>
        {resource.is_active ? "Aktywna" : "Nieaktywna"}
      </StatusBadge>
      <StatusBadge tone={resource.online_bookable ? "positive" : "neutral"}>
        {resource.online_bookable ? "Online" : "Offline"}
      </StatusBadge>
    </div>
  );
}

function PositionCard({
  resource,
  onOpenDetails,
  isLast,
}: {
  resource: LaneConfigurationResource;
  onOpenDetails: (resource: LaneConfigurationResource, trigger: HTMLButtonElement) => void;
  isLast: boolean;
}) {
  const missingSalesConfiguration =
    resource.durations.length === 0 && resource.pricing.length === 0;

  return (
    <article className="relative rounded-2xl border border-[#30372c] bg-[#141814] p-4 sm:p-5">
      <span
        aria-hidden="true"
        className="absolute -left-4 top-6 text-sm text-[#665d45] sm:-left-5"
      >
        {isLast ? "└" : "├"}
      </span>
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <p className="break-words font-bold text-[#f2efe4]">{resource.name}</p>
          <div className="mt-2">
            <ResourceBadges resource={resource} />
          </div>
        </div>
        <button
          type="button"
          onClick={(event) => onOpenDetails(resource, event.currentTarget)}
          className="min-h-11 shrink-0 rounded-xl border border-[#536143] px-4 py-2 text-sm font-semibold text-[#d7c895] transition hover:bg-[#20271e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
        >
          Szczegóły
        </button>
      </div>

      <div className="mt-5">
        <ResourceFacts resource={resource} />
      </div>
      {missingSalesConfiguration && (
        <p className="mt-4 rounded-xl border border-[#3d4638] bg-[#191e19] px-3 py-2 text-sm text-[#a9ada4]">
          Nie skonfigurowano sprzedaży
        </p>
      )}
    </article>
  );
}

function LaneFamilyCard({
  family,
  onOpenDetails,
  onEdit,
}: {
  family: LaneConfigurationFamily;
  onOpenDetails: (resource: LaneConfigurationResource, trigger: HTMLButtonElement) => void;
  onEdit: (family: LaneConfigurationFamily, trigger: HTMLButtonElement) => void;
}) {
  const activeChildren = family.children.filter((child) => child.is_active).length;

  return (
    <article className="rounded-3xl border border-[#3d4638] bg-[#191e19] p-4 sm:p-6">
      <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
          <ResourceBadges resource={family.root} />
          <h2 className="mt-3 break-words text-xl font-bold text-[#f2efe4] sm:text-2xl">
            {family.root.name}
          </h2>
          <p className="mt-2 text-sm text-[#a9ada4]">
            {family.children.length === 0
              ? "Brak stanowisk"
              : `${family.children.length} stanowisk · ${activeChildren} aktywnych / ${family.children.length}`}
          </p>
        </div>
        <div className="flex flex-col gap-2 sm:flex-row">
          <button
            type="button"
            onClick={(event) => onOpenDetails(family.root, event.currentTarget)}
            className="min-h-11 shrink-0 rounded-xl border border-[#536143] px-4 py-2 text-sm font-semibold text-[#d7c895] transition hover:bg-[#20271e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            Szczegóły
          </button>
          <button
            type="button"
            onClick={(event) => onEdit(family, event.currentTarget)}
            className="min-h-11 shrink-0 rounded-xl bg-[#d7c895] px-4 py-2 text-sm font-bold text-[#171a15] transition hover:bg-[#e3d5a7] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f2efe4]"
          >
            Edytuj konfigurację
          </button>
        </div>
      </div>

      <div className="mt-6">
        <ResourceFacts resource={family.root} />
      </div>

      <div className="mt-5 grid gap-3 sm:grid-cols-2">
        <BooleanIndicator
          label="Rezerwacja całej osi"
          value={family.root.whole_lane_bookable}
        />
        <BooleanIndicator
          label="Rezerwacja stanowisk"
          value={family.root.positions_bookable}
        />
      </div>

      {family.children.length > 0 && (
        <section
          aria-label={`Stanowiska: ${family.root.name}`}
          className="mt-6 border-l border-[#665d45] pl-4 sm:pl-5"
        >
          <div className="grid gap-3">
            {family.children.map((child, index) => (
              <PositionCard
                key={child.lane_id}
                resource={child}
                onOpenDetails={onOpenDetails}
                isLast={index === family.children.length - 1}
              />
            ))}
          </div>
        </section>
      )}
    </article>
  );
}

function formatPrice(value: number, currencyCode: string) {
  try {
    return new Intl.NumberFormat("pl-PL", {
      style: "currency",
      currency: currencyCode,
      minimumFractionDigits: 0,
      maximumFractionDigits: 2,
    }).format(value);
  } catch {
    return `${value.toFixed(2)} ${currencyCode}`;
  }
}

function getPeopleRangeLabel(rule: LaneConfigurationPricingRule) {
  if (rule.min_shooters === rule.max_shooters) {
    return rule.min_shooters === 1
      ? "1 osoba"
      : `${rule.min_shooters} osoby`;
  }
  return `${rule.min_shooters}–${rule.max_shooters} osób`;
}

function PricingGroup({
  title,
  rules,
  currencyCode,
}: {
  title: string;
  rules: LaneConfigurationPricingRule[];
  currencyCode: string;
}) {
  return (
    <div className="rounded-xl border border-[#30372c] bg-[#101310] p-4">
      <h4 className="font-semibold text-[#d7c895]">{title}</h4>
      {rules.length === 0 ? (
        <p className="mt-3 text-sm text-[#858c7f]">Brak aktywnych reguł.</p>
      ) : (
        <ul className="mt-3 space-y-2">
          {rules.map((rule) => (
            <li
              key={`${rule.day_group}-${rule.min_shooters}-${rule.max_shooters}-${rule.display_order}`}
              className="flex flex-col gap-1 border-b border-[#272d26] pb-2 text-sm last:border-0 last:pb-0 sm:flex-row sm:items-start sm:justify-between"
            >
              <span className="text-[#c7cbbf]">
                {getPeopleRangeLabel(rule)} · {rule.label}
              </span>
              <strong className="shrink-0 text-[#f2efe4]">
                {formatPrice(rule.hourly_price, currencyCode)}/h
              </strong>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function ConfigurationDetailsDialog({
  resource,
  parentName,
  closeButtonRef,
  onClose,
}: {
  resource: LaneConfigurationResource;
  parentName: string | null;
  closeButtonRef: RefObject<HTMLButtonElement | null>;
  onClose: () => void;
}) {
  const activeDurations = resource.durations.filter((duration) => duration.is_active);
  const inactiveDurations = resource.durations.filter((duration) => !duration.is_active);
  const activePricing = resource.pricing.filter((rule) => rule.is_active);
  const inactivePricing = resource.pricing.filter((rule) => !rule.is_active);

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/75 p-0 sm:items-center sm:p-5"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="lane-configuration-details-title"
        className="max-h-[92vh] w-full overflow-y-auto rounded-t-3xl border border-[#3d4638] bg-[#141814] p-5 shadow-2xl sm:max-w-3xl sm:rounded-3xl sm:p-7"
      >
        <header className="flex items-start justify-between gap-4 border-b border-[#30372c] pb-5">
          <div className="min-w-0">
            <p className="text-xs font-bold uppercase tracking-[0.2em] text-[#d7c895]">
              Szczegóły konfiguracji
            </p>
            <h2
              id="lane-configuration-details-title"
              className="mt-2 break-words text-2xl font-bold text-[#f2efe4]"
            >
              {resource.name}
            </h2>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            onClick={onClose}
            aria-label="Zamknij szczegóły konfiguracji"
            className="min-h-11 min-w-11 rounded-xl border border-[#3d4638] text-xl text-[#c7cbbf] transition hover:bg-[#20241f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            ×
          </button>
        </header>

        <div className="mt-6 space-y-6">
          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-5">
            <h3 className="font-semibold text-[#f2efe4]">Status zasobu</h3>
            <div className="mt-3">
              <ResourceBadges resource={resource} />
            </div>
            {parentName && (
              <p className="mt-4 text-sm text-[#a9ada4]">
                Oś nadrzędna: <strong className="text-[#f2efe4]">{parentName}</strong>
              </p>
            )}
            <div className="mt-5">
              <ResourceFacts resource={resource} />
            </div>
            {resource.resource_kind === "lane" && (
              <div className="mt-5 grid gap-3 sm:grid-cols-2">
                <BooleanIndicator
                  label="Rezerwacja całej osi"
                  value={resource.whole_lane_bookable}
                />
                <BooleanIndicator
                  label="Rezerwacja stanowisk"
                  value={resource.positions_bookable}
                />
              </div>
            )}
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-5">
            <h3 className="font-semibold text-[#f2efe4]">Dostępne czasy</h3>
            {activeDurations.length === 0 ? (
              <p className="mt-3 text-sm text-[#a9ada4]">
                Brak skonfigurowanych czasów rezerwacji.
              </p>
            ) : (
              <div className="mt-3 flex flex-wrap gap-2">
                {activeDurations.map((duration) => (
                  <StatusBadge key={duration.duration_minutes} tone="positive">
                    {duration.duration_minutes} min
                  </StatusBadge>
                ))}
              </div>
            )}
            {inactiveDurations.length > 0 && (
              <details className="mt-4 rounded-xl border border-[#3d4638] bg-[#141814] p-3">
                <summary className="min-h-11 cursor-pointer py-2 text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]">
                  Nieaktywne czasy ({inactiveDurations.length})
                </summary>
                <div className="mt-2 flex flex-wrap gap-2">
                  {inactiveDurations.map((duration) => (
                    <StatusBadge key={duration.duration_minutes}>
                      {duration.duration_minutes} min · Nieaktywny
                    </StatusBadge>
                  ))}
                </div>
              </details>
            )}
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-5">
            <h3 className="font-semibold text-[#f2efe4]">Cennik</h3>
            {activePricing.length === 0 ? (
              <p className="mt-3 text-sm text-[#a9ada4]">Brak skonfigurowanego cennika.</p>
            ) : (
              <div className="mt-4 grid gap-3 md:grid-cols-2">
                <PricingGroup
                  title="Pon–Czw"
                  rules={activePricing.filter((rule) => rule.day_group === "mon_thu")}
                  currencyCode={resource.currency_code}
                />
                <PricingGroup
                  title="Pt–Nd"
                  rules={activePricing.filter((rule) => rule.day_group === "fri_sun")}
                  currencyCode={resource.currency_code}
                />
              </div>
            )}
            {inactivePricing.length > 0 && (
              <details className="mt-4 rounded-xl border border-[#3d4638] bg-[#141814] p-3">
                <summary className="min-h-11 cursor-pointer py-2 text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]">
                  Nieaktywne reguły ({inactivePricing.length})
                </summary>
                <ul className="mt-2 space-y-2 text-sm text-[#a9ada4]">
                  {inactivePricing.map((rule) => (
                    <li
                      key={`${rule.day_group}-${rule.min_shooters}-${rule.max_shooters}-${rule.display_order}`}
                    >
                      {rule.day_group === "mon_thu" ? "Pon–Czw" : "Pt–Nd"}: {getPeopleRangeLabel(rule)} · {formatPrice(rule.hourly_price, resource.currency_code)}/h
                    </li>
                  ))}
                </ul>
              </details>
            )}
          </section>
        </div>
      </section>
    </div>
  );
}

export default function AdminLaneConfigurationPage() {
  const [snapshot, setSnapshot] = useState<AdminLaneConfigurationSnapshot | null>(
    null
  );
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState("");
  const [accessDenied, setAccessDenied] = useState(false);
  const [search, setSearch] = useState("");
  const [selectedResourceId, setSelectedResourceId] = useState<string | null>(null);
  const [selectedFamilyId, setSelectedFamilyId] = useState<string | null>(null);
  const [editorDirty, setEditorDirty] = useState(false);
  const [successMessage, setSuccessMessage] = useState("");
  const requestRef = useRef(0);
  const detailsTriggerRef = useRef<HTMLButtonElement | null>(null);
  const editorTriggerRef = useRef<HTMLButtonElement | null>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);

  const loadConfiguration = useCallback(async () => {
    const requestId = ++requestRef.current;
    setLoading(true);
    setErrorMessage("");
    setSuccessMessage("");
    setAccessDenied(false);

    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (requestId !== requestRef.current) return;
    if (authError || !authData.user) {
      setSnapshot(null);
      setAccessDenied(true);
      setLoading(false);
      return;
    }

    const { data: roleData, error: roleError } = await supabase.rpc("get_my_role");
    if (requestId !== requestRef.current) return;
    if (roleError || roleData !== "admin") {
      setSnapshot(null);
      setAccessDenied(true);
      setLoading(false);
      return;
    }

    const { data, error } = await supabase.rpc(
      "admin_get_lane_booking_configuration_v2"
    );
    if (requestId !== requestRef.current) return;

    if (error) {
      console.error("Admin lane configuration read failed:", error.code);
      setSnapshot(null);
      setErrorMessage(CONTROLLED_READ_ERROR);
      setLoading(false);
      return;
    }

    try {
      setSnapshot(parseAdminLaneConfigurationSnapshot(data));
    } catch {
      console.error("Admin lane configuration RPC returned malformed data.");
      setSnapshot(null);
      setErrorMessage(CONTROLLED_READ_ERROR);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const timeoutId = window.setTimeout(() => {
      void loadConfiguration();
    }, 0);
    return () => {
      window.clearTimeout(timeoutId);
      requestRef.current += 1;
    };
  }, [loadConfiguration]);

  const families = useMemo(
    () => (snapshot ? buildLaneConfigurationHierarchy(snapshot) : []),
    [snapshot]
  );
  const visibleFamilies = useMemo(
    () => filterLaneConfigurationHierarchy(families, search),
    [families, search]
  );
  const summary = useMemo(
    () => getLaneConfigurationSummary(snapshot?.resources ?? []),
    [snapshot]
  );
  const selectedResource =
    snapshot?.resources.find((resource) => resource.lane_id === selectedResourceId) ??
    null;
  const selectedParentName = selectedResource?.parent_lane_id
    ? snapshot?.resources.find(
        (resource) => resource.lane_id === selectedResource.parent_lane_id
      )?.name ?? null
    : null;
  const selectedFamily =
    snapshot?.families.find((family) => family.root_lane_id === selectedFamilyId) ??
    null;

  const closeDetails = useCallback(() => {
    setSelectedResourceId(null);
    window.setTimeout(() => detailsTriggerRef.current?.focus(), 0);
  }, []);

  useEffect(() => {
    if (!selectedResource) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    window.setTimeout(() => closeButtonRef.current?.focus(), 0);

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        closeDetails();
        return;
      }
      if (event.key !== "Tab") return;
      const dialog = closeButtonRef.current?.closest('[role="dialog"]');
      const focusable = dialog?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), summary, a[href], input:not([disabled])'
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
    };
  }, [closeDetails, selectedResource]);

  function openDetails(
    resource: LaneConfigurationResource,
    trigger: HTMLButtonElement
  ) {
    detailsTriggerRef.current = trigger;
    setSelectedResourceId(resource.lane_id);
  }

  function openEditor(
    family: LaneConfigurationFamily,
    trigger: HTMLButtonElement
  ) {
    editorTriggerRef.current = trigger;
    setSelectedFamilyId(family.root_lane_id);
    setEditorDirty(false);
    setSuccessMessage("");
  }

  const closeEditor = useCallback(() => {
    setSelectedFamilyId(null);
    setEditorDirty(false);
    window.setTimeout(() => editorTriggerRef.current?.focus(), 0);
  }, []);

  const writeFamilyConfiguration = useCallback(
    async (
      rootLaneId: string,
      expectedVersion: number,
      payload: LaneFamilyWriteResource[],
      acknowledgeFutureObligations: boolean
    ) => {
      const { data, error } = await supabase.rpc(
        "admin_set_lane_booking_family_configuration_v2",
        {
          p_root_lane_id: rootLaneId,
          p_expected_version: expectedVersion,
          p_resources: payload,
          p_acknowledge_future_obligations: acknowledgeFutureObligations,
        }
      );
      if (error) {
        console.error("Admin lane configuration write failed:", error.code);
        throw new Error("controlled_write_error");
      }
      return parseLaneConfigurationWriteResult(data);
    },
    []
  );

  const completeEditor = useCallback(
    async (message: string) => {
      setSelectedFamilyId(null);
      setEditorDirty(false);
      await loadConfiguration();
      setSuccessMessage(message);
      window.setTimeout(() => editorTriggerRef.current?.focus(), 0);
    },
    [loadConfiguration]
  );

  const refreshConfiguration = useCallback(async () => {
    if (
      editorDirty &&
      !window.confirm("Masz niezapisane zmiany. Czy na pewno chcesz je odrzucić?")
    ) {
      return;
    }
    setSelectedFamilyId(null);
    setEditorDirty(false);
    await loadConfiguration();
  }, [editorDirty, loadConfiguration]);

  return (
    <AdminShell
      eyebrow="Panel administracyjny"
      title="Konfiguracja osi"
      description="Podgląd i kontrolowana edycja podstawowych ustawień osi i stanowisk."
      badge={<StatusBadge tone="olive">Edycja kontrolowana</StatusBadge>}
      actions={
        <>
          <button
            type="button"
            onClick={() => void refreshConfiguration()}
            disabled={loading}
            className="min-h-11 rounded-xl border border-[#536143] bg-[#20271e] px-4 py-2 text-sm font-semibold text-[#d7c895] transition hover:border-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-50"
          >
            {loading ? "Odświeżanie…" : "Odśwież"}
          </button>
          <Link
            href="/admin"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#3d4638] px-4 py-2 text-sm font-semibold text-[#c7cbbf] transition hover:bg-[#1d211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            ← Wróć do panelu
          </Link>
        </>
      }
    >
      <div aria-busy={loading}>
        {successMessage && (
          <div role="status" className="mb-5 rounded-2xl border border-[#536143] bg-[#20271e] p-4 text-[#b9c9a5]">
            {successMessage}
          </div>
        )}
        {accessDenied ? (
          <div role="alert" className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-5 text-[#e1c477]">
            Brak dostępu. Ten moduł jest dostępny tylko dla administratora.
          </div>
        ) : errorMessage ? (
          <div role="alert" className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-5 text-[#edb1b1]">
            {errorMessage}
          </div>
        ) : loading && !snapshot ? (
          <div role="status" className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
            Wczytywanie konfiguracji osi…
          </div>
        ) : snapshot ? (
          <>
            <section aria-labelledby="configuration-summary-heading">
              <h2 id="configuration-summary-heading" className="sr-only">
                Podsumowanie konfiguracji
              </h2>
              <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
                <SummaryCard label="Liczba osi" value={summary.lanes} />
                <SummaryCard label="Liczba stanowisk" value={summary.positions} />
                <SummaryCard label="Aktywne zasoby" value={summary.activeResources} />
                <SummaryCard label="Zasoby online" value={summary.onlineResources} />
              </div>
            </section>

            <section className="mt-7" aria-labelledby="configuration-search-heading">
              <h2 id="configuration-search-heading" className="sr-only">
                Wyszukiwanie zasobów
              </h2>
              <label className="block max-w-xl">
                <span className="mb-2 block text-sm font-semibold text-[#c7cbbf]">
                  Szukaj po nazwie osi lub stanowiska
                </span>
                <input
                  type="search"
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  placeholder="Wpisz nazwę zasobu"
                  className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-4 text-[#f2efe4] outline-none placeholder:text-[#73796e] focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25"
                />
              </label>
            </section>

            <section className="mt-7" aria-labelledby="configuration-resources-heading">
              <div className="mb-4 flex flex-wrap items-end justify-between gap-2">
                <div>
                  <h2 id="configuration-resources-heading" className="text-xl font-bold text-[#f2efe4] sm:text-2xl">
                    Osie i stanowiska
                  </h2>
                  <p className="mt-1 text-sm text-[#a9ada4]">
                    Status, czasy i cennik pozostają widoczne; podstawowe ustawienia edytujesz osobno dla każdej rodziny.
                  </p>
                </div>
                <p className="text-sm text-[#858c7f]">
                  Widoczne rodziny: {visibleFamilies.length}
                </p>
              </div>

              {families.length === 0 ? (
                <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
                  Brak skonfigurowanych osi i stanowisk.
                </div>
              ) : visibleFamilies.length === 0 ? (
                <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
                  Brak zasobów pasujących do wyszukiwania.
                </div>
              ) : (
                <div className="grid gap-5">
                  {visibleFamilies.map((family) => (
                    <LaneFamilyCard
                      key={family.root.lane_id}
                      family={family}
                      onOpenDetails={openDetails}
                      onEdit={openEditor}
                    />
                  ))}
                </div>
              )}
            </section>
          </>
        ) : null}
      </div>

      {selectedResource && (
        <ConfigurationDetailsDialog
          resource={selectedResource}
          parentName={selectedParentName}
          closeButtonRef={closeButtonRef}
          onClose={closeDetails}
        />
      )}
      {selectedFamily && (
        <LaneConfigurationEditor
          family={selectedFamily}
          onClose={closeEditor}
          onDirtyChange={setEditorDirty}
          onWrite={writeFamilyConfiguration}
          onCompleted={completeEditor}
        />
      )}
    </AdminShell>
  );
}
