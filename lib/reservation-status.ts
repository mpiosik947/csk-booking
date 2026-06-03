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

export function isCancelledReservationStatus(status: string | null | undefined) {
  return (
    status === RESERVATION_STATUS.CANCELLED ||
    status === RESERVATION_STATUS.CANCELED ||
    status === RESERVATION_STATUS.CANCELLED_BY_ADMIN ||
    status === RESERVATION_STATUS.CANCELLED_BY_USER
  );
}

export function getReservationStatusLabel(status: string | null | undefined) {
  switch (status) {
    case RESERVATION_STATUS.CONFIRMED:
      return "Potwierdzona";
    case RESERVATION_STATUS.COMPLETED:
      return "Zakończona";
    case RESERVATION_STATUS.NO_SHOW:
      return "No-show";
    case RESERVATION_STATUS.CANCELLED:
    case RESERVATION_STATUS.CANCELED:
    case RESERVATION_STATUS.CANCELLED_BY_ADMIN:
    case RESERVATION_STATUS.CANCELLED_BY_USER:
      return "Anulowana";
    default:
      return status || "Brak statusu";
  }
}

export function getReservationStatusBadgeClass(
  status: string | null | undefined
) {
  switch (status) {
    case RESERVATION_STATUS.CONFIRMED:
      return "border-green-700 bg-green-950 text-green-300";
    case RESERVATION_STATUS.COMPLETED:
      return "border-blue-700 bg-blue-950 text-blue-300";
    case RESERVATION_STATUS.NO_SHOW:
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case RESERVATION_STATUS.CANCELLED:
    case RESERVATION_STATUS.CANCELED:
    case RESERVATION_STATUS.CANCELLED_BY_ADMIN:
    case RESERVATION_STATUS.CANCELLED_BY_USER:
      return "border-red-700 bg-red-950 text-red-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }
}