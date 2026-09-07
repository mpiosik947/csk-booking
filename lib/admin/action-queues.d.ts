export const ADMIN_QUEUE_TIME_ZONE: "Europe/Warsaw";

export function getWarsawDateISO(date?: Date): string;
export function isValidIsoDate(value: string | null | undefined): boolean;
export function buildAdminActionQueueLinks(date?: Date): {
  expectedToday: string;
  unpaid: string;
  eventReserve: string;
  todayReservations: string;
};
export function isExpectedTodayReservation(reservation: {
  reservation_status?: string | null;
  attendance_status?: string | null;
}): boolean;
export function isUnpaidActionReservation(reservation: {
  reservation_status?: string | null;
  payment_status?: string | null;
}): boolean;
