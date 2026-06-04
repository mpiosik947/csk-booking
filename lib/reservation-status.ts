export const RESERVATION_STATUS = {
  CONFIRMED: "confirmed",
  COMPLETED: "completed",
  NO_SHOW: "no_show",
  CANCELLED: "cancelled",
  CANCELED: "canceled",
  CANCELLED_BY_ADMIN: "cancelled_by_admin",
  CANCELLED_BY_USER: "cancelled_by_user",
} as const;

export type ReservationStatus =
  (typeof RESERVATION_STATUS)[keyof typeof RESERVATION_STATUS];

export const RESERVATION_STATUSES = Object.values(RESERVATION_STATUS);

export const RESERVATION_STATUS_LABELS: Record<ReservationStatus, string> = {
  [RESERVATION_STATUS.CONFIRMED]: "Potwierdzona",
  [RESERVATION_STATUS.COMPLETED]: "Zakończona",
  [RESERVATION_STATUS.NO_SHOW]: "Nieobecny",
  [RESERVATION_STATUS.CANCELLED]: "Anulowana",
  [RESERVATION_STATUS.CANCELED]: "Anulowana",
  [RESERVATION_STATUS.CANCELLED_BY_ADMIN]: "Anulowana przez obsługę",
  [RESERVATION_STATUS.CANCELLED_BY_USER]: "Anulowana przez klienta",
};

export const RESERVATION_STATUS_BADGE_CLASSES: Record<
  ReservationStatus,
  string
> = {
  [RESERVATION_STATUS.CONFIRMED]: "border-green-700 bg-green-950 text-green-300",
  [RESERVATION_STATUS.COMPLETED]: "border-blue-700 bg-blue-950 text-blue-300",
  [RESERVATION_STATUS.NO_SHOW]: "border-yellow-700 bg-yellow-950 text-yellow-300",
  [RESERVATION_STATUS.CANCELLED]: "border-red-700 bg-red-950 text-red-300",
  [RESERVATION_STATUS.CANCELED]: "border-red-700 bg-red-950 text-red-300",
  [RESERVATION_STATUS.CANCELLED_BY_ADMIN]:
    "border-red-700 bg-red-950 text-red-300",
  [RESERVATION_STATUS.CANCELLED_BY_USER]:
    "border-red-700 bg-red-950 text-red-300",
};

export function isReservationStatus(
  status: string | null | undefined,
): status is ReservationStatus {
  if (!status) return false;

  return RESERVATION_STATUSES.includes(status as ReservationStatus);
}

export function isCancelledReservationStatus(
  status: string | null | undefined,
) {
  return (
    status === RESERVATION_STATUS.CANCELLED ||
    status === RESERVATION_STATUS.CANCELED ||
    status === RESERVATION_STATUS.CANCELLED_BY_ADMIN ||
    status === RESERVATION_STATUS.CANCELLED_BY_USER
  );
}

export function getReservationStatusLabel(
  status: string | null | undefined,
) {
  if (!status) return "Brak statusu";

  if (isReservationStatus(status)) {
    return RESERVATION_STATUS_LABELS[status];
  }

  return status;
}

export function getReservationStatusBadgeClass(
  status: string | null | undefined,
) {
  if (!status) {
    return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }

  if (isReservationStatus(status)) {
    return RESERVATION_STATUS_BADGE_CLASSES[status];
  }

  return "border-zinc-700 bg-zinc-900 text-zinc-300";
}