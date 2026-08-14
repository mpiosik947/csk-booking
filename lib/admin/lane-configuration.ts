export const ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION = 1;

export type LaneResourceKind = "lane" | "position";

export type LaneConfigurationDuration = {
  duration_minutes: number;
  display_order: number;
  is_active: boolean;
};

export type LaneConfigurationPricingRule = {
  day_group: "mon_thu" | "fri_sun";
  min_shooters: number;
  max_shooters: number;
  label: string;
  hourly_price: number;
  display_order: number;
  is_active: boolean;
};

export type LaneConfigurationResource = {
  lane_id: string;
  name: string;
  resource_kind: LaneResourceKind;
  parent_lane_id: string | null;
  display_order: number;
  is_active: boolean;
  max_shooters: number;
  whole_lane_bookable: boolean;
  positions_bookable: boolean;
  booking_step_minutes: number;
  currency_code: string;
  online_bookable: boolean;
  max_people_online: number;
  durations: LaneConfigurationDuration[];
  pricing: LaneConfigurationPricingRule[];
};

export type AdminLaneConfigurationSnapshot = {
  contract_version: 1;
  resources: LaneConfigurationResource[];
};

export type LaneConfigurationFamily = {
  root: LaneConfigurationResource;
  children: LaneConfigurationResource[];
};

export type LaneConfigurationSummary = {
  lanes: number;
  positions: number;
  activeResources: number;
  onlineResources: number;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const RESOURCE_KEYS = [
  "lane_id",
  "name",
  "resource_kind",
  "parent_lane_id",
  "display_order",
  "is_active",
  "max_shooters",
  "whole_lane_bookable",
  "positions_bookable",
  "booking_step_minutes",
  "currency_code",
  "online_bookable",
  "max_people_online",
  "durations",
  "pricing",
] as const;

const DURATION_KEYS = ["duration_minutes", "display_order", "is_active"] as const;
const PRICING_KEYS = [
  "day_group",
  "min_shooters",
  "max_shooters",
  "label",
  "hourly_price",
  "display_order",
  "is_active",
] as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  expectedKeys: readonly string[]
) {
  const actualKeys = Object.keys(value).sort();
  const sortedExpected = [...expectedKeys].sort();
  return (
    actualKeys.length === sortedExpected.length &&
    actualKeys.every((key, index) => key === sortedExpected[index])
  );
}

function isInteger(value: unknown, minimum = 0): value is number {
  return Number.isInteger(value) && (value as number) >= minimum;
}

function parseDuration(value: unknown): LaneConfigurationDuration {
  if (!isRecord(value) || !hasExactKeys(value, DURATION_KEYS)) {
    throw new Error("invalid_duration");
  }

  if (
    !isInteger(value.duration_minutes, 1) ||
    !isInteger(value.display_order) ||
    typeof value.is_active !== "boolean"
  ) {
    throw new Error("invalid_duration");
  }

  return {
    duration_minutes: value.duration_minutes,
    display_order: value.display_order,
    is_active: value.is_active,
  };
}

function parsePricingRule(value: unknown): LaneConfigurationPricingRule {
  if (!isRecord(value) || !hasExactKeys(value, PRICING_KEYS)) {
    throw new Error("invalid_pricing");
  }

  if (
    (value.day_group !== "mon_thu" && value.day_group !== "fri_sun") ||
    !isInteger(value.min_shooters, 1) ||
    !isInteger(value.max_shooters, 1) ||
    value.min_shooters > value.max_shooters ||
    typeof value.label !== "string" ||
    value.label.trim() === "" ||
    typeof value.hourly_price !== "number" ||
    !Number.isFinite(value.hourly_price) ||
    value.hourly_price < 0 ||
    !isInteger(value.display_order) ||
    typeof value.is_active !== "boolean"
  ) {
    throw new Error("invalid_pricing");
  }

  return {
    day_group: value.day_group,
    min_shooters: value.min_shooters,
    max_shooters: value.max_shooters,
    label: value.label.trim(),
    hourly_price: value.hourly_price,
    display_order: value.display_order,
    is_active: value.is_active,
  };
}

function parseResource(value: unknown): LaneConfigurationResource {
  if (!isRecord(value) || !hasExactKeys(value, RESOURCE_KEYS)) {
    throw new Error("invalid_resource");
  }

  const parentLaneId = value.parent_lane_id;
  if (
    typeof value.lane_id !== "string" ||
    !UUID_PATTERN.test(value.lane_id) ||
    typeof value.name !== "string" ||
    value.name.trim() === "" ||
    (value.resource_kind !== "lane" && value.resource_kind !== "position") ||
    (parentLaneId !== null &&
      (typeof parentLaneId !== "string" || !UUID_PATTERN.test(parentLaneId))) ||
    !isInteger(value.display_order) ||
    typeof value.is_active !== "boolean" ||
    !isInteger(value.max_shooters, 1) ||
    typeof value.whole_lane_bookable !== "boolean" ||
    typeof value.positions_bookable !== "boolean" ||
    !isInteger(value.booking_step_minutes, 1) ||
    typeof value.currency_code !== "string" ||
    !/^[A-Z]{3}$/.test(value.currency_code) ||
    typeof value.online_bookable !== "boolean" ||
    !isInteger(value.max_people_online, 1) ||
    !Array.isArray(value.durations) ||
    !Array.isArray(value.pricing)
  ) {
    throw new Error("invalid_resource");
  }

  const durations = value.durations.map(parseDuration);
  const pricing = value.pricing.map(parsePricingRule);
  if (
    new Set(durations.map((duration) => duration.duration_minutes)).size !==
    durations.length
  ) {
    throw new Error("duplicate_duration");
  }

  const pricingKeys = pricing.map(
    (rule) =>
      `${rule.day_group}:${rule.min_shooters}:${rule.max_shooters}:${rule.is_active}`
  );
  if (new Set(pricingKeys).size !== pricingKeys.length) {
    throw new Error("duplicate_pricing");
  }

  for (const dayGroup of ["mon_thu", "fri_sun"] as const) {
    const activeRules = pricing
      .filter((rule) => rule.day_group === dayGroup && rule.is_active)
      .sort((first, second) => first.min_shooters - second.min_shooters);
    if (
      activeRules.some(
        (rule, index) =>
          index > 0 && rule.min_shooters <= activeRules[index - 1].max_shooters
      )
    ) {
      throw new Error("overlapping_pricing");
    }
  }

  return {
    lane_id: value.lane_id,
    name: value.name.trim(),
    resource_kind: value.resource_kind,
    parent_lane_id: parentLaneId,
    display_order: value.display_order,
    is_active: value.is_active,
    max_shooters: value.max_shooters,
    whole_lane_bookable: value.whole_lane_bookable,
    positions_bookable: value.positions_bookable,
    booking_step_minutes: value.booking_step_minutes,
    currency_code: value.currency_code,
    online_bookable: value.online_bookable,
    max_people_online: value.max_people_online,
    durations,
    pricing,
  };
}

export function parseAdminLaneConfigurationSnapshot(
  value: unknown
): AdminLaneConfigurationSnapshot {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, ["contract_version", "resources"]) ||
    value.contract_version !== ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION ||
    !Array.isArray(value.resources)
  ) {
    throw new Error("invalid_contract");
  }

  const resources = value.resources.map(parseResource);
  const resourcesById = new Map<string, LaneConfigurationResource>();
  for (const resource of resources) {
    if (resourcesById.has(resource.lane_id)) {
      throw new Error("duplicate_resource");
    }
    resourcesById.set(resource.lane_id, resource);
  }

  for (const resource of resources) {
    if (resource.resource_kind === "lane") {
      if (resource.parent_lane_id !== null) {
        throw new Error("invalid_hierarchy");
      }
      continue;
    }

    const parent = resource.parent_lane_id
      ? resourcesById.get(resource.parent_lane_id)
      : null;
    if (
      !parent ||
      parent.resource_kind !== "lane" ||
      parent.parent_lane_id !== null ||
      parent.lane_id === resource.lane_id
    ) {
      throw new Error("invalid_hierarchy");
    }
  }

  return { contract_version: 1, resources };
}

export function buildLaneConfigurationHierarchy(
  resources: LaneConfigurationResource[]
): LaneConfigurationFamily[] {
  return resources
    .filter((resource) => resource.resource_kind === "lane")
    .map((root) => ({
      root,
      children: resources.filter(
        (resource) =>
          resource.resource_kind === "position" &&
          resource.parent_lane_id === root.lane_id
      ),
    }));
}

export function filterLaneConfigurationHierarchy(
  families: LaneConfigurationFamily[],
  search: string
): LaneConfigurationFamily[] {
  const normalizedSearch = search.trim().toLocaleLowerCase("pl-PL");
  if (!normalizedSearch) return families;

  return families.flatMap((family) => {
    if (family.root.name.toLocaleLowerCase("pl-PL").includes(normalizedSearch)) {
      return [family];
    }
    const matchingChildren = family.children.filter((child) =>
      child.name.toLocaleLowerCase("pl-PL").includes(normalizedSearch)
    );
    return matchingChildren.length > 0
      ? [{ root: family.root, children: matchingChildren }]
      : [];
  });
}

export function getLaneConfigurationSummary(
  resources: LaneConfigurationResource[]
): LaneConfigurationSummary {
  return {
    lanes: resources.filter((resource) => resource.resource_kind === "lane").length,
    positions: resources.filter((resource) => resource.resource_kind === "position")
      .length,
    activeResources: resources.filter((resource) => resource.is_active).length,
    onlineResources: resources.filter((resource) => resource.online_bookable).length,
  };
}
