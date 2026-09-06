import {
  CALENDAR_RECORD_ID_PATTERN,
  calendarError,
  calendarFile,
  getCalendarRequestContext,
} from "@/lib/server/calendar-export-route";
import { createIcsCalendar } from "@/lib/server/icalendar";
import { EVENT_REGISTRATION_STATUS } from "@/lib/event-registration-status";

type RouteContext = { params: Promise<{ id: string }> };

type EventRecord = {
  id: string;
  title: string;
  description: string | null;
  event_date: string;
  start_time: string;
  end_time: string;
  location: string | null;
};

export async function GET(request: Request, { params }: RouteContext) {
  try {
    const { id } = await params;
    if (!CALENDAR_RECORD_ID_PATTERN.test(id)) {
      return calendarError("invalid_request", 400, "Nieprawidłowy identyfikator zapisu.");
    }

    const context = await getCalendarRequestContext(request);
    if (!context.ok) return context.response;

    const { data, error } = await context.supabase
      .from("event_registrations")
      .select("id,registration_status,events!inner(id,title,description,event_date,start_time,end_time,location)")
      .eq("id", id)
      .eq("user_id", context.user.id)
      .maybeSingle();

    if (error) {
      console.error("Event registration calendar read failed", { code: error.code });
      return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
    }

    if (!data) {
      return calendarError("not_found", 404, "Nie znaleziono zapisu.");
    }

    const status = data.registration_status?.trim().toLowerCase();
    if (
      status !== EVENT_REGISTRATION_STATUS.REGISTERED &&
      status !== EVENT_REGISTRATION_STATUS.APPROVED
    ) {
      return calendarError("invalid_status", 409, "Status zapisu nie pozwala dodać terminu do kalendarza.");
    }

    const event = data.events as unknown as EventRecord;
    if (
      !event ||
      typeof event.id !== "string" ||
      typeof event.title !== "string" ||
      typeof event.event_date !== "string" ||
      typeof event.start_time !== "string" ||
      typeof event.end_time !== "string" ||
      (event.description !== null && typeof event.description !== "string") ||
      (event.location !== null && typeof event.location !== "string")
    ) {
      console.error("Event registration calendar read returned invalid data");
      return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
    }

    const calendar = createIcsCalendar({
      recordType: "event-registration",
      recordId: id,
      date: event.event_date,
      startTime: event.start_time,
      endTime: event.end_time,
      summary: `CSK — ${event.title}`,
      description: event.description?.trim() || "Potwierdzony udział w wydarzeniu CSK.",
      location: event.location,
    });

    if (!calendar) {
      console.error("Event registration calendar contains an invalid time range");
      return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
    }

    return calendarFile(calendar, "csk-szkolenie.ics");
  } catch {
    console.error("Event registration calendar endpoint failed");
    return calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.");
  }
}
