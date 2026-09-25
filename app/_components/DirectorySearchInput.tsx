"use client";

import { useSyncExternalStore } from "react";

function subscribe(onChange: () => void) {
  const media = window.matchMedia("(max-width: 639px)");
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
}

export default function DirectorySearchInput({ search }: { search: string }) {
  const mobile = useSyncExternalStore(subscribe,
    () => window.matchMedia("(max-width: 639px)").matches, () => true);
  return <input id="tenant-search" name="q" type="search" maxLength={80}
    defaultValue={search}
    placeholder={mobile ? "Szukaj strzelnicy lub miasta" : "Wyszukaj strzelnicę lub miejscowość"}
    className="min-h-12 min-w-0 flex-1 bg-transparent py-3 text-base text-[#F4F3EE] outline-none placeholder:text-[#777f73]" />;
}
