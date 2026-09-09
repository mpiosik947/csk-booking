export type LaneParentHydrationLane = {
  id: string;
  name: string | null;
  resource_kind: string | null;
  parent_lane_id: string | null;
  display_order: number | null;
  is_active: boolean | null;
  parent_lane?: unknown;
};

type LaneRelation =
  | LaneParentHydrationLane
  | LaneParentHydrationLane[]
  | null
  | undefined;

export class LaneParentHydrationError extends Error {
  code: "lane_parent_read_failed" | "lane_parent_missing";
}

export function hydrateLaneRows<T extends LaneParentHydrationLane>(
  supabase: unknown,
  lanes: T[],
): Promise<T[]>;

export function hydrateReservationLaneParents<
  T extends { shooting_lanes?: LaneRelation },
>(supabase: unknown, reservations: T[]): Promise<T[]>;
