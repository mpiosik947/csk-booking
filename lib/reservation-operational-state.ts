import {
  isCancelledReservationStatus,
  RESERVATION_STATUS,
} from "./reservation-status";

export type ReservationOperationalSnapshot = {
  reservation_status: string | null | undefined;
  attendance_status: string | null | undefined;
  checked_in_at: string | null | undefined;
  completed_at: string | null | undefined;
};

export type ReservationOperationalState =
  | "planned"
  | "present"
  | "completed"
  | "no_show"
  | "cancelled"
  | "invalid";

export type ReservationAttendanceAction =
  | "start"
  | "reset"
  | "complete"
  | "no_show";

export function getReservationOperationalState(
  reservation: ReservationOperationalSnapshot
): ReservationOperationalState {
  const reservationStatus = reservation.reservation_status;
  const attendanceStatus = reservation.attendance_status ?? "planned";
  const hasCheckedInAt = Boolean(reservation.checked_in_at);
  const hasCompletedAt = Boolean(reservation.completed_at);

  if (
    reservationStatus === RESERVATION_STATUS.CONFIRMED &&
    attendanceStatus === "planned" &&
    !hasCheckedInAt &&
    !hasCompletedAt
  ) {
    return "planned";
  }

  if (
    reservationStatus === RESERVATION_STATUS.CONFIRMED &&
    attendanceStatus === "present" &&
    hasCheckedInAt &&
    !hasCompletedAt
  ) {
    return "present";
  }

  if (
    reservationStatus === RESERVATION_STATUS.COMPLETED &&
    attendanceStatus === "completed" &&
    hasCheckedInAt &&
    hasCompletedAt
  ) {
    return "completed";
  }

  if (
    reservationStatus === RESERVATION_STATUS.NO_SHOW &&
    attendanceStatus === "no_show" &&
    !hasCheckedInAt &&
    !hasCompletedAt
  ) {
    return "no_show";
  }

  if (
    isCancelledReservationStatus(reservationStatus) &&
    attendanceStatus === "planned" &&
    !hasCheckedInAt &&
    !hasCompletedAt
  ) {
    return "cancelled";
  }

  return "invalid";
}

export function getReservationAttendanceActions(
  reservation: ReservationOperationalSnapshot
): readonly ReservationAttendanceAction[] {
  const state = getReservationOperationalState(reservation);

  if (state === "planned") return ["start", "no_show"];
  if (state === "present") return ["complete", "reset"];

  return [];
}
