export const CALENDAR_ENTRY_TYPES = [
  "reservation",
  "lane_block",
  "event",
] as const;

export type CalendarEntryType = (typeof CALENDAR_ENTRY_TYPES)[number];

export const CALENDAR_FEED_ROLES = [
  "admin",
  "pracownik",
  "instruktor",
] as const;

export type CalendarFeedRole = (typeof CALENDAR_FEED_ROLES)[number];

export const CALENDAR_RESERVATION_STATUSES = [
  "confirmed",
  "completed",
  "no_show",
] as const;

export type CalendarReservationStatus =
  (typeof CALENDAR_RESERVATION_STATUSES)[number];

export type CalendarEntryLinks = {
  primary:
    | "/admin/reservations"
    | "/admin/lane-blocks"
    | "/admin/events";
  checkIn: null;
};

export type CalendarLane = {
  id: string;
  name: string;
  isActive: boolean;
  isHistoricalOnly: boolean;
  displayOrder: number;
  bookingStepMinutes: number;
};

type CalendarEntryBase = {
  id: string;
  type: CalendarEntryType;
  date: string;
  startTime: string;
  endTime: string;
  label: string;
  occupiesLane: boolean;
  isHistorical: boolean;
  links: CalendarEntryLinks;
};

export type CalendarReservationEntry = CalendarEntryBase & {
  type: "reservation";
  laneId: string;
  laneName: string;
  laneMetadataAvailable: boolean;
  status: CalendarReservationStatus;
  shootersCount: number;
};

export type CalendarLaneBlockEntry = CalendarEntryBase & {
  type: "lane_block";
  laneId: string;
  laneName: string;
  laneMetadataAvailable: boolean;
  status: "active" | "inactive";
  reason: string | null;
  isActive: boolean;
};

export type CalendarEventEntry = CalendarEntryBase & {
  type: "event";
  laneId: null;
  laneName: null;
  status: "active";
  occupiesLane: false;
  location: string;
  maxParticipants: number;
};

export type CalendarEntry =
  | CalendarReservationEntry
  | CalendarLaneBlockEntry
  | CalendarEventEntry;

export const CALENDAR_DAY_FLAGS = [
  "full_day",
  "full_lane_block",
  "overlapping_blocks",
  "outside_opening_hours",
  "missing_lane_metadata",
] as const;

export type CalendarDayFlag = (typeof CALENDAR_DAY_FLAGS)[number];

export type CalendarDaySummary = {
  date: string;
  reservationCount: number;
  blockCount: number;
  eventCount: number;
  availableMinutes: number;
  occupiedMinutes: number;
  occupancyPercent: number | null;
  isFull: boolean;
  flags: CalendarDayFlag[];
};

export type CalendarFeed = {
  ok: true;
  rangeStart: string;
  rangeEnd: string;
  timeZone: "Europe/Warsaw";
  openingStart: string;
  openingEnd: string;
  occupancyBasis: "current_active_lanes";
  lanes: CalendarLane[];
  entries: CalendarEntry[];
  dailySummaries: CalendarDaySummary[];
};

export type CalendarFeedErrorCode =
  | "invalid_query"
  | "invalid_date"
  | "invalid_range"
  | "range_too_large"
  | "invalid_types"
  | "unauthorized"
  | "forbidden"
  | "lane_not_found"
  | "calendar_feed_failed";

export type CalendarFeedError = {
  ok: false;
  code: CalendarFeedErrorCode;
  message: string;
};

export type CalendarFeedResponse = CalendarFeed | CalendarFeedError;

export type CalendarFeedQuery = {
  rangeStart: string;
  rangeEnd: string;
  laneId: string | "all";
  types: CalendarEntryType[];
  includeHistoricalStatuses: boolean;
};
