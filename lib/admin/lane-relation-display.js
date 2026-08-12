import { buildLaneHierarchyDisplayModel } from "./lane-hierarchy.js";

function singleRelation(value) {
  if (Array.isArray(value)) {
    return value.length === 1 ? value[0] : null;
  }

  return value;
}

export function getLaneRelationDisplay(value) {
  const lane = singleRelation(value);

  if (!lane || typeof lane !== "object") {
    return null;
  }

  const resources = [];

  if (lane.resource_kind === "position") {
    const parent = singleRelation(lane.parent_lane);

    if (!parent || typeof parent !== "object") {
      return null;
    }

    resources.push(parent);
  }

  resources.push(lane);

  const hierarchy = buildLaneHierarchyDisplayModel(resources);

  if (!hierarchy.ok) {
    return null;
  }

  return hierarchy.value.find((resource) => resource.id === lane.id) ?? null;
}
