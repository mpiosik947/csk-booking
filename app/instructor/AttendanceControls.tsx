"use client";
import { useState } from "react";
import { supabase } from "@/lib/supabase";
import type { InstructorParticipant } from "@/lib/instructor-contracts";

const labels = { unmarked: "Nieoznaczony", present: "Obecny", no_show: "Nieobecny" };
export default function AttendanceControls({ row, onRefresh }: { row: InstructorParticipant; onRefresh: (message?: string) => void }) {
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  if (row.registration_status === "reserve") return null;
  async function save(status: InstructorParticipant["attendance_status"]) {
    if (busy) return;
    setBusy(true); setMessage("");
    try {
      const result = await supabase.rpc("set_event_registration_attendance_v1", {
        p_registration_id: row.registration_id, p_attendance_status: status,
        p_expected_attendance_version: row.attendance_version,
      });
      let outcome = "";
      if (result.error) {
        outcome = result.error.code === "40001"
          ? "Obecność została zmieniona przez inną osobę. Odświeżono stan; sprawdź go przed ponowną zmianą."
          : "Nie można zmienić obecności. Sprawdź dostęp i dozwolone okno czasowe.";
      }
      // Reauthorize/read after both success and conflict. Never blind retry.
      onRefresh(outcome);
    } catch { setMessage("Nie udało się potwierdzić zmiany. Odśwież listę przed ponowną próbą."); }
    finally { setBusy(false); }
  }
  return <div className="mt-3 min-w-0">
    <p className="text-sm font-semibold">Obecność: {labels[row.attendance_status]}</p>
    <div className="mt-2 flex flex-wrap gap-2">
      {(["present", "no_show", "unmarked"] as const).map(status => <button key={status} type="button" disabled={busy}
        onClick={() => void save(status)} aria-pressed={row.attendance_status === status}
        className="min-h-11 rounded-xl border border-[#556044] px-4 py-3 text-sm disabled:opacity-50">
        {status === "unmarked" ? "Wyczyść" : labels[status]}
      </button>)}
    </div>
    {message && <p role="alert" className="mt-2 text-sm">{message}</p>}
  </div>;
}
