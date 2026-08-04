export type BookingDayGroup = "mon_thu" | "fri_sun";

export const BOOKING_DAY_GROUP_LABELS: Record<BookingDayGroup, string> = {
  mon_thu: "Poniedziałek–czwartek",
  fri_sun: "Piątek–niedziela",
};

export function getBookingDayGroup(date: string): BookingDayGroup | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);

  if (!match) {
    return null;
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const calendarDate = new Date(Date.UTC(year, month - 1, day));

  if (
    calendarDate.getUTCFullYear() !== year ||
    calendarDate.getUTCMonth() !== month - 1 ||
    calendarDate.getUTCDate() !== day
  ) {
    return null;
  }

  const isoDay = calendarDate.getUTCDay() || 7;
  return isoDay <= 4 ? "mon_thu" : "fri_sun";
}
