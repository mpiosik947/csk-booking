"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
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
      return "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
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

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-6xl px-4 py-10 sm:px-6 sm:py-12">
        <header className="mb-10">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            ADMIN PANEL
          </p>
          <h1 className="text-3xl font-bold sm:text-4xl">Blokady osi</h1>
          <p className="mt-3 max-w-3xl text-zinc-400">
            Zarządzanie blokadami osi strzeleckich, serwisem, zawodami i
            szkoleniami zamkniętymi.
          </p>
        </header>

        {message && (
          <div role="status" className={getMessageClass(message)}>
            {message}
          </div>
        )}

        {loadError && (
          <div
            role="alert"
            className="mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300"
          >
            {LANE_DATA_LOAD_ERROR}
          </div>
        )}

        <section className="mb-10 rounded-2xl border border-zinc-800 bg-zinc-900 p-4 sm:p-6">
          <h2 className="mb-6 text-2xl font-bold">Dodaj blokadę</h2>

          <div className="grid gap-5">
            <label
              htmlFor="lane-block-resource"
              className="grid gap-2 text-sm font-semibold text-zinc-200"
            >
              Oś lub stanowisko
              <select
                id="lane-block-resource"
                value={laneId}
                onChange={(event) => setLaneId(event.target.value)}
                disabled={loading || loadError}
                className="min-h-11 w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition focus-visible:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600 disabled:cursor-not-allowed disabled:opacity-60"
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

            <div className="grid gap-5 md:grid-cols-3">
              <label className="grid gap-2 text-sm font-semibold text-zinc-200">
                Data blokady
                <input
                  type="date"
                  value={blockDate}
                  onChange={(event) => setBlockDate(event.target.value)}
                  className="min-h-11 w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus-visible:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600"
                />
              </label>

              <label className="grid gap-2 text-sm font-semibold text-zinc-200">
                Początek
                <input
                  type="time"
                  value={startTime}
                  onChange={(event) => setStartTime(event.target.value)}
                  className="min-h-11 w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus-visible:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600"
                />
              </label>

              <label className="grid gap-2 text-sm font-semibold text-zinc-200">
                Koniec
                <input
                  type="time"
                  value={endTime}
                  onChange={(event) => setEndTime(event.target.value)}
                  className="min-h-11 w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus-visible:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600"
                />
              </label>
            </div>

            <label className="grid gap-2 text-sm font-semibold text-zinc-200">
              Powód blokady
              <textarea
                value={reason}
                onChange={(event) => setReason(event.target.value)}
                rows={4}
                placeholder="Powód blokady (np. zawody, serwis, szkolenie zamknięte)"
                className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus-visible:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600"
              />
            </label>

            <button
              type="button"
              onClick={createBlock}
              disabled={loading || loadError || !selectedLaneIsActive}
              className="min-h-11 rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-900 disabled:cursor-not-allowed disabled:opacity-60"
            >
              Dodaj blokadę
            </button>
          </div>
        </section>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie blokad...
          </div>
        )}

        {!loading && !loadError && (
          <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 className="text-2xl font-bold">Zaplanowane blokady</h2>
              <p className="mt-1 text-sm text-zinc-400">
                Zasoby są opisane pełną nazwą osi i stanowiska.
              </p>
            </div>

            <label
              htmlFor="lane-block-status-filter"
              className="grid gap-2 text-sm font-semibold text-zinc-300 sm:w-52"
            >
              Status blokady
              <select
                id="lane-block-status-filter"
                value={blockFilter}
                onChange={(event) =>
                  setBlockFilter(event.target.value as LaneBlockFilter)
                }
                className="min-h-11 w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-2 text-white outline-none focus-visible:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600"
              >
                <option value="all">Wszystkie</option>
                <option value="active">Aktywne</option>
                <option value="inactive">Nieaktywne</option>
              </select>
            </label>
          </div>
        )}

        {!loading && !loadError && visibleBlocks.length === 0 && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Brak blokad dla wybranego filtra.
          </div>
        )}

        {!loading && !loadError && visibleBlocks.length > 0 && (
          <div className="grid gap-5">
            {visibleBlocks.map((block) => {
              const lane = lanesById.get(block.lane_id);
              const activationDisabled =
                !block.is_active && (!lane || !lane.isActive);

              return (
                <article
                  key={block.id}
                  className="min-w-0 rounded-2xl border border-zinc-800 bg-zinc-900 p-4 sm:p-6"
                >
                  <div className="flex min-w-0 flex-col gap-5 sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0">
                      <div className="mb-3 flex flex-wrap items-center gap-2">
                        <span
                          className={
                            block.is_active
                              ? "inline-flex rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300"
                              : "inline-flex rounded-full bg-zinc-800 px-3 py-1 text-xs font-semibold text-zinc-300"
                          }
                        >
                          {block.is_active ? "Aktywna blokada" : "Nieaktywna"}
                        </span>

                        {lane && !lane.isActive && (
                          <span className="inline-flex rounded-full border border-amber-800 bg-amber-950 px-3 py-1 text-xs font-semibold text-amber-200">
                            Zasób nieaktywny
                          </span>
                        )}
                      </div>

                      <h3 className="break-words text-xl font-bold sm:text-2xl">
                        {lane?.displayName ?? "Nieznany zasób"}
                      </h3>
                      <p className="mt-2 text-zinc-400">
                        {block.block_date} · {block.start_time.slice(0, 5)}–
                        {block.end_time.slice(0, 5)}
                      </p>

                      {block.reason && (
                        <p className="mt-3 break-words text-sm leading-relaxed text-zinc-300">
                          <span className="font-semibold text-zinc-200">
                            Powód:
                          </span>{" "}
                          {block.reason}
                        </p>
                      )}
                    </div>

                    <button
                      type="button"
                      onClick={() => toggleBlock(block.id, block.is_active)}
                      disabled={activationDisabled}
                      aria-label={`${block.is_active ? "Dezaktywuj" : "Aktywuj"} blokadę dla ${lane?.displayName ?? "nieznanego zasobu"}`}
                      className={
                        block.is_active
                          ? "min-h-11 w-full rounded-xl border border-green-800 px-5 py-3 text-sm font-semibold text-green-300 transition hover:bg-green-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 disabled:cursor-not-allowed disabled:opacity-60 sm:w-auto"
                          : "min-h-11 w-full rounded-xl border border-red-800 px-5 py-3 text-sm font-semibold text-red-300 transition hover:bg-red-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400 disabled:cursor-not-allowed disabled:opacity-60 sm:w-auto"
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
        )}

        <div className="mt-8">
          <Link
            href="/admin"
            className="inline-flex min-h-11 max-w-full items-center rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-500"
          >
            ← Panel administratora
          </Link>
        </div>
      </section>
    </main>
  );
}
