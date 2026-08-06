"use client";

import Link from "next/link";
import { useEffect, useRef } from "react";
import type {
  CalendarEntryPreviewData,
  CalendarEntryPreviewNavigation,
} from "../calendar-ui";

export default function CalendarEntryPreview({
  entry,
  navigation,
  onClose,
}: {
  entry: CalendarEntryPreviewData;
  navigation: CalendarEntryPreviewNavigation | null;
  onClose: () => void;
}) {
  const closeButtonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    closeButtonRef.current?.focus();
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center overflow-x-hidden bg-black/70 p-3 sm:items-center sm:p-6"
      onMouseDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="calendar-entry-preview-title"
        aria-describedby="calendar-entry-preview-content"
        className="w-full max-w-md overflow-hidden rounded-2xl border border-[#3d4638] bg-[#171c17] p-5 shadow-2xl"
      >
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h2
                id="calendar-entry-preview-title"
                className="text-xl font-black text-[#f2efe4]"
              >
                {entry.title}
              </h2>
              {entry.type !== "event" && entry.isHistorical && (
                <span className="rounded-full border border-[#596057] px-2 py-0.5 text-xs font-semibold text-[#b5baaf]">
                  Historyczna
                </span>
              )}
            </div>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            onClick={onClose}
            className="shrink-0 rounded-lg border border-[#536143] px-3 py-2 text-sm font-bold text-[#d7c895] hover:bg-[#20271e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            Zamknij
          </button>
        </div>

        <div
          id="calendar-entry-preview-content"
          className="mt-5 space-y-2 text-[#c7cbbf]"
        >
          {entry.type === "event" && (
            <p className="break-words text-base font-semibold text-[#f2efe4]">
              {entry.label}
            </p>
          )}
          {entry.type === "event" && <p>Data: {entry.date}</p>}
          <p className="font-bold tabular-nums text-[#f2efe4]">{entry.time}</p>
          {entry.type !== "event" && <p>{entry.laneName}</p>}
          {entry.type === "reservation" && (
            <p className="break-words">{entry.label}</p>
          )}
          {entry.type === "lane_block" && entry.reason && (
            <p className="break-words">{entry.reason}</p>
          )}
          {entry.type === "event" && entry.location && (
            <p className="break-words">{entry.location}</p>
          )}
          {entry.type === "event" && entry.laneName && <p>{entry.laneName}</p>}
          {entry.type === "event" && <p>Limit uczestnikĂłw: {entry.maxParticipants}</p>}
        </div>

        {navigation && (
          <Link
            href={navigation.href}
            className="mt-6 block w-full rounded-xl bg-[#536143] px-4 py-3 text-center font-bold text-[#f2efe4] hover:bg-[#647451] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
          >
            {navigation.label}
          </Link>
        )}
      </section>
    </div>
  );
}
