export type BookingTimeRange = {
  startTime: string;
  endTime: string;
};

export type BookingSlotState =
  | "available"
  | "selected_start"
  | "selected_range"
  | "occupied"
  | "blocked"
  | "insufficient_time"
  | "outside_hours"
  | "past";

type ClassifyBookingSlotInput = {
  slotStart: string;
  slotMinutes: number;
  durationMinutes: number;
  openingStart: string;
  openingEnd: string;
  busyRanges: BookingTimeRange[];
  blockedRanges: BookingTimeRange[];
  selectedStart?: string;
  isPast?: boolean;
};

function normalizeTime(value: string) {
  return value.slice(0, 5);
}

export function timeToMinutes(value: string) {
  const [hours, minutes] = normalizeTime(value).split(":").map(Number);
  return hours * 60 + minutes;
}

export function addMinutesToTime(value: string, minutes: number) {
  const total = timeToMinutes(value) + minutes;
  const hours = Math.floor(total / 60);
  const remainingMinutes = total % 60;
  return `${String(hours).padStart(2, "0")}:${String(remainingMinutes).padStart(2, "0")}`;
}

export function rangesOverlap(
  first: BookingTimeRange,
  second: BookingTimeRange
) {
  return (
    timeToMinutes(first.startTime) < timeToMinutes(second.endTime) &&
    timeToMinutes(first.endTime) > timeToMinutes(second.startTime)
  );
}

export function rangeFitsOpeningHours(
  range: BookingTimeRange,
  openingStart: string,
  openingEnd: string
) {
  return (
    timeToMinutes(range.startTime) >= timeToMinutes(openingStart) &&
    timeToMinutes(range.endTime) <= timeToMinutes(openingEnd)
  );
}

export function getOccupiedSlotStarts(
  startTime: string,
  durationMinutes: number,
  slots: string[]
) {
  if (!startTime || durationMinutes <= 0) {
    return [];
  }

  const endTime = addMinutesToTime(startTime, durationMinutes);
  return slots.filter(
    (slotStart) =>
      timeToMinutes(slotStart) >= timeToMinutes(startTime) &&
      timeToMinutes(slotStart) < timeToMinutes(endTime)
  );
}

export function classifyBookingSlot({
  slotStart,
  slotMinutes,
  durationMinutes,
  openingStart,
  openingEnd,
  busyRanges,
  blockedRanges,
  selectedStart = "",
  isPast = false,
}: ClassifyBookingSlotInput): BookingSlotState {
  const slotRange = {
    startTime: slotStart,
    endTime: addMinutesToTime(slotStart, slotMinutes),
  };
  const candidateRange = {
    startTime: slotStart,
    endTime: addMinutesToTime(slotStart, durationMinutes),
  };
  const selectedRange = selectedStart
    ? {
        startTime: selectedStart,
        endTime: addMinutesToTime(selectedStart, durationMinutes),
      }
    : null;

  if (
    selectedRange &&
    timeToMinutes(slotStart) > timeToMinutes(selectedRange.startTime) &&
    timeToMinutes(slotStart) < timeToMinutes(selectedRange.endTime)
  ) {
    return "selected_range";
  }

  if (blockedRanges.some((range) => rangesOverlap(slotRange, range))) {
    return "blocked";
  }

  if (busyRanges.some((range) => rangesOverlap(slotRange, range))) {
    return "occupied";
  }

  if (isPast) {
    return "past";
  }

  if (!rangeFitsOpeningHours(candidateRange, openingStart, openingEnd)) {
    return "outside_hours";
  }

  if (busyRanges.some((range) => rangesOverlap(candidateRange, range))) {
    return "insufficient_time";
  }

  if (selectedStart === slotStart) {
    return "selected_start";
  }

  return "available";
}

export function bookingSlotIsAvailable(state: BookingSlotState) {
  return state === "available" || state === "selected_start";
}
