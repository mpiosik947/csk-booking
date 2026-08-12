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
  displayName: string;
  parentName: string | null;
  isActive: boolean;
  isHistoricalOnly: boolean;
  displayOrder: number;
  bookingStepMinutes: number;
  resourceKind: "lane" | "position";
  parentLaneId: string | null;
  depth: 0 | 1;
  isParent: boolean;
  isPosition: boolean;
};

export type CalendarEntryResource = Pick<
  CalendarLane,
  "id" | "displayName" | "depth" | "isActive" | "isPosition"
>;

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
  laneResource: CalendarEntryResource | null;
  status: CalendarReservationStatus;
  shootersCount: number;
};

export type CalendarLaneBlockEntry = CalendarEntryBase & {
  type: "lane_block";
  laneId: string;
  laneName: string;
  laneMetadataAvailable: boolean;
  laneResource: CalendarEntryResource | null;
  status: "active" | "inactive";
  reason: string | null;
  isActive: boolean;
};

type CalendarEventDetails = CalendarEntryBase & {
  type: "event";
  status: "active";
  location: string | null;
  maxParticipants: number;
  sourceEventId: string;
  laneIds: string[];
  resources: CalendarEntryResource[];
};

export type CalendarGlobalEventEntry = CalendarEventDetails & {
  laneId: null;
  laneName: null;
  laneMetadataAvailable: false;
  laneResource: null;
  occupiesLane: false;
  isLaneProjection: false;
};

export type CalendarLaneEventEntry = CalendarEventDetails & {
  laneId: string;
  laneName: string;
  laneMetadataAvailable: true;
  laneResource: CalendarEntryResource;
  occupiesLane: true;
  isLaneProjection: true;
};

export type CalendarEventEntry = CalendarGlobalEventEntry | CalendarLaneEventEntry;

export type CalendarEntry =
  | CalendarReservationEntry
  | CalendarLaneBlockEntry
  | CalendarEventEntry;

export type CalendarLaneOccupyingEntry =
  | CalendarReservationEntry
  | CalendarLaneBlockEntry
  | CalendarLaneEventEntry;

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
