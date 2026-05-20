"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type Lane = {
  id: string;
  name: string;
  price_per_hour: number;
};

type BookingFormProps = {
  lanes: Lane[];
};

type BookedReservation = {
  start_time: string;
  end_time: string;
};

type LaneBlock = {
  start_time: string;
  end_time: string;
};

type ConfirmationData = {
  date: string;
  startTime: string;
  endTime: string;
  laneName: string;
  price: number;
};

const durations = [
  { label: "1 godzina", value: 60 },
  { label: "2 godziny", value: 120 },
  { label: "3 godziny", value: 180 },
  { label: "4 godziny", value: 240 },
];

const hours = [
  "08:00",
  "09:00",
  "10:00",
  "11:00",
  "12:00",
  "13:00",
  "14:00",
  "15:00",
  "16:00",
  "17:00",
  "18:00",
  "19:00",
];

function addMinutesToTime(time: string, minutes: number) {
  const [hour, mins] = time.split(":").map(Number);

  const date = new Date();
  date.setHours(hour);
  date.setMinutes(mins + minutes);
  date.setSeconds(0);

  return date.toTimeString().slice(0, 5);
}

function timeToMinutes(time: string) {
  const [hour, minutes] = time.slice(0, 5).split(":").map(Number);
  return hour * 60 + minutes;
}

function rangesOverlap(
  startA: string,
  endA: string,
  startB: string,
  endB: string
) {
  return timeToMinutes(startA) < timeToMinutes(endB) &&
    timeToMinutes(endA) > timeToMinutes(startB);
}

function getBlockedHoursFromRanges(blocks: LaneBlock[]) {
  const blockedHours: string[] = [];

  for (const block of blocks) {
    for (const hour of hours) {
      const hourEnd = addMinutesToTime(hour, 60);

      if (rangesOverlap(hour, hourEnd, block.start_time, block.end_time)) {
        blockedHours.push(hour);
      }
    }
  }

  return blockedHours;
}

function getSelectedRange(startTime: string, durationMinutes: number) {
  if (!startTime) return [];

  const endTime = addMinutesToTime(startTime, durationMinutes);

  return hours.filter((hour) => {
    const hourEnd = addMinutesToTime(hour, 60);
    return rangesOverlap(hour, hourEnd, startTime, endTime);
  });
}

function getMessageClass(message: string) {
  if (message.includes("zapisana")) {
    return "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
  }

  return "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
}

export default function BookingForm({ lanes }: BookingFormProps) {
  const [checkingUser, setCheckingUser] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);

  const [userId, setUserId] = useState("");

  const [customerName, setCustomerName] = useState("");
  const [customerEmail, setCustomerEmail] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");

  const [reservationDate, setReservationDate] = useState("");
  const [laneId, setLaneId] = useState("");
  const [durationMinutes, setDurationMinutes] = useState(60);
  const [selectedHour, setSelectedHour] = useState("");
  const [acceptedRules, setAcceptedRules] = useState(false);

  const [bookedHours, setBookedHours] = useState<string[]>([]);
  const [checkingAvailability, setCheckingAvailability] = useState(false);

  const [confirmationData, setConfirmationData] =
    useState<ConfirmationData | null>(null);

  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    async function loadUser() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setIsLoggedIn(false);
        setCheckingUser(false);
        return;
      }

      const metadata = user.user_metadata ?? {};

      setIsLoggedIn(true);
      setUserId(user.id);
      setCustomerName(metadata.full_name ?? metadata.name ?? "");
      setCustomerEmail(user.email ?? "");
      setCustomerPhone(
        metadata.phone ??
          metadata.telefon ??
          metadata.Phone ??
          metadata.phone_number ??
          metadata.phoneNumber ??
          user.phone ??
          ""
      );

      setCheckingUser(false);
    }

    loadUser();
  }, []);

  useEffect(() => {
    async function loadBookedHours() {
      setMessage("");
      setBookedHours([]);
      setSelectedHour("");

      if (!reservationDate || !laneId) {
        return;
      }

      setCheckingAvailability(true);

      const { data, error } = await supabase
        .from("reservations")
        .select("start_time, end_time")
        .eq("lane_id", laneId)
        .eq("reservation_date", reservationDate)
        .eq("reservation_status", "confirmed");

      const { data: blockedData, error: blockedError } = await supabase
        .from("lane_blocks")
        .select("start_time, end_time")
        .eq("lane_id", laneId)
        .eq("block_date", reservationDate)
        .eq("is_active", true);

      setCheckingAvailability(false);

      if (error || blockedError) {
        setMessage("Błąd pobierania dostępnych godzin.");
        return;
      }

      const reservedHours = getBlockedHoursFromRanges(
        (data ?? []) as BookedReservation[]
      );

      const blockedHours = getBlockedHoursFromRanges(
        (blockedData ?? []) as LaneBlock[]
      );

      setBookedHours([...new Set([...reservedHours, ...blockedHours])]);
    }

    loadBookedHours();
  }, [reservationDate, laneId]);

  const selectedLane = lanes.find((lane) => lane.id === laneId);

  const price = selectedLane
    ? (Number(selectedLane.price_per_hour) / 60) * durationMinutes
    : 0;

  const selectedRange = getSelectedRange(selectedHour, durationMinutes);

  function canSelectStartHour(hour: string) {
    const endTime = addMinutesToTime(hour, durationMinutes);
    const lastPossibleEnd = addMinutesToTime(hours[hours.length - 1], 60);

    if (timeToMinutes(endTime) > timeToMinutes(lastPossibleEnd)) {
      return false;
    }

    const range = getSelectedRange(hour, durationMinutes);

    return !range.some((rangeHour) => bookedHours.includes(rangeHour));
  }

  async function handleSubmit() {
    setMessage("");

    if (!userId) {
      setMessage("Musisz być zalogowany, aby dokonać rezerwacji.");
      return;
    }

    if (
      !customerName ||
      !customerEmail ||
      !customerPhone ||
      !reservationDate ||
      !laneId ||
      !selectedHour
    ) {
      setMessage("Uzupełnij wszystkie wymagane pola.");
      return;
    }

    if (!canSelectStartHour(selectedHour)) {
      setMessage("Wybrany zakres rezerwacji koliduje z inną rezerwacją lub blokadą.");
      return;
    }

    if (!acceptedRules) {
      setMessage("Musisz zaakceptować regulamin i zasady bezpieczeństwa.");
      return;
    }

    const endTime = addMinutesToTime(selectedHour, durationMinutes);
    const laneName = selectedLane?.name ?? "Wybrana oś";

    setLoading(true);

    const { data: existingReservations, error: checkError } = await supabase
      .from("reservations")
      .select("id, start_time, end_time")
      .eq("lane_id", laneId)
      .eq("reservation_date", reservationDate)
      .eq("reservation_status", "confirmed");

    const { data: existingBlocks, error: blockCheckError } = await supabase
      .from("lane_blocks")
      .select("id, start_time, end_time")
      .eq("lane_id", laneId)
      .eq("block_date", reservationDate)
      .eq("is_active", true);

    if (checkError || blockCheckError) {
      setLoading(false);
      setMessage("Błąd sprawdzania dostępności.");
      return;
    }

    const hasReservationConflict = ((existingReservations ?? []) as BookedReservation[]).some(
      (reservation) =>
        rangesOverlap(
          selectedHour,
          endTime,
          reservation.start_time,
          reservation.end_time
        )
    );

    const hasBlockConflict = ((existingBlocks ?? []) as LaneBlock[]).some(
      (block) =>
        rangesOverlap(selectedHour, endTime, block.start_time, block.end_time)
    );

    if (hasReservationConflict || hasBlockConflict) {
      setLoading(false);
      setMessage("Wybrany zakres jest już zajęty lub zablokowany.");
      setSelectedHour("");
      return;
    }

    const { error } = await supabase.from("reservations").insert({
      user_id: userId,
      lane_id: laneId,
      customer_name: customerName,
      customer_email: customerEmail,
      customer_phone: customerPhone,
      reservation_date: reservationDate,
      start_time: selectedHour,
      end_time: endTime,
      duration_minutes: durationMinutes,
      price: price,
      reservation_status: "confirmed",
      payment_status: "pay_on_site",
    });

    setLoading(false);

    if (error) {
      setMessage(`Błąd zapisu rezerwacji: ${error.message}`);
      return;
    }

    setConfirmationData({
      date: reservationDate,
      startTime: selectedHour,
      endTime,
      laneName,
      price,
    });

    setMessage("Rezerwacja została zapisana. Płatność na miejscu.");

    setReservationDate("");
    setLaneId("");
    setDurationMinutes(60);
    setSelectedHour("");
    setAcceptedRules(false);
    setBookedHours([]);
  }

  if (checkingUser) {
    return (
      <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
        Sprawdzanie użytkownika...
      </div>
    );
  }

  if (!isLoggedIn) {
    return (
      <div className="rounded-2xl border border-red-800 bg-red-950 p-8 text-center">
        <h2 className="mb-3 text-2xl font-bold text-red-200">
          Logowanie wymagane
        </h2>

        <p className="mx-auto mb-6 max-w-xl text-red-100">
          Aby zarezerwować oś strzelecką, musisz najpierw zalogować się na
          swoje konto albo utworzyć nowe konto użytkownika.
        </p>

        <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
          <a
            href="/login"
            className="rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
          >
            Zaloguj się
          </a>

          <a
            href="/register"
            className="rounded-xl border border-red-300 px-5 py-3 font-semibold text-red-100 transition hover:bg-red-900"
          >
            Utwórz konto
          </a>
        </div>
      </div>
    );
  }

  return (
    <>
      {confirmationData && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 px-4">
          <div className="w-full max-w-lg rounded-2xl border border-green-800 bg-zinc-950 p-6 text-white shadow-2xl">
            <div className="mb-4 rounded-full border border-green-800 bg-green-950 px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.25em] text-green-300">
              Rezerwacja przyjęta
            </div>

            <h2 className="mb-3 text-3xl font-bold">
              Udało się dokonać rezerwacji
            </h2>

            <p className="mb-6 text-zinc-400">
              Poniżej znajduje się podsumowanie Twojej rezerwacji.
            </p>

            <div className="grid gap-3 rounded-2xl border border-zinc-800 bg-zinc-900 p-5 text-sm">
              <div>
                <p className="text-zinc-500">Data</p>
                <p className="text-lg font-semibold text-white">
                  {confirmationData.date}
                </p>
              </div>

              <div>
                <p className="text-zinc-500">Godzina</p>
                <p className="text-lg font-semibold text-white">
                  {confirmationData.startTime} - {confirmationData.endTime}
                </p>
              </div>

              <div>
                <p className="text-zinc-500">Oś</p>
                <p className="text-lg font-semibold text-white">
                  {confirmationData.laneName}
                </p>
              </div>

              <div>
                <p className="text-zinc-500">Cena</p>
                <p className="text-lg font-semibold text-green-500">
                  {confirmationData.price.toFixed(0)} zł
                </p>
              </div>

              <div>
                <p className="text-zinc-500">Płatność</p>
                <p className="text-lg font-semibold text-green-500">
                  Na miejscu
                </p>
              </div>
            </div>

            <div className="mt-6 grid gap-3 sm:grid-cols-2">
              <button
                type="button"
                onClick={() => setConfirmationData(null)}
                className="rounded-xl bg-green-700 px-5 py-3 font-semibold transition hover:bg-green-600"
              >
                OK
              </button>

              <a
                href="/my-reservations"
                className="rounded-xl border border-zinc-700 px-5 py-3 text-center font-semibold text-zinc-300 transition hover:bg-zinc-900"
              >
                Moje rezerwacje
              </a>
            </div>
          </div>
        </div>
      )}

      <form className="grid gap-6 rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
        <div className="grid gap-4 md:grid-cols-3">
          <div>
            <label className="mb-2 block text-sm text-zinc-300">
              Imię i nazwisko
            </label>

            <input
              type="text"
              value={customerName}
              disabled
              className="w-full rounded-xl border border-zinc-700 bg-zinc-800 px-4 py-3 text-zinc-300"
            />
          </div>

          <div>
            <label className="mb-2 block text-sm text-zinc-300">E-mail</label>

            <input
              type="email"
              value={customerEmail}
              disabled
              className="w-full rounded-xl border border-zinc-700 bg-zinc-800 px-4 py-3 text-zinc-300"
            />
          </div>

          <div>
            <label className="mb-2 block text-sm text-zinc-300">Telefon</label>

            <input
              type="tel"
              value={customerPhone}
              onChange={(event) => setCustomerPhone(event.target.value)}
              placeholder="Wpisz numer telefonu"
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />
          </div>
        </div>

        <div>
          <label className="mb-2 block text-sm text-zinc-300">
            Data rezerwacji
          </label>

          <input
            type="date"
            value={reservationDate}
            onChange={(event) => setReservationDate(event.target.value)}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
          />
        </div>

        <div>
          <label className="mb-2 block text-sm text-zinc-300">
            Oś / stanowisko
          </label>

          <select
            value={laneId}
            onChange={(event) => setLaneId(event.target.value)}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
          >
            <option value="">Wybierz oś</option>

            {lanes.map((lane) => (
              <option key={lane.id} value={lane.id}>
                {lane.name} — {lane.price_per_hour} zł / h
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="mb-2 block text-sm text-zinc-300">
            Czas rezerwacji
          </label>

          <select
            value={durationMinutes}
            onChange={(event) => {
              setDurationMinutes(Number(event.target.value));
              setSelectedHour("");
            }}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
          >
            {durations.map((duration) => (
              <option key={duration.value} value={duration.value}>
                {duration.label}
              </option>
            ))}
          </select>
        </div>

        <div>
          <div className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
            <label className="block text-sm text-zinc-300">
              Wybierz godzinę startu
            </label>

            {reservationDate && laneId && (
              <span className="text-xs text-zinc-500">
                Żółte kafelki pokazują cały wybrany zakres rezerwacji.
              </span>
            )}
          </div>

          {!reservationDate || !laneId ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-400">
              Najpierw wybierz datę oraz oś, aby zobaczyć dostępne godziny.
            </div>
          ) : checkingAvailability ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-400">
              Sprawdzanie dostępnych godzin...
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
              {hours.map((hour) => {
                const isBooked = bookedHours.includes(hour);
                const isSelected = selectedHour === hour;
                const isInSelectedRange = selectedRange.includes(hour);
                const isStartAvailable = canSelectStartHour(hour);

                return (
                  <button
                    key={hour}
                    type="button"
                    disabled={!isStartAvailable}
                    onClick={() => setSelectedHour(hour)}
                    className={
                      !isStartAvailable
                        ? "cursor-not-allowed rounded-xl border border-red-900 bg-zinc-900 px-4 py-3 font-semibold text-zinc-600"
                        : isSelected
                          ? "rounded-xl border border-yellow-400 bg-yellow-600 px-4 py-3 font-semibold text-black"
                          : isInSelectedRange
                            ? "rounded-xl border border-yellow-500 bg-yellow-950 px-4 py-3 font-semibold text-yellow-300"
                            : "rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 font-semibold transition hover:border-green-600 hover:bg-green-700"
                    }
                  >
                    <span>{hour}</span>
                    <span className="mt-1 block text-xs">
                      {!isStartAvailable
                        ? isBooked
                          ? "Niedostępne"
                          : "Za długi zakres"
                        : isInSelectedRange
                          ? "Wybrany zakres"
                          : "Wolne"}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
        </div>

        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-300">
          <p>
            Status rezerwacji:{" "}
            <span className="font-semibold text-green-500">
              potwierdzona automatycznie
            </span>
          </p>

          <p>
            Płatność:{" "}
            <span className="font-semibold text-green-500">na miejscu</span>
          </p>

          <p>
            Cena orientacyjna:{" "}
            <span className="font-semibold text-green-500">
              {price.toFixed(0)} zł
            </span>
          </p>
        </div>

        <label className="flex gap-3 text-sm text-zinc-300">
          <input
            type="checkbox"
            checked={acceptedRules}
            onChange={(event) => setAcceptedRules(event.target.checked)}
            className="mt-1"
          />

          <span>
            Potwierdzam zapoznanie się z regulaminem i zasadami bezpieczeństwa.
          </span>
        </label>

        {message && <div className={getMessageClass(message)}>{message}</div>}

        <button
          type="button"
          onClick={handleSubmit}
          disabled={loading}
          className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
        >
          {loading ? "Zapisywanie..." : "Potwierdź rezerwację"}
        </button>
      </form>
    </>
  );
}