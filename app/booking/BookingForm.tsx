"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "../../lib/supabase";
import { getProfileDisplayName } from "../../lib/profile-display-name";
import {
  BOOKING_DAY_GROUP_LABELS,
  getBookingDayGroup,
  type BookingDayGroup,
} from "../../lib/booking-day-group";
import {
  addMinutesToTime,
  bookingSlotIsAvailable,
  classifyBookingSlot,
  getBookingSlotVisualClass,
  getOccupiedSlotStarts,
  normalizeBookingTime,
  type BookingSlotState,
  type BookingTimeRange,
} from "../../lib/booking-time-range";

export type BookingLane = {
  id: string;
  name: string;
  max_shooters: number;
  booking_step_minutes: number;
  display_order: number;
  currency_code: string;
};

export type BookingDuration = {
  id: string;
  lane_id: string;
  duration_minutes: number;
  display_order: number;
};

export type BookingPricingRule = {
  id: string;
  lane_id: string;
  day_group: BookingDayGroup;
  min_shooters: number;
  max_shooters: number;
  label: string;
  hourly_price: number;
  display_order: number;
};

type BookingFormProps = {
  lanes: BookingLane[];
  durations: BookingDuration[];
  pricingRules: BookingPricingRule[];
};

type BusyRangeRow = {
  start_time: string;
  end_time: string;
};

type Profile = {
  email: string | null;
  first_name: string | null;
  last_name: string | null;
  full_name: string | null;
  phone: string | null;
  verification_status: string | null;
};

type CreateReservationResponse = {
  ok: boolean;
  changed: boolean;
  code: string;
  reservationId?: string;
  reservationStatus?: string;
  laneName?: string;
  shootersCount?: number;
  durationMinutes?: number;
  pricingDayGroup?: BookingDayGroup;
  pricePerHour?: number;
  totalPrice?: number;
  currencyCode?: string;
  message?: string;
  error?: string;
};

type ConfirmationData = {
  date: string;
  startTime: string;
  endTime: string;
  laneName: string;
  shootersCount: number;
  durationMinutes: number;
  pricingDayGroup: BookingDayGroup;
  totalPrice: number;
  currencyCode: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CODE_MESSAGES: Record<string, string> = {
  unauthorized: "Sesja wygasła. Zaloguj się ponownie.",
  not_allowed: "To konto nie może tworzyć rezerwacji.",
  profile_not_found: "Nie znaleziono profilu użytkownika.",
  profile_incomplete:
    "Profil wymaga uzupełnienia imienia i nazwiska, e-maila oraz telefonu.",
  profile_rejected: "Konto zostało odrzucone. Skontaktuj się z obsługą CSK.",
  verification_limit_reached:
    "Konto oczekuje na weryfikację i ma już aktywną rezerwację.",
  invalid_date: "Wybierz prawidłową datę.",
  reservation_already_started: "Wybrany termin już się rozpoczął.",
  invalid_start_time: "Wybrana godzina nie jest dostępna dla tej osi.",
  outside_booking_hours: "Rezerwacja musi zakończyć się najpóźniej o 20:00.",
  invalid_duration: "Wybrana długość nie jest już dostępna.",
  invalid_shooters_count: "Wybierz prawidłową liczbę strzelców.",
  capacity_exceeded: "Liczba strzelców przekracza pojemność osi.",
  lane_not_found: "Nie znaleziono wybranej osi.",
  lane_inactive: "Wybrana oś nie jest już aktywna.",
  pricing_not_configured: "Cennik osi nie jest skonfigurowany.",
  lane_blocked: "Oś jest zablokowana w wybranym terminie.",
  slot_unavailable: "Termin został właśnie zajęty. Wybierz inną godzinę.",
  idempotency_conflict:
    "Dane tej próby rezerwacji uległy zmianie. Spróbuj ponownie.",
  internal_error: "Nie udało się utworzyć rezerwacji. Spróbuj ponownie.",
};

function getTodayDateString() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}


function formatDuration(minutes: number) {
  if (minutes % 60 === 0) {
    const hours = minutes / 60;
    return `${hours} ${hours === 1 ? "godzina" : hours < 5 ? "godziny" : "godzin"}`;
  }
  return `${minutes} minut`;
}

function formatMoney(value: number, currency: string) {
  return new Intl.NumberFormat("pl-PL", {
    style: "currency",
    currency,
  }).format(value);
}

function formatReservationDate(date: string) {
  const [year, month, day] = date.split("-").map(Number);
  return new Intl.DateTimeFormat("pl-PL", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(year, month - 1, day)));
}

function getLanePricingNotice(laneName: string) {
  const normalizedName = laneName.trim().toLocaleLowerCase("pl-PL");

  if (normalizedName.includes("trap") || normalizedName.includes("skeet")) {
    return "Cena obejmuje wyłączną rezerwację osi. Rzutki i amunicja rozliczane są oddzielnie na miejscu.";
  }

  if (normalizedName.includes("100 m")) {
    return "Grupy powyżej 6 osób prosimy o kontakt z obsługą.";
  }

  if (normalizedName.includes("50 m")) {
    return "Grupy powyżej 5 osób prosimy o kontakt z obsługą.";
  }

  return null;
}

function isCreateReservationResponse(
  value: unknown
): value is CreateReservationResponse {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const result = value as Partial<CreateReservationResponse>;
  return (
    typeof result.ok === "boolean" &&
    typeof result.changed === "boolean" &&
    typeof result.code === "string"
  );
}

export default function BookingForm({
  lanes,
  durations,
  pricingRules,
}: BookingFormProps) {
  const [checkingUser, setCheckingUser] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [reservationDate, setReservationDate] = useState("");
  const [laneId, setLaneId] = useState("");
  const [durationMinutes, setDurationMinutes] = useState(0);
  const [shootersCount, setShootersCount] = useState(1);
  const [selectedHour, setSelectedHour] = useState("");
  const [reservationNote, setReservationNote] = useState("");
  const [acceptedRules, setAcceptedRules] = useState(false);
  const [busyRanges, setBusyRanges] = useState<BookingTimeRange[]>([]);
  const [blockedRanges, setBlockedRanges] = useState<BookingTimeRange[]>([]);
  const [checkingAvailability, setCheckingAvailability] = useState(false);
  const [availabilityReady, setAvailabilityReady] = useState(false);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [messageSuccess, setMessageSuccess] = useState(false);
  const [confirmationData, setConfirmationData] =
    useState<ConfirmationData | null>(null);
  const creationRequestIdRef = useRef("");
  const submissionInProgressRef = useRef(false);
  const availabilityRequestRef = useRef(0);

  const selectedLane = lanes.find((lane) => lane.id === laneId);
  const selectedDayGroup = getBookingDayGroup(reservationDate);
  const laneDurations = useMemo(
    () => durations.filter((duration) => duration.lane_id === laneId),
    [durations, laneId]
  );
  const matchingPricingRule = pricingRules.find(
    (rule) =>
      rule.lane_id === laneId &&
      rule.day_group === selectedDayGroup &&
      rule.min_shooters <= shootersCount &&
      rule.max_shooters >= shootersCount
  );
  const estimatedPrice =
    matchingPricingRule && durationMinutes > 0
      ? Math.round(
          (Number(matchingPricingRule.hourly_price) * durationMinutes * 100) /
            60
        ) / 100
      : null;

  const bookingSlots = useMemo(() => {
    if (!selectedLane) {
      return [];
    }

    const result: string[] = [];
    const step = Number(selectedLane.booking_step_minutes);

    for (
      let start = 8 * 60;
      start < 20 * 60;
      start += step
    ) {
      result.push(addMinutesToTime("00:00", start));
    }

    return result;
  }, [selectedLane]);

  const selectedRangeSlots = useMemo(
    () => getOccupiedSlotStarts(selectedHour, durationMinutes, bookingSlots),
    [bookingSlots, durationMinutes, selectedHour]
  );
  const selectedRangeSlotSet = useMemo(
    () => new Set(selectedRangeSlots.map(normalizeBookingTime)),
    [selectedRangeSlots]
  );

  const selectedEndTime = selectedHour
    ? addMinutesToTime(selectedHour, durationMinutes)
    : "";

  function resetAttempt() {
    creationRequestIdRef.current = "";
    setMessage("");
    setMessageSuccess(false);
  }

  function getCreationRequestId() {
    if (!creationRequestIdRef.current) {
      creationRequestIdRef.current = crypto.randomUUID();
    }
    return creationRequestIdRef.current;
  }

  useEffect(() => {
    async function loadUser() {
      const {
        data: { user },
        error,
      } = await supabase.auth.getUser();

      if (error || !user) {
        setIsLoggedIn(false);
        setCheckingUser(false);
        return;
      }

      const { data } = await supabase
        .from("profiles")
        .select(
          "email,first_name,last_name,full_name,phone,verification_status"
        )
        .eq("user_id", user.id)
        .maybeSingle();

      setProfile((data as Profile | null) ?? null);
      setIsLoggedIn(true);
      setCheckingUser(false);
    }

    loadUser();
  }, []);

  const loadAvailability = useCallback(async (
    targetLaneId: string,
    targetDate: string
  ) => {
    if (!targetDate || !targetLaneId) {
      return false;
    }

    const requestNumber = ++availabilityRequestRef.current;

    const [busyResult, blockResult] = await Promise.all([
      supabase.rpc(
        "get_lane_booking_busy_ranges",
        {
          p_lane_id: targetLaneId,
          p_reservation_date: targetDate,
        }
      ),
      supabase
        .from("lane_blocks")
        .select("start_time,end_time")
        .eq("lane_id", targetLaneId)
        .eq("block_date", targetDate)
        .eq("is_active", true),
    ]);

    if (requestNumber !== availabilityRequestRef.current) {
      return false;
    }

    setCheckingAvailability(false);

    if (busyResult.error || blockResult.error) {
      setAvailabilityReady(false);
      setMessage("Nie udało się pobrać podglądu dostępności.");
      return false;
    }

    const normalizeRanges = (rows: BusyRangeRow[]): BookingTimeRange[] =>
      rows.map((range) => ({
        startTime: normalizeBookingTime(range.start_time),
        endTime: normalizeBookingTime(range.end_time),
      }));

    setBusyRanges(normalizeRanges((busyResult.data ?? []) as BusyRangeRow[]));
    setBlockedRanges(
      normalizeRanges((blockResult.data ?? []) as BusyRangeRow[])
    );
    setAvailabilityReady(true);
    return true;
  }, []);

  const getSlotState = useCallback((
    hour: string,
    candidateDuration = durationMinutes,
    candidateSelection = selectedHour
  ): BookingSlotState => {
    const now = new Date();
    const [hourValue, minuteValue] = hour.split(":").map(Number);

    return classifyBookingSlot({
      slotStart: hour,
      slotMinutes: Number(selectedLane?.booking_step_minutes ?? 60),
      durationMinutes: candidateDuration,
      openingStart: "08:00",
      openingEnd: "20:00",
      busyRanges,
      blockedRanges,
      selectedStart: candidateSelection,
      isPast:
        reservationDate === getTodayDateString() &&
        hourValue * 60 + minuteValue <= now.getHours() * 60 + now.getMinutes(),
    });
  }, [
    blockedRanges,
    busyRanges,
    durationMinutes,
    reservationDate,
    selectedHour,
    selectedLane?.booking_step_minutes,
  ]);

  async function sendConfirmationEmail(
    accessToken: string,
    reservationId: string
  ) {
    try {
      const response = await fetch("/api/send-reservation-confirmation", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({ reservationId }),
      });
      const result: unknown = await response.json().catch(() => null);

      if (!result || typeof result !== "object" || Array.isArray(result)) {
        return false;
      }

      const code = (result as { code?: unknown }).code;
      return response.ok && (code === "sent" || code === "already_sent");
    } catch {
      return false;
    }
  }

  async function handleSubmit() {
    if (submissionInProgressRef.current || loading) {
      return;
    }

    setMessage("");
    setMessageSuccess(false);

    if (
      !reservationDate ||
      !laneId ||
      !selectedHour ||
      durationMinutes <= 0 ||
      shootersCount <= 0 ||
      !acceptedRules ||
      !matchingPricingRule
    ) {
      setMessage("Uzupełnij wszystkie wymagane pola rezerwacji.");
      return;
    }

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.access_token) {
      setMessage("Sesja wygasła. Zaloguj się ponownie.");
      return;
    }

    submissionInProgressRef.current = true;
    setLoading(true);

    try {
      const response = await fetch("/api/create-reservation", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({
          laneId,
          reservationDate,
          startTime: selectedHour,
          durationMinutes,
          shootersCount,
          creationRequestId: getCreationRequestId(),
          reservationNote: reservationNote.trim() || null,
        }),
      });
      const result: unknown = await response.json().catch(() => null);

      if (!isCreateReservationResponse(result)) {
        setMessage("Nie udało się potwierdzić wyniku rezerwacji.");
        return;
      }

      if (!response.ok || !result.ok) {
        if (result.code === "slot_unavailable") {
          setSelectedHour("");
          creationRequestIdRef.current = "";
          setAvailabilityReady(false);
          setCheckingAvailability(true);
          await loadAvailability(laneId, reservationDate);
          setMessageSuccess(false);
          setMessage(
            "Ten przedział został właśnie zajęty. Wybierz inną godzinę."
          );
          return;
        }

        setMessage(
          CODE_MESSAGES[result.code] ??
            result.error ??
            "Nie udało się utworzyć rezerwacji."
        );
        return;
      }

      if (
        !result.reservationId ||
        !UUID_PATTERN.test(result.reservationId) ||
        typeof result.totalPrice !== "number" ||
        typeof result.durationMinutes !== "number" ||
        (result.pricingDayGroup !== "mon_thu" &&
          result.pricingDayGroup !== "fri_sun") ||
        typeof result.shootersCount !== "number" ||
        !result.laneName ||
        !result.currencyCode
      ) {
        setMessage("Rezerwacja istnieje, ale odpowiedź serwera jest niepełna.");
        return;
      }

      const endTime = addMinutesToTime(selectedHour, result.durationMinutes);
      const emailSent = await sendConfirmationEmail(
        session.access_token,
        result.reservationId
      );

      setConfirmationData({
        date: reservationDate,
        startTime: selectedHour,
        endTime,
        laneName: result.laneName,
        shootersCount: result.shootersCount,
        durationMinutes: result.durationMinutes,
        pricingDayGroup: result.pricingDayGroup,
        totalPrice: result.totalPrice,
        currencyCode: result.currencyCode,
      });
      setMessageSuccess(true);
      setMessage(
        emailSent
          ? result.code === "already_created"
            ? "Rezerwacja była już utworzona. Potwierdzenie e-mail jest zabezpieczone przed duplikatem."
            : "Rezerwacja została utworzona, a potwierdzenie wysłane e-mailem."
          : "Rezerwacja istnieje, ale nie udało się wysłać e-maila. Wysyłkę można ponowić."
      );

      creationRequestIdRef.current = "";
      setReservationDate("");
      setLaneId("");
      setDurationMinutes(0);
      setShootersCount(1);
      setSelectedHour("");
      setReservationNote("");
      setAcceptedRules(false);
      setBusyRanges([]);
      setBlockedRanges([]);
      setAvailabilityReady(false);
    } catch {
      setMessage(
        "Nie udało się połączyć z serwerem. Ponowienie zachowa identyfikator tej samej próby."
      );
    } finally {
      submissionInProgressRef.current = false;
      setLoading(false);
    }
  }

  if (checkingUser) {
    return (
      <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
        Sprawdzanie użytkownika...
      </div>
    );
  }

  if (!isLoggedIn) {
    return (
      <div className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-6 text-center">
        <h2 className="text-2xl font-bold">Logowanie wymagane</h2>
        <p className="mt-3 text-[#e0a0a0]">
          Zaloguj się, aby utworzyć rezerwację.
        </p>
        <a
          href="/login?redirectTo=%2Fbooking"
          className="mt-5 inline-flex rounded-xl bg-[#536143] px-5 py-3 font-semibold"
        >
          Zaloguj się
        </a>
      </div>
    );
  }

  const displayName = getProfileDisplayName(profile ?? {}, "");
  const verificationStatus = profile?.verification_status ?? "pending";
  const profileRejected = verificationStatus === "rejected";
  const noLaneConfiguration =
    Boolean(laneId) &&
    (laneDurations.length === 0 ||
      !pricingRules.some((rule) => rule.lane_id === laneId));
  const lanePricingNotice = selectedLane
    ? getLanePricingNotice(selectedLane.name)
    : null;

  return (
    <>
      {confirmationData && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 px-4 py-6">
          <div
            role="dialog"
            aria-modal="true"
            className="w-full max-w-lg rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl"
          >
            <p className="text-sm font-bold uppercase tracking-[0.2em] text-[#a9d4ad]">
              Rezerwacja przyjęta
            </p>
            <h2 className="mt-3 text-3xl font-bold">
              Udało się dokonać rezerwacji
            </h2>
            <div className="mt-5 grid gap-3 rounded-2xl border border-[#30372c] bg-[#191e19] p-5">
              <p>{formatReservationDate(confirmationData.date)}</p>
              <p>
                {confirmationData.startTime}–{confirmationData.endTime}
              </p>
              <p>{confirmationData.laneName}</p>
              <p>
                {confirmationData.shootersCount} strzelców ·{" "}
                {formatDuration(confirmationData.durationMinutes)}
              </p>
              <p>{BOOKING_DAY_GROUP_LABELS[confirmationData.pricingDayGroup]}</p>
              <p className="font-semibold text-[#d7c895]">
                {formatMoney(
                  confirmationData.totalPrice,
                  confirmationData.currencyCode
                )}
              </p>
            </div>
            <button
              type="button"
              onClick={() => {
                window.location.href = "/my-reservations";
              }}
              className="mt-6 min-h-12 w-full rounded-xl bg-[#536143] px-5 py-3 font-semibold"
            >
              Gotowe
            </button>
          </div>
        </div>
      )}

      <form
        onSubmit={(event) => {
          event.preventDefault();
          void handleSubmit();
        }}
        className="grid gap-5 rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6"
      >
        {verificationStatus !== "verified" && (
          <div
            role={profileRejected ? "alert" : "status"}
            className={`rounded-xl border p-4 text-sm ${
              profileRejected
                ? "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]"
                : "border-[#806a32] bg-[#2b2618] text-[#e1c477]"
            }`}
          >
            {profileRejected
              ? "Konto zostało odrzucone. Rezerwacja jest zablokowana."
              : "Do czasu weryfikacji możesz mieć tylko jedną aktywną rezerwację."}
          </div>
        )}

        <div className="grid gap-4 md:grid-cols-3">
          <label className="grid gap-2 text-sm text-[#a9ada4]">
            Imię i nazwisko
            <input
              value={displayName}
              disabled
              className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-4 text-[#858c7f]"
            />
          </label>
          <label className="grid gap-2 text-sm text-[#a9ada4]">
            E-mail
            <input
              value={profile?.email ?? ""}
              disabled
              className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-4 text-[#858c7f]"
            />
          </label>
          <label className="grid gap-2 text-sm text-[#a9ada4]">
            Telefon
            <input
              value={profile?.phone ?? ""}
              disabled
              className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-4 text-[#858c7f]"
            />
          </label>
        </div>

        <div className="grid gap-4 md:grid-cols-2">
          <label className="grid gap-2 text-sm text-[#a9ada4]">
            Oś / stanowisko
            <select
              value={laneId}
              disabled={profileRejected || loading}
              onChange={(event) => {
                const nextLaneId = event.target.value;
                const nextDurations = durations.filter(
                  (duration) => duration.lane_id === nextLaneId
                );
                setLaneId(nextLaneId);
                setDurationMinutes(nextDurations[0]?.duration_minutes ?? 0);
                setShootersCount(1);
                setSelectedHour("");
                availabilityRequestRef.current += 1;
                setBusyRanges([]);
                setBlockedRanges([]);
                setAvailabilityReady(false);
                setCheckingAvailability(Boolean(nextLaneId && reservationDate));
                if (nextLaneId && reservationDate) {
                  void loadAvailability(nextLaneId, reservationDate);
                }
                resetAttempt();
              }}
              className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-4 text-[#f2efe4]"
            >
              <option value="">Wybierz oś</option>
              {lanes.map((lane) => (
                <option key={lane.id} value={lane.id}>
                  {lane.name} · maks. {lane.max_shooters}
                </option>
              ))}
            </select>
          </label>

          <label className="grid gap-2 text-sm text-[#a9ada4]">
            Data
            <input
              type="date"
              min={getTodayDateString()}
              value={reservationDate}
              disabled={profileRejected || loading}
              onChange={(event) => {
                const nextDate = event.target.value;
                setReservationDate(nextDate);
                setSelectedHour("");
                availabilityRequestRef.current += 1;
                setBusyRanges([]);
                setBlockedRanges([]);
                setAvailabilityReady(false);
                setCheckingAvailability(Boolean(laneId && nextDate));
                if (laneId && nextDate) {
                  void loadAvailability(laneId, nextDate);
                }
                resetAttempt();
              }}
              className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-4 text-[#f2efe4]"
            />
          </label>

          <label className="grid gap-2 text-sm text-[#a9ada4]">
            Liczba strzelców
            <select
              value={shootersCount}
              disabled={!selectedLane || profileRejected || loading}
              onChange={(event) => {
                setShootersCount(Number(event.target.value));
                resetAttempt();
              }}
              className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-4 text-[#f2efe4]"
            >
              {Array.from(
                { length: selectedLane?.max_shooters ?? 1 },
                (_, index) => index + 1
              ).map((count) => (
                <option key={count} value={count}>
                  {count}
                </option>
              ))}
            </select>
          </label>

          <label className="grid gap-2 text-sm text-[#a9ada4]">
            Czas rezerwacji
            <select
              value={durationMinutes}
              disabled={!laneId || laneDurations.length === 0 || loading}
              onChange={(event) => {
                const nextDuration = Number(event.target.value);
                setDurationMinutes(nextDuration);
                resetAttempt();
                if (
                  selectedHour &&
                  !bookingSlotIsAvailable(
                    getSlotState(selectedHour, nextDuration, selectedHour)
                  )
                ) {
                  setSelectedHour("");
                  setMessage(
                    "Wybrany przedział nie mieści się w dostępnych godzinach. Wybierz inną godzinę rozpoczęcia."
                  );
                }
              }}
              className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-4 text-[#f2efe4]"
            >
              {laneDurations.length === 0 && (
                <option value={0}>Brak konfiguracji</option>
              )}
              {laneDurations.map((duration) => (
                <option key={duration.id} value={duration.duration_minutes}>
                  {formatDuration(duration.duration_minutes)}
                </option>
              ))}
            </select>
          </label>
        </div>

        {noLaneConfiguration && (
          <div className="rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]">
            Ta oś nie ma kompletnej konfiguracji długości lub cennika.
          </div>
        )}

        <div className="rounded-xl border border-[#30372c] bg-[#141814] p-4">
          <p className="text-sm text-[#a9ada4]">Cena orientacyjna</p>
          {matchingPricingRule && estimatedPrice !== null && selectedLane ? (
            <>
              <p className="mt-1 text-2xl font-bold text-[#d7c895]">
                {formatMoney(estimatedPrice, selectedLane.currency_code)}
              </p>
              <p className="mt-1 text-sm text-[#858c7f]">
                {matchingPricingRule.label} ·{" "}
                {formatMoney(
                  Number(matchingPricingRule.hourly_price),
                  selectedLane.currency_code
                )}
                /h. Ostateczną cenę wylicza serwer.
              </p>
              <p className="mt-2 text-sm font-semibold text-[#a9ada4]">
                Taryfa {BOOKING_DAY_GROUP_LABELS[matchingPricingRule.day_group].toLowerCase()}
              </p>
              {lanePricingNotice && (
                <p className="mt-2 text-sm text-[#a9ada4]">
                  {lanePricingNotice}
                </p>
              )}
            </>
          ) : (
            <p className="mt-1 text-sm text-[#e1c477]">
              Brak dopasowanej reguły cenowej.
            </p>
          )}
        </div>

        <fieldset className="rounded-xl border border-[#30372c] bg-[#141814] p-4">
          <legend className="px-2 text-sm text-[#a9ada4]">
            Godzina rozpoczęcia
          </legend>
          {checkingAvailability ? (
            <p className="text-sm text-[#858c7f]">Sprawdzanie dostępności...</p>
          ) : bookingSlots.length === 0 ? (
            <p className="text-sm text-[#e1c477]">
              Brak godzin dla wybranej konfiguracji.
            </p>
          ) : (
            <div className="grid grid-cols-3 gap-2 sm:grid-cols-5 md:grid-cols-6">
              {bookingSlots.map((hour) => {
                const normalizedHour = normalizeBookingTime(hour);
                const normalizedSelectedStart = selectedHour
                  ? normalizeBookingTime(selectedHour)
                  : "";
                const baseState = getSlotState(hour, durationMinutes, "");
                const state: BookingSlotState =
                  normalizedSelectedStart === normalizedHour
                    ? "selected_start"
                    : selectedRangeSlotSet.has(normalizedHour)
                      ? "selected_range"
                      : baseState;
                const available = bookingSlotIsAvailable(state);
                const isSelectedStart = state === "selected_start";
                const isSelectedRange = state === "selected_range";
                const slotVisualClass = getBookingSlotVisualClass(state);
                const labels: Record<BookingSlotState, string> = {
                  available: "Wolne",
                  selected_start: "Początek",
                  selected_range: "Wybrany przedział",
                  occupied: "Zajęte",
                  blocked: "Zablokowane",
                  insufficient_time: "Za mało wolnego czasu",
                  outside_hours: "Poza godzinami",
                  past: "Godzina minęła",
                };
                return (
                  <button
                    key={hour}
                    type="button"
                    disabled={!availabilityReady || !available || loading}
                    onClick={() => {
                      setSelectedHour(hour);
                      resetAttempt();
                    }}
                    aria-pressed={isSelectedStart}
                    data-slot-state={state}
                    style={
                      isSelectedStart
                        ? {
                            backgroundColor: "#536143",
                            borderColor: "#e1c477",
                            color: "#ffffff",
                          }
                        : isSelectedRange
                          ? {
                              backgroundColor: "#3f4935",
                              borderColor: "#78865f",
                              color: "#f2efe4",
                            }
                          : undefined
                    }
                    className={`min-h-14 rounded-lg border px-2 py-2 text-sm ${slotVisualClass}`}
                  >
                    <span className="block font-semibold">{hour}</span>
                    <span className="mt-1 block text-[0.68rem] leading-tight">
                      {labels[state]}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
          {selectedHour && selectedRangeSlots.length > 0 && (
            <p
              role="status"
              aria-live="polite"
              className="mt-4 rounded-lg border border-[#6f5a2e] bg-[#2b2618] px-3 py-2 text-sm font-semibold text-[#d7c895]"
            >
              Wybrany przedział: {selectedHour}–{selectedEndTime}
            </p>
          )}
        </fieldset>

        <label className="grid gap-2 text-sm text-[#a9ada4]">
          Notatka do rezerwacji (opcjonalnie)
          <textarea
            value={reservationNote}
            maxLength={1000}
            disabled={loading}
            onChange={(event) => {
              setReservationNote(event.target.value);
              resetAttempt();
            }}
            className="min-h-24 rounded-xl border border-[#30372c] bg-[#141814] p-4 text-[#f2efe4]"
          />
        </label>

        <label className="flex gap-3 text-sm text-[#a9ada4]">
          <input
            type="checkbox"
            checked={acceptedRules}
            disabled={loading}
            onChange={(event) => setAcceptedRules(event.target.checked)}
          />
          Akceptuję regulamin i zasady bezpieczeństwa.
        </label>

        {message && (
          <div
            role={messageSuccess ? "status" : "alert"}
            className={`rounded-xl border p-4 text-sm ${
              messageSuccess
                ? "border-[#3f6848] bg-[#1b2a1d] text-[#a9d4ad]"
                : "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]"
            }`}
          >
            {message}
          </div>
        )}

        <button
          type="submit"
          disabled={
            loading ||
            profileRejected ||
            !reservationDate ||
            !laneId ||
            !selectedHour ||
            !matchingPricingRule ||
            !acceptedRules
          }
          className="min-h-12 rounded-xl bg-[#536143] px-5 py-3 font-semibold disabled:cursor-not-allowed disabled:opacity-50"
        >
          {loading ? "Tworzenie rezerwacji..." : "Potwierdź rezerwację"}
        </button>
      </form>
    </>
  );
}
