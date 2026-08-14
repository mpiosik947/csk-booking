export const ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION = 2;

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

export type LaneConfigurationFamily = {
  root_lane_id: string;
  configuration_version: number;
  root: LaneConfigurationResource;
  children: LaneConfigurationResource[];
  resources: LaneConfigurationResource[];
};

export type AdminLaneConfigurationSnapshot = {
  contract_version: 2;
  families: LaneConfigurationFamily[];
  resources: LaneConfigurationResource[];
};

export type LaneConfigurationSummary = {
  lanes: number;
  positions: number;
  activeResources: number;
  onlineResources: number;
};

export type LaneFamilyResourceEdit = {
  lane_id: string;
  max_shooters: string;
  max_people_online: string;
};

export type LaneFamilyEditState = {
  root_online_bookable: boolean;
  root_whole_lane_bookable: boolean;
  root_positions_bookable: boolean;
  resources: LaneFamilyResourceEdit[];
};

export type LaneFamilyWritePricing = {
  day_group: "mon_thu" | "fri_sun";
  min_shooters: number;
  max_shooters: number;
  label: string;
  hourly_price: number;
};

export type LaneFamilyWriteResource = {
  lane_id: string;
  is_active: boolean;
  whole_lane_bookable: boolean;
  positions_bookable: boolean;
  max_shooters: number;
  online_bookable: boolean;
  max_people_online: number;
  durations_minutes: number[];
  pricing: LaneFamilyWritePricing[];
};

export type LaneFamilyChange = {
  resourceName: string;
  label: string;
  before: string;
  after: string;
};

export type LaneFamilyValidation = {
  valid: boolean;
  errors: string[];
};

export const LANE_CONFIGURATION_WRITE_CODES = [
  "updated",
  "no_change",
  "not_allowed",
  "family_not_found",
  "invalid_payload",
  "invalid_hierarchy",
  "invalid_configuration",
  "stale_configuration",
  "confirmation_required",
  "reservation_capacity_conflict",
] as const;

export type LaneConfigurationWriteCode =
  (typeof LANE_CONFIGURATION_WRITE_CODES)[number];

export type LaneConfigurationWriteResult = {
  code: LaneConfigurationWriteCode;
  futureReservationsCount: number;
  futureLaneBlocksCount: number;
  futureEventsCount: number;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

const FAMILY_KEYS = [
  "root_lane_id",
  "configuration_version",
  "resources",
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
  return Number.isSafeInteger(value) && (value as number) >= minimum;
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
    value.max_people_online > value.max_shooters ||
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

function hasCompleteActiveSalesConfiguration(
  resource: LaneConfigurationResource,
  maxPeopleOnline = resource.max_people_online
) {
  const activeDurations = resource.durations.filter((duration) => duration.is_active);
  const activePricing = resource.pricing.filter((rule) => rule.is_active);
  if (activeDurations.length === 0 || activePricing.length === 0) return false;

  return (["mon_thu", "fri_sun"] as const).every((dayGroup) => {
    const rules = activePricing
      .filter((rule) => rule.day_group === dayGroup)
      .sort(
        (first, second) =>
          first.min_shooters - second.min_shooters ||
          first.max_shooters - second.max_shooters
      );
    if (rules.length === 0 || rules[0].min_shooters !== 1) return false;
    if (rules[rules.length - 1].max_shooters !== maxPeopleOnline) return false;
    return rules.every(
      (rule, index) =>
        rule.max_shooters <= maxPeopleOnline &&
        (index === 0 || rule.min_shooters === rules[index - 1].max_shooters + 1)
    );
  });
}

function validateParsedFamily(family: LaneConfigurationFamily) {
  const { root, children } = family;
  if (
    root.lane_id !== family.root_lane_id ||
    root.resource_kind !== "lane" ||
    root.parent_lane_id !== null ||
    children.some(
      (child) =>
        child.resource_kind !== "position" ||
        child.parent_lane_id !== family.root_lane_id ||
        child.whole_lane_bookable ||
        child.positions_bookable
    )
  ) {
    throw new Error("invalid_hierarchy");
  }

  if (
    family.resources.some(
      (resource) =>
        (resource.durations.some(
          (duration) =>
            duration.duration_minutes > 1440 ||
            duration.duration_minutes % resource.booking_step_minutes !== 0
        ) ||
          (resource.pricing.some((rule) => rule.is_active) &&
            !hasCompleteActiveSalesConfiguration(resource)))
    )
  ) {
    throw new Error("invalid_configuration");
  }

  if (
    (root.online_bookable &&
      (!root.is_active ||
        !root.whole_lane_bookable ||
        !hasCompleteActiveSalesConfiguration(root))) ||
    (!root.is_active &&
      children.some((child) => child.is_active || child.online_bookable)) ||
    children.some(
      (child) =>
        child.online_bookable &&
        (!child.is_active ||
          !root.positions_bookable ||
          !hasCompleteActiveSalesConfiguration(child))
    ) ||
    (root.positions_bookable &&
      !children.some(
        (child) =>
          child.is_active &&
          child.online_bookable &&
          hasCompleteActiveSalesConfiguration(child)
      )) ||
    (root.positions_bookable &&
      children
        .filter((child) => child.is_active && child.online_bookable)
        .reduce((total, child) => total + child.max_shooters, 0) >
        root.max_shooters)
  ) {
    throw new Error("invalid_configuration");
  }
}

function parseFamily(value: unknown): LaneConfigurationFamily {
  if (!isRecord(value) || !hasExactKeys(value, FAMILY_KEYS)) {
    throw new Error("invalid_family");
  }
  if (
    typeof value.root_lane_id !== "string" ||
    !UUID_PATTERN.test(value.root_lane_id) ||
    !isInteger(value.configuration_version, 1) ||
    !Array.isArray(value.resources) ||
    value.resources.length === 0
  ) {
    throw new Error("invalid_family");
  }

  const resources = value.resources.map(parseResource);
  if (new Set(resources.map((resource) => resource.lane_id)).size !== resources.length) {
    throw new Error("duplicate_resource");
  }
  const roots = resources.filter((resource) => resource.resource_kind === "lane");
  if (roots.length !== 1) throw new Error("invalid_hierarchy");

  const family: LaneConfigurationFamily = {
    root_lane_id: value.root_lane_id,
    configuration_version: value.configuration_version,
    root: roots[0],
    children: resources.filter((resource) => resource.resource_kind === "position"),
    resources,
  };
  validateParsedFamily(family);
  return family;
}

export function parseAdminLaneConfigurationSnapshot(
  value: unknown
): AdminLaneConfigurationSnapshot {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, ["contract_version", "families"]) ||
    value.contract_version !== ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION ||
    !Array.isArray(value.families)
  ) {
    throw new Error("invalid_contract");
  }

  const families = value.families.map(parseFamily);
  if (new Set(families.map((family) => family.root_lane_id)).size !== families.length) {
    throw new Error("duplicate_family");
  }
  const resources = families.flatMap((family) => family.resources);
  if (new Set(resources.map((resource) => resource.lane_id)).size !== resources.length) {
    throw new Error("duplicate_resource");
  }

  return { contract_version: 2, families, resources };
}

export function buildLaneConfigurationHierarchy(
  snapshot: AdminLaneConfigurationSnapshot
): LaneConfigurationFamily[] {
  return snapshot.families;
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
      ? [{ ...family, children: matchingChildren }]
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

export function createLaneFamilyEditState(
  family: LaneConfigurationFamily
): LaneFamilyEditState {
  return {
    root_online_bookable: family.root.online_bookable,
    root_whole_lane_bookable: family.root.whole_lane_bookable,
    root_positions_bookable: family.root.positions_bookable,
    resources: family.resources.map((resource) => ({
      lane_id: resource.lane_id,
      max_shooters: String(resource.max_shooters),
      max_people_online: String(resource.max_people_online),
    })),
  };
}

function parsePositiveInteger(value: string) {
  return /^[1-9][0-9]*$/.test(value) && Number.isSafeInteger(Number(value))
    ? Number(value)
    : null;
}

function getEditedLimits(family: LaneConfigurationFamily, state: LaneFamilyEditState) {
  if (
    state.resources.length !== family.resources.length ||
    new Set(state.resources.map((resource) => resource.lane_id)).size !==
      state.resources.length
  ) {
    return null;
  }

  const result = new Map<string, { maxShooters: number; maxPeopleOnline: number }>();
  for (const resource of family.resources) {
    const edit = state.resources.find((candidate) => candidate.lane_id === resource.lane_id);
    if (!edit) return null;
    const maxShooters = parsePositiveInteger(edit.max_shooters);
    const maxPeopleOnline = parsePositiveInteger(edit.max_people_online);
    if (maxShooters === null || maxPeopleOnline === null) return null;
    result.set(resource.lane_id, { maxShooters, maxPeopleOnline });
  }
  return result;
}

export function validateLaneFamilyEditState(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): LaneFamilyValidation {
  const errors: string[] = [];
  const limits = getEditedLimits(family, state);
  if (!limits) {
    return {
      valid: false,
      errors: [
        "Pojemność i maksymalna liczba osób w jednej rezerwacji muszą być liczbami całkowitymi co najmniej 1.",
      ],
    };
  }

  for (const resource of family.resources) {
    const edited = limits.get(resource.lane_id)!;
    if (edited.maxPeopleOnline > edited.maxShooters) {
      const capacityName =
        resource.resource_kind === "position" ? "pojemności stanowiska" : "pojemności osi";
      errors.push(
        `${resource.name}: maks. osób w jednej rezerwacji nie może przekraczać ${capacityName}.`
      );
    }
    if (
      resource.pricing.some((rule) => rule.is_active) &&
      !hasCompleteActiveSalesConfiguration(resource, edited.maxPeopleOnline)
    ) {
      errors.push(
        `${resource.name}: Obecny cennik obejmuje rezerwacje dla innej liczby osób. Aby ustawić ten limit, trzeba również dostosować progi cenowe. Edycja cennika będzie dostępna w kolejnym etapie konfiguracji.`
      );
    }
  }

  const rootLimits = limits.get(family.root_lane_id)!;
  if (
    state.root_online_bookable &&
    (!family.root.is_active ||
      !state.root_whole_lane_bookable ||
      !hasCompleteActiveSalesConfiguration(family.root, rootLimits.maxPeopleOnline))
  ) {
    errors.push(
      "Rezerwacja online całej osi wymaga aktywnej osi oraz kompletnego cennika i czasów."
    );
  }

  const usableChildren = family.children.filter(
    (child) =>
      child.is_active &&
      child.online_bookable &&
      hasCompleteActiveSalesConfiguration(
        child,
        limits.get(child.lane_id)!.maxPeopleOnline
      )
  );
  if (state.root_positions_bookable && usableChildren.length === 0) {
    errors.push("Najpierw skonfiguruj co najmniej jedno stanowisko do rezerwacji online.");
  }
  if (
    state.root_positions_bookable &&
    usableChildren.reduce(
      (total, child) => total + limits.get(child.lane_id)!.maxShooters,
      0
    ) > rootLimits.maxShooters
  ) {
    errors.push("Suma pojemności stanowisk online przekracza pojemność osi.");
  }

  return { valid: errors.length === 0, errors: [...new Set(errors)] };
}

export function buildLaneFamilyWritePayload(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): LaneFamilyWriteResource[] {
  const validation = validateLaneFamilyEditState(family, state);
  const limits = getEditedLimits(family, state);
  if (!validation.valid || !limits) throw new Error("invalid_edit_state");

  return family.resources
    .map((resource) => {
      const edited = limits.get(resource.lane_id)!;
      const isRoot = resource.lane_id === family.root_lane_id;
      return {
        lane_id: resource.lane_id,
        is_active: resource.is_active,
        whole_lane_bookable: isRoot
          ? state.root_whole_lane_bookable
          : resource.whole_lane_bookable,
        positions_bookable: isRoot
          ? state.root_positions_bookable
          : resource.positions_bookable,
        max_shooters: edited.maxShooters,
        online_bookable: isRoot
          ? state.root_online_bookable
          : resource.online_bookable,
        max_people_online: edited.maxPeopleOnline,
        durations_minutes: resource.durations
          .filter((duration) => duration.is_active)
          .map((duration) => duration.duration_minutes)
          .sort((first, second) => first - second),
        pricing: resource.pricing
          .filter((rule) => rule.is_active)
          .map((rule) => ({
            day_group: rule.day_group,
            min_shooters: rule.min_shooters,
            max_shooters: rule.max_shooters,
            label: rule.label,
            hourly_price: rule.hourly_price,
          }))
          .sort(
            (first, second) =>
              first.day_group.localeCompare(second.day_group) ||
              first.min_shooters - second.min_shooters ||
              first.max_shooters - second.max_shooters ||
              first.label.localeCompare(second.label, "pl-PL")
          ),
      };
    })
    .sort((first, second) => first.lane_id.localeCompare(second.lane_id));
}

function yesNo(value: boolean) {
  return value ? "Tak" : "Nie";
}

export function getLaneFamilyChanges(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): LaneFamilyChange[] {
  const changes: LaneFamilyChange[] = [];
  const limits = getEditedLimits(family, state);
  if (!limits) return changes;

  const rootBooleanChanges = [
    ["Rezerwacja online", family.root.online_bookable, state.root_online_bookable],
    [
      "Rezerwacja całej osi",
      family.root.whole_lane_bookable,
      state.root_whole_lane_bookable,
    ],
    [
      "Rezerwacja stanowisk",
      family.root.positions_bookable,
      state.root_positions_bookable,
    ],
  ] as const;
  for (const [label, before, after] of rootBooleanChanges) {
    if (before !== after) {
      changes.push({
        resourceName: family.root.name,
        label,
        before: yesNo(before),
        after: yesNo(after),
      });
    }
  }

  for (const resource of family.resources) {
    const edited = limits.get(resource.lane_id)!;
    if (edited.maxShooters !== resource.max_shooters) {
      changes.push({
        resourceName: resource.name,
        label:
          resource.resource_kind === "position"
            ? "Pojemność stanowiska"
            : "Pojemność osi",
        before: String(resource.max_shooters),
        after: String(edited.maxShooters),
      });
    }
    if (edited.maxPeopleOnline !== resource.max_people_online) {
      changes.push({
        resourceName: resource.name,
        label: "Maks. osób w jednej rezerwacji",
        before: String(resource.max_people_online),
        after: String(edited.maxPeopleOnline),
      });
    }
  }
  return changes;
}

export function isLaneFamilyDirty(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
) {
  const original = createLaneFamilyEditState(family);
  if (
    state.root_online_bookable !== original.root_online_bookable ||
    state.root_whole_lane_bookable !== original.root_whole_lane_bookable ||
    state.root_positions_bookable !== original.root_positions_bookable ||
    state.resources.length !== original.resources.length
  ) {
    return true;
  }
  return state.resources.some((resource, index) => {
    const originalResource = original.resources[index];
    return (
      !originalResource ||
      resource.lane_id !== originalResource.lane_id ||
      resource.max_shooters !== originalResource.max_shooters ||
      resource.max_people_online !== originalResource.max_people_online
    );
  });
}

function parseCount(value: unknown) {
  return isInteger(value) ? value : null;
}

export function parseLaneConfigurationWriteResult(
  value: unknown
): LaneConfigurationWriteResult {
  if (!isRecord(value) || typeof value.code !== "string") {
    throw new Error("invalid_write_result");
  }
  if (!(LANE_CONFIGURATION_WRITE_CODES as readonly string[]).includes(value.code)) {
    throw new Error("unknown_write_code");
  }

  const successfulCode = value.code === "updated" || value.code === "no_change";
  if (
    typeof value.ok !== "boolean" ||
    typeof value.changed !== "boolean" ||
    (successfulCode && !value.ok) ||
    (!successfulCode && value.ok) ||
    (value.code === "updated" && !value.changed) ||
    (value.code !== "updated" && value.changed)
  ) {
    throw new Error("invalid_write_result");
  }

  if (value.code === "confirmation_required") {
    const futureReservationsCount = parseCount(value.future_reservations_count);
    const futureLaneBlocksCount = parseCount(value.future_lane_blocks_count);
    const futureEventsCount = parseCount(value.future_events_count);
    if (
      futureReservationsCount === null ||
      futureLaneBlocksCount === null ||
      futureEventsCount === null
    ) {
      throw new Error("invalid_write_result");
    }
    return {
      code: value.code,
      futureReservationsCount,
      futureLaneBlocksCount,
      futureEventsCount,
    };
  }

  return {
    code: value.code as LaneConfigurationWriteCode,
    futureReservationsCount: 0,
    futureLaneBlocksCount: 0,
    futureEventsCount: 0,
  };
}
