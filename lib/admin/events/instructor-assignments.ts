import type { AdminEvent } from "./event-management";
export type InstructorOption = { user_id: string; display_name: string };
export function parseInstructorOptions(value: unknown): InstructorOption[] {
  if (!Array.isArray(value) || value.some(row => !row || typeof row.user_id !== "string" || typeof row.display_name !== "string")) throw Error("Invalid instructor lookup");
  return value.map(row => ({ user_id: row.user_id, display_name: row.display_name }));
}
/** Structural optimistic revision matches the private DB projection; never authority. */
export function eventEditRevision(event: AdminEvent) {
  const fullTime = (time: string) => time.length === 5 ? `${time}:00` : time;
  return { title: event.title, description: event.description, event_date: event.event_date,
    start_time: fullTime(event.start_time), end_time: fullTime(event.end_time), location: event.location,
    price: event.price, max_participants: event.max_participants, is_active: event.is_active,
    cancelled_at: null, lane_ids: [...event.laneIds].sort() };
}
export function assignmentError(code?: string) {
  return code === "40001"
    ? "Dane wydarzenia lub obsada zostały zmienione przez inną osobę. Zamknij edycję, odśwież listę i spróbuj ponownie. Nic nie zapisano."
    : "Nie udało się zapisać wydarzenia i obsady. Sprawdź dostępność instruktorów i odśwież dane. Nic nie zapisano.";
}
