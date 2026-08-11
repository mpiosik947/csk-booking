const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function normalizeResource(value) {
  if (!isRecord(value)) {
    return null;
  }

  const id = typeof value.id === "string" ? value.id : "";
  const name = typeof value.name === "string" ? value.name.trim() : "";
  const resourceKind = value.resource_kind;
  const parentLaneId = value.parent_lane_id;
  const displayOrder = value.display_order;
  const isActive = value.is_active;

  if (
    !UUID_PATTERN.test(id) ||
    !name ||
    (resourceKind !== "lane" && resourceKind !== "position") ||
    (parentLaneId !== null &&
      (typeof parentLaneId !== "string" || !UUID_PATTERN.test(parentLaneId))) ||
    typeof displayOrder !== "number" ||
    !Number.isInteger(displayOrder) ||
    typeof isActive !== "boolean"
  ) {
    return null;
  }

  return {
    id,
    name,
    resourceKind,
    parentLaneId,
    displayOrder,
    isActive,
  };
}

function compareResources(first, second) {
  if (first.displayOrder !== second.displayOrder) {
    return first.displayOrder - second.displayOrder;
  }

  const nameComparison = first.name.localeCompare(second.name, "pl");
  return nameComparison !== 0
    ? nameComparison
    : first.id.localeCompare(second.id);
}

export function buildLaneHierarchyDisplayModel(value) {
  if (!Array.isArray(value)) {
    return { ok: false, code: "invalid_input" };
  }

  const resourcesById = new Map();

  for (const candidate of value) {
    const resource = normalizeResource(candidate);

    if (!resource) {
      return { ok: false, code: "invalid_resource" };
    }

    if (resourcesById.has(resource.id)) {
      return { ok: false, code: "duplicate_id" };
    }

    resourcesById.set(resource.id, resource);
  }

  const roots = [];
  const childrenByParent = new Map();

  for (const resource of resourcesById.values()) {
    if (resource.resourceKind === "lane") {
      if (resource.parentLaneId !== null) {
        return { ok: false, code: "invalid_hierarchy" };
      }

      roots.push(resource);
      continue;
    }

    if (resource.parentLaneId === null || resource.parentLaneId === resource.id) {
      return { ok: false, code: "invalid_hierarchy" };
    }

    const parent = resourcesById.get(resource.parentLaneId);

    if (!parent) {
      return { ok: false, code: "missing_parent" };
    }

    if (parent.resourceKind !== "lane" || parent.parentLaneId !== null) {
      return { ok: false, code: "unsupported_depth" };
    }

    const siblings = childrenByParent.get(parent.id) ?? [];
    siblings.push(resource);
    childrenByParent.set(parent.id, siblings);
  }

  roots.sort(compareResources);
  const displayItems = [];

  for (const root of roots) {
    displayItems.push({
      ...root,
      displayName: root.name,
      parentName: null,
      depth: 0,
      isParent: true,
      isPosition: false,
    });

    const children = childrenByParent.get(root.id) ?? [];
    children.sort(compareResources);

    for (const child of children) {
      displayItems.push({
        ...child,
        displayName: `${root.name} — ${child.name}`,
        parentName: root.name,
        depth: 1,
        isParent: false,
        isPosition: true,
      });
    }
  }

  if (displayItems.length !== resourcesById.size) {
    return { ok: false, code: "invalid_hierarchy" };
  }

  return { ok: true, value: displayItems };
}
