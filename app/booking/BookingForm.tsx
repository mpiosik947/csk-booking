"use client";

import { useEffect, useRef, useState } from "react";
import { supabase } from "../../lib/supabase";
import { PAYMENT_STATUS } from "../../lib/payment-status";
import { getProfileDisplayName } from "../../lib/profile-display-name";
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
  first_name: string | null;
  last_name: string | null;
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

type ReservationConfirmationResponse = {
  ok: boolean;
  code: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isReservationConfirmationResponse(
  value: unknown
): value is ReservationConfirmationResponse {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Partial<ReservationConfirmationResponse>;

  return typeof result.ok === "boolean" && typeof result.code === "string";
}

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

const reservationDateFormatter = new Intl.DateTimeFormat("pl-PL", {
  day: "numeric",
  month: "long",
  year: "numeric",
  timeZone: "UTC",
});

function formatReservationDate(date: string) {
  const [year, month, day] = date.split("-").map(Number);

  return reservationDateFormatter.format(
    new Date(Date.UTC(year, month - 1, day))
  );
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
    return "rounded-xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm font-semibold text-[#a9d4ad]";
  }

  return "rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]";
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
        "rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm text-[#e0a0a0]",
      titleClassName: "font-semibold text-[#e0a0a0]",
    };
  }

  return {
    title: "Konto oczekuje na weryfikację",
    text: "Możesz wykonać jedną rezerwację na pierwszą wizytę. Podczas wizyty pracownik recepcji sprawdzi Twoje dane i zweryfikuje konto. Do czasu weryfikacji nie możesz mieć więcej niż jednej aktywnej rezerwacji.",
    className:
      "rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]",
    titleClassName: "font-semibold text-[#e1c477]",
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
  const confirmationButtonRef = useRef<HTMLButtonElement>(null);
  const confirmationTriggerRef = useRef<HTMLElement | null>(null);
  const submissionInProgressRef = useRef(false);

  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    if (!confirmationData) return;

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        setConfirmationData(null);
      }
    }

    confirmationButtonRef.current?.focus();
    document.addEventListener("keydown", handleKeyDown);

    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      confirmationTriggerRef.current?.focus();
    };
  }, [confirmationData]);

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
        .select(
          "user_id,email,first_name,last_name,full_name,phone,role,verification_status"
        )
        .eq("user_id", user.id)
        .single();

      if (profileError || !profile) {
        setVerificationStatus("pending");
        setCustomerName(getProfileDisplayName({ email: user.email }, ""));
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
        getProfileDisplayName(
          {
            first_name: typedProfile.first_name,
            last_name: typedProfile.last_name,
            full_name: typedProfile.full_name,
            email: typedProfile.email || user.email,
          },
          ""
        )
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
    if (submissionInProgressRef.current) {
      return;
    }

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

    confirmationTriggerRef.current =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;

    submissionInProgressRef.current = true;
    setLoading(true);
    let reservationCreated = false;

    try {
      if (!isVerified) {
        const { data: activeReservations, error: activeReservationsError } =
          await supabase
            .from("reservations")
            .select("id")
            .eq("user_id", userId)
            .in("reservation_status", [RESERVATION_STATUS.CONFIRMED]);

        if (activeReservationsError) {
          setMessage(
            "Nie udało się sprawdzić możliwości utworzenia rezerwacji. Spróbuj ponownie."
          );
          return;
        }

        if ((activeReservations ?? []).length >= 1) {
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
        setMessage("Błąd sprawdzania blokad osi.");
        return;
      }

      const blockConflict = ((allBlocksForLane ?? []) as LaneBlock[]).filter(
        (block) =>
          rangesOverlap(selectedHour, endTime, block.start_time, block.end_time)
      );

      if (blockConflict.length > 0) {
        setMessage(
          `Nie można zarezerwować tego zakresu. Kolizja z blokadą osi: ${normalizeTime(
            blockConflict[0].start_time
          )} - ${normalizeTime(blockConflict[0].end_time)}.`
        );
        setSelectedHour("");
        return;
      }

      const checkInToken = crypto.randomUUID();
      const { data: insertedReservation, error } = await supabase
        .from("reservations")
        .insert({
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
        })
        .select("id")
        .single();

      if (error) {
        setMessage("Nie udało się utworzyć rezerwacji. Spróbuj ponownie.");
        return;
      }

      reservationCreated = true;
      const reservationId =
        typeof insertedReservation?.id === "string"
          ? insertedReservation.id.trim()
          : "";

      if (!reservationId || !UUID_PATTERN.test(reservationId)) {
        setMessage(
          "Nie udało się potwierdzić utworzenia rezerwacji. Odśwież stronę przed ponowną próbą."
        );
        return;
      }

      const {
        data: { session },
      } = await supabase.auth.getSession();
      let confirmationEmailSent = false;

      if (session?.access_token) {
        try {
          const emailResponse = await fetch(
            "/api/send-reservation-confirmation",
            {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                Authorization: `Bearer ${session.access_token}`,
              },
              body: JSON.stringify({ reservationId }),
            }
          );
          const emailResult: unknown = await emailResponse
            .json()
            .catch(() => null);

          confirmationEmailSent =
            emailResponse.ok &&
            isReservationConfirmationResponse(emailResult) &&
            emailResult.ok === true &&
            emailResult.code === "sent";
        } catch {
          console.error("Reservation confirmation request failed");
        }
      }

      setConfirmationData({
        date: reservationDate,
        startTime: selectedHour,
        endTime,
        laneName,
        price,
      });

      if (confirmationEmailSent) {
        setMessage(
          "Rezerwacja została zapisana. Email potwierdzający został wysłany. Płatność na miejscu."
        );
      } else {
        setMessage(
          "Rezerwacja została utworzona, ale wiadomość e-mail nie została wysłana."
        );
      }

      setReservationDate("");
      setLaneId("");
      setDurationMinutes(60);
      setSelectedHour("");
      setAcceptedRules(false);
      setBookedHours([]);
    } catch {
      setMessage(
        reservationCreated
          ? "Rezerwacja została utworzona, ale wiadomość e-mail nie została wysłana."
          : "Nie udało się utworzyć rezerwacji. Spróbuj ponownie."
      );
    } finally {
      submissionInProgressRef.current = false;
      setLoading(false);
    }
  }

  if (checkingUser) {
    return (
      <div
        role="status"
        aria-live="polite"
        className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]"
      >
        Sprawdzanie użytkownika...
      </div>
    );
  }

  if (!isLoggedIn) {
    return (
      <div
        role="alert"
        className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-6 text-center sm:p-8"
      >
        <h2 className="mb-3 text-2xl font-bold text-[#f2efe4]">
          Logowanie wymagane
        </h2>

        <p className="mx-auto mb-6 max-w-xl text-[#e0a0a0]">
          Aby zarezerwować oś strzelecką, musisz najpierw zalogować się na
          swoje konto albo utworzyć nowe konto użytkownika.
        </p>

        <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
          <a
            href="/login?redirectTo=%2Fbooking"
            className="min-h-12 rounded-xl bg-[#536143] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
          >
            Zaloguj się
          </a>

          <a
            href="/register"
            className="min-h-12 rounded-xl border border-[#744545] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#3a2424] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
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
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 px-4 py-6">
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="booking-confirmation-title"
            aria-describedby="booking-confirmation-description"
            className="w-full max-w-lg rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 text-[#f2efe4] shadow-2xl sm:p-8"
          >
            <div className="mb-4 rounded-full border border-[#3f6848] bg-[#1b2a1d] px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.2em] text-[#a9d4ad]">
              Rezerwacja przyjęta
            </div>

            <h2
              id="booking-confirmation-title"
              className="mb-3 text-3xl font-bold"
            >
              Udało się dokonać rezerwacji
            </h2>

            <p
              id="booking-confirmation-description"
              className="mb-6 text-[#a9ada4]"
            >
              Poniżej znajduje się podsumowanie Twojej rezerwacji.
            </p>

            <div className="grid gap-3 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 text-sm">
              <div>
                <p className="text-[#858c7f]">Data</p>
                <p className="text-lg font-semibold text-[#f2efe4]">
                  {formatReservationDate(confirmationData.date)}
                </p>
              </div>

              <div>
                <p className="text-[#858c7f]">Godzina</p>
                <p className="text-lg font-semibold text-[#f2efe4]">
                  {confirmationData.startTime} - {confirmationData.endTime}
                </p>
              </div>

              <div>
                <p className="text-[#858c7f]">Oś</p>
                <p className="text-lg font-semibold text-[#f2efe4]">
                  {confirmationData.laneName}
                </p>
              </div>

              <div>
                <p className="text-[#858c7f]">Cena</p>
                <p className="text-lg font-semibold text-[#d7c895]">
                  {confirmationData.price.toFixed(0)} zł
                </p>
              </div>

              <div>
                <p className="text-[#858c7f]">Płatność</p>
                <p className="text-lg font-semibold text-[#d7c895]">
                  Na miejscu
                </p>
              </div>
            </div>

            <div className="mt-6 grid gap-3">
              <button
                ref={confirmationButtonRef}
                type="button"
                onClick={() => {
                  window.location.href = "/my-reservations";
                }}
                className="min-h-12 rounded-xl bg-[#536143] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              >
                Gotowe
              </button>

            </div>
          </div>
        </div>
      )}

      <form className="grid gap-5 rounded-2xl border border-[#30372c] bg-[#191e19] p-4 text-[#f2efe4] sm:gap-6 sm:p-6">
        {verificationBox && (
          <div
            role={isRejected ? "alert" : "status"}
            aria-live={isRejected ? undefined : "polite"}
            className={verificationBox.className}
          >
            <p className={verificationBox.titleClassName}>
              {verificationBox.title}
            </p>

            <p className="mt-2 opacity-80">{verificationBox.text}</p>
          </div>
        )}

        <div className="grid gap-4 rounded-2xl border border-[#30372c] bg-[#141814] p-4 md:grid-cols-3 sm:p-5">
          <div>
            <label
              htmlFor="booking-full-name"
              className="mb-2 block text-sm font-medium text-[#a9ada4]"
            >
              Imię i nazwisko
            </label>

            <input
              id="booking-full-name"
              type="text"
              value={customerName}
              disabled
              className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-[#858c7f] disabled:cursor-not-allowed"
            />
          </div>

          <div>
            <label
              htmlFor="booking-email"
              className="mb-2 block text-sm font-medium text-[#a9ada4]"
            >
              E-mail
            </label>

            <input
              id="booking-email"
              type="email"
              value={customerEmail}
              disabled
              className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-[#858c7f] disabled:cursor-not-allowed"
            />
          </div>

          <div>
            <label
              htmlFor="booking-phone"
              className="mb-2 block text-sm font-medium text-[#a9ada4]"
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
              className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:text-[#858c7f]"
            />
          </div>
        </div>

        <div className="grid gap-5 rounded-2xl border border-[#30372c] bg-[#141814] p-4 sm:p-5 md:grid-cols-3">
          <div>
            <label
              htmlFor="booking-date"
              className="mb-2 block text-sm font-medium text-[#a9ada4]"
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
              className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-[#f2efe4] outline-none focus:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:text-[#858c7f]"
            />
          </div>

          <div>
            <label
              htmlFor="booking-lane"
              className="mb-2 block text-sm font-medium text-[#a9ada4]"
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
              className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-[#f2efe4] outline-none focus:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:text-[#858c7f]"
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
              className="mb-2 block text-sm font-medium text-[#a9ada4]"
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
              className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-[#f2efe4] outline-none focus:border-[#78865f] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:text-[#858c7f]"
            >
              {durations.map((duration) => (
                <option key={duration.value} value={duration.value}>
                  {duration.label}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div className="rounded-2xl border border-[#30372c] bg-[#141814] p-4 sm:p-5">
          <div className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
            <label className="block text-sm font-medium text-[#a9ada4]">
              Wybierz godzinę startu
            </label>

            {reservationDate && laneId && (
              <span className="text-xs text-[#858c7f]">
                Każdy kafelek oznacza pełny przedział jednej godziny, np.
                12:00–13:00.
              </span>
            )}
          </div>

          {!canUseBookingForm ? (
            <div
              role="alert"
              className="rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm text-[#e0a0a0]"
            >
              Godziny rezerwacji są niedostępne dla kont odrzuconych.
            </div>
          ) : !reservationDate || !laneId ? (
            <div
              role="status"
              aria-live="polite"
              className="rounded-xl border border-[#30372c] bg-[#191e19] p-4 text-sm text-[#a9ada4]"
            >
              Najpierw wybierz datę oraz oś, aby zobaczyć dostępne godziny.
            </div>
          ) : checkingAvailability ? (
            <div
              role="status"
              aria-live="polite"
              className="rounded-xl border border-[#30372c] bg-[#191e19] p-4 text-sm text-[#a9ada4]"
            >
              Sprawdzanie dostępnych godzin...
            </div>
          ) : (
            <>
              <div className="mb-3 rounded-xl border border-[#30372c] bg-[#191e19] p-3 text-xs text-[#a9ada4]">
                <p>
                  <span className="font-semibold text-[#e0a0a0]">Zajęte</span> —
                  ta godzina jest już zarezerwowana.
                </p>
                <p>
                  <span className="font-semibold text-[#a9ada4]">
                    Start niedostępny
                  </span>{" "}
                  — wybrany czas rezerwacji zachodziłby na zajęty termin.
                </p>
                <p>
                  <span className="font-semibold text-[#d7c895]">
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
                    aria-live="polite"
                    className="mb-3 rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]"
                  >
                    <p className="font-semibold text-[#f2efe4]">
                      Brak wolnych godzin dla wybranej daty, osi i czasu
                      rezerwacji.
                    </p>
                    <p className="mt-1 text-[#a9ada4]">
                      Wybierz inną datę, oś lub czas rezerwacji.
                    </p>
                  </div>
                )}

              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4">
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
                            ? "min-h-14 cursor-pointer rounded-xl border border-[#9a7c3e] bg-[#536143] px-3 py-3 font-semibold text-[#f2efe4] shadow-sm"
                            : "min-h-14 cursor-default rounded-xl border border-[#6f5a2e] bg-[#2b2618] px-3 py-3 font-semibold text-[#d7c895]"
                          : !isStartAvailable
                            ? isBooked
                              ? "min-h-14 cursor-not-allowed rounded-xl border border-[#744545] bg-[#2a1b1b] px-3 py-3 font-semibold text-[#e0a0a0] opacity-80"
                              : "min-h-14 cursor-not-allowed rounded-xl border border-[#30372c] bg-[#191e19] px-3 py-3 font-semibold text-[#858c7f] opacity-70"
                            : "min-h-14 rounded-xl border border-[#30372c] bg-[#191e19] px-3 py-3 font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
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

        <div className="rounded-2xl border border-[#30372c] bg-[#141814] p-4 text-sm text-[#a9ada4] sm:p-5">
          <p>
            Status konta:{" "}
            <span
              className={
                isVerified
                  ? "font-semibold text-[#a9d4ad]"
                  : verificationStatus === "rejected"
                    ? "font-semibold text-[#e0a0a0]"
                    : "font-semibold text-[#e1c477]"
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
            <p className="mt-2 text-[#e1c477]">
              Możesz wykonać jedną rezerwację na pierwszą wizytę. Kolejne
              rezerwacje będą dostępne po weryfikacji konta przez pracownika.
            </p>
          )}

          <p>
            Status rezerwacji:{" "}
            <span className="font-semibold text-[#a9d4ad]">
              potwierdzona automatycznie
            </span>
          </p>

          <p>
            Płatność:{" "}
            <span className="font-semibold text-[#a9d4ad]">na miejscu</span>
          </p>

          <p>
            Cena orientacyjna:{" "}
            <span className="font-semibold text-[#d7c895]">
              {price.toFixed(0)} zł
            </span>
          </p>
        </div>

        <label className="flex min-h-12 items-start gap-3 rounded-xl border border-[#30372c] bg-[#141814] p-4 text-sm text-[#a9ada4]">
          <input
            type="checkbox"
            checked={acceptedRules}
            disabled={!canUseBookingForm}
            onChange={(event) => setAcceptedRules(event.target.checked)}
            className="mt-0.5 size-5 shrink-0 accent-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed"
          />

          <span>
            Potwierdzam zapoznanie się z regulaminem i zasadami bezpieczeństwa.
          </span>
        </label>

        {message && (
          <div
            role={message.includes("zapisana") ? "status" : "alert"}
            aria-live={message.includes("zapisana") ? "polite" : undefined}
            className={getMessageClass(message)}
          >
            {message}
          </div>
        )}

        <button
          type="button"
          onClick={handleSubmit}
          disabled={!canSubmit}
          className="min-h-12 w-full rounded-xl bg-[#536143] px-4 py-3.5 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:bg-[#30372c] disabled:text-[#858c7f]"
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

