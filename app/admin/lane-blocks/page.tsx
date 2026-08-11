"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import {
  HierarchyResourceLabel,
  ResourceStatusBadge,
  ResourceTypeBadge,
} from "../_components/HierarchyResourcePresentation";
import {
  getLaneBlockErrorMessage,
  LANE_BLOCK_GENERIC_ERROR,
  validateLaneBlockRpcResult,
} from "../../../lib/admin/lane-block-management";
import {
  buildLaneHierarchyDisplayModel,
  type LaneHierarchyDisplayItem,
} from "../../../lib/admin/lane-hierarchy";
import { supabase } from "../../../lib/supabase";

type LaneBlock = {
  id: string;
  lane_id: string;
  block_date: string;
  start_time: string;
  end_time: string;
  reason: string;
  is_active: boolean;
};

type LaneBlockFilter = "all" | "active" | "inactive";

const LANE_DATA_LOAD_ERROR =
  "Nie udało się poprawnie wczytać zasobów i blokad.";

export default function LaneBlocksPage() {
  const [lanes, setLanes] = useState<LaneHierarchyDisplayItem[]>([]);
  const [blocks, setBlocks] = useState<LaneBlock[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(false);
  const [blockFilter, setBlockFilter] = useState<LaneBlockFilter>("all");

  const [laneId, setLaneId] = useState("");
  const [blockDate, setBlockDate] = useState("");
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [reason, setReason] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    void loadData();
  }, []);

  async function loadData() {
    setLoading(true);
    setLoadError(false);

    const [lanesResponse, blocksResponse] = await Promise.all([
      supabase
        .from("shooting_lanes")
        .select(
          "id,name,resource_kind,parent_lane_id,display_order,is_active"
        ),
      supabase
        .from("lane_blocks")
        .select("id,lane_id,block_date,start_time,end_time,reason,is_active")
        .order("block_date", { ascending: true })
        .order("start_time", { ascending: true })
        .order("id", { ascending: true }),
    ]);

    const hierarchy = buildLaneHierarchyDisplayModel(lanesResponse.data);

    if (lanesResponse.error || blocksResponse.error || !hierarchy.ok) {
      setLoadError(true);
      setLoading(false);
      return;
    }

    setLanes(hierarchy.value);
    setBlocks((blocksResponse.data as LaneBlock[] | null) ?? []);
    setLaneId((current) =>
      hierarchy.value.some((lane) => lane.id === current && lane.isActive)
        ? current
        : ""
    );
    setLoading(false);
  }

  async function createBlock() {
    setMessage("");

    const selectedLane = lanes.find((lane) => lane.id === laneId);

    if (!selectedLane?.isActive || !blockDate || !startTime || !endTime) {
      setMessage("Uzupełnij wymagane pola.");
      return;
    }

    const { data, error } = await supabase.rpc("admin_create_lane_block", {
      p_lane_id: laneId,
      p_block_date: blockDate,
      p_start_time: startTime,
      p_end_time: endTime,
      p_reason: reason,
    });

    if (error) {
      setMessage(LANE_BLOCK_GENERIC_ERROR);
      return;
    }

    const result = validateLaneBlockRpcResult(data);

    if (!result.ok || result.value.code !== "created") {
      setMessage(
        result.ok
          ? getLaneBlockErrorMessage(result.value.code)
          : LANE_BLOCK_GENERIC_ERROR
      );
      return;
    }

    setMessage("Blokada została dodana.");
    setLaneId("");
    setBlockDate("");
    setStartTime("");
    setEndTime("");
    setReason("");
    void loadData();
  }

  async function toggleBlock(blockId: string, currentStatus: boolean) {
    const targetStatus = !currentStatus;
    const { data, error } = await supabase.rpc(
      "admin_set_lane_block_active",
      {
        p_block_id: blockId,
        p_is_active: targetStatus,
      }
    );

    if (error) {
      setMessage(LANE_BLOCK_GENERIC_ERROR);
      return;
    }

    const result = validateLaneBlockRpcResult(data);
    const expectedCode = targetStatus ? "activated" : "deactivated";

    if (
      !result.ok ||
      result.value.lane_block_id !== blockId ||
      (result.value.code !== expectedCode && result.value.code !== "no_change")
    ) {
      setMessage(
        result.ok
          ? getLaneBlockErrorMessage(result.value.code)
          : LANE_BLOCK_GENERIC_ERROR
      );
      return;
    }

    void loadData();
  }

  function getMessageClass(value: string) {
    if (value.includes("dodana")) {
      return "mb-6 rounded-xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm font-semibold text-[#a9d4ad]";
    }

    return "mb-6 rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]";
  }

  const lanesById = new Map(lanes.map((lane) => [lane.id, lane]));
  const visibleBlocks = blocks.filter((block) => {
    if (blockFilter === "active") return block.is_active;
    if (blockFilter === "inactive") return !block.is_active;
    return true;
  });
  const selectedLaneIsActive = lanes.some(
    (lane) => lane.id === laneId && lane.isActive
  );
  const selectedLane = lanesById.get(laneId);
  const selectedLaneScopeMessage = selectedLane?.isActive
    ? selectedLane.isPosition
      ? "Blokada stanowiska uwzględnia również oś nadrzędną."
      : "Blokada całej osi obejmuje również jej stanowiska."
    : null;

  return (
    <main className="min-h-screen bg-[#090b09] text-[#f2efe4]">
      <section className="mx-auto max-w-6xl px-4 py-8 sm:px-6 sm:py-12">
        <header className="mb-8 sm:mb-10">
          <p className="mb-3 text-xs font-bold uppercase tracking-[0.3em] text-[#d7c895] sm:text-sm">
            ADMIN PANEL
          </p>
          <h1 className="text-3xl font-bold sm:text-4xl">Blokady osi</h1>
          <p className="mt-3 max-w-3xl text-sm leading-relaxed text-[#a9ada4] sm:text-base">
            Zarządzaj wyłączeniami całych osi i pojedynczych stanowisk bez
            zmiany konfiguracji rezerwacji.
          </p>
        </header>

        {message ? (
          <div role="status" className={getMessageClass(message)}>
            {message}
          </div>
        ) : null}

        {loadError ? (
          <div
            role="alert"
            className="mb-6 rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]"
          >
            {LANE_DATA_LOAD_ERROR}
          </div>
        ) : null}

        <section className="mb-10 overflow-hidden rounded-[2rem] border border-[#30372c] bg-[#141814] shadow-[0_24px_70px_rgba(0,0,0,0.24)]">
          <div className="border-b border-[#30372c] px-4 py-5 sm:px-6">
            <p className="text-xs font-bold uppercase tracking-[0.2em] text-[#d7c895]">
              Nowa blokada
            </p>
            <h2 className="mt-2 text-2xl font-bold">Dodaj blokadę</h2>
            <p className="mt-2 text-sm text-[#a9ada4]">
              Wybierz zasób, określ termin i opcjonalnie opisz przyczynę.
            </p>
          </div>

          <div className="grid gap-0 lg:grid-cols-2">
            <fieldset className="min-w-0 border-b border-[#30372c] p-4 sm:p-6 lg:border-r">
              <legend className="sr-only">Zasób</legend>
              <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#d7c895]">
                1. Zasób
              </p>
              <label
                htmlFor="lane-block-resource"
                className="mt-4 grid gap-2 text-sm font-semibold text-[#f2efe4]"
              >
                Oś lub stanowisko
                <select
                  id="lane-block-resource"
                  value={laneId}
                  onChange={(event) => setLaneId(event.target.value)}
                  disabled={loading || loadError}
                  className="min-h-11 w-full max-w-full rounded-xl border border-[#3d4638] bg-[#0f120f] px-4 py-3 text-[#f2efe4] outline-none transition hover:border-[#536143] focus-visible:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60"
                >
                  <option value="">Wybierz zasób</option>
                  {lanes.map((lane) => (
                    <option
                      key={lane.id}
                      value={lane.id}
                      disabled={!lane.isActive}
                    >
                      {lane.depth === 1 ? "↳ " : ""}
                      {lane.displayName}
                      {!lane.isActive ? " · Nieaktywne" : ""}
                    </option>
                  ))}
                </select>
              </label>

              {selectedLaneScopeMessage && selectedLane ? (
                <div className="mt-4 rounded-xl border border-[#536143] bg-[#20271e] p-3">
                  <HierarchyResourceLabel
                    resource={selectedLane}
                    compact
                    showStatus
                  />
                  <p className="mt-2 text-xs leading-relaxed text-[#c7cbbf]">
                    {selectedLaneScopeMessage}
                  </p>
                </div>
              ) : null}
            </fieldset>

            <fieldset className="min-w-0 border-b border-[#30372c] p-4 sm:p-6">
              <legend className="sr-only">Termin</legend>
              <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#d7c895]">
                2. Termin
              </p>
              <div className="mt-4 grid gap-4 sm:grid-cols-3 lg:grid-cols-1 xl:grid-cols-3">
                <label className="grid gap-2 text-sm font-semibold text-[#f2efe4]">
                  Data
                  <input
                    type="date"
                    value={blockDate}
                    onChange={(event) => setBlockDate(event.target.value)}
                    className="min-h-11 w-full min-w-0 rounded-xl border border-[#3d4638] bg-[#0f120f] px-4 py-3 text-[#f2efe4] outline-none transition hover:border-[#536143] focus-visible:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                  />
                </label>
                <label className="grid gap-2 text-sm font-semibold text-[#f2efe4]">
                  Od
                  <input
                    type="time"
                    value={startTime}
                    onChange={(event) => setStartTime(event.target.value)}
                    className="min-h-11 w-full min-w-0 rounded-xl border border-[#3d4638] bg-[#0f120f] px-4 py-3 text-[#f2efe4] outline-none transition hover:border-[#536143] focus-visible:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                  />
                </label>
                <label className="grid gap-2 text-sm font-semibold text-[#f2efe4]">
                  Do
                  <input
                    type="time"
                    value={endTime}
                    onChange={(event) => setEndTime(event.target.value)}
                    className="min-h-11 w-full min-w-0 rounded-xl border border-[#3d4638] bg-[#0f120f] px-4 py-3 text-[#f2efe4] outline-none transition hover:border-[#536143] focus-visible:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                  />
                </label>
              </div>
            </fieldset>

            <fieldset className="min-w-0 border-b border-[#30372c] p-4 sm:p-6 lg:border-r lg:border-b-0">
              <legend className="sr-only">Szczegóły</legend>
              <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#d7c895]">
                3. Szczegóły
              </p>
              <label className="mt-4 grid gap-2 text-sm font-semibold text-[#f2efe4]">
                Powód blokady
                <textarea
                  value={reason}
                  onChange={(event) => setReason(event.target.value)}
                  rows={4}
                  placeholder="Np. zawody, serwis lub szkolenie zamknięte"
                  className="w-full min-w-0 resize-y rounded-xl border border-[#3d4638] bg-[#0f120f] px-4 py-3 text-[#f2efe4] outline-none transition placeholder:text-[#858c7f] hover:border-[#536143] focus-visible:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                />
              </label>
              <p className="mt-2 text-xs text-[#858c7f]">
                Opis jest widoczny wyłącznie w panelu administracyjnym.
              </p>
            </fieldset>

            <div className="flex min-w-0 flex-col justify-between gap-4 p-4 sm:p-6">
              <div>
                <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#d7c895]">
                  4. Akcja
                </p>
                <p className="mt-3 text-sm leading-relaxed text-[#a9ada4]">
                  Aktywną blokadę możesz później bezpiecznie dezaktywować z
                  listy poniżej.
                </p>
              </div>
              <button
                type="button"
                onClick={createBlock}
                disabled={loading || loadError || !selectedLaneIsActive}
                className="min-h-11 w-full rounded-xl border border-[#536143] bg-[#536143] px-5 py-3 text-sm font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:opacity-60 sm:w-auto sm:self-start"
              >
                Dodaj blokadę
              </button>
            </div>
          </div>
        </section>

        {loading ? (
          <div
            role="status"
            className="animate-pulse rounded-2xl border border-[#30372c] bg-[#151915] p-6 text-sm text-[#a9ada4]"
          >
            Ładowanie blokad…
          </div>
        ) : null}

        {!loading && !loadError ? (
          <div className="mb-5 flex min-w-0 flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div className="min-w-0">
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-[#d7c895]">
                Harmonogram wyłączeń
              </p>
              <h2 className="mt-2 text-2xl font-bold">Zaplanowane blokady</h2>
              <p className="mt-1 text-sm text-[#a9ada4]">
                Pełna nazwa zawsze wskazuje oś i ewentualne stanowisko.
              </p>
            </div>

            <div
              role="group"
              aria-label="Filtr statusu blokad"
              className="grid w-full grid-cols-3 gap-1 rounded-xl border border-[#30372c] bg-[#141814] p-1 sm:w-auto"
            >
              {(
                [
                  ["all", "Wszystkie"],
                  ["active", "Aktywne"],
                  ["inactive", "Nieaktywne"],
                ] as const
              ).map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  aria-pressed={blockFilter === value}
                  onClick={() => setBlockFilter(value)}
                  className={`min-h-11 rounded-lg px-3 py-2 text-xs font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] sm:text-sm ${
                    blockFilter === value
                      ? "bg-[#536143] text-[#f2efe4] shadow-sm"
                      : "text-[#a9ada4] hover:bg-[#20271e] hover:text-[#f2efe4]"
                  }`}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>
        ) : null}

        {!loading && !loadError && visibleBlocks.length === 0 ? (
          <div className="rounded-2xl border border-[#30372c] bg-[#151915] p-6 text-center">
            <p className="font-semibold text-[#f2efe4]">Brak blokad</p>
            <p className="mt-2 text-sm text-[#a9ada4]">
              Dla wybranego filtra nie ma zaplanowanych wyłączeń.
            </p>
          </div>
        ) : null}

        {!loading && !loadError && visibleBlocks.length > 0 ? (
          <div className="grid gap-4">
            {visibleBlocks.map((block) => {
              const lane = lanesById.get(block.lane_id);
              const activationDisabled =
                !block.is_active && (!lane || !lane.isActive);

              return (
                <article
                  key={block.id}
                  className="min-w-0 rounded-2xl border border-[#30372c] bg-[#151915] p-4 transition hover:border-[#536143] sm:p-6"
                >
                  <div className="flex min-w-0 flex-col gap-5 md:flex-row md:items-center md:justify-between">
                    <div className="min-w-0 flex-1">
                      <h3 className="break-words text-xl font-bold text-[#f2efe4] sm:text-2xl">
                        {lane?.displayName ?? "Nieznany zasób"}
                      </h3>
                      <div className="mt-3 flex flex-wrap items-center gap-2">
                        {lane ? (
                          <>
                            <ResourceTypeBadge isPosition={lane.isPosition} />
                            <ResourceStatusBadge isActive={lane.isActive} />
                          </>
                        ) : null}
                        <span
                          className={
                            block.is_active
                              ? "inline-flex rounded-full border border-[#806a32] bg-[#2b2618] px-2.5 py-1 text-[0.68rem] font-bold uppercase tracking-[0.1em] text-[#e1c477]"
                              : "inline-flex rounded-full border border-[#343a31] bg-[#171a17] px-2.5 py-1 text-[0.68rem] font-bold uppercase tracking-[0.1em] text-[#858c7f]"
                          }
                        >
                          {block.is_active
                            ? "Blokada aktywna"
                            : "Blokada nieaktywna"}
                        </span>
                      </div>

                      <div className="mt-4 grid gap-3 sm:grid-cols-2">
                        <div className="rounded-xl border border-[#30372c] bg-[#0f120f] p-3">
                          <p className="text-xs uppercase tracking-[0.12em] text-[#858c7f]">
                            Data
                          </p>
                          <p className="mt-1 font-semibold text-[#f2efe4]">
                            {block.block_date}
                          </p>
                        </div>
                        <div className="rounded-xl border border-[#30372c] bg-[#0f120f] p-3">
                          <p className="text-xs uppercase tracking-[0.12em] text-[#858c7f]">
                            Godziny
                          </p>
                          <p className="mt-1 font-semibold text-[#f2efe4]">
                            {block.start_time.slice(0, 5)}–
                            {block.end_time.slice(0, 5)}
                          </p>
                        </div>
                      </div>

                      {block.reason ? (
                        <div className="mt-3 rounded-xl border border-[#30372c] bg-[#141814] p-3">
                          <p className="text-xs uppercase tracking-[0.12em] text-[#858c7f]">
                            Powód
                          </p>
                          <p className="mt-1 break-words text-sm leading-relaxed text-[#c7cbbf]">
                            {block.reason}
                          </p>
                        </div>
                      ) : null}
                    </div>

                    <button
                      type="button"
                      onClick={() => toggleBlock(block.id, block.is_active)}
                      disabled={activationDisabled}
                      aria-label={`${block.is_active ? "Dezaktywuj" : "Aktywuj"} blokadę dla ${lane?.displayName ?? "nieznanego zasobu"}`}
                      className={
                        block.is_active
                          ? "min-h-11 w-full rounded-xl border border-[#806a32] px-5 py-3 text-sm font-semibold text-[#e1c477] transition hover:bg-[#2b2618] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60 md:w-auto"
                          : "min-h-11 w-full rounded-xl border border-[#536143] bg-[#20271e] px-5 py-3 text-sm font-semibold text-[#a9d4ad] transition hover:border-[#78865f] hover:bg-[#293126] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60 md:w-auto"
                      }
                    >
                      {activationDisabled
                        ? "Zasób nieaktywny"
                        : block.is_active
                          ? "Dezaktywuj blokadę"
                          : "Aktywuj blokadę"}
                    </button>
                  </div>
                </article>
              );
            })}
          </div>
        ) : null}

        <div className="mt-8">
          <Link
            href="/admin"
            className="inline-flex min-h-11 max-w-full items-center rounded-xl border border-[#3d4638] px-5 py-3 text-sm font-semibold text-[#c7cbbf] transition hover:border-[#536143] hover:bg-[#20271e] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            ← Panel administratora
          </Link>
        </div>
      </section>
    </main>
  );
}
