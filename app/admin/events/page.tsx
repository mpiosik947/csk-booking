"use client";

import { useEffect, useRef, useState } from "react";
import {
  normalizeAdminEvent,
  type AdminEvent,
} from "../../../lib/admin/events/event-management";
import { supabase } from "../../../lib/supabase";

type RegistrationAction = "approve" | "cancel";

const EVENTS_LOAD_ERROR_MESSAGE =
  "Nie udało się poprawnie wczytać listy szkoleń.";

type ApproveRegistrationResult = {
  ok: boolean;
  changed: boolean;
  code: string;
  registration_id?: string;
  event_id?: string;
  previous_status?: string;
  new_status?: string;
};

type CancelRegistrationResult = {
  success: boolean;
  cancellation: {
    registrationId: string;
    eventId: string;
    changed: boolean;
    previousStatus: string;
    newStatus: string;
    freedParticipantPlace: boolean;
  };
  promotion: {
    attempted: boolean;
    succeeded: boolean;
    warning: boolean;
  };
  message: string;
};

type Registration = {
  id: string;
  customer_name: string;
  customer_email: string;
  customer_phone: string;
  registration_status: string;
  payment_status: string;
  created_at: string;
};

function translateRegistrationStatus(status: string) {
  if (status === "registered") return "Zapisany";
  if (status === "approved") return "Zatwierdzony";
  if (status === "cancelled") return "Anulowany";
  if (status === "reserve") return "Rezerwowy";
  return status;
}

function getStatusClass(status: string) {
  if (status === "approved") {
    return "rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400";
  }

  if (status === "registered") {
    return "rounded-full bg-blue-950 px-3 py-1 text-xs font-semibold text-blue-300";
  }

  if (status === "reserve") {
    return "rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300";
  }

  if (status === "cancelled") {
    return "rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300";
  }

  return "rounded-full bg-zinc-950 px-3 py-1 text-xs font-semibold text-zinc-300";
}

function getPaidRegistrationsCount(registrations: Registration[]) {
  return registrations.filter(
    (registration) =>
      registration.registration_status === "registered" ||
      registration.registration_status === "approved"
  ).length;
}

function getReserveRegistrationsCount(registrations: Registration[]) {
  return registrations.filter(
    (registration) => registration.registration_status === "reserve"
  ).length;
}

function getCancelledRegistrationsCount(registrations: Registration[]) {
  return registrations.filter(
    (registration) => registration.registration_status === "cancelled"
  ).length;
}

function getParticipantRegistrations(registrations: Registration[]) {
  return registrations.filter(
    (registration) =>
      registration.registration_status === "registered" ||
      registration.registration_status === "approved"
  );
}

function getReserveRegistrations(registrations: Registration[]) {
  return registrations
    .filter((registration) => registration.registration_status === "reserve")
    .sort(
      (first, second) =>
        new Date(first.created_at).getTime() -
        new Date(second.created_at).getTime()
    );
}

function getCancelledRegistrations(registrations: Registration[]) {
  return registrations.filter(
    (registration) => registration.registration_status === "cancelled"
  );
}

function EventLanesSummary({ lanes }: { lanes: AdminEvent["lanes"] }) {
  return (
    <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
      <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">
        Zajmowane osie
      </p>

      {lanes.length === 0 ? (
        <p className="mt-2 text-sm text-zinc-400">
          Event globalny — nie blokuje osi
        </p>
      ) : (
        <div className="mt-2 flex flex-wrap gap-2">
          {lanes.map((lane) => (
            <span
              key={lane.id}
              className="inline-flex max-w-full flex-wrap items-center gap-2 rounded-full border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm font-semibold text-zinc-200"
            >
              <span className="break-words">{lane.name}</span>
              {!lane.is_active && (
                <span className="rounded-full bg-yellow-950 px-2 py-0.5 text-xs font-semibold text-yellow-300">
                  Nieaktywna
                </span>
              )}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function FieldHelp({ children }: { children: React.ReactNode }) {
  return <p className="mt-2 text-xs leading-relaxed text-zinc-500">{children}</p>;
}

export default function AdminEventsPage() {
  const [loading, setLoading] = useState(true);
  const [events, setEvents] = useState<AdminEvent[]>([]);
  const [selectedEventId, setSelectedEventId] = useState("");
  const [registrations, setRegistrations] = useState<Registration[]>([]);
  const [message, setMessage] = useState("");
  const [userRole, setUserRole] = useState("");
  const [registrationActions, setRegistrationActions] = useState<
    Record<string, RegistrationAction>
  >({});
  const registrationActionLocksRef = useRef(new Set<string>());
  const eventsLoadRequestRef = useRef(0);

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [eventDate, setEventDate] = useState("");
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [location, setLocation] = useState("");
  const [price, setPrice] = useState("");
  const [maxParticipants, setMaxParticipants] = useState("10");

  const [editingEventId, setEditingEventId] = useState("");
  const [editTitle, setEditTitle] = useState("");
  const [editDescription, setEditDescription] = useState("");
  const [editEventDate, setEditEventDate] = useState("");
  const [editStartTime, setEditStartTime] = useState("");
  const [editEndTime, setEditEndTime] = useState("");
  const [editLocation, setEditLocation] = useState("");
  const [editPrice, setEditPrice] = useState("");
  const [editMaxParticipants, setEditMaxParticipants] = useState("");

  const canManageEvents = userRole === "admin" || userRole === "pracownik";

  useEffect(() => {
    loadEvents();
    loadRole();
  }, []);

  async function loadRole() {
    const { data, error } = await supabase.rpc("get_my_role");

    if (error) {
      setUserRole("");
      return;
    }

    if (data) {
      setUserRole(String(data));
    }
  }

  async function loadEvents() {
    const requestId = ++eventsLoadRequestRef.current;
    const { data, error } = await supabase
      .from("events")
      .select(`
        id,
        title,
        description,
        event_date,
        start_time,
        end_time,
        location,
        price,
        max_participants,
        is_active,
        created_at,
        event_lanes (
          lane_id,
          shooting_lanes (
            id,
            name,
            type,
            is_active,
            display_order
          )
        )
      `)
      .order("event_date", { ascending: true });

    if (requestId !== eventsLoadRequestRef.current) {
      return;
    }

    setLoading(false);

    if (error) {
      setMessage(EVENTS_LOAD_ERROR_MESSAGE);
      return;
    }

    if (!Array.isArray(data)) {
      setMessage(EVENTS_LOAD_ERROR_MESSAGE);
      return;
    }

    const normalizedEvents: AdminEvent[] = [];

    for (const record of data) {
      const normalized = normalizeAdminEvent(record);

      if (!normalized.ok) {
        setMessage(EVENTS_LOAD_ERROR_MESSAGE);
        return;
      }

      normalizedEvents.push(normalized.value);
    }

    setEvents(normalizedEvents);
    setMessage((current) =>
      current === EVENTS_LOAD_ERROR_MESSAGE ? "" : current
    );
  }

  async function loadRegistrations(eventId: string) {
    setSelectedEventId(eventId);

    const { data, error } = await supabase
      .from("event_registrations")
      .select("*")
      .eq("event_id", eventId)
      .order("created_at", { ascending: false });

    if (error) {
      console.error("Event registrations loading failed", { code: error.code });
      setMessage("Nie udało się pobrać zapisów. Spróbuj ponownie.");
      return;
    }

    setRegistrations((data ?? []) as Registration[]);
  }

  async function createEvent() {
    setMessage("");

    if (!canManageEvents) {
      setMessage("Brak dostępu. Instruktor nie może tworzyć szkoleń.");
      return;
    }

    if (
      !title ||
      !description ||
      !eventDate ||
      !startTime ||
      !endTime ||
      !location ||
      !price ||
      !maxParticipants
    ) {
      setMessage("Uzupełnij wszystkie pola.");
      return;
    }

    if (Number(price) < 0) {
      setMessage("Cena nie może być ujemna.");
      return;
    }

    if (Number(maxParticipants) <= 0) {
      setMessage("Liczba miejsc musi być większa od zera.");
      return;
    }

    const { error } = await supabase.from("events").insert({
      title,
      description,
      event_date: eventDate,
      start_time: startTime,
      end_time: endTime,
      location,
      price: Number(price),
      max_participants: Number(maxParticipants),
      is_active: true,
    });

    if (error) {
      setMessage(`Błąd tworzenia szkolenia: ${error.message}`);
      return;
    }

    setMessage("Szkolenie zostało dodane.");

    setTitle("");
    setDescription("");
    setEventDate("");
    setStartTime("");
    setEndTime("");
    setLocation("");
    setPrice("");
    setMaxParticipants("10");

    loadEvents();
  }

  function startEditing(event: AdminEvent) {
    if (!canManageEvents) {
      setMessage("Brak dostępu. Instruktor nie może edytować szkoleń.");
      return;
    }

    setEditingEventId(event.id);
    setEditTitle(event.title);
    setEditDescription(event.description ?? "");
    setEditEventDate(event.event_date);
    setEditStartTime(event.start_time.slice(0, 5));
    setEditEndTime(event.end_time.slice(0, 5));
    setEditLocation(event.location ?? "");
    setEditPrice(String(event.price));
    setEditMaxParticipants(String(event.max_participants));
  }

  function cancelEditing() {
    setEditingEventId("");
    setEditTitle("");
    setEditDescription("");
    setEditEventDate("");
    setEditStartTime("");
    setEditEndTime("");
    setEditLocation("");
    setEditPrice("");
    setEditMaxParticipants("");
  }

  async function saveEditedEvent(eventId: string) {
    setMessage("");

    if (!canManageEvents) {
      setMessage("Brak dostępu. Instruktor nie może edytować szkoleń.");
      return;
    }

    if (
      !editTitle ||
      !editDescription ||
      !editEventDate ||
      !editStartTime ||
      !editEndTime ||
      !editLocation ||
      !editPrice ||
      !editMaxParticipants
    ) {
      setMessage("Uzupełnij wszystkie pola edycji.");
      return;
    }

    if (Number(editPrice) < 0) {
      setMessage("Cena nie może być ujemna.");
      return;
    }

    if (Number(editMaxParticipants) <= 0) {
      setMessage("Liczba miejsc musi być większa od zera.");
      return;
    }

    const { error } = await supabase
      .from("events")
      .update({
        title: editTitle,
        description: editDescription,
        event_date: editEventDate,
        start_time: editStartTime,
        end_time: editEndTime,
        location: editLocation,
        price: Number(editPrice),
        max_participants: Number(editMaxParticipants),
      })
      .eq("id", eventId);

    if (error) {
      setMessage(`Błąd edycji szkolenia: ${error.message}`);
      return;
    }

    setMessage("Szkolenie zostało zaktualizowane.");
    cancelEditing();
    loadEvents();
  }

  async function toggleEvent(eventId: string, currentStatus: boolean) {
    if (!canManageEvents) {
      setMessage(
        "Brak dostępu. Instruktor nie może aktywować ani ukrywać szkoleń."
      );
      return;
    }

    const { error } = await supabase
      .from("events")
      .update({ is_active: !currentStatus })
      .eq("id", eventId);

    if (error) {
      setMessage(`Błąd zmiany statusu szkolenia: ${error.message}`);
      return;
    }

    loadEvents();
  }

  function beginRegistrationAction(
    registrationId: string,
    action: RegistrationAction
  ) {
    if (registrationActionLocksRef.current.has(registrationId)) {
      return false;
    }

    registrationActionLocksRef.current.add(registrationId);
    setRegistrationActions((current) => ({
      ...current,
      [registrationId]: action,
    }));
    return true;
  }

  function endRegistrationAction(registrationId: string) {
    registrationActionLocksRef.current.delete(registrationId);
    setRegistrationActions((current) => {
      const next = { ...current };
      delete next[registrationId];
      return next;
    });
  }

  function isApproveRegistrationResult(
    value: unknown
  ): value is ApproveRegistrationResult {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }

    const result = value as Record<string, unknown>;
    return (
      typeof result.ok === "boolean" &&
      typeof result.changed === "boolean" &&
      typeof result.code === "string"
    );
  }

  function isCancelRegistrationResult(
    value: unknown
  ): value is CancelRegistrationResult {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }

    const result = value as Record<string, unknown>;
    const cancellation = result.cancellation;
    const promotion = result.promotion;

    if (
      !cancellation ||
      typeof cancellation !== "object" ||
      Array.isArray(cancellation) ||
      !promotion ||
      typeof promotion !== "object" ||
      Array.isArray(promotion)
    ) {
      return false;
    }

    const cancellationResult = cancellation as Record<string, unknown>;
    const promotionResult = promotion as Record<string, unknown>;

    return (
      result.success === true &&
      typeof result.message === "string" &&
      typeof cancellationResult.registrationId === "string" &&
      typeof cancellationResult.eventId === "string" &&
      typeof cancellationResult.changed === "boolean" &&
      typeof cancellationResult.previousStatus === "string" &&
      typeof cancellationResult.newStatus === "string" &&
      typeof cancellationResult.freedParticipantPlace === "boolean" &&
      typeof promotionResult.attempted === "boolean" &&
      typeof promotionResult.succeeded === "boolean" &&
      typeof promotionResult.warning === "boolean"
    );
  }

  async function reloadSelectedRegistrations() {
    if (selectedEventId) {
      await loadRegistrations(selectedEventId);
    }
  }

  async function approveRegistration(registrationId: string) {
    setMessage("");

    if (!canManageEvents) {
      setMessage("Brak uprawnień do zarządzania zapisami uczestników.");
      return;
    }

    if (!beginRegistrationAction(registrationId, "approve")) {
      return;
    }

    try {
      const { data, error } = await supabase.rpc(
        "approve_event_registration",
        { p_registration_id: registrationId }
      );

      if (error) {
        console.error("Event registration approval failed", {
          code: error.code,
        });
        setMessage("Nie udało się zatwierdzić uczestnika. Spróbuj ponownie.");
        return;
      }

      if (!isApproveRegistrationResult(data)) {
        console.error("Event registration approval returned invalid data");
        setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
        return;
      }

      if (data.code === "updated") {
        if (
          !data.ok ||
          !data.changed ||
          data.registration_id !== registrationId ||
          data.event_id !== selectedEventId ||
          data.previous_status !== "registered" ||
          data.new_status !== "approved"
        ) {
          console.error("Event registration approval returned invalid update");
          setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
          await reloadSelectedRegistrations();
          return;
        }

        setRegistrations((current) =>
          current.map((item) =>
            item.id === registrationId
              ? { ...item, registration_status: "approved" }
              : item
          )
        );
        setMessage("Uczestnik został zatwierdzony.");
        return;
      }

      if (data.code === "unchanged") {
        if (
          !data.ok ||
          data.changed ||
          data.registration_id !== registrationId ||
          data.event_id !== selectedEventId ||
          data.previous_status !== "approved" ||
          data.new_status !== "approved"
        ) {
          console.error("Event registration approval returned invalid no-op");
          setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
          await reloadSelectedRegistrations();
          return;
        }

        setMessage("Uczestnik jest już zatwierdzony.");
        return;
      }

      if (data.code === "invalid_transition") {
        setMessage("Zapisu w tym statusie nie można zatwierdzić.");
        await reloadSelectedRegistrations();
        return;
      }

      if (data.code === "unauthorized") {
        setMessage("Nie masz uprawnień do zatwierdzenia uczestnika.");
        return;
      }

      if (
        data.code === "registration_not_found" ||
        data.code === "event_not_found"
      ) {
        setMessage(
          "Nie znaleziono zapisu lub szkolenia. Lista została odświeżona."
        );
        await reloadSelectedRegistrations();
        return;
      }

      console.error("Event registration approval returned unknown code");
      setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
    } catch {
      setMessage("Nie udało się zatwierdzić uczestnika. Spróbuj ponownie.");
    } finally {
      endRegistrationAction(registrationId);
    }
  }

  async function cancelRegistration(registrationId: string) {
    setMessage("");

    if (!canManageEvents) {
      setMessage("Brak uprawnień do zarządzania zapisami uczestników.");
      return;
    }

    if (!beginRegistrationAction(registrationId, "cancel")) {
      return;
    }

    try {
      const {
        data: { session },
        error: sessionError,
      } = await supabase.auth.getSession();

      if (sessionError || !session?.access_token) {
        setMessage("Brak aktywnej sesji. Zaloguj się ponownie.");
        return;
      }

      const response = await fetch("/api/cancel-event-registration", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ registrationId }),
      });
      const data: unknown = await response.json().catch(() => null);

      if (!response.ok) {
        if (response.status === 401) {
          setMessage("Brak aktywnej sesji. Zaloguj się ponownie.");
        } else if (response.status === 403) {
          setMessage("Nie masz uprawnień do anulowania tego zapisu.");
        } else if (response.status === 404) {
          setMessage(
            "Nie znaleziono zapisu lub szkolenia. Lista została odświeżona."
          );
          await reloadSelectedRegistrations();
        } else if (response.status === 409) {
          setMessage("Zapisu w tym statusie nie można anulować.");
          await reloadSelectedRegistrations();
        } else {
          setMessage("Nie udało się anulować zapisu. Spróbuj ponownie.");
        }
        return;
      }

      if (
        !isCancelRegistrationResult(data) ||
        data.cancellation.registrationId !== registrationId ||
        data.cancellation.eventId !== selectedEventId ||
        data.cancellation.newStatus !== "cancelled"
      ) {
        console.error("Event registration cancellation returned invalid data");
        setMessage("Nie udało się potwierdzić wyniku anulowania.");
        await reloadSelectedRegistrations();
        return;
      }

      if (data.cancellation.changed) {
        setRegistrations((current) =>
          current.map((item) =>
            item.id === registrationId
              ? { ...item, registration_status: "cancelled" }
              : item
          )
        );
      } else {
        await reloadSelectedRegistrations();
      }

      if (data.promotion.attempted) {
        await reloadSelectedRegistrations();
      }

      setMessage(
        data.promotion.warning
          ? "Zapis anulowano, ale obsługa listy rezerwowej wymaga ponowienia."
          : data.cancellation.changed
            ? "Udział został anulowany."
            : "Udział jest anulowany."
      );
    } catch {
      setMessage("Nie udało się anulować zapisu. Spróbuj ponownie.");
    } finally {
      endRegistrationAction(registrationId);
    }
  }

  async function markRegistrationPaid(registrationId: string) {
    if (!canManageEvents) {
      setMessage("Brak uprawnień do zarządzania zapisami uczestników.");
      return;
    }

    const { error } = await supabase
      .from("event_registrations")
      .update({ payment_status: "paid_on_site" })
      .eq("id", registrationId);

    if (error) {
      setMessage(`Błąd zmiany płatności: ${error.message}`);
      return;
    }

    setRegistrations((current) =>
      current.map((item) =>
        item.id === registrationId
          ? { ...item, payment_status: "paid_on_site" }
          : item
      )
    );

    setMessage("Uczestnik oznaczony jako opłacony.");
  }

  function getMessageClass(message: string) {
    if (
      message.includes("dodane") ||
      message.includes("zaktualizowany") ||
      message.includes("zaktualizowane") ||
      message.includes("opłacony") ||
      message.includes("zatwierdzony") ||
      message.includes("anulowany")
    ) {
      return "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-6 py-12">
        <div className="mb-10">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            ADMIN PANEL
          </p>

          <h1 className="text-4xl font-bold">Eventy i szkolenia</h1>

          <p className="mt-3 text-zinc-400">
            Dodawanie, edycja, aktywacja, lista uczestników, zatwierdzanie
            zapisów i płatności.
          </p>

          {userRole === "instruktor" && (
            <div className="mt-5 rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-sm font-semibold text-yellow-200">
              Tryb instruktora: możesz przeglądać szkolenia i listy uczestników,
              ale nie możesz tworzyć, edytować ani ukrywać szkoleń.
            </div>
          )}
        </div>

        {message && (
          <div className={`mb-6 ${getMessageClass(message)}`}>{message}</div>
        )}

        {canManageEvents && (
          <div className="mb-10 rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
            <div className="mb-6">
              <h2 className="text-2xl font-bold">Dodaj nowe szkolenie</h2>

              <p className="mt-2 text-sm text-zinc-400">
                Wypełnij dane szkolenia. Wolne miejsca nie są wpisywane ręcznie —
                system liczy je automatycznie na podstawie liczby zapisanych
                uczestników.
              </p>
            </div>

            <div className="grid gap-5">
              <div>
                <label className="mb-2 block text-sm font-semibold text-zinc-200">
                  Nazwa szkolenia
                </label>

                <input
                  type="text"
                  value={title}
                  onChange={(event) => setTitle(event.target.value)}
                  placeholder="Np. Szkolenie pistolet podstawowy"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                />

                <FieldHelp>
                  Wpisz krótką, czytelną nazwę szkolenia widoczną dla klienta.
                </FieldHelp>
              </div>

              <div>
                <label className="mb-2 block text-sm font-semibold text-zinc-200">
                  Opis szkolenia
                </label>

                <textarea
                  value={description}
                  onChange={(event) => setDescription(event.target.value)}
                  rows={5}
                  placeholder="Np. Zakres szkolenia, wymagania, dla kogo jest szkolenie, co zawiera cena..."
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                />

                <FieldHelp>
                  Opisz, czego dotyczy szkolenie i co uczestnik powinien wiedzieć
                  przed zapisem.
                </FieldHelp>
              </div>

              <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-5">
                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Data szkolenia
                  </label>

                  <input
                    type="date"
                    value={eventDate}
                    onChange={(event) => setEventDate(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

                  <FieldHelp>
                    Wybierz dzień, w którym odbędzie się szkolenie.
                  </FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Godzina rozpoczęcia
                  </label>

                  <input
                    type="time"
                    value={startTime}
                    onChange={(event) => setStartTime(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

                  <FieldHelp>Podaj godzinę startu, np. 10:00.</FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Godzina zakończenia
                  </label>

                  <input
                    type="time"
                    value={endTime}
                    onChange={(event) => setEndTime(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

                  <FieldHelp>Podaj godzinę zakończenia, np. 14:00.</FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Cena
                  </label>

                  <input
                    type="number"
                    min="0"
                    value={price}
                    onChange={(event) => setPrice(event.target.value)}
                    placeholder="Np. 250"
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

                  <FieldHelp>
                    Wpisz cenę za jednego uczestnika. Dla darmowego szkolenia
                    wpisz 0.
                  </FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Liczba miejsc
                  </label>

                  <input
                    type="number"
                    min="1"
                    value={maxParticipants}
                    onChange={(event) => setMaxParticipants(event.target.value)}
                    placeholder="Np. 10"
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

                  <FieldHelp>
                    Maksymalna liczba uczestników. Wolne miejsca system wyliczy
                    sam.
                  </FieldHelp>
                </div>
              </div>

              <div>
                <label className="mb-2 block text-sm font-semibold text-zinc-200">
                  Miejsce / oś
                </label>

                <input
                  type="text"
                  value={location}
                  onChange={(event) => setLocation(event.target.value)}
                  placeholder="Np. Oś 25 m, sala szkoleniowa, oś 100 m"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                />

                <FieldHelp>
                  Wpisz miejsce prowadzenia szkolenia albo konkretną oś.
                </FieldHelp>
              </div>

              <div className="rounded-xl border border-green-900 bg-green-950/40 p-4 text-sm text-green-200">
                <p className="font-semibold">Informacja o wolnych miejscach</p>
                <p className="mt-1 text-green-300">
                  Tego pola nie uzupełniasz ręcznie. System liczy wolne miejsca:
                  liczba miejsc minus zapisani uczestnicy.
                </p>
              </div>

              <button
                type="button"
                onClick={createEvent}
                className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600"
              >
                Dodaj szkolenie
              </button>
            </div>
          </div>
        )}

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie szkoleń...
          </div>
        )}

        <div className="grid gap-6">
          {events.map((event) => {
            const selectedRegistrations =
              selectedEventId === event.id ? registrations : [];

            const activeRegistrationsCount =
              getPaidRegistrationsCount(selectedRegistrations);

            const reserveRegistrationsCount =
              getReserveRegistrationsCount(selectedRegistrations);

            const cancelledRegistrationsCount =
              getCancelledRegistrationsCount(selectedRegistrations);

            const participantRegistrations =
              getParticipantRegistrations(selectedRegistrations);

            const reserveRegistrations =
              getReserveRegistrations(selectedRegistrations);

            const cancelledRegistrations =
              getCancelledRegistrations(selectedRegistrations);

            const freePlaces =
              selectedEventId === event.id
                ? Math.max(event.max_participants - activeRegistrationsCount, 0)
                : null;

            return (
              <div
                key={event.id}
                className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
              >
                {editingEventId === event.id && canManageEvents ? (
                  <div className="grid gap-5">
                    <h2 className="text-2xl font-bold text-green-400">
                      Edycja szkolenia
                    </h2>

                    <div>
                      <label className="mb-2 block text-sm font-semibold text-zinc-200">
                        Nazwa szkolenia
                      </label>

                      <input
                        type="text"
                        value={editTitle}
                        onChange={(e) => setEditTitle(e.target.value)}
                        placeholder="Np. Szkolenie pistolet podstawowy"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                      />

                      <FieldHelp>
                        Krótka nazwa szkolenia widoczna dla klienta.
                      </FieldHelp>
                    </div>

                    <div>
                      <label className="mb-2 block text-sm font-semibold text-zinc-200">
                        Opis szkolenia
                      </label>

                      <textarea
                        value={editDescription}
                        onChange={(e) => setEditDescription(e.target.value)}
                        rows={5}
                        placeholder="Opis szkolenia, wymagania, zakres, informacje organizacyjne..."
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                      />

                      <FieldHelp>
                        Opisz zakres szkolenia i najważniejsze informacje dla
                        uczestnika.
                      </FieldHelp>
                    </div>

                    <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-5">
                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Data szkolenia
                        </label>

                        <input
                          type="date"
                          value={editEventDate}
                          onChange={(e) => setEditEventDate(e.target.value)}
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                        />

                        <FieldHelp>Dzień, w którym odbędzie się szkolenie.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Godzina rozpoczęcia
                        </label>

                        <input
                          type="time"
                          value={editStartTime}
                          onChange={(e) => setEditStartTime(e.target.value)}
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                        />

                        <FieldHelp>Godzina startu szkolenia.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Godzina zakończenia
                        </label>

                        <input
                          type="time"
                          value={editEndTime}
                          onChange={(e) => setEditEndTime(e.target.value)}
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                        />

                        <FieldHelp>Godzina zakończenia szkolenia.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Cena
                        </label>

                        <input
                          type="number"
                          min="0"
                          value={editPrice}
                          onChange={(e) => setEditPrice(e.target.value)}
                          placeholder="Np. 250"
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                        />

                        <FieldHelp>Cena za jednego uczestnika.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Liczba miejsc
                        </label>

                        <input
                          type="number"
                          min="1"
                          value={editMaxParticipants}
                          onChange={(e) =>
                            setEditMaxParticipants(e.target.value)
                          }
                          placeholder="Np. 10"
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                        />

                        <FieldHelp>
                          Limit uczestników. Wolne miejsca liczy system.
                        </FieldHelp>
                      </div>
                    </div>

                    <div>
                      <label className="mb-2 block text-sm font-semibold text-zinc-200">
                        Miejsce / oś
                      </label>

                      <input
                        type="text"
                        value={editLocation}
                        onChange={(e) => setEditLocation(e.target.value)}
                        placeholder="Np. Oś 25 m, sala szkoleniowa, oś 100 m"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                      />

                      <FieldHelp>
                        Miejsce prowadzenia szkolenia albo konkretna oś.
                      </FieldHelp>
                    </div>

                    <div className="rounded-xl border border-green-900 bg-green-950/40 p-4 text-sm text-green-200">
                      <p className="font-semibold">
                        Wolnych miejsc nie edytujesz ręcznie
                      </p>
                      <p className="mt-1 text-green-300">
                        System wylicza je automatycznie z liczby miejsc i liczby
                        zapisanych uczestników.
                      </p>
                    </div>

                    <div className="flex flex-col gap-3 sm:flex-row">
                      <button
                        type="button"
                        onClick={() => saveEditedEvent(event.id)}
                        className="rounded-xl bg-green-700 px-5 py-3 text-sm font-semibold transition hover:bg-green-600"
                      >
                        Zapisz zmiany
                      </button>

                      <button
                        type="button"
                        onClick={cancelEditing}
                        className="rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-800"
                      >
                        Anuluj edycję
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                      <div className="max-w-4xl">
                        <span
                          className={
                            event.is_active
                              ? "mb-3 inline-block rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400"
                              : "mb-3 inline-block rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-400"
                          }
                        >
                          {event.is_active ? "AKTYWNE" : "UKRYTE"}
                        </span>

                        <h2 className="mb-3 text-3xl font-bold">
                          {event.title}
                        </h2>

                        <p className="mb-5 whitespace-pre-line text-zinc-300">
                          {event.description}
                        </p>

                        <div className="grid gap-3 text-sm text-zinc-400 md:grid-cols-2 lg:grid-cols-5">
                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-1 text-zinc-500">Data</p>
                            <p className="font-semibold text-white">
                              {event.event_date}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-1 text-zinc-500">Godzina</p>
                            <p className="font-semibold text-white">
                              {event.start_time.slice(0, 5)} -{" "}
                              {event.end_time.slice(0, 5)}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-1 text-zinc-500">Miejsce</p>
                            <p className="font-semibold text-white">
                              {event.location}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-1 text-zinc-500">Cena</p>
                            <p className="font-semibold text-green-500">
                              {Number(event.price).toFixed(0)} zł
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-1 text-zinc-500">Miejsca</p>
                            <p className="font-semibold text-white">
                              Limit: {event.max_participants}
                            </p>
                            {freePlaces !== null && (
                              <p className="mt-1 text-xs font-semibold text-green-400">
                                Wolne: {freePlaces}
                              </p>
                            )}

                            {selectedEventId === event.id && (
                              <div className="mt-3 space-y-1 border-t border-zinc-800 pt-3 text-xs">
                                <p className="font-semibold text-green-400">
                                  Uczestnicy: {activeRegistrationsCount} / {event.max_participants}
                                </p>
                                <p className="font-semibold text-yellow-300">
                                  Lista rezerwowa: {reserveRegistrationsCount}
                                </p>
                                <p className="font-semibold text-red-300">
                                  Anulowani: {cancelledRegistrationsCount}
                                </p>
                              </div>
                            )}
                          </div>
                        </div>

                        <EventLanesSummary lanes={event.lanes} />
                      </div>

                      <div className="flex min-w-[220px] flex-col gap-3">
                        {canManageEvents && (
                          <button
                            type="button"
                            onClick={() => startEditing(event)}
                            className="rounded-xl border border-blue-800 px-4 py-3 text-sm font-semibold text-blue-300 transition hover:bg-blue-950"
                          >
                            Edytuj szkolenie
                          </button>
                        )}

                        <button
                          type="button"
                          onClick={() => loadRegistrations(event.id)}
                          className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold transition hover:bg-zinc-800"
                        >
                          Pokaż zapisanych
                        </button>

                        {canManageEvents && (
                          <button
                            type="button"
                            onClick={() =>
                              toggleEvent(event.id, event.is_active)
                            }
                            className={
                              event.is_active
                                ? "rounded-xl border border-red-800 px-4 py-3 text-sm font-semibold text-red-400 transition hover:bg-red-950"
                                : "rounded-xl border border-green-800 px-4 py-3 text-sm font-semibold text-green-400 transition hover:bg-green-950"
                            }
                          >
                            {event.is_active
                              ? "Ukryj szkolenie"
                              : "Aktywuj szkolenie"}
                          </button>
                        )}
                      </div>
                    </div>

                    {selectedEventId === event.id && (
                      <div className="mt-6 rounded-2xl border border-zinc-800 bg-zinc-950 p-5">
                        <h3 className="mb-5 text-xl font-bold">
                          Lista zapisanych osób
                        </h3>

                        {registrations.length === 0 ? (
                          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-zinc-400">
                            Brak zapisanych osób.
                          </div>
                        ) : (
                          <div className="grid gap-5">
                            {participantRegistrations.length > 0 && (
                              <div className="rounded-xl border border-green-900 bg-green-950/20 p-4">
                                <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
                                  <div>
                                    <h4 className="text-lg font-bold text-green-300">
                                      Uczestnicy
                                    </h4>
                                    <p className="text-sm text-zinc-400">
                                      Osoby zapisane jako uczestnicy szkolenia.
                                    </p>
                                  </div>

                                  <span className="rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-300">
                                    {participantRegistrations.length} / {event.max_participants}
                                  </span>
                                </div>

                                <div className="overflow-x-auto">
                                  <table className="min-w-full text-sm">
                                    <thead>
                                      <tr className="border-b border-zinc-800 text-left text-zinc-500">
                                        <th className="px-4 py-3">Imię i nazwisko</th>
                                        <th className="px-4 py-3">E-mail</th>
                                        <th className="px-4 py-3">Telefon</th>
                                        <th className="px-4 py-3">Status</th>
                                        <th className="px-4 py-3">Płatność</th>
                                        {canManageEvents && (
                                          <th className="px-4 py-3">Akcje</th>
                                        )}
                                      </tr>
                                    </thead>

                                    <tbody>
                                      {participantRegistrations.map((registration) => (
                                        <tr key={registration.id} className="border-b border-zinc-900">
                                          <td className="px-4 py-4 font-semibold">
                                            {registration.customer_name}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_email}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_phone}
                                          </td>
                                          <td className="px-4 py-4">
                                            <span className={getStatusClass(registration.registration_status)}>
                                              {translateRegistrationStatus(registration.registration_status)}
                                            </span>
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.payment_status === "paid_on_site"
                                              ? "Opłacone"
                                              : "Płatność na miejscu"}
                                          </td>
                                          {canManageEvents && (
                                            <td className="px-4 py-4">
                                              <div className="flex flex-wrap gap-2">
                                              <button
                                                type="button"
                                                onClick={() => approveRegistration(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-green-800 px-3 py-2 text-xs text-green-300 hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                {registrationActions[registration.id] === "approve"
                                                  ? "Zatwierdzanie..."
                                                  : "Zatwierdź"}
                                              </button>

                                              <button
                                                type="button"
                                                onClick={() => markRegistrationPaid(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-blue-800 px-3 py-2 text-xs text-blue-300 hover:bg-blue-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                Opłacone
                                              </button>

                                              <button
                                                type="button"
                                                onClick={() => cancelRegistration(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-red-800 px-3 py-2 text-xs text-red-300 hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                {registrationActions[registration.id] === "cancel"
                                                  ? "Anulowanie..."
                                                  : "Anuluj"}
                                              </button>
                                              </div>
                                            </td>
                                          )}
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              </div>
                            )}

                            {reserveRegistrations.length > 0 && (
                              <div className="rounded-xl border border-yellow-900 bg-yellow-950/20 p-4">
                                <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
                                  <div>
                                    <h4 className="text-lg font-bold text-yellow-300">
                                      Lista rezerwowa
                                    </h4>
                                    <p className="text-sm text-zinc-400">
                                      Kolejność według daty zapisu. Pierwsza osoba na liście ma najwyższy priorytet.
                                    </p>
                                  </div>

                                  <span className="rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300">
                                    {reserveRegistrations.length}
                                  </span>
                                </div>

                                <div className="overflow-x-auto">
                                  <table className="min-w-full text-sm">
                                    <thead>
                                      <tr className="border-b border-zinc-800 text-left text-zinc-500">
                                        <th className="px-4 py-3">Kolejka</th>
                                        <th className="px-4 py-3">Imię i nazwisko</th>
                                        <th className="px-4 py-3">E-mail</th>
                                        <th className="px-4 py-3">Telefon</th>
                                        <th className="px-4 py-3">Status</th>
                                        <th className="px-4 py-3">Płatność</th>
                                        {canManageEvents && (
                                          <th className="px-4 py-3">Akcje</th>
                                        )}
                                      </tr>
                                    </thead>

                                    <tbody>
                                      {reserveRegistrations.map((registration, index) => (
                                        <tr key={registration.id} className="border-b border-zinc-900">
                                          <td className="px-4 py-4 font-bold text-yellow-300">
                                            #{index + 1}
                                          </td>
                                          <td className="px-4 py-4 font-semibold">
                                            {registration.customer_name}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_email}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_phone}
                                          </td>
                                          <td className="px-4 py-4">
                                            <span className={getStatusClass(registration.registration_status)}>
                                              {translateRegistrationStatus(registration.registration_status)}
                                            </span>
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.payment_status === "paid_on_site"
                                              ? "Opłacone"
                                              : "Płatność na miejscu"}
                                          </td>
                                          {canManageEvents && (
                                            <td className="px-4 py-4">
                                              <div className="flex flex-wrap gap-2">
                                              <button
                                                type="button"
                                                onClick={() => markRegistrationPaid(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-blue-800 px-3 py-2 text-xs text-blue-300 hover:bg-blue-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                Opłacone
                                              </button>

                                              <button
                                                type="button"
                                                onClick={() => cancelRegistration(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-red-800 px-3 py-2 text-xs text-red-300 hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                {registrationActions[registration.id] === "cancel"
                                                  ? "Anulowanie..."
                                                  : "Anuluj"}
                                              </button>
                                              </div>
                                            </td>
                                          )}
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              </div>
                            )}

                            {cancelledRegistrations.length > 0 && (
                              <div className="rounded-xl border border-red-900 bg-red-950/20 p-4">
                                <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
                                  <div>
                                    <h4 className="text-lg font-bold text-red-300">
                                      Anulowani
                                    </h4>
                                    <p className="text-sm text-zinc-400">
                                      Osoby, których zapis został anulowany.
                                    </p>
                                  </div>

                                  <span className="rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300">
                                    {cancelledRegistrations.length}
                                  </span>
                                </div>

                                <div className="overflow-x-auto">
                                  <table className="min-w-full text-sm">
                                    <thead>
                                      <tr className="border-b border-zinc-800 text-left text-zinc-500">
                                        <th className="px-4 py-3">Imię i nazwisko</th>
                                        <th className="px-4 py-3">E-mail</th>
                                        <th className="px-4 py-3">Telefon</th>
                                        <th className="px-4 py-3">Status</th>
                                        <th className="px-4 py-3">Płatność</th>
                                      </tr>
                                    </thead>

                                    <tbody>
                                      {cancelledRegistrations.map((registration) => (
                                        <tr key={registration.id} className="border-b border-zinc-900">
                                          <td className="px-4 py-4 font-semibold">
                                            {registration.customer_name}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_email}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_phone}
                                          </td>
                                          <td className="px-4 py-4">
                                            <span className={getStatusClass(registration.registration_status)}>
                                              {translateRegistrationStatus(registration.registration_status)}
                                            </span>
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.payment_status === "paid_on_site"
                                              ? "Opłacone"
                                              : "Płatność na miejscu"}
                                          </td>
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              </div>
                            )}
                          </div>
                        )}
                      </div>
                    )}
                  </>
                )}
              </div>
            );
          })}
        </div>

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/admin"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel administratora
          </a>

          <a
            href="/events"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Zobacz stronę szkoleń
          </a>
        </div>
      </section>
    </main>
  );
}
