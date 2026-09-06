import {
  CALENDAR_RECORD_ID_PATTERN,
  calendarError,
  calendarFile,
  getCalendarRequestContext,
} from "@/lib/server/calendar-export-route";
import { createIcsCalendar } from "@/lib/server/icalendar";
import { isCancelledReservationStatus } from "@/lib/reservation-status";

type RouteContext = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: RouteContext) {
  try {
    const { id } = await params;
    if (!CALENDAR_RECORD_ID_PATTERN.test(id)) {
      return calendarError("invalid_request", 400, "Nieprawidłowy identyfikator rezerwacji.");
    }

    const context = await getCalendarRequestContext(request);
    if (!context.ok) return context.response;

    const { data, error } = await context.supabase
      .rpc("get_my_reservations_v2")
      .eq("id", id)
      .maybeSingle();

    if (error) {
      console.error("Reservation calendar read failed", { code: error.code });
      return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
    }

    if (!data) {
      return calendarError("not_found", 404, "Nie znaleziono rezerwacji.");
    }

    const reservation = data as unknown as Record<string, unknown>;
    if (
      typeof reservation.reservation_date !== "string" ||
      typeof reservation.start_time !== "string" ||
      typeof reservation.end_time !== "string" ||
      typeof reservation.reservation_status !== "string" ||
      typeof reservation.lane_display_name !== "string"
    ) {
      console.error("Reservation calendar read returned invalid data");
      return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
    }

    if (isCancelledReservationStatus(reservation.reservation_status)) {
      return calendarError("invalid_status", 409, "Anulowanej rezerwacji nie można dodać do kalendarza.");
    }

    const calendar = createIcsCalendar({
      recordType: "reservation",
      recordId: id,
      date: reservation.reservation_date,
      startTime: reservation.start_time,
      endTime: reservation.end_time,
      summary: "CSK — Rezerwacja strzelnicy",
      description: `Rezerwacja: ${reservation.lane_display_name}`,
    });

    if (!calendar) {
      console.error("Reservation calendar contains an invalid time range");
      return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
    }

    return calendarFile(calendar, "csk-rezerwacja.ics");
  } catch {
    console.error("Reservation calendar endpoint failed");
    return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
  }
}
