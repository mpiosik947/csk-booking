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

export function normalizeBookingTime(value: string) {
  return value.slice(0, 5);
}

export function timeToMinutes(value: string) {
  const [hours, minutes] = normalizeBookingTime(value).split(":").map(Number);
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
    timeToMinutes(slotStart) === timeToMinutes(selectedRange.startTime)
  ) {
    return "selected_start";
  }
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


  return "available";
}

export function getBookingSlotVisualClass(state: BookingSlotState) {
  switch (state) {
    case "selected_start":
      return "border-[#e1c477] bg-[#536143] font-semibold text-[#ffffff] ring-2 ring-[#c5a861] ring-offset-1 ring-offset-[#141814] disabled:opacity-100";
    case "selected_range":
      return "cursor-default border-[#78865f] bg-[#3f4935] font-semibold text-[#f2efe4] disabled:opacity-100";
    case "blocked":
      return "cursor-not-allowed border-[#806a32] bg-[#2b2618] text-[#e1c477]";
    case "occupied":
      return "cursor-not-allowed border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]";
    case "available":
      return "border-[#30372c] bg-[#191e19] transition hover:border-[#78865f] hover:bg-[#536143]";
    default:
      return "cursor-not-allowed border-[#30372c] bg-[#111411] text-[#858c7f]";
  }
}

export function bookingSlotIsAvailable(state: BookingSlotState) {
  return state === "available" || state === "selected_start";
}
