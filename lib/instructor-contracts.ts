export type InstructorEvent = {
  id: string; title: string; description: string | null; event_date: string;
  start_time: string; end_time: string; location: string | null;
  status: "upcoming" | "past" | "cancelled"; participants_available: boolean;
};
export type InstructorParticipant = {
  registration_id: string; display_name: string;
  registration_status: "registered" | "approved" | "reserve";
  attendance_status: "unmarked" | "present" | "no_show";
  attendance_version: number;
};
export type InstructorPage<T> = { items: T[]; total: number };
const record = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
export function parseInstructorPage<T>(value: unknown, parse: (row: unknown) => T): InstructorPage<T> {
  if (!record(value) || !Array.isArray(value.items) || !Number.isSafeInteger(value.total) || (value.total as number) < 0) throw Error("Invalid instructor response");
  return { total: value.total as number, items: value.items.map(parse) };
}
export function parseInstructorEvent(value: unknown): InstructorEvent {
  if (!record(value) || !["id", "title", "event_date", "start_time", "end_time"].every(k => typeof value[k] === "string") ||
    !(value.description === null || typeof value.description === "string") || !(value.location === null || typeof value.location === "string") ||
    !["upcoming", "past", "cancelled"].includes(String(value.status)) || typeof value.participants_available !== "boolean") throw Error("Invalid instructor event");
  return { id: value.id as string, title: value.title as string, event_date: value.event_date as string,
    start_time: value.start_time as string, end_time: value.end_time as string, description: value.description,
    location: value.location, status: value.status as InstructorEvent["status"], participants_available: value.participants_available };
}
export function parseInstructorParticipant(value: unknown): InstructorParticipant {
  if (!record(value) || typeof value.registration_id !== "string" || typeof value.display_name !== "string" ||
    !["registered", "approved", "reserve"].includes(String(value.registration_status)) ||
    !["unmarked", "present", "no_show"].includes(String(value.attendance_status)) ||
    !Number.isSafeInteger(value.attendance_version) || (value.attendance_version as number)<0) throw Error("Invalid instructor participant");
  return { registration_id: value.registration_id, display_name: value.display_name, registration_status: value.registration_status as InstructorParticipant["registration_status"],
    attendance_status: value.attendance_status as InstructorParticipant["attendance_status"], attendance_version: value.attendance_version as number };
}
