"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

type Event = {
  id: string;
  title: string;
  description: string;
  event_date: string;
  start_time: string;
  end_time: string;
  location: string;
  price: number;
  max_participants: number;
  is_active: boolean;
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

export default function AdminEventsPage() {
  const [loading, setLoading] = useState(true);
  const [events, setEvents] = useState<Event[]>([]);
  const [selectedEventId, setSelectedEventId] = useState("");
  const [registrations, setRegistrations] = useState<Registration[]>([]);
  const [message, setMessage] = useState("");

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

  useEffect(() => {
    loadEvents();
  }, []);

  async function loadEvents() {
    const { data, error } = await supabase
      .from("events")
      .select("*")
      .order("event_date", { ascending: true });

    setLoading(false);

    if (error) {
      setMessage(`Błąd pobierania szkoleń: ${error.message}`);
      return;
    }

    setEvents((data ?? []) as Event[]);
  }

  async function loadRegistrations(eventId: string) {
    setSelectedEventId(eventId);

    const { data, error } = await supabase
      .from("event_registrations")
      .select("*")
      .eq("event_id", eventId)
      .order("created_at", { ascending: false });

    if (error) {
      setMessage(`Błąd pobierania zapisów: ${error.message}`);
      return;
    }

    setRegistrations((data ?? []) as Registration[]);
  }

  async function createEvent() {
    setMessage("");

    if (
      !title ||
      !description ||
      !eventDate ||
      !startTime ||
      !endTime ||
      !location
    ) {
      setMessage("Uzupełnij wszystkie pola.");
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

  function startEditing(event: Event) {
    setEditingEventId(event.id);
    setEditTitle(event.title);
    setEditDescription(event.description);
    setEditEventDate(event.event_date);
    setEditStartTime(event.start_time.slice(0, 5));
    setEditEndTime(event.end_time.slice(0, 5));
    setEditLocation(event.location);
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

  async function updateRegistrationStatus(
    registrationId: string,
    status: string
  ) {
    const { error } = await supabase
      .from("event_registrations")
      .update({ registration_status: status })
      .eq("id", registrationId);

    if (error) {
      setMessage(`Błąd zmiany statusu uczestnika: ${error.message}`);
      return;
    }

    setRegistrations((current) =>
      current.map((item) =>
        item.id === registrationId
          ? { ...item, registration_status: status }
          : item
      )
    );

    setMessage("Status uczestnika został zaktualizowany.");
  }

  async function markRegistrationPaid(registrationId: string) {
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
      message.includes("opłacony")
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
        </div>

        {message && (
          <div className={`mb-6 ${getMessageClass(message)}`}>{message}</div>
        )}

        <div className="mb-10 rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
          <h2 className="mb-6 text-2xl font-bold">Dodaj nowe szkolenie</h2>

          <div className="grid gap-5">
            <input
              type="text"
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder="Nazwa szkolenia"
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />

            <textarea
              value={description}
              onChange={(event) => setDescription(event.target.value)}
              rows={5}
              placeholder="Opis szkolenia..."
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />

            <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-5">
              <input
                type="date"
                value={eventDate}
                onChange={(event) => setEventDate(event.target.value)}
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

              <input
                type="number"
                value={price}
                onChange={(event) => setPrice(event.target.value)}
                placeholder="Cena"
                className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
              />

              <input
                type="number"
                value={maxParticipants}
                onChange={(event) => setMaxParticipants(event.target.value)}
                placeholder="Limit miejsc"
                className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
              />
            </div>

            <input
              type="text"
              value={location}
              onChange={(event) => setLocation(event.target.value)}
              placeholder="Miejsce / oś"
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />

            <button
              type="button"
              onClick={createEvent}
              className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600"
            >
              Dodaj szkolenie
            </button>
          </div>
        </div>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie szkoleń...
          </div>
        )}

        <div className="grid gap-6">
          {events.map((event) => (
            <div
              key={event.id}
              className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
            >
              {editingEventId === event.id ? (
                <div className="grid gap-5">
                  <h2 className="text-2xl font-bold text-green-400">
                    Edycja szkolenia
                  </h2>

                  <input
                    type="text"
                    value={editTitle}
                    onChange={(e) => setEditTitle(e.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

                  <textarea
                    value={editDescription}
                    onChange={(e) => setEditDescription(e.target.value)}
                    rows={5}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

                  <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-5">
                    <input
                      type="date"
                      value={editEventDate}
                      onChange={(e) => setEditEventDate(e.target.value)}
                      className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />

                    <input
                      type="time"
                      value={editStartTime}
                      onChange={(e) => setEditStartTime(e.target.value)}
                      className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />

                    <input
                      type="time"
                      value={editEndTime}
                      onChange={(e) => setEditEndTime(e.target.value)}
                      className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />

                    <input
                      type="number"
                      value={editPrice}
                      onChange={(e) => setEditPrice(e.target.value)}
                      className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />

                    <input
                      type="number"
                      value={editMaxParticipants}
                      onChange={(e) => setEditMaxParticipants(e.target.value)}
                      className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />
                  </div>

                  <input
                    type="text"
                    value={editLocation}
                    onChange={(e) => setEditLocation(e.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />

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

                      <div className="grid gap-3 text-sm text-zinc-400 md:grid-cols-2 lg:grid-cols-4">
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
                          <p className="mb-1 text-zinc-500">Cena / limit</p>
                          <p className="font-semibold text-green-500">
                            {Number(event.price).toFixed(0)} zł /{" "}
                            {event.max_participants} miejsc
                          </p>
                        </div>
                      </div>
                    </div>

                    <div className="flex min-w-[220px] flex-col gap-3">
                      <button
                        type="button"
                        onClick={() => startEditing(event)}
                        className="rounded-xl border border-blue-800 px-4 py-3 text-sm font-semibold text-blue-300 transition hover:bg-blue-950"
                      >
                        Edytuj szkolenie
                      </button>

                      <button
                        type="button"
                        onClick={() => loadRegistrations(event.id)}
                        className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold transition hover:bg-zinc-800"
                      >
                        Pokaż zapisanych
                      </button>

                      <button
                        type="button"
                        onClick={() => toggleEvent(event.id, event.is_active)}
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
                        <div className="overflow-x-auto">
                          <table className="min-w-full text-sm">
                            <thead>
                              <tr className="border-b border-zinc-800 text-left text-zinc-500">
                                <th className="px-4 py-3">Imię i nazwisko</th>
                                <th className="px-4 py-3">E-mail</th>
                                <th className="px-4 py-3">Telefon</th>
                                <th className="px-4 py-3">Status</th>
                                <th className="px-4 py-3">Płatność</th>
                                <th className="px-4 py-3">Akcje</th>
                              </tr>
                            </thead>

                            <tbody>
                              {registrations.map((registration) => (
                                <tr
                                  key={registration.id}
                                  className="border-b border-zinc-900"
                                >
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
                                    <span
                                      className={getStatusClass(
                                        registration.registration_status
                                      )}
                                    >
                                      {translateRegistrationStatus(
                                        registration.registration_status
                                      )}
                                    </span>
                                  </td>

                                  <td className="px-4 py-4 text-zinc-300">
                                    {registration.payment_status ===
                                    "paid_on_site"
                                      ? "Opłacone"
                                      : "Płatność na miejscu"}
                                  </td>

                                  <td className="px-4 py-4">
                                    <div className="flex flex-wrap gap-2">
                                      <button
                                        type="button"
                                        onClick={() =>
                                          updateRegistrationStatus(
                                            registration.id,
                                            "approved"
                                          )
                                        }
                                        className="rounded-lg border border-green-800 px-3 py-2 text-xs text-green-300 hover:bg-green-950"
                                      >
                                        Zatwierdź
                                      </button>

                                      <button
                                        type="button"
                                        onClick={() =>
                                          updateRegistrationStatus(
                                            registration.id,
                                            "reserve"
                                          )
                                        }
                                        className="rounded-lg border border-yellow-800 px-3 py-2 text-xs text-yellow-300 hover:bg-yellow-950"
                                      >
                                        Rezerwowy
                                      </button>

                                      <button
                                        type="button"
                                        onClick={() =>
                                          markRegistrationPaid(registration.id)
                                        }
                                        className="rounded-lg border border-blue-800 px-3 py-2 text-xs text-blue-300 hover:bg-blue-950"
                                      >
                                        Opłacone
                                      </button>

                                      <button
                                        type="button"
                                        onClick={() =>
                                          updateRegistrationStatus(
                                            registration.id,
                                            "cancelled"
                                          )
                                        }
                                        className="rounded-lg border border-red-800 px-3 py-2 text-xs text-red-300 hover:bg-red-950"
                                      >
                                        Anuluj
                                      </button>
                                    </div>
                                  </td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                      )}
                    </div>
                  )}
                </>
              )}
            </div>
          ))}
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