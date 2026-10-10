"use client";
import { useEffect, useRef, useState } from "react";
import type { InstructorEvent, InstructorPage, InstructorParticipant } from "@/lib/instructor-contracts";
import { supabase } from "@/lib/supabase";
import AttendanceControls from "./AttendanceControls";

type Data = { events?: InstructorPage<InstructorEvent>; event?: InstructorEvent; participants?: InstructorPage<InstructorParticipant> | null };
type AccessState = { key: string } & (
  | { status: "loading" | "denied" | "error" }
  | { status: "authorized"; data: Data }
);
const labels = { upcoming: "Nadchodzące", past: "Zakończone", cancelled: "Anulowane" };
const control = "rounded-xl border border-[#556044] px-4 py-3 text-sm text-[#e8ebe4] disabled:opacity-50";
export default function InstructorEvents({ slug, eventId }: { slug: string; eventId?: string }) {
  const [scope, setScope] = useState<keyof typeof labels>("upcoming");
  const [section, setSection] = useState("participants");
  const [page, setPage] = useState(0);
  const [reload, setReload] = useState(0);
  // In-memory identity only; equivalent SIGNED_IN notifications are not a retry trigger.
  const sessionKey = useRef<string | null | undefined>(undefined);
  const requestKey = JSON.stringify([slug, eventId, scope, section, page]);
  const [access, setAccess] = useState<AccessState>({ key: requestKey, status: "loading" });
  // Never render the previous tenant/event/page while its replacement effect is pending.
  const status = access.key === requestKey ? access.status : "loading";
  const data = access.key === requestKey && access.status === "authorized" ? access.data : null;
  const [attendanceMessage, setAttendanceMessage] = useState("");
  useEffect(() => {
    let controller: AbortController | undefined;
    let timer: number | undefined;
    let active = true;
    let terminal = false;
    const stop = () => {
      window.clearTimeout(timer); timer = undefined; controller?.abort();
    };
    const pause = () => {
      stop();
      if (!terminal) setAccess({ key: requestKey, status: "loading" });
    };
    const load = async () => {
      stop(); terminal = false;
      setAccess({ key: requestKey, status: "loading" });
      if (document.visibilityState === "hidden") return;
      controller = new AbortController();
      const current = controller;
      const query = new URLSearchParams({ scope, section, page: String(page) });
      if (eventId) query.set("eventId", eventId);
      try {
        const response = await fetch(`/api/instructor/${slug}/events?${query}`, { cache: "no-store", signal: current.signal });
        if (!response.ok) {
          if (active && !current.signal.aborted) {
            terminal = true;
            setAccess({ key: requestKey,
              status: response.status === 401 || response.status === 403 ? "denied" : "error" });
          }
          return;
        }
        const next = await response.json() as Data;
        if (active && !current.signal.aborted) {
          setAccess({ key: requestKey, status: "authorized", data: next });
          // Refresh data/revocation only after success, never after denial or transport failure.
          timer = window.setTimeout(refresh, 15000);
        }
      } catch {
        if (active && !current.signal.aborted) {
          terminal = true; setAccess({ key: requestKey, status: "error" });
        }
      }
    };
    const refresh = () => { void load(); };
    const resume = () => { if (!terminal) refresh(); };
    const visibility = () => document.visibilityState === "hidden" ? pause() : resume();
    refresh();
    window.addEventListener("focus", resume); window.addEventListener("blur", pause);
    window.addEventListener("pageshow", resume); window.addEventListener("pagehide", pause);
    document.addEventListener("visibilitychange", visibility);
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
      // Cookie recovery can emit SIGNED_IN after the initial fetch starts.
      // Auth events invalidate data; only the server reader can grant access.
      if (!active) return;
      const nextKey = session ? `${session.user.id}:${session.access_token}` : null;
      const previousKey = sessionKey.current;
      sessionKey.current = nextKey;
      if (event === "SIGNED_OUT") {
        stop(); terminal = true; setAccess({ key: requestKey, status: "denied" });
      } else if (nextKey !== previousKey && !(event === "INITIAL_SESSION" && previousKey === undefined)) {
        refresh();
      }
    });
    return () => { active = false; stop(); subscription.unsubscribe();
      window.removeEventListener("focus", resume); window.removeEventListener("blur", pause);
      window.removeEventListener("pageshow", resume); window.removeEventListener("pagehide", pause);
      document.removeEventListener("visibilitychange", visibility); };
  }, [slug, eventId, scope, section, page, reload, requestKey]);
  const total = data?.events?.total ?? data?.participants?.total ?? 0;
  return <section className="min-w-0 rounded-2xl border border-[#343d2e] bg-[#141814] p-4 sm:p-6">
    <h1 className="text-2xl font-semibold">{eventId ? "Szczegóły szkolenia" : "Moje szkolenia"}</h1>
    <p className="mt-2 text-sm text-[#adb3a4]">Panel instruktora · tylko przypisane szkolenia</p>
    {attendanceMessage && <p role="alert" className="mt-3 text-sm">{attendanceMessage}</p>}
    <nav aria-label={eventId ? "Sekcje szkolenia" : "Zakres szkoleń"} className="my-4 flex flex-wrap gap-2">
      {!eventId ? Object.entries(labels).map(([key,label]) => <button className={control} key={key} aria-pressed={scope === key} onClick={() => { setScope(key as keyof typeof labels); setPage(0); }}>{label}</button>) : <>
        <button className={control} aria-pressed={section === "participants"} onClick={() => { setSection("participants"); setPage(0); }}>Uczestnicy</button>
        <button className={control} aria-pressed={section === "reserve"} onClick={() => { setSection("reserve"); setPage(0); }}>Lista rezerwowa</button>
      </>}
      <button className={control} onClick={() => setReload(v => v+1)}>Odśwież</button>
    </nav>
    {status === "denied" ? <p role="alert">Brak dostępu do szkoleń w tej lokalizacji.</p>
      : status === "error" ? <p role="alert">Nie udało się wczytać danych. Spróbuj ponownie.</p>
      : !data ? <p role="status">Sprawdzanie dostępu…</p> : <>
      {data.events && <ul className="space-y-3">{data.events.items.map(event => <li key={event.id} className="rounded-xl border border-[#343d2e] p-4 [overflow-wrap:anywhere]">
        <a className="font-semibold text-[#d7c895] underline" href={`/t/${slug}/instructor/events/${event.id}`}>{event.title}</a>
        <p>{event.event_date} · {event.start_time.slice(0,5)}–{event.end_time.slice(0,5)}</p><p>{event.location}</p><p>{labels[event.status]}</p>
      </li>)}{!data.events.items.length && <li>Brak przypisanych szkoleń w tym zakresie.</li>}</ul>}
      {data.event && <><h2 className="mt-4 text-xl font-semibold [overflow-wrap:anywhere]">{data.event.title}</h2>
        <h3 className="mt-4 font-semibold">Informacje</h3><p>{data.event.event_date} · {data.event.start_time.slice(0,5)}–{data.event.end_time.slice(0,5)}</p>
        <p className="[overflow-wrap:anywhere]">{data.event.location}</p><p>{labels[data.event.status]}</p><p className="mt-3 whitespace-pre-wrap [overflow-wrap:anywhere]">{data.event.description}</p>
        <h3 className="mt-6 font-semibold">{section === "reserve" ? "Lista rezerwowa — tylko odczyt" : "Lista obecności"}</h3>
        {data.event.participants_available && data.participants && <div className="mt-3">
          <div className="flex flex-wrap gap-2">
            <a className={control} href={`/api/instructor/${slug}/events/${data.event.id}/attendance/csv`}>Pobierz CSV</a>
            <a className={control} href={`/api/instructor/${slug}/events/${data.event.id}/attendance/print`} target="_blank" rel="noopener noreferrer">Drukuj listę</a>
          </div><p className="mt-2 text-sm text-[#adb3a4]">CSV i wydruk: zapisani i zatwierdzeni, bez rezerwy. Limit 100 osób. Każde pobranie wymaga aktualnego dostępu.</p>
        </div>}
        {section === "participants" && <p className="mt-2 text-sm text-[#adb3a4]">Zmiany od 2 godzin przed rozpoczęciem do 24 godzin po zakończeniu. Dostęp i czas sprawdza serwer.</p>}
        {data.participants === null ? <p>Dane uczestników są niedostępne: szkolenie anulowane lub upłynął okres dostępu.</p> : <ul className="mt-3 space-y-2">{data.participants?.items.map(row => <li key={row.registration_id} className="rounded-xl border border-[#343d2e] p-3 [overflow-wrap:anywhere]">{row.display_name}<span className="block text-sm text-[#adb3a4]">{row.registration_status === "reserve" ? "Rezerwa" : row.registration_status === "approved" ? "Zatwierdzony" : "Zapisany"}</span>
          <AttendanceControls row={row} onRefresh={message => { setAttendanceMessage(message ?? ""); setReload(v => v+1); }} />
        </li>)}{data.participants?.items.length === 0 && <li>Brak osób w tej sekcji.</li>}</ul>}
      </>}
    </>}
    <div className="mt-5 flex flex-wrap gap-2"><button className={control} disabled={page === 0 || !data} onClick={() => setPage(v=>v-1)}>Poprzednia</button>
      <button className={control} disabled={!data || (page+1)*(eventId ? 50 : 20)>=total} onClick={() => setPage(v=>v+1)}>Następna</button></div>
    {eventId && <a className="mt-5 inline-block text-[#d7c895] underline" href={`/t/${slug}/instructor/events`}>Wróć do moich szkoleń</a>}
  </section>;
}
