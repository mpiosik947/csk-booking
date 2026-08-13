import { buildLaneHierarchyDisplayModel } from "./lane-hierarchy.js";

function singleRelation(value) {
  if (Array.isArray(value)) {
    return value.length === 1 ? value[0] : null;
  }

  return value;
}

function withPresentationDefaults(value) {
  return {
    ...value,
    display_order:
      typeof value.display_order === "number" ? value.display_order : 0,
    is_active: typeof value.is_active === "boolean" ? value.is_active : false,
  };
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

    resources.push(withPresentationDefaults(parent));
  }

  resources.push(withPresentationDefaults(lane));

  const hierarchy = buildLaneHierarchyDisplayModel(resources);

  if (!hierarchy.ok) {
    return null;
  }

  return hierarchy.value.find((resource) => resource.id === lane.id) ?? null;
}
