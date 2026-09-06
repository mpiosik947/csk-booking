import { parsePublicEventAvailability, type PublicEventAvailability } from "./public-event-availability.ts";
import type { AdminEvent, AdminEventLane } from "./admin/events/event-management.ts";
import { parseAdminEventRegistrations, type AdminEventRegistration } from "./admin/events/event-registrations.ts";

export const EVENT_LIST_PAGE_SIZE = 20;
export const EVENT_PARTICIPANT_PAGE_SIZE = 50;

export type EventPage<T> = { items: T[]; page: number; pageSize: number; total: number };
export type PublicEventFilters = { search: string; scope: "upcoming" | "all"; page: number };
export type AdminEventScope = "all" | "upcoming" | "past" | "inactive";
export type AdminEventFilters = { search: string; scope: AdminEventScope; sort: "nearest" | "latest"; page: number };
export type ParticipantFilters = { status: string; paymentStatus: string; page: number };
export type MyEventScope = "upcoming" | "history" | "all";
export type MyEventFilters = { scope: MyEventScope; status: string; page: number };

export type MyEventRegistration = {
  id: string;
  registration_status: string;
  payment_status: string;
  created_at: string;
  events: {
    id: string; title: string; description: string; event_date: string;
    start_time: string; end_time: string; location: string; price: number;
  };
};

export type ParticipantSummary = {
  registeredCount: number; reserveCount: number; cancelledCount: number; paidCount: number;
};

function record(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function integer(value: unknown, minimum = 0): value is number {
  return Number.isInteger(value) && Number(value) >= minimum;
}

function uuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function pagination(value: unknown) {
  if (!record(value) || !integer(value.page, 1) || !integer(value.page_size, 1) || !integer(value.total)) return null;
  return { page: value.page, pageSize: value.page_size, total: value.total };
}

export function parsePageNumber(value: string | null) {
  if (value === null) return 1;
  if (!/^\d+$/.test(value)) return null;
  const page = Number(value);
  return integer(page, 1) && page <= 100000 ? page : null;
}

export function buildEventSearchParams(values: Record<string, string | number | null | undefined>) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) {
    if (value !== null && value !== undefined && value !== "" && value !== 1) params.set(key, String(value));
  }
  return params;
}

export function parsePublicEventList(value: unknown): EventPage<PublicEventAvailability> | null {
  if (!record(value) || value.ok !== true || value.code !== "ok" || value.contract_version !== 2) return null;
  const page = pagination(value.pagination);
  const items = parsePublicEventAvailability(value.items);
  return page && items ? { ...page, items } : null;
}

function parseLane(value: unknown): AdminEventLane | null {
  if (!record(value) || !uuid(value.id) || typeof value.name !== "string" || typeof value.type !== "string" ||
      typeof value.is_active !== "boolean" || !integer(value.display_order) ||
      !["lane", "position"].includes(String(value.resource_kind)) ||
      (value.parent_lane_id !== null && !uuid(value.parent_lane_id)) ||
      (value.parent_name !== null && typeof value.parent_name !== "string")) return null;
  const isPosition = value.resource_kind === "position";
  if (isPosition && (!uuid(value.parent_lane_id) || !value.parent_name)) return null;
  return {
    id: value.id, name: value.name, type: value.type, is_active: value.is_active,
    display_order: value.display_order, resource_kind: value.resource_kind as "lane" | "position",
    parent_lane_id: value.parent_lane_id as string | null,
    displayName: isPosition ? `${value.parent_name} — ${value.name}` : value.name,
    parentName: isPosition ? value.parent_name as string : null,
    depth: isPosition ? 1 : 0, isParent: !isPosition, isPosition,
  };
}

function parseAdminEvent(value: unknown): AdminEvent | null {
  if (!record(value) || !uuid(value.id) || typeof value.title !== "string" ||
      (value.description !== null && typeof value.description !== "string") || typeof value.event_date !== "string" ||
      typeof value.start_time !== "string" || typeof value.end_time !== "string" ||
      (value.location !== null && typeof value.location !== "string") || typeof value.price !== "number" ||
      !integer(value.max_participants, 1) || typeof value.is_active !== "boolean" || typeof value.created_at !== "string" || !Array.isArray(value.lanes)) return null;
  const lanes = value.lanes.map(parseLane);
  if (lanes.some((lane) => lane === null)) return null;
  return {
    id: value.id, title: value.title, description: value.description as string | null,
    event_date: value.event_date, start_time: value.start_time, end_time: value.end_time,
    location: value.location as string | null, price: value.price, max_participants: value.max_participants,
    is_active: value.is_active, created_at: value.created_at,
    lanes: lanes as AdminEventLane[], laneIds: (lanes as AdminEventLane[]).map((lane) => lane.id),
  };
}

export function parseAdminEventList(value: unknown): (EventPage<AdminEvent> & { summary: { allCount: number; upcomingCount: number; pastCount: number; inactiveCount: number } }) | null {
  if (!record(value) || value.ok !== true || value.code !== "ok" || value.contract_version !== 1 || !Array.isArray(value.items) || !record(value.summary)) return null;
  const page = pagination(value.pagination);
  const items = value.items.map(parseAdminEvent);
  const summary = value.summary;
  if (!page || items.some((item) => item === null) || !integer(summary.all_count) || !integer(summary.upcoming_count) || !integer(summary.past_count) || !integer(summary.inactive_count)) return null;
  return { ...page, items: items as AdminEvent[], summary: { allCount: summary.all_count, upcomingCount: summary.upcoming_count, pastCount: summary.past_count, inactiveCount: summary.inactive_count } };
}

export function parseParticipantList(value: unknown): (EventPage<AdminEventRegistration> & { summary: ParticipantSummary }) | null {
  if (!record(value) || value.ok !== true || value.code !== "ok" || value.contract_version !== 1 || !record(value.summary)) return null;
  const page = pagination(value.pagination);
  const items = parseAdminEventRegistrations(value.items);
  const summary = value.summary;
  if (!page || !items || !integer(summary.registered_count) || !integer(summary.reserve_count) || !integer(summary.cancelled_count) || !integer(summary.paid_count)) return null;
  return { ...page, items, summary: { registeredCount: summary.registered_count, reserveCount: summary.reserve_count, cancelledCount: summary.cancelled_count, paidCount: summary.paid_count } };
}

function parseMyItem(value: unknown): MyEventRegistration | null {
  if (!record(value) || !uuid(value.id) || typeof value.registration_status !== "string" || typeof value.payment_status !== "string" || typeof value.created_at !== "string" || !record(value.events)) return null;
  const event = value.events;
  if (!uuid(event.id) || typeof event.title !== "string" || typeof event.description !== "string" || typeof event.event_date !== "string" || typeof event.start_time !== "string" || typeof event.end_time !== "string" || typeof event.location !== "string" || typeof event.price !== "number") return null;
  return value as MyEventRegistration;
}

export function parseMyEventList(value: unknown): EventPage<MyEventRegistration> | null {
  if (!record(value) || value.ok !== true || value.code !== "ok" || value.contract_version !== 1 || !Array.isArray(value.items)) return null;
  const page = pagination(value.pagination);
  const items = value.items.map(parseMyItem);
  return page && !items.some((item) => item === null) ? { ...page, items: items as MyEventRegistration[] } : null;
}
