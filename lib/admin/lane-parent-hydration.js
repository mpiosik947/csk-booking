const PARENT_LANE_SELECT =
  "id,name,resource_kind,parent_lane_id,display_order,is_active";

export class LaneParentHydrationError extends Error {
  constructor(code, options = {}) {
    super(code, options);
    this.name = "LaneParentHydrationError";
    this.code = code;
  }
}

function laneValues(value) {
  if (Array.isArray(value)) return value;
  return value && typeof value === "object" ? [value] : [];
}

function collectParentIds(laneRelations) {
  const ids = new Set();

  for (const relation of laneRelations) {
    for (const lane of laneValues(relation)) {
      if (typeof lane.parent_lane_id === "string" && lane.parent_lane_id) {
        ids.add(lane.parent_lane_id);
      }
    }
  }

  return [...ids];
}

async function loadParentMap(supabase, laneRelations) {
  const parentIds = collectParentIds(laneRelations);

  if (parentIds.length === 0) return null;

  const { data, error } = await supabase
    .from("shooting_lanes")
    .select(PARENT_LANE_SELECT)
    .in("id", parentIds);

  if (error || !Array.isArray(data)) {
    throw new LaneParentHydrationError("lane_parent_read_failed", {
      cause: error ?? undefined,
    });
  }

  const parents = new Map();

  for (const parent of data) {
    if (parent && typeof parent === "object" && typeof parent.id === "string") {
      parents.set(parent.id, parent);
    }
  }

  for (const parentId of parentIds) {
    if (!parents.has(parentId)) {
      throw new LaneParentHydrationError("lane_parent_missing");
    }
  }

  return parents;
}

function hydrateLaneRelation(relation, parents) {
  const hydrate = (lane) => {
    if (!lane || typeof lane !== "object") return lane;

    if (typeof lane.parent_lane_id !== "string" || !lane.parent_lane_id) {
      return { ...lane, parent_lane: null };
    }

    const parent = parents?.get(lane.parent_lane_id);
    if (!parent) {
      throw new LaneParentHydrationError("lane_parent_missing");
    }

    return { ...lane, parent_lane: parent };
  };

  return Array.isArray(relation) ? relation.map(hydrate) : hydrate(relation);
}

export async function hydrateLaneRows(supabase, lanes) {
  const parents = await loadParentMap(supabase, lanes);
  return lanes.map((lane) => hydrateLaneRelation(lane, parents));
}

export async function hydrateReservationLaneParents(supabase, reservations) {
  const laneRelations = reservations.map((reservation) =>
    reservation && typeof reservation === "object"
      ? reservation.shooting_lanes
      : null,
  );
  const parents = await loadParentMap(supabase, laneRelations);

  return reservations.map((reservation) => {
    if (!reservation || typeof reservation !== "object") return reservation;

    return {
      ...reservation,
      shooting_lanes: hydrateLaneRelation(reservation.shooting_lanes, parents),
    };
  });
}
