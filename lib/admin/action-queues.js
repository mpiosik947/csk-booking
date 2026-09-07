export const ADMIN_QUEUE_TIME_ZONE = "Europe/Warsaw";

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/u;

export function getWarsawDateISO(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: ADMIN_QUEUE_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));

  return `${values.year}-${values.month}-${values.day}`;
}

export function isValidIsoDate(value) {
  if (!ISO_DATE_PATTERN.test(value ?? "")) return false;

  const [year, month, day] = value.split("-").map(Number);
  const candidate = new Date(Date.UTC(year, month - 1, day));

  return (
    candidate.getUTCFullYear() === year &&
    candidate.getUTCMonth() === month - 1 &&
    candidate.getUTCDate() === day
  );
}

export function buildAdminActionQueueLinks(date = new Date()) {
  const today = getWarsawDateISO(date);

  return {
    expectedToday: `/admin/check-in?date=${today}&attendance=expected&page=1`,
    unpaid: `/admin/reservations?date=${today}&status=confirmed&payment=unpaid&page=1`,
    eventReserve: "/admin/events?participantStatus=reserve&participantPage=1&page=1",
    todayReservations: `/admin/reservations?date=${today}&page=1`,
  };
}

export function isExpectedTodayReservation(reservation) {
  return (
    reservation?.reservation_status === "confirmed" &&
    (reservation?.attendance_status === "planned" ||
      reservation?.attendance_status === null)
  );
}

export function isUnpaidActionReservation(reservation) {
  return (
    reservation?.reservation_status === "confirmed" &&
    reservation?.payment_status === "unpaid"
  );
}
