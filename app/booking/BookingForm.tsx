"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { PAYMENT_STATUS } from "../../lib/payment-status";
import {
  RESERVATION_STATUS,
  isCancelledReservationStatus,
} from "../../lib/reservation-status";

type Lane = {
  id: string;
  name: string;
  price_per_hour: number;
};

type BookingFormProps = {
  lanes: Lane[];
};

type BookedReservation = {
  id?: string;
  lane_id?: string;
  reservation_date?: string;
  start_time: string;
  end_time: string;
  reservation_status?: string | null;
};

type LaneBlock = {
  id?: string;
  start_time: string;
  end_time: string;
};

type Profile = {
  user_id: string;
  email: string | null;
  full_name: string | null;
  phone: string | null;
  role: string | null;
  verification_status: string | null;
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
function getTodayDateString() {
  const today = new Date();
  const year = today.getFullYear();
  const month = String(today.getMonth() + 1).padStart(2, "0");
  const day = String(today.getDate()).padStart(2, "0");

  return `${year}-${month}-${day}`;
}

function getCurrentTimeInMinutes() {
  const now = new Date();
  return now.getHours() * 60 + now.getMinutes();
}

function isPastReservationDate(date: string) {
  if (!date) return false;

  return date < getTodayDateString();
}

function isTodayReservationDate(date: string) {
  return date === getTodayDateString();
}

function isPastStartHour(date: string, hour: string) {
  if (!date || !hour) return false;

  if (!isTodayReservationDate(date)) {
    return false;
  }

  return timeToMinutes(hour) <= getCurrentTimeInMinutes();
}

function normalizeTime(time: string) {
  return time.slice(0, 5);
}

function isActiveReservation(status?: string | null) {
  const normalizedStatus = (status ?? RESERVATION_STATUS.CONFIRMED).toLowerCase();

  return (
    !isCancelledReservationStatus(normalizedStatus) &&
    normalizedStatus !== RESERVATION_STATUS.COMPLETED &&
    normalizedStatus !== RESERVATION_STATUS.NO_SHOW
  );
}

function addMinutesToTime(time: string, minutes: number) {
  const [hour, mins] = normalizeTime(time).split(":").map(Number);

  const date = new Date();
  date.setHours(hour);
  date.setMinutes(mins + minutes);
  date.setSeconds(0);

  return date.toTimeString().slice(0, 5);
}

function timeToMinutes(time: string) {
  const [hour, minutes] = normalizeTime(time).split(":").map(Number);
  return hour * 60 + minutes;
}

function rangesOverlap(
  startA: string,
  endA: string,
  startB: string,
  endB: string
) {
  return (
    timeToMinutes(startA) < timeToMinutes(endB) &&
    timeToMinutes(endA) > timeToMinutes(startB)
  );
}

function getBlockedHoursFromRanges(blocks: LaneBlock[]) {
  const blockedHours: string[] = [];

  for (const block of blocks) {
    for (const hour of hours) {
      const hourEnd = addMinutesToTime(hour, 60);

      if (
        rangesOverlap(
          hour,
          hourEnd,
          normalizeTime(block.start_time),
          normalizeTime(block.end_time)
        )
      ) {
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

function getVerificationBox(status: string) {
  if (status === "verified") {
    return null;
  }

  if (status === "rejected") {
    return {
      title: "Konto nie zostało zatwierdzone",
      text: "Twoje konto zostało odrzucone lub wymaga dodatkowego kontaktu z obsługą CSK. Rezerwacja osi jest obecnie zablokowana.",
      className:
        "rounded-xl border border-red-800 bg-red-950 p-4 text-sm text-red-100",
      titleClassName: "font-semibold text-red-300",
    };
  }

  return {
    title: "Konto oczekuje na weryfikację",
    text: "Możesz wykonać jedną rezerwację na pierwszą wizytę. Podczas wizyty pracownik recepcji sprawdzi Twoje dane i zweryfikuje konto. Do czasu weryfikacji nie możesz mieć więcej niż jednej aktywnej rezerwacji.",
    className:
      "rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-sm text-yellow-100",
    titleClassName: "font-semibold text-yellow-300",
  };
}

export default function BookingForm({ lanes }: BookingFormProps) {
  const [checkingUser, setCheckingUser] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);

  const [userId, setUserId] = useState("");
  const [verificationStatus, setVerificationStatus] = useState("pending");

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
      setCheckingUser(true);
      setMessage("");

      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();

      if (userError || !user) {
        setIsLoggedIn(false);
        setCheckingUser(false);
        return;
      }

      setIsLoggedIn(true);
      setUserId(user.id);
      setCustomerEmail(user.email ?? "");

      const { data: profile, error: profileError } = await supabase
        .from("profiles")
        .select("user_id,email,full_name,phone,role,verification_status")
        .eq("user_id", user.id)
        .single();

      if (profileError || !profile) {
        setVerificationStatus("pending");
        setCustomerName(
          String(user.user_metadata?.full_name ?? user.email ?? "")
        );
        setCustomerPhone(String(user.user_metadata?.phone ?? ""));
        setMessage(
          "Nie udało się pobrać profilu użytkownika. Skontaktuj się z obsługą CSK."
        );
        setCheckingUser(false);
        return;
      }

      const typedProfile = profile as Profile;

      setVerificationStatus(typedProfile.verification_status ?? "pending");
      setCustomerName(
        typedProfile.full_name ||
          String(user.user_metadata?.full_name ?? user.email ?? "")
      );
      setCustomerEmail(typedProfile.email || user.email || "");
      setCustomerPhone(
        typedProfile.phone || String(user.user_metadata?.phone ?? "")
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
        .select(
          "id, lane_id, reservation_date, start_time, end_time, reservation_status"
        )
        .eq("lane_id", laneId)
        .eq("reservation_date", reservationDate);

      const { data: blockedData, error: blockedError } = await supabase
        .from("lane_blocks")
        .select("id, start_time, end_time")
        .eq("lane_id", laneId)
        .eq("block_date", reservationDate)
        .eq("is_active", true);

      setCheckingAvailability(false);

      if (error || blockedError) {
        setMessage("Błąd pobierania dostępnych godzin.");
        return;
      }

      const activeReservations = ((data ?? []) as BookedReservation[]).filter(
        (reservation) => isActiveReservation(reservation.reservation_status)
      );

      const reservedHours = getBlockedHoursFromRanges(activeReservations);

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

  function getUnavailableHoursInRange(hour: string) {
    const range = getSelectedRange(hour, durationMinutes);
    return range.filter((rangeHour) => bookedHours.includes(rangeHour));
  }

  function isRangeInsideOpeningHours(hour: string) {
    if (!hour) return false;

    const endTime = addMinutesToTime(hour, durationMinutes);
    const lastPossibleEnd = addMinutesToTime(hours[hours.length - 1], 60);

    return timeToMinutes(endTime) <= timeToMinutes(lastPossibleEnd);
  }

 function canSelectStartHour(hour: string) {
  if (!hour) return false;

  if (isPastReservationDate(reservationDate)) {
    return false;
  }

  if (isPastStartHour(reservationDate, hour)) {
    return false;
  }

  if (!isRangeInsideOpeningHours(hour)) {
    return false;
  }

  const unavailableHours = getUnavailableHoursInRange(hour);

  return unavailableHours.length === 0;
}

  const hasSelectedRangeConflict =
    selectedHour !== "" && !canSelectStartHour(selectedHour);

  const hasAvailableStartHour = hours.some(canSelectStartHour);

  const isVerified = verificationStatus === "verified";
  const isRejected = verificationStatus === "rejected";
  const canUseBookingForm = !isRejected;

  const canSubmit =
  !loading &&
  canUseBookingForm &&
  userId !== "" &&
  customerName !== "" &&
  customerEmail !== "" &&
  customerPhone !== "" &&
  reservationDate !== "" &&
  !isPastReservationDate(reservationDate) &&
  laneId !== "" &&
  selectedHour !== "" &&
  !isPastStartHour(reservationDate, selectedHour) &&
  acceptedRules &&
  !hasSelectedRangeConflict;

  const verificationBox = getVerificationBox(verificationStatus);

  function handleHourClick(hour: string) {
    setMessage("");
      if (isPastReservationDate(reservationDate)) {
    setSelectedHour("");
    setMessage("Nie można dokonać rezerwacji z datą wsteczną.");
    return;
  }

  if (isPastStartHour(reservationDate, hour)) {
    setSelectedHour("");
    setMessage("Nie można wybrać godziny, która już minęła.");
    return;
  }

    if (!isRangeInsideOpeningHours(hour)) {
      setSelectedHour("");
      setMessage(
        "Wybrany czas rezerwacji wychodzi poza dostępne godziny pracy. Wybierz wcześniejszą godzinę startu albo krótszy czas rezerwacji."
      );
      return;
    }

    const unavailableHours = getUnavailableHoursInRange(hour);

    if (unavailableHours.length > 0) {
      setSelectedHour("");
      setMessage(
        `Nie można rozpocząć rezerwacji o tej godzinie. Wybrany czas rezerwacji zachodziłby na zajęte godziny: ${unavailableHours.join(
          ", "
        )}.`
      );
      return;
    }

    setSelectedHour(hour);
  }

  async function handleSubmit() {
    setMessage("");
      if (isPastReservationDate(reservationDate)) {
    setMessage("Nie można dokonać rezerwacji z datą wsteczną.");
    setSelectedHour("");
    return;
  }

  if (isPastStartHour(reservationDate, selectedHour)) {
    setMessage("Nie można dokonać rezerwacji na godzinę, która już minęła.");
    setSelectedHour("");
    return;
  }

    if (isRejected) {
      setMessage(
        "Twoje konto nie jest zatwierdzone. Skontaktuj się z obsługą CSK."
      );
      return;
    }

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

    if (!acceptedRules) {
      setMessage("Musisz zaakceptować regulamin i zasady bezpieczeństwa.");
      return;
    }

    if (!isRangeInsideOpeningHours(selectedHour)) {
      setMessage(
        "Wybrany czas rezerwacji wychodzi poza dostępne godziny pracy."
      );
      setSelectedHour("");
      return;
    }

    const selectedRangeHours = getSelectedRange(selectedHour, durationMinutes);

    const collisionHours = selectedRangeHours.filter((hour) =>
      bookedHours.includes(hour)
    );

    if (collisionHours.length > 0) {
      setMessage(
        `Nie można utworzyć rezerwacji. Wybrany zakres zachodzi na zajęte godziny: ${collisionHours.join(
          ", "
        )}.`
      );
      setSelectedHour("");
      return;
    }

    const endTime = addMinutesToTime(selectedHour, durationMinutes);
    const laneName = selectedLane?.name ?? "Wybrana oś";

    setLoading(true);

    if (!isVerified) {
      const { data: activeReservations, error: activeReservationsError } =
        await supabase
          .from("reservations")
          .select("id")
          .eq("user_id", userId)
          .in("reservation_status", [RESERVATION_STATUS.CONFIRMED]);

      if (activeReservationsError) {
        setLoading(false);
        setMessage(
          `Błąd sprawdzania aktywnych rezerwacji: ${activeReservationsError.message}`
        );
        return;
      }

      if ((activeReservations ?? []).length >= 1) {
        setLoading(false);
        setMessage(
          "Twoje konto oczekuje na weryfikację. Do czasu pierwszej wizyty i potwierdzenia danych przez pracownika możesz mieć tylko jedną aktywną rezerwację."
        );
        return;
      }
    }

    const { data: allReservationsForLane, error: reservationsError } =
      await supabase
        .from("reservations")
        .select(
          "id, lane_id, reservation_date, start_time, end_time, reservation_status"
        )
        .eq("lane_id", laneId)
        .eq("reservation_date", reservationDate);

    if (reservationsError) {
      setLoading(false);
      setMessage("Błąd sprawdzania rezerwacji.");
      return;
    }

    const reservationConflict = (
      (allReservationsForLane ?? []) as BookedReservation[]
    ).filter((reservation) => {
      return (
        isActiveReservation(reservation.reservation_status) &&
        rangesOverlap(
          selectedHour,
          endTime,
          reservation.start_time,
          reservation.end_time
        )
      );
    });

    if (reservationConflict.length > 0) {
      setLoading(false);
      setMessage(
        `Nie można zarezerwować tego zakresu. Kolizja z istniejącą rezerwacją: ${normalizeTime(
          reservationConflict[0].start_time
        )} - ${normalizeTime(reservationConflict[0].end_time)}.`
      );
      setSelectedHour("");
      return;
    }

    const { data: allBlocksForLane, error: blocksError } = await supabase
      .from("lane_blocks")
      .select("id, start_time, end_time")
      .eq("lane_id", laneId)
      .eq("block_date", reservationDate)
      .eq("is_active", true);

    if (blocksError) {
      setLoading(false);
      setMessage("Błąd sprawdzania blokad osi.");
      return;
    }

    const blockConflict = ((allBlocksForLane ?? []) as LaneBlock[]).filter(
      (block) =>
        rangesOverlap(selectedHour, endTime, block.start_time, block.end_time)
    );

    if (blockConflict.length > 0) {
      setLoading(false);
      setMessage(
        `Nie można zarezerwować tego zakresu. Kolizja z blokadą osi: ${normalizeTime(
          blockConflict[0].start_time
        )} - ${normalizeTime(blockConflict[0].end_time)}.`
      );
      setSelectedHour("");
      return;
    }

    const checkInToken = crypto.randomUUID();

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
      reservation_status: RESERVATION_STATUS.CONFIRMED,
      payment_status: PAYMENT_STATUS.PAY_ON_SITE,
      check_in_token: checkInToken,
    });

    setLoading(false);

    if (error) {
      setMessage(`Błąd zapisu rezerwacji: ${error.message}`);
      return;
    }

    const emailResponse = await fetch("/api/send-reservation-confirmation", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        customerEmail,
        customerName,
        reservationDate,
        startTime: selectedHour,
        endTime,
        laneName,
        price,
        checkInToken,
      }),
    });

    setConfirmationData({
      date: reservationDate,
      startTime: selectedHour,
      endTime,
      laneName,
      price,
    });

    if (!emailResponse.ok) {
      setMessage(
        "Rezerwacja zosta\u0142a zapisana. Nie uda\u0142o si\u0119 wys\u0142a\u0107 emaila potwierdzaj\u0105cego."
      );
    } else {
      setMessage(
        "Rezerwacja zosta\u0142a zapisana. Email potwierdzaj\u0105cy zosta\u0142 wys\u0142any. P\u0142atno\u015b\u0107 na miejscu."
      );
    }

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
            href="/login?redirectTo=%2Fbooking"
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
        {verificationBox && (
          <div className={verificationBox.className}>
            <p className={verificationBox.titleClassName}>
              {verificationBox.title}
            </p>

            <p className="mt-2 opacity-80">{verificationBox.text}</p>
          </div>
        )}

        <div className="grid gap-4 md:grid-cols-3">
          <div>
            <label
              htmlFor="booking-full-name"
              className="mb-2 block text-sm text-zinc-300"
            >
              Imię i nazwisko
            </label>

            <input
              id="booking-full-name"
              type="text"
              value={customerName}
              disabled
              className="w-full rounded-xl border border-zinc-700 bg-zinc-800 px-4 py-3 text-zinc-300"
            />
          </div>

          <div>
            <label
              htmlFor="booking-email"
              className="mb-2 block text-sm text-zinc-300"
            >
              E-mail
            </label>

            <input
              id="booking-email"
              type="email"
              value={customerEmail}
              disabled
              className="w-full rounded-xl border border-zinc-700 bg-zinc-800 px-4 py-3 text-zinc-300"
            />
          </div>

          <div>
            <label
              htmlFor="booking-phone"
              className="mb-2 block text-sm text-zinc-300"
            >
              Telefon
            </label>

            <input
              id="booking-phone"
              type="tel"
              value={customerPhone}
              onChange={(event) => setCustomerPhone(event.target.value)}
              placeholder="Wpisz numer telefonu"
              disabled={!canUseBookingForm}
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-900 disabled:cursor-not-allowed disabled:bg-zinc-800 disabled:text-zinc-500"
            />
          </div>
        </div>

        <div>
          <label
            htmlFor="booking-date"
            className="mb-2 block text-sm text-zinc-300"
          >
            Data rezerwacji
          </label>

          <input
            id="booking-date"
            type="date"
            value={reservationDate}
            min={getTodayDateString()}
            disabled={!canUseBookingForm}
            onChange={(event) => {
              const newDate = event.target.value;

              setReservationDate(newDate);
              setSelectedHour("");

              if (isPastReservationDate(newDate)) {
                setMessage("Nie można wybrać daty wstecznej.");
                return;
              }

              setMessage("");
            }}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-900 disabled:cursor-not-allowed disabled:bg-zinc-800 disabled:text-zinc-500"
          />
        </div>

        <div>
          <label
            htmlFor="booking-lane"
            className="mb-2 block text-sm text-zinc-300"
          >
            Oś / stanowisko
          </label>

          <select
            id="booking-lane"
            value={laneId}
            disabled={!canUseBookingForm}
            onChange={(event) => {
              setLaneId(event.target.value);
              setSelectedHour("");
              setMessage("");
            }}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-900 disabled:cursor-not-allowed disabled:bg-zinc-800 disabled:text-zinc-500"
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
          <label
            htmlFor="booking-duration"
            className="mb-2 block text-sm text-zinc-300"
          >
            Czas rezerwacji
          </label>

          <select
            id="booking-duration"
            value={durationMinutes}
            disabled={!canUseBookingForm}
            onChange={(event) => {
              setDurationMinutes(Number(event.target.value));
              setSelectedHour("");
              setMessage("");
            }}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600 focus-visible:ring-2 focus-visible:ring-green-600 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-900 disabled:cursor-not-allowed disabled:bg-zinc-800 disabled:text-zinc-500"
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
                Każdy kafelek oznacza pełny przedział jednej godziny, np.
                12:00–13:00.
              </span>
            )}
          </div>

          {!canUseBookingForm ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-400">
              Godziny rezerwacji są niedostępne dla kont odrzuconych.
            </div>
          ) : !reservationDate || !laneId ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-400">
              Najpierw wybierz datę oraz oś, aby zobaczyć dostępne godziny.
            </div>
          ) : checkingAvailability ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-400">
              Sprawdzanie dostępnych godzin...
            </div>
          ) : (
            <>
              <div className="mb-3 rounded-xl border border-zinc-800 bg-zinc-950 p-3 text-xs text-zinc-400">
                <p>
                  <span className="font-semibold text-red-300">Zajęte</span> —
                  ta godzina jest już zarezerwowana.
                </p>
                <p>
                  <span className="font-semibold text-zinc-300">
                    Start niedostępny
                  </span>{" "}
                  — wybrany czas rezerwacji zachodziłby na zajęty termin.
                </p>
                <p>
                  <span className="font-semibold text-yellow-300">
                    Wybrany zakres
                  </span>{" "}
                  — godziny objęte Twoją aktualną rezerwacją.
                </p>
              </div>

              {reservationDate &&
                laneId &&
                durationMinutes > 0 &&
                !checkingAvailability &&
                !hasAvailableStartHour && (
                  <div
                    role="status"
                    className="mb-3 rounded-xl border border-zinc-700 bg-zinc-950 p-4 text-sm text-zinc-300"
                  >
                    <p className="font-semibold text-zinc-100">
                      Brak wolnych godzin dla wybranej daty, osi i czasu
                      rezerwacji.
                    </p>
                    <p className="mt-1 text-zinc-400">
                      Wybierz inną datę, oś lub czas rezerwacji.
                    </p>
                  </div>
                )}

              <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
                {hours.map((hour) => {
                  const hourEnd = addMinutesToTime(hour, 60);
                  const isBooked = bookedHours.includes(hour);
                  const isSelected = selectedHour === hour;
                  const isInSelectedRange = selectedRange.includes(hour);
                  const isInsideOpeningHours = isRangeInsideOpeningHours(hour);
                  const unavailableHours = getUnavailableHoursInRange(hour);
                  const hasRangeConflict = unavailableHours.length > 0;
                  const isPastHour = isPastStartHour(reservationDate, hour);
const isStartAvailable =
  isInsideOpeningHours && !hasRangeConflict && !isPastHour;

                  return (
                    <button
                      key={hour}
                      type="button"
                      onClick={() => handleHourClick(hour)}
                      disabled={!isStartAvailable}
                      className={
                        isInSelectedRange
                          ? isSelected
                            ? "cursor-pointer rounded-xl border border-yellow-400 bg-yellow-600 px-4 py-3 font-semibold text-black"
                            : "cursor-default rounded-xl border border-yellow-500 bg-yellow-950 px-4 py-3 font-semibold text-yellow-300"
                          : !isStartAvailable
                            ? isBooked
                              ? "cursor-not-allowed rounded-xl border border-red-900 bg-red-950 px-4 py-3 font-semibold text-red-300 opacity-80"
                              : "cursor-not-allowed rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 font-semibold text-zinc-500 opacity-80"
                            : "rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 font-semibold transition hover:border-green-600 hover:bg-green-700"
                      }
                    >
                      <span className="block text-sm">
                        {hour}–{hourEnd}
                      </span>

                      <span className="mt-1 block text-xs">
                        {isInSelectedRange
  ? "Wybrany zakres"
  : !isStartAvailable
    ? isBooked
      ? "Zajęte"
      : isPastHour
        ? "Godzina minęła"
        : "Start niedostępny"
    : "Wolne"}
                      </span>
                    </button>
                  );
                })}
              </div>
            </>
          )}
        </div>

        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-300">
          <p>
            Status konta:{" "}
            <span
              className={
                isVerified
                  ? "font-semibold text-green-500"
                  : verificationStatus === "rejected"
                    ? "font-semibold text-red-400"
                    : "font-semibold text-yellow-400"
              }
            >
              {isVerified
                ? "zweryfikowane"
                : verificationStatus === "rejected"
                  ? "odrzucone"
                  : "oczekuje na weryfikację"}
            </span>
          </p>

          {!isVerified && verificationStatus !== "rejected" && (
            <p className="mt-2 text-yellow-200">
              Możesz wykonać jedną rezerwację na pierwszą wizytę. Kolejne
              rezerwacje będą dostępne po weryfikacji konta przez pracownika.
            </p>
          )}

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
            disabled={!canUseBookingForm}
            onChange={(event) => setAcceptedRules(event.target.checked)}
            className="mt-1 disabled:cursor-not-allowed"
          />

          <span>
            Potwierdzam zapoznanie się z regulaminem i zasadami bezpieczeństwa.
          </span>
        </label>

        {message && <div className={getMessageClass(message)}>{message}</div>}

        <button
          type="button"
          onClick={handleSubmit}
          disabled={!canSubmit}
          className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
        >
          {loading
            ? "Zapisywanie..."
            : isRejected
              ? "Konto odrzucone"
              : "Potwierdź rezerwację"}
        </button>
      </form>
    </>
  );
}

