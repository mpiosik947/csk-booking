"use client";
import { useEffect, useState } from "react";
import type { InstructorEvent, InstructorPage, InstructorParticipant } from "@/lib/instructor-contracts";
import { supabase } from "@/lib/supabase";

type Data = { events?: InstructorPage<InstructorEvent>; event?: InstructorEvent; participants?: InstructorPage<InstructorParticipant> | null };
const labels = { upcoming: "Nadchodzące", past: "Zakończone", cancelled: "Anulowane" };
const control = "rounded-xl border border-[#556044] px-4 py-3 text-sm text-[#e8ebe4] disabled:opacity-50";
export default function InstructorEvents({ slug, eventId }: { slug: string; eventId?: string }) {
  const [scope, setScope] = useState<keyof typeof labels>("upcoming");
  const [section, setSection] = useState("participants");
  const [page, setPage] = useState(0);
  const [reload, setReload] = useState(0);
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState(false);
  useEffect(() => {
    let controller: AbortController | undefined;
    let active = true;
    const clear = () => { controller?.abort(); setData(null); };
    const load = async () => {
      clear(); setError(false);
      if (document.visibilityState === "hidden") return;
      controller = new AbortController();
      const current = controller;
      const query = new URLSearchParams({ scope, section, page: String(page) });
      if (eventId) query.set("eventId", eventId);
      try {
        const response = await fetch(`/api/instructor/${slug}/events?${query}`, { cache: "no-store", signal: current.signal });
        if (!response.ok) throw Error("Denied");
        const next = await response.json() as Data;
        if (active && !current.signal.aborted) setData(next);
      } catch { if (active && !current.signal.aborted) { setData(null); setError(true); } }
    };
    const refresh = () => { void load(); };
    const visibility = () => document.visibilityState === "hidden" ? clear() : refresh();
    refresh();
    const timer = window.setInterval(refresh, 15000);
    window.addEventListener("focus", refresh); window.addEventListener("blur", clear);
    window.addEventListener("pageshow", refresh); window.addEventListener("pagehide", clear);
    document.addEventListener("visibilitychange", visibility);
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
      // INITIAL_SESSION must not abort the initial authorized fetch.
      if (event === "INITIAL_SESSION") return;
      clear(); setError(true);
    });
    return () => { active = false; controller?.abort(); window.clearInterval(timer); subscription.unsubscribe();
      window.removeEventListener("focus", refresh); window.removeEventListener("blur", clear);
      window.removeEventListener("pageshow", refresh); window.removeEventListener("pagehide", clear);
      document.removeEventListener("visibilitychange", visibility); };
  }, [slug, eventId, scope, section, page, reload]);
  const total = data?.events?.total ?? data?.participants?.total ?? 0;
  return <section className="min-w-0 rounded-2xl border border-[#343d2e] bg-[#141814] p-4 sm:p-6">
    <h1 className="text-2xl font-semibold">{eventId ? "Szczegóły szkolenia" : "Moje szkolenia"}</h1>
    <p className="mt-2 text-sm text-[#adb3a4]">Panel instruktora · tylko przypisane szkolenia</p>
    <nav aria-label={eventId ? "Sekcje szkolenia" : "Zakres szkoleń"} className="my-4 flex flex-wrap gap-2">
      {!eventId ? Object.entries(labels).map(([key,label]) => <button className={control} key={key} aria-pressed={scope === key} onClick={() => { setData(null); setScope(key as keyof typeof labels); setPage(0); }}>{label}</button>) : <>
        <button className={control} aria-pressed={section === "participants"} onClick={() => { setData(null); setSection("participants"); setPage(0); }}>Uczestnicy</button>
        <button className={control} aria-pressed={section === "reserve"} onClick={() => { setData(null); setSection("reserve"); setPage(0); }}>Lista rezerwowa</button>
      </>}
      <button className={control} onClick={() => setReload(v => v+1)}>Odśwież</button>
    </nav>
    {error ? <p role="alert">Brak dostępu lub nie udało się wczytać danych. Odśwież stronę.</p> : !data ? <p role="status">Sprawdzanie dostępu…</p> : <>
      {data.events && <ul className="space-y-3">{data.events.items.map(event => <li key={event.id} className="rounded-xl border border-[#343d2e] p-4 [overflow-wrap:anywhere]">
        <a className="font-semibold text-[#d7c895] underline" href={`/t/${slug}/instructor/events/${event.id}`}>{event.title}</a>
        <p>{event.event_date} · {event.start_time.slice(0,5)}–{event.end_time.slice(0,5)}</p><p>{event.location}</p><p>{labels[event.status]}</p>
      </li>)}{!data.events.items.length && <li>Brak przypisanych szkoleń w tym zakresie.</li>}</ul>}
      {data.event && <><h2 className="mt-4 text-xl font-semibold [overflow-wrap:anywhere]">{data.event.title}</h2>
        <h3 className="mt-4 font-semibold">Informacje</h3><p>{data.event.event_date} · {data.event.start_time.slice(0,5)}–{data.event.end_time.slice(0,5)}</p>
        <p className="[overflow-wrap:anywhere]">{data.event.location}</p><p>{labels[data.event.status]}</p><p className="mt-3 whitespace-pre-wrap [overflow-wrap:anywhere]">{data.event.description}</p>
        <h3 className="mt-6 font-semibold">{section === "reserve" ? "Lista rezerwowa — tylko odczyt" : "Uczestnicy"}</h3>
        {data.participants === null ? <p>Dane uczestników są niedostępne: szkolenie anulowane lub upłynął okres dostępu.</p> : <ul className="mt-3 space-y-2">{data.participants?.items.map(row => <li key={row.registration_id} className="rounded-xl border border-[#343d2e] p-3 [overflow-wrap:anywhere]">{row.display_name}<span className="block text-sm text-[#adb3a4]">{row.registration_status === "reserve" ? "Rezerwa" : row.registration_status === "approved" ? "Zatwierdzony" : "Zapisany"}</span></li>)}{data.participants?.items.length === 0 && <li>Brak osób w tej sekcji.</li>}</ul>}
      </>}
    </>}
    <div className="mt-5 flex flex-wrap gap-2"><button className={control} disabled={page === 0 || !data} onClick={() => { setData(null); setPage(v=>v-1); }}>Poprzednia</button>
      <button className={control} disabled={!data || (page+1)*(eventId ? 50 : 20)>=total} onClick={() => { setData(null); setPage(v=>v+1); }}>Następna</button></div>
    {eventId && <a className="mt-5 inline-block text-[#d7c895] underline" href={`/t/${slug}/instructor/events`}>Wróć do moich szkoleń</a>}
  </section>;
}
