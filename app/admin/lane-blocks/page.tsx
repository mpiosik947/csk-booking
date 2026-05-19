"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

type ShootingLane = {
  id: string;
  name: string;
};

type LaneBlock = {
  id: string;
  block_date: string;
  start_time: string;
  end_time: string;
  reason: string;
  is_active: boolean;
  shooting_lanes: {
    name: string;
  } | null;
};

export default function LaneBlocksPage() {
  const [lanes, setLanes] = useState<ShootingLane[]>([]);
  const [blocks, setBlocks] = useState<LaneBlock[]>([]);
  const [loading, setLoading] = useState(true);

  const [laneId, setLaneId] = useState("");
  const [blockDate, setBlockDate] = useState("");
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [reason, setReason] = useState("");

  const [message, setMessage] = useState("");

  useEffect(() => {
    loadData();
  }, []);

  async function loadData() {
    const { data: lanesData } = await supabase
      .from("shooting_lanes")
      .select("id, name")
      .order("name");

    const { data: blocksData } = await supabase
      .from("lane_blocks")
      .select(
        `
        id,
        block_date,
        start_time,
        end_time,
        reason,
        is_active,
        shooting_lanes (
          name
        )
      `
      )
      .order("block_date", { ascending: true });

    setLanes((lanesData as any) ?? []);
    setBlocks((blocksData as any) ?? []);

    setLoading(false);
  }

  async function createBlock() {
    setMessage("");

    if (!laneId || !blockDate || !startTime || !endTime) {
      setMessage("Uzupełnij wymagane pola.");
      return;
    }

    const { error } = await supabase.from("lane_blocks").insert({
      lane_id: laneId,
      block_date: blockDate,
      start_time: startTime,
      end_time: endTime,
      reason,
      is_active: true,
    });

    if (error) {
      setMessage(`Błąd blokady: ${error.message}`);
      return;
    }

    setMessage("Blokada została dodana.");

    setLaneId("");
    setBlockDate("");
    setStartTime("");
    setEndTime("");
    setReason("");

    loadData();
  }

  async function toggleBlock(blockId: string, currentStatus: boolean) {
    const { error } = await supabase
      .from("lane_blocks")
      .update({
        is_active: !currentStatus,
      })
      .eq("id", blockId);

    if (error) {
      setMessage(`Błąd zmiany statusu blokady: ${error.message}`);
      return;
    }

    loadData();
  }

  function getMessageClass(message: string) {
    if (message.includes("dodana")) {
      return "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-6xl px-6 py-12">
        <div className="mb-10">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            ADMIN PANEL
          </p>

          <h1 className="text-4xl font-bold">Blokady osi</h1>

          <p className="mt-3 text-zinc-400">
            Zarządzanie blokadami osi strzeleckich, serwisem, zawodami i
            szkoleniami zamkniętymi.
          </p>
        </div>

        {message && (
          <div className={getMessageClass(message)}>{message}</div>
        )}

        <div className="mb-10 rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
          <h2 className="mb-6 text-2xl font-bold">Dodaj blokadę</h2>

          <div className="grid gap-5">
            <select
              value={laneId}
              onChange={(event) => setLaneId(event.target.value)}
              className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            >
              <option value="">Wybierz oś</option>

              {lanes.map((lane) => (
                <option key={lane.id} value={lane.id}>
                  {lane.name}
                </option>
              ))}
            </select>

            <div className="grid gap-5 md:grid-cols-3">
              <input
                type="date"
                value={blockDate}
                onChange={(event) => setBlockDate(event.target.value)}
                className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
              />

              <input
                type="time"
                value={startTime}
                onChange={(event) => setStartTime(event.target.value)}
                className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
              />

              <input
                type="time"
                value={endTime}
                onChange={(event) => setEndTime(event.target.value)}
                className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
              />
            </div>

            <textarea
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              rows={4}
              placeholder="Powód blokady (np. zawody, serwis, szkolenie zamknięte)"
              className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />

            <button
              type="button"
              onClick={createBlock}
              className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600"
            >
              Dodaj blokadę
            </button>
          </div>
        </div>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie blokad...
          </div>
        )}

        {!loading && (
          <div className="grid gap-5">
            {blocks.map((block) => (
              <div
                key={block.id}
                className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
              >
                <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                  <div>
                    <span
                      className={
                        block.is_active
                          ? "mb-3 inline-block rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-400"
                          : "mb-3 inline-block rounded-full bg-zinc-800 px-3 py-1 text-xs font-semibold text-zinc-400"
                      }
                    >
                      {block.is_active ? "AKTYWNA BLOKADA" : "NIEAKTYWNA"}
                    </span>

                    <h2 className="text-2xl font-bold">
                      {block.shooting_lanes?.name ?? "Brak osi"}
                    </h2>

                    <p className="mt-2 text-zinc-400">
                      {block.block_date} |{" "}
                      {block.start_time.slice(0, 5)} -{" "}
                      {block.end_time.slice(0, 5)}
                    </p>

                    {block.reason && (
                      <p className="mt-3 text-zinc-300">
                        {block.reason}
                      </p>
                    )}
                  </div>

                  <button
                    type="button"
                    onClick={() =>
                      toggleBlock(block.id, block.is_active)
                    }
                    className={
                      block.is_active
                        ? "rounded-xl border border-green-800 px-5 py-3 text-sm font-semibold text-green-400 transition hover:bg-green-950"
                        : "rounded-xl border border-red-800 px-5 py-3 text-sm font-semibold text-red-400 transition hover:bg-red-950"
                    }
                  >
                    {block.is_active
                      ? "Dezaktywuj blokadę"
                      : "Aktywuj blokadę"}
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}

        <div className="mt-8">
          <a
            href="/admin"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel administratora
          </a>
        </div>
      </section>
    </main>
  );
}