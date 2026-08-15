function isCapacityResource(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    typeof value.id === "string" &&
    value.id.length > 0 &&
    typeof value.isActive === "boolean" &&
    typeof value.isParent === "boolean" &&
    typeof value.isPosition === "boolean" &&
    (value.parentLaneId === null || typeof value.parentLaneId === "string") &&
    typeof value.onlineBookable === "boolean" &&
    typeof value.wholeLaneBookable === "boolean" &&
    typeof value.positionsBookable === "boolean"
  );
}

/**
 * Maps hierarchy resources to physical capacity units.
 *
 * A root in positions mode represents all usable direct positions instead of
 * an additional unit. This mapping lets consumers union busy ranges per
 * physical unit, so overlapping whole/position data cannot be double-counted.
 */
export function buildEffectiveLaneCapacity(resources) {
  if (!Array.isArray(resources) || resources.some((item) => !isCapacityResource(item))) {
    return { ok: false, code: "invalid_input" };
  }

  const resourcesById = new Map();
  const childrenByParent = new Map();

  for (const resource of resources) {
    if (resourcesById.has(resource.id)) {
      return { ok: false, code: "invalid_input" };
    }
    resourcesById.set(resource.id, resource);
  }

  for (const resource of resources) {
    if (resource.isParent) {
      if (resource.isPosition || resource.parentLaneId !== null) {
        return { ok: false, code: "invalid_input" };
      }
      continue;
    }

    if (!resource.isPosition || !resource.parentLaneId) {
      return { ok: false, code: "invalid_input" };
    }
    const parent = resourcesById.get(resource.parentLaneId);
    if (!parent || !parent.isParent || parent.isPosition) {
      return { ok: false, code: "invalid_input" };
    }
    const siblings = childrenByParent.get(parent.id) ?? [];
    siblings.push(resource);
    childrenByParent.set(parent.id, siblings);
  }

  const unitIds = new Set();
  const unitIdsByResourceId = new Map();

  for (const resource of resources) {
    if (!resource.isParent) continue;

    const children = childrenByParent.get(resource.id) ?? [];
    const usablePositions = children.filter(
      (child) => child.isActive && child.onlineBookable,
    );
    const usesPositionUnits =
      resource.isActive &&
      resource.positionsBookable &&
      usablePositions.length > 0;
    const rootUnits = !resource.isActive
      ? []
      : usesPositionUnits
        ? usablePositions.map((child) => child.id)
        : [resource.id];

    unitIdsByResourceId.set(resource.id, rootUnits);
    for (const unitId of rootUnits) unitIds.add(unitId);

    const usableIds = new Set(rootUnits);
    for (const child of children) {
      unitIdsByResourceId.set(
        child.id,
        !resource.isActive || !child.isActive
          ? []
          : usesPositionUnits
            ? usableIds.has(child.id)
              ? [child.id]
              : []
            : [resource.id],
      );
    }
  }

  if (unitIdsByResourceId.size !== resources.length) {
    return { ok: false, code: "invalid_input" };
  }

  return {
    ok: true,
    effectiveCapacity: unitIds.size,
    unitIds,
    unitIdsByResourceId,
  };
}
