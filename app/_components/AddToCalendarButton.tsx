"use client";

import { useState } from "react";
import { reportClientError } from "../../lib/safe-client-error";
import { supabase } from "../../lib/supabase";

type AddToCalendarButtonProps = {
  endpoint: string;
  filename: string;
};

export function AddToCalendarButton({ endpoint, filename }: AddToCalendarButtonProps) {
  const [downloading, setDownloading] = useState(false);
  const [message, setMessage] = useState("");

  async function downloadCalendar() {
    if (downloading) return;

    setDownloading(true);
    setMessage("");

    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) {
        setMessage("Sesja wygasła. Zaloguj się ponownie.");
        return;
      }

      const response = await fetch(endpoint, {
        method: "GET",
        headers: { Authorization: `Bearer ${session.access_token}` },
        cache: "no-store",
      });

      if (!response.ok) {
        setMessage(
          response.status === 409
            ? "Tego terminu nie można dodać do kalendarza."
            : "Nie udało się przygotować pliku kalendarza.",
        );
        return;
      }

      const blob = await response.blob();
      const downloadUrl = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = downloadUrl;
      link.download = filename;
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(downloadUrl);
    } catch {
      reportClientError("Calendar export failed");
      setMessage("Nie udało się przygotować pliku kalendarza.");
    } finally {
      setDownloading(false);
    }
  }

  return (
    <div className="min-w-0">
      <button
        type="button"
        onClick={downloadCalendar}
        disabled={downloading}
        className="inline-flex min-h-11 max-w-full items-center justify-center rounded-xl border border-[#536143] px-4 py-2 text-center text-sm font-semibold text-[#d7c895] transition hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:opacity-60"
      >
        {downloading ? "Przygotowywanie…" : "Dodaj do kalendarza"}
      </button>
      {message && (
        <p role="alert" className="mt-2 max-w-sm text-sm text-[#e0a0a0]">
          {message}
        </p>
      )}
    </div>
  );
}
