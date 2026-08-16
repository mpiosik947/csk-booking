export const ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION = 2;
export const LANE_RESOURCE_NAME_MAX_LENGTH = 120;

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
  name: string;
  is_active: boolean;
  online_bookable: boolean;
  max_shooters: string;
  max_people_online: string;
  durations_minutes: string[];
  pricing: LaneFamilyPricingEdit[];
};

export type LaneFamilyPricingEdit = {
  edit_key: string;
  day_group: "mon_thu" | "fri_sun";
  min_shooters: string;
  max_shooters: string;
  label: string;
  hourly_price: string;
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
  name: string;
  is_active: boolean;
  whole_lane_bookable: boolean;
  positions_bookable: boolean;
  max_shooters: number;
  online_bookable: boolean;
  max_people_online: number;
  durations_minutes: number[];
  pricing: LaneFamilyWritePricing[];
};

export type LaneFamilyCreateResourceEdit = {
  edit_key: string;
  name: string;
  is_active: boolean;
  online_bookable: boolean;
  max_shooters: string;
  max_people_online: string;
  booking_step_minutes: string;
  durations_minutes: string[];
  pricing: LaneFamilyPricingEdit[];
};

export type LaneFamilyCreateState = {
  root_whole_lane_bookable: boolean;
  root_positions_bookable: boolean;
  root: LaneFamilyCreateResourceEdit;
  positions: LaneFamilyCreateResourceEdit[];
};

export type LaneFamilyCreateWriteResource = {
  name: string;
  is_active: boolean;
  online_bookable: boolean;
  max_shooters: number;
  max_people_online: number;
  booking_step_minutes: number;
  durations_minutes: number[];
  pricing: LaneFamilyWritePricing[];
};

export type LaneFamilyCreateWritePayload = {
  root: LaneFamilyCreateWriteResource & {
    whole_lane_bookable: boolean;
    positions_bookable: boolean;
  };
  positions: LaneFamilyCreateWriteResource[];
};

export type LaneFamilyCreateResult = {
  code: "created" | "not_allowed" | "invalid_payload" | "invalid_configuration";
  rootLaneId: string | null;
  configurationVersion: number | null;
  createdResourceCount: number;
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

export type LanePositionReadiness = {
  ready: boolean;
  missing: string[];
};

export type LaneFamilyPositionSummary = {
  positions: number;
  ready: number;
  active: number;
  online: number;
};

export type LanePositionBulkActivationItem = {
  lane_id: string;
  name: string;
  reasons: string[];
};

export type LanePositionBulkActivationPlan = {
  eligiblePositions: LanePositionBulkActivationItem[];
  positionsToActivate: LanePositionBulkActivationItem[];
  skippedPositions: LanePositionBulkActivationItem[];
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

  const activePricingKeys = pricing
    .filter((rule) => rule.is_active)
    .map(
    (rule) =>
      `${rule.day_group}:${rule.min_shooters}:${rule.max_shooters}`
    );
  if (new Set(activePricingKeys).size !== activePricingKeys.length) {
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
      name: resource.name,
      is_active: resource.is_active,
      online_bookable: resource.online_bookable,
      max_shooters: String(resource.max_shooters),
      max_people_online: String(resource.max_people_online),
      durations_minutes: resource.durations
        .filter((duration) => duration.is_active)
        .map((duration) => String(duration.duration_minutes))
        .sort((first, second) => Number(first) - Number(second)),
      pricing: resource.pricing
        .filter((rule) => rule.is_active)
        .sort(
          (first, second) =>
            first.day_group.localeCompare(second.day_group) ||
            first.min_shooters - second.min_shooters ||
            first.max_shooters - second.max_shooters ||
            first.label.localeCompare(second.label, "pl-PL")
        )
        .map((rule, index) => ({
          edit_key: `${resource.lane_id}:pricing:${index}`,
          day_group: rule.day_group,
          min_shooters: String(rule.min_shooters),
          max_shooters: String(rule.max_shooters),
          label: rule.label,
          hourly_price: String(rule.hourly_price),
        })),
    })),
  };
}

export function copyLanePositionEditSettings(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState,
  sourceLaneId: string,
  targetLaneIds: string[]
): LaneFamilyEditState {
  const positionIds = new Set(family.children.map((child) => child.lane_id));
  const uniqueTargetIds = [...new Set(targetLaneIds)];
  if (
    !positionIds.has(sourceLaneId) ||
    uniqueTargetIds.length === 0 ||
    uniqueTargetIds.some(
      (laneId) => laneId === sourceLaneId || !positionIds.has(laneId)
    )
  ) {
    throw new Error("invalid_copy_target");
  }

  const source = state.resources.find(
    (resource) => resource.lane_id === sourceLaneId
  );
  if (!source) throw new Error("invalid_copy_source");

  const targetSet = new Set(uniqueTargetIds);
  return {
    ...state,
    resources: state.resources.map((resource) => {
      if (!targetSet.has(resource.lane_id)) return resource;
      return {
        ...resource,
        max_shooters: source.max_shooters,
        max_people_online: source.max_people_online,
        durations_minutes: [...source.durations_minutes],
        pricing: source.pricing.map((rule, index) => ({
          ...rule,
          edit_key: `${resource.lane_id}:copied:${rule.day_group}:${index}`,
        })),
      };
    }),
  };
}

function parsePositiveInteger(value: string) {
  return /^[1-9][0-9]*$/.test(value) && Number.isSafeInteger(Number(value))
    ? Number(value)
    : null;
}

function parseMoney(value: string) {
  const normalized = value.trim().replace(",", ".");
  if (!/^[0-9]+(?:\.[0-9]{1,2})?$/.test(normalized)) return null;
  const parsed = Number(normalized);
  return Number.isFinite(parsed) && parsed <= 9999999999.99 ? parsed : null;
}

function createDefaultPricing(editKey: string): LaneFamilyPricingEdit[] {
  return (["mon_thu", "fri_sun"] as const).map((dayGroup) => ({
    edit_key: `${editKey}:pricing:${dayGroup}:1`,
    day_group: dayGroup,
    min_shooters: "1",
    max_shooters: "1",
    label: "1 osoba",
    hourly_price: "",
  }));
}

function createEmptyCreateResource(
  editKey: string,
  name: string
): LaneFamilyCreateResourceEdit {
  return {
    edit_key: editKey,
    name,
    is_active: false,
    online_bookable: false,
    max_shooters: "1",
    max_people_online: "1",
    booking_step_minutes: "60",
    durations_minutes: ["60"],
    pricing: createDefaultPricing(editKey),
  };
}

export function createInitialLaneFamilyCreateState(): LaneFamilyCreateState {
  return {
    root_whole_lane_bookable: true,
    root_positions_bookable: false,
    root: createEmptyCreateResource("root", ""),
    positions: [],
  };
}

export function addPositionToLaneFamilyCreateState(
  state: LaneFamilyCreateState
): LaneFamilyCreateState {
  const nextNumber =
    state.positions.reduce((highest, position) => {
      const match = /^position:(\d+)$/.exec(position.edit_key);
      return match ? Math.max(highest, Number(match[1])) : highest;
    }, 0) + 1;
  const editKey = `position:${nextNumber}`;
  return {
    ...state,
    positions: [
      ...state.positions,
      createEmptyCreateResource(editKey, `Stanowisko ${nextNumber}`),
    ],
  };
}

export function removePositionFromLaneFamilyCreateState(
  state: LaneFamilyCreateState,
  editKey: string
): LaneFamilyCreateState {
  return {
    ...state,
    positions: state.positions.filter((position) => position.edit_key !== editKey),
  };
}

type ParsedLaneFamilyResourceEdit = {
  name: string;
  isActive: boolean;
  onlineBookable: boolean;
  maxShooters: number;
  maxPeopleOnline: number;
  durationsMinutes: number[];
  pricing: LaneFamilyWritePricing[];
};

type ParsedLaneFamilyEditState = {
  values: Map<string, ParsedLaneFamilyResourceEdit>;
  errors: string[];
};

const DAY_GROUPS = ["mon_thu", "fri_sun"] as const;

function dayGroupLabel(dayGroup: LaneFamilyWritePricing["day_group"]) {
  return dayGroup === "mon_thu" ? "Pon–Czw" : "Pt–Nd";
}

function sortPricing(first: LaneFamilyWritePricing, second: LaneFamilyWritePricing) {
  return (
    first.day_group.localeCompare(second.day_group) ||
    first.min_shooters - second.min_shooters ||
    first.max_shooters - second.max_shooters ||
    first.label.localeCompare(second.label, "pl-PL")
  );
}

function hasCompletePricingCoverage(
  pricing: LaneFamilyWritePricing[],
  maxPeopleOnline: number
) {
  return DAY_GROUPS.every((dayGroup) => {
    const rules = pricing
      .filter((rule) => rule.day_group === dayGroup)
      .sort(sortPricing);
    return (
      rules.length > 0 &&
      rules[0].min_shooters === 1 &&
      rules[rules.length - 1].max_shooters === maxPeopleOnline &&
      rules.every(
        (rule, index) =>
          rule.max_shooters <= maxPeopleOnline &&
          (index === 0 || rule.min_shooters === rules[index - 1].max_shooters + 1)
      )
    );
  });
}

function pricingCoverageErrors(
  resourceName: string,
  pricing: LaneFamilyWritePricing[],
  maxPeopleOnline: number
) {
  const errors: string[] = [];
  for (const dayGroup of DAY_GROUPS) {
    const label = dayGroupLabel(dayGroup);
    const rules = pricing
      .filter((rule) => rule.day_group === dayGroup)
      .sort(sortPricing);
    if (rules.length === 0) {
      errors.push(`${resourceName}: brak cennika ${label}.`);
      continue;
    }
    let previousMax = 0;
    for (const rule of rules) {
      if (rule.min_shooters <= previousMax) {
        errors.push(`${resourceName}: progi cennika ${label} nakładają się.`);
      } else if (rule.min_shooters !== previousMax + 1) {
        errors.push(`${resourceName}: cennik ${label} zawiera lukę w liczbie osób.`);
      }
      previousMax = Math.max(previousMax, rule.max_shooters);
    }
    if (previousMax !== maxPeopleOnline) {
      errors.push(
        `${resourceName}: dostosuj cennik ${label} do nowego maksymalnego limitu osób.`
      );
    }
  }
  return errors;
}

type ParsedLaneFamilyCreateResource = {
  name: string;
  isActive: boolean;
  onlineBookable: boolean;
  maxShooters: number;
  maxPeopleOnline: number;
  bookingStepMinutes: number;
  durationsMinutes: number[];
  pricing: LaneFamilyWritePricing[];
};

function parseLaneFamilyCreateResource(
  resource: LaneFamilyCreateResourceEdit,
  resourceLabel: string
): { value: ParsedLaneFamilyCreateResource | null; errors: string[] } {
  const errors: string[] = [];
  const name = typeof resource.name === "string" ? resource.name.trim() : "";
  if (
    name === "" ||
    name.length > LANE_RESOURCE_NAME_MAX_LENGTH ||
    /[<>\u0000-\u001f\u007f]/u.test(name)
  ) {
    errors.push(
      `${resourceLabel}: nazwa musi mieć od 1 do ${LANE_RESOURCE_NAME_MAX_LENGTH} znaków i nie może zawierać znaczników HTML ani znaków sterujących.`
    );
  }

  const maxShooters = parsePositiveInteger(resource.max_shooters);
  const maxPeopleOnline = parsePositiveInteger(resource.max_people_online);
  const bookingStepMinutes = parsePositiveInteger(resource.booking_step_minutes);
  if (maxShooters === null || maxPeopleOnline === null) {
    errors.push(`${resourceLabel}: oba limity muszą być liczbami całkowitymi co najmniej 1.`);
  } else if (maxPeopleOnline > maxShooters) {
    errors.push(
      `${resourceLabel}: maks. osób w jednej rezerwacji nie może przekraczać pojemności zasobu.`
    );
  }
  if (bookingStepMinutes === null || bookingStepMinutes > 1440) {
    errors.push(`${resourceLabel}: krok rezerwacji musi wynosić od 1 do 1440 minut.`);
  }

  const durationsMinutes: number[] = [];
  for (const duration of resource.durations_minutes) {
    const parsed = parsePositiveInteger(duration);
    if (
      parsed === null ||
      parsed > 1440 ||
      bookingStepMinutes === null ||
      parsed % bookingStepMinutes !== 0
    ) {
      errors.push(
        `${resourceLabel}: każdy czas musi wynosić 1–1440 minut i być podzielny przez krok rezerwacji.`
      );
    } else {
      durationsMinutes.push(parsed);
    }
  }
  if (durationsMinutes.length === 0) {
    errors.push(`${resourceLabel}: dodaj co najmniej jeden czas rezerwacji.`);
  }
  if (new Set(durationsMinutes).size !== durationsMinutes.length) {
    errors.push(`${resourceLabel}: ten sam czas rezerwacji występuje więcej niż raz.`);
  }

  const pricing: LaneFamilyWritePricing[] = [];
  for (const rule of resource.pricing) {
    const minShooters = parsePositiveInteger(rule.min_shooters);
    const maxRuleShooters = parsePositiveInteger(rule.max_shooters);
    const hourlyPrice = parseMoney(rule.hourly_price);
    const label = rule.label.trim();
    if (
      minShooters === null ||
      maxRuleShooters === null ||
      maxRuleShooters < minShooters
    ) {
      errors.push(`${resourceLabel}: zakres liczby osób w cenniku jest nieprawidłowy.`);
      continue;
    }
    if (!label) {
      errors.push(`${resourceLabel}: opis progu cenowego nie może być pusty.`);
      continue;
    }
    if (hourlyPrice === null) {
      errors.push(
        `${resourceLabel}: cena musi być nieujemna i mieć maksymalnie 2 miejsca po przecinku.`
      );
      continue;
    }
    pricing.push({
      day_group: rule.day_group,
      min_shooters: minShooters,
      max_shooters: maxRuleShooters,
      label,
      hourly_price: hourlyPrice,
    });
  }

  if (maxPeopleOnline !== null) {
    errors.push(...pricingCoverageErrors(resourceLabel, pricing, maxPeopleOnline));
  }

  if (
    errors.length > 0 ||
    maxShooters === null ||
    maxPeopleOnline === null ||
    bookingStepMinutes === null
  ) {
    return { value: null, errors: [...new Set(errors)] };
  }

  return {
    errors: [],
    value: {
      name,
      isActive: resource.is_active,
      onlineBookable: resource.online_bookable,
      maxShooters,
      maxPeopleOnline,
      bookingStepMinutes,
      durationsMinutes: [...durationsMinutes].sort((first, second) => first - second),
      pricing: pricing.sort(sortPricing),
    },
  };
}

function parseLaneFamilyCreateState(state: LaneFamilyCreateState) {
  const root = parseLaneFamilyCreateResource(state.root, "Oś główna");
  const positionKeys = new Set<string>();
  const positions = state.positions.map((position, index) => {
    if (positionKeys.has(position.edit_key)) {
      return {
        value: null,
        errors: [`Stanowisko ${index + 1}: wykryto zduplikowany klucz formularza.`],
      };
    }
    positionKeys.add(position.edit_key);
    return parseLaneFamilyCreateResource(position, `Stanowisko ${index + 1}`);
  });
  return {
    root: root.value,
    positions: positions.map((position) => position.value),
    errors: [...root.errors, ...positions.flatMap((position) => position.errors)],
  };
}

export function validateLaneFamilyCreateState(
  state: LaneFamilyCreateState
): LaneFamilyValidation {
  const parsed = parseLaneFamilyCreateState(state);
  const errors = [...parsed.errors];
  const root = parsed.root;
  const positions = parsed.positions.filter(
    (position): position is ParsedLaneFamilyCreateResource => position !== null
  );

  if (root) {
    if (root.onlineBookable && (!root.isActive || !state.root_whole_lane_bookable)) {
      errors.push(
        "Rezerwacja online całej osi wymaga aktywnej osi i włączonej rezerwacji całej osi."
      );
    }
    if (
      !root.isActive &&
      (root.onlineBookable ||
        positions.some((position) => position.isActive || position.onlineBookable))
    ) {
      errors.push("Nieaktywna oś nie może mieć aktywnych ani dostępnych online stanowisk.");
    }
    if (
      positions.some(
        (position) =>
          position.onlineBookable &&
          (!position.isActive || !state.root_positions_bookable)
      )
    ) {
      errors.push(
        "Stanowisko online wymaga aktywnego statusu i włączonej rezerwacji stanowisk."
      );
    }
    if (
      state.root_positions_bookable &&
      !positions.some((position) => position.isActive && position.onlineBookable)
    ) {
      errors.push(
        "Rezerwacja stanowisk wymaga co najmniej jednego aktywnego stanowiska online."
      );
    }
    const positionCapacity = positions
      .filter((position) => position.isActive && position.onlineBookable)
      .reduce((total, position) => total + position.maxShooters, 0);
    if (state.root_positions_bookable && positionCapacity > root.maxShooters) {
      errors.push("Suma pojemności stanowisk online przekracza pojemność osi.");
    }
  }

  return { valid: errors.length === 0, errors: [...new Set(errors)] };
}

function toCreateWriteResource(
  resource: ParsedLaneFamilyCreateResource
): LaneFamilyCreateWriteResource {
  return {
    name: resource.name,
    is_active: resource.isActive,
    online_bookable: resource.onlineBookable,
    max_shooters: resource.maxShooters,
    max_people_online: resource.maxPeopleOnline,
    booking_step_minutes: resource.bookingStepMinutes,
    durations_minutes: resource.durationsMinutes,
    pricing: resource.pricing,
  };
}

export function buildLaneFamilyCreatePayload(
  state: LaneFamilyCreateState
): LaneFamilyCreateWritePayload {
  const validation = validateLaneFamilyCreateState(state);
  const parsed = parseLaneFamilyCreateState(state);
  if (
    !validation.valid ||
    !parsed.root ||
    parsed.positions.some((position) => position === null)
  ) {
    throw new Error("invalid_create_state");
  }
  return {
    root: {
      ...toCreateWriteResource(parsed.root),
      whole_lane_bookable: state.root_whole_lane_bookable,
      positions_bookable: state.root_positions_bookable,
    },
    positions: parsed.positions.map((position) =>
      toCreateWriteResource(position as ParsedLaneFamilyCreateResource)
    ),
  };
}

function parseLaneFamilyEditState(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): ParsedLaneFamilyEditState {
  const errors: string[] = [];
  const values = new Map<string, ParsedLaneFamilyResourceEdit>();
  if (
    state.resources.length !== family.resources.length ||
    new Set(state.resources.map((resource) => resource.lane_id)).size !==
      state.resources.length
  ) {
    return {
      values,
      errors: ["Nie udało się odtworzyć pełnej konfiguracji rodziny osi."],
    };
  }

  for (const resource of family.resources) {
    const edit = state.resources.find((candidate) => candidate.lane_id === resource.lane_id);
    if (!edit) {
      errors.push(`${resource.name}: brak ustawień zasobu w formularzu.`);
      continue;
    }
    if (
      typeof edit.is_active !== "boolean" ||
      typeof edit.online_bookable !== "boolean"
    ) {
      errors.push(`${resource.name}: status zasobu jest nieprawidłowy.`);
      continue;
    }
    const trimmedName = typeof edit.name === "string" ? edit.name.trim() : "";
    if (
      trimmedName === "" ||
      trimmedName.length > LANE_RESOURCE_NAME_MAX_LENGTH ||
      /[<>\u0000-\u001f\u007f]/u.test(trimmedName)
    ) {
      const label = resource.resource_kind === "position" ? "Nazwa stanowiska" : "Nazwa osi";
      errors.push(
        `${resource.name}: ${label.toLocaleLowerCase("pl-PL")} musi mieć od 1 do ${LANE_RESOURCE_NAME_MAX_LENGTH} znaków i nie może zawierać znaczników HTML.`
      );
      continue;
    }
    const maxShooters = parsePositiveInteger(edit.max_shooters);
    const maxPeopleOnline = parsePositiveInteger(edit.max_people_online);
    if (maxShooters === null || maxPeopleOnline === null) {
      errors.push(
        `${resource.name}: pojemność i maksymalna liczba osób w jednej rezerwacji muszą być liczbami całkowitymi co najmniej 1.`
      );
      continue;
    }
    if (maxPeopleOnline > maxShooters) {
      const capacityName =
        resource.resource_kind === "position" ? "pojemności stanowiska" : "pojemności osi";
      errors.push(
        `${resource.name}: maks. osób w jednej rezerwacji nie może przekraczać ${capacityName}.`
      );
    }

    const durationsMinutes: number[] = [];
    let durationsValid = true;
    for (const duration of edit.durations_minutes) {
      const parsed = parsePositiveInteger(duration);
      if (parsed === null || parsed > 1440) {
        errors.push(`${resource.name}: czas rezerwacji musi być liczbą od 1 do 1440 minut.`);
        durationsValid = false;
        continue;
      }
      if (parsed % resource.booking_step_minutes !== 0) {
        errors.push(
          `${resource.name}: czas rezerwacji musi być podzielny przez krok ${resource.booking_step_minutes} min.`
        );
        durationsValid = false;
      }
      durationsMinutes.push(parsed);
    }
    if (new Set(durationsMinutes).size !== durationsMinutes.length) {
      errors.push(`${resource.name}: ten czas rezerwacji został dodany więcej niż raz.`);
      durationsValid = false;
    }
    durationsMinutes.sort((first, second) => first - second);

    const pricing: LaneFamilyWritePricing[] = [];
    let pricingRowsValid = true;
    for (const rule of edit.pricing) {
      const minShooters = parsePositiveInteger(rule.min_shooters);
      const maxShootersRule = parsePositiveInteger(rule.max_shooters);
      const hourlyPrice = parseMoney(rule.hourly_price);
      const trimmedLabel = rule.label.trim();
      if (minShooters === null || maxShootersRule === null || minShooters > maxShootersRule) {
        errors.push(`${resource.name}: zakres liczby osób w cenniku jest nieprawidłowy.`);
        pricingRowsValid = false;
      }
      if (trimmedLabel === "") {
        errors.push(`${resource.name}: opis / nazwa progu cenowego nie może być pusta.`);
        pricingRowsValid = false;
      }
      if (hourlyPrice === null) {
        errors.push(
          `${resource.name}: cena za godzinę musi być nieujemną liczbą z maksymalnie 2 miejscami po przecinku.`
        );
        pricingRowsValid = false;
      }
      if (
        minShooters !== null &&
        maxShootersRule !== null &&
        minShooters <= maxShootersRule &&
        trimmedLabel !== "" &&
        hourlyPrice !== null
      ) {
        pricing.push({
          day_group: rule.day_group,
          min_shooters: minShooters,
          max_shooters: maxShootersRule,
          label: trimmedLabel,
          hourly_price: hourlyPrice,
        });
      }
    }
    pricing.sort(sortPricing);

    const onlineBookable =
      resource.lane_id === family.root_lane_id
        ? state.root_online_bookable
        : edit.online_bookable;
    if (onlineBookable && durationsMinutes.length === 0) {
      errors.push(`${resource.name}: rezerwacja online wymaga co najmniej jednego czasu.`);
    }
    if (pricingRowsValid) {
      if (pricing.length === 0 && onlineBookable) {
        errors.push(`${resource.name}: brak cennika Pon–Czw.`);
        errors.push(`${resource.name}: brak cennika Pt–Nd.`);
      } else if (pricing.length > 0) {
        errors.push(...pricingCoverageErrors(resource.name, pricing, maxPeopleOnline));
      }
    }

    if (durationsValid && pricingRowsValid) {
      values.set(resource.lane_id, {
        name: trimmedName,
        isActive: edit.is_active,
        onlineBookable: edit.online_bookable,
        maxShooters,
        maxPeopleOnline,
        durationsMinutes,
        pricing,
      });
    }
  }

  return { values, errors };
}

export function getLanePositionReadiness(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState,
  laneId: string
): LanePositionReadiness {
  const position = family.children.find((child) => child.lane_id === laneId);
  if (!position) {
    return { ready: false, missing: ["Nie znaleziono stanowiska w tej rodzinie."] };
  }

  const parsed = parseLaneFamilyEditState(family, state);
  const values = parsed.values.get(laneId);
  const positionErrors = parsed.errors
    .filter((error) => error.startsWith(`${position.name}:`))
    .map((error) => error.slice(position.name.length + 1).trim());
  const missing = new Set(positionErrors);

  if (!values) {
    if (missing.size === 0) {
      missing.add("Uzupełnij poprawne limity, czasy i cennik.");
    }
    return { ready: false, missing: [...missing] };
  }
  if (values.durationsMinutes.length === 0) {
    missing.add("Dodaj co najmniej jeden poprawny czas rezerwacji.");
  }
  if (!hasCompletePricingCoverage(values.pricing, values.maxPeopleOnline)) {
    missing.add("Uzupełnij cennik Pon–Czw i Pt–Nd dla pełnego zakresu osób.");
  }

  return { ready: missing.size === 0, missing: [...missing] };
}

export function getLaneFamilyPositionSummary(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): LaneFamilyPositionSummary {
  const edits = new Map(
    state.resources.map((resource) => [resource.lane_id, resource])
  );
  return {
    positions: family.children.length,
    ready: family.children.filter(
      (child) => getLanePositionReadiness(family, state, child.lane_id).ready
    ).length,
    active: family.children.filter((child) => edits.get(child.lane_id)?.is_active)
      .length,
    online: family.children.filter(
      (child) => edits.get(child.lane_id)?.online_bookable
    ).length,
  };
}

export function getLanePositionBulkActivationPlan(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): LanePositionBulkActivationPlan {
  const edits = new Map(
    state.resources.map((resource) => [resource.lane_id, resource])
  );
  const eligiblePositions: LanePositionBulkActivationItem[] = [];
  const positionsToActivate: LanePositionBulkActivationItem[] = [];
  const skippedPositions: LanePositionBulkActivationItem[] = [];

  for (const child of family.children) {
    const readiness = getLanePositionReadiness(family, state, child.lane_id);
    const reasons = [...readiness.missing];
    if (!family.root.is_active) {
      reasons.push("Oś główna jest nieaktywna.");
    }
    const item = { lane_id: child.lane_id, name: child.name, reasons };
    if (!readiness.ready || !family.root.is_active) {
      skippedPositions.push(item);
      continue;
    }

    eligiblePositions.push(item);
    const edit = edits.get(child.lane_id);
    if (!edit?.is_active || !edit.online_bookable) {
      positionsToActivate.push(item);
    }
  }

  return { eligiblePositions, positionsToActivate, skippedPositions };
}

export function prepareLanePositionBulkActivation(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): { state: LaneFamilyEditState; plan: LanePositionBulkActivationPlan } {
  const plan = getLanePositionBulkActivationPlan(family, state);
  if (plan.eligiblePositions.length === 0) {
    return { state, plan };
  }
  const eligibleIds = new Set(
    plan.eligiblePositions.map((position) => position.lane_id)
  );
  return {
    plan,
    state: {
      ...state,
      root_positions_bookable: true,
      resources: state.resources.map((resource) =>
        eligibleIds.has(resource.lane_id)
          ? { ...resource, is_active: true, online_bookable: true }
          : resource
      ),
    },
  };
}

export function laneFamilyHasUsableOnlinePosition(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
) {
  return family.children.some((child) => {
    const edit = state.resources.find(
      (resource) => resource.lane_id === child.lane_id
    );
    return Boolean(
      edit?.is_active &&
        edit.online_bookable &&
        getLanePositionReadiness(family, state, child.lane_id).ready
    );
  });
}

export function validateLaneFamilyEditState(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): LaneFamilyValidation {
  const parsed = parseLaneFamilyEditState(family, state);
  const errors = [...parsed.errors];
  const rootValues = parsed.values.get(family.root_lane_id);
  if (
    state.root_online_bookable &&
    (!family.root.is_active ||
      !state.root_whole_lane_bookable ||
      !rootValues ||
      rootValues.durationsMinutes.length === 0 ||
      !hasCompletePricingCoverage(rootValues.pricing, rootValues.maxPeopleOnline))
  ) {
    errors.push(
      "Rezerwacja online całej osi wymaga aktywnej osi oraz kompletnego cennika i czasów."
    );
  }

  const usableChildren = family.children.filter((child) => {
    const values = parsed.values.get(child.lane_id);
    return Boolean(
      values?.isActive &&
        values.onlineBookable &&
        values.durationsMinutes.length > 0 &&
        hasCompletePricingCoverage(values.pricing, values.maxPeopleOnline)
    );
  });
  for (const child of family.children) {
    const values = parsed.values.get(child.lane_id);
    if (!values) continue;
    if (!values.isActive && values.onlineBookable) {
      errors.push(`${child.name}: nieaktywne stanowisko nie może przyjmować rezerwacji online.`);
    }
    if (
      values.onlineBookable &&
      !getLanePositionReadiness(family, state, child.lane_id).ready
    ) {
      errors.push(`${child.name}: uzupełnij konfigurację przed włączeniem rezerwacji online.`);
    }
    if (values.onlineBookable && !state.root_positions_bookable) {
      errors.push(`${child.name}: włącz na osi tryb „Rezerwacja stanowisk”.`);
    }
  }
  if (
    !family.root.is_active &&
    family.children.some((child) => {
      const values = parsed.values.get(child.lane_id);
      return values?.isActive || values?.onlineBookable;
    })
  ) {
    errors.push("Nieaktywna oś nie może mieć aktywnych ani dostępnych online stanowisk.");
  }
  if (state.root_positions_bookable && usableChildren.length === 0) {
    errors.push("Najpierw skonfiguruj co najmniej jedno stanowisko do rezerwacji online.");
  }
  if (
    state.root_positions_bookable &&
    usableChildren.reduce(
      (total, child) => total + parsed.values.get(child.lane_id)!.maxShooters,
      0
    ) > (rootValues?.maxShooters ?? 0)
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
  const parsed = parseLaneFamilyEditState(family, state);
  if (!validation.valid || parsed.values.size !== family.resources.length) {
    throw new Error("invalid_edit_state");
  }

  return family.resources
    .map((resource) => {
      const edited = parsed.values.get(resource.lane_id)!;
      const isRoot = resource.lane_id === family.root_lane_id;
      return {
        lane_id: resource.lane_id,
        name: edited.name,
        is_active: isRoot ? resource.is_active : edited.isActive,
        whole_lane_bookable: isRoot
          ? state.root_whole_lane_bookable
          : resource.whole_lane_bookable,
        positions_bookable: isRoot
          ? state.root_positions_bookable
          : resource.positions_bookable,
        max_shooters: edited.maxShooters,
        online_bookable: isRoot
          ? state.root_online_bookable
          : edited.onlineBookable,
        max_people_online: edited.maxPeopleOnline,
        durations_minutes: edited.durationsMinutes,
        pricing: edited.pricing,
      };
    })
    .sort((first, second) => first.lane_id.localeCompare(second.lane_id));
}

function yesNo(value: boolean) {
  return value ? "Tak" : "Nie";
}

function formatDurations(values: number[]) {
  return values.length > 0 ? values.map((value) => `${value} min`).join(", ") : "Brak";
}

function formatPeopleRange(minShooters: number, maxShooters: number) {
  if (minShooters === maxShooters) {
    return minShooters === 1 ? "1 osoba" : `${minShooters} osób`;
  }
  return `${minShooters}–${maxShooters} osób`;
}

function formatPricing(
  pricing: LaneFamilyWritePricing[],
  dayGroup: LaneFamilyWritePricing["day_group"],
  currencyCode: string
) {
  const rules = pricing.filter((rule) => rule.day_group === dayGroup).sort(sortPricing);
  if (rules.length === 0) return "Brak";
  return rules
    .map(
      (rule) =>
        `${formatPeopleRange(rule.min_shooters, rule.max_shooters)}: ${rule.hourly_price.toLocaleString("pl-PL", { maximumFractionDigits: 2 })} ${currencyCode}/h — ${rule.label}`
    )
    .join("; ");
}

export function getLaneFamilyChanges(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
): LaneFamilyChange[] {
  const changes: LaneFamilyChange[] = [];
  const parsed = parseLaneFamilyEditState(family, state);

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
    const edited = parsed.values.get(resource.lane_id);
    if (!edited) continue;
    if (edited.name !== resource.name) {
      changes.push({
        resourceName: resource.name,
        label: resource.resource_kind === "position" ? "Nazwa stanowiska" : "Nazwa osi",
        before: resource.name,
        after: edited.name,
      });
    }
    if (
      resource.resource_kind === "position" &&
      edited.isActive !== resource.is_active
    ) {
      changes.push({
        resourceName: resource.name,
        label: "Status",
        before: resource.is_active ? "Aktywne" : "Nieaktywne",
        after: edited.isActive ? "Aktywne" : "Nieaktywne",
      });
    }
    if (
      resource.resource_kind === "position" &&
      edited.onlineBookable !== resource.online_bookable
    ) {
      changes.push({
        resourceName: resource.name,
        label: "Rezerwacje online",
        before: resource.online_bookable ? "Włączone" : "Wyłączone",
        after: edited.onlineBookable ? "Włączone" : "Wyłączone",
      });
    }
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
    const originalDurations = resource.durations
      .filter((duration) => duration.is_active)
      .map((duration) => duration.duration_minutes)
      .sort((first, second) => first - second);
    if (JSON.stringify(originalDurations) !== JSON.stringify(edited.durationsMinutes)) {
      changes.push({
        resourceName: resource.name,
        label: "Dostępne czasy rezerwacji",
        before: formatDurations(originalDurations),
        after: formatDurations(edited.durationsMinutes),
      });
    }
    const originalPricing = resource.pricing
      .filter((rule) => rule.is_active)
      .map((rule) => ({
        day_group: rule.day_group,
        min_shooters: rule.min_shooters,
        max_shooters: rule.max_shooters,
        label: rule.label,
        hourly_price: rule.hourly_price,
      }))
      .sort(sortPricing);
    for (const dayGroup of DAY_GROUPS) {
      const beforeRules = originalPricing.filter((rule) => rule.day_group === dayGroup);
      const afterRules = edited.pricing.filter((rule) => rule.day_group === dayGroup);
      if (JSON.stringify(beforeRules) !== JSON.stringify(afterRules)) {
        changes.push({
          resourceName: resource.name,
          label: `Cennik ${dayGroupLabel(dayGroup)}`,
          before: formatPricing(originalPricing, dayGroup, resource.currency_code),
          after: formatPricing(edited.pricing, dayGroup, resource.currency_code),
        });
      }
    }
  }
  return changes;
}

function comparableEditState(state: LaneFamilyEditState) {
  return {
    root_online_bookable: state.root_online_bookable,
    root_whole_lane_bookable: state.root_whole_lane_bookable,
    root_positions_bookable: state.root_positions_bookable,
    resources: state.resources
      .map((resource) => ({
        lane_id: resource.lane_id,
        name: resource.name,
        is_active: resource.is_active,
        online_bookable: resource.online_bookable,
        max_shooters: resource.max_shooters,
        max_people_online: resource.max_people_online,
        durations_minutes: [...resource.durations_minutes].sort(
          (first, second) => Number(first) - Number(second)
        ),
        pricing: resource.pricing
          .map((rule) => ({
            day_group: rule.day_group,
            min_shooters: rule.min_shooters,
            max_shooters: rule.max_shooters,
            label: rule.label,
            hourly_price: rule.hourly_price,
          }))
          .sort((first, second) =>
            `${first.day_group}:${first.min_shooters}:${first.max_shooters}:${first.label}:${first.hourly_price}`.localeCompare(
              `${second.day_group}:${second.min_shooters}:${second.max_shooters}:${second.label}:${second.hourly_price}`
            )
          ),
      }))
      .sort((first, second) => first.lane_id.localeCompare(second.lane_id)),
  };
}

export function isLaneFamilyDirty(
  family: LaneConfigurationFamily,
  state: LaneFamilyEditState
) {
  const original = createLaneFamilyEditState(family);
  return JSON.stringify(comparableEditState(state)) !== JSON.stringify(comparableEditState(original));
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

export function parseLaneFamilyCreateResult(value: unknown): LaneFamilyCreateResult {
  const expectedKeys = [
    "changed",
    "code",
    "configuration_version",
    "created_resource_count",
    "ok",
    "root_lane_id",
  ] as const;
  if (!isRecord(value) || !hasExactKeys(value, expectedKeys)) {
    throw new Error("invalid_create_result");
  }
  const allowedCodes = [
    "created",
    "not_allowed",
    "invalid_payload",
    "invalid_configuration",
  ] as const;
  if (
    typeof value.code !== "string" ||
    !(allowedCodes as readonly string[]).includes(value.code) ||
    typeof value.ok !== "boolean" ||
    typeof value.changed !== "boolean" ||
    !isInteger(value.created_resource_count)
  ) {
    throw new Error("invalid_create_result");
  }
  const created = value.code === "created";
  if (
    value.ok !== created ||
    value.changed !== created ||
    (created &&
      (typeof value.root_lane_id !== "string" ||
        !UUID_PATTERN.test(value.root_lane_id) ||
        value.configuration_version !== 1 ||
        value.created_resource_count < 1)) ||
    (!created &&
      (value.root_lane_id !== null ||
        value.configuration_version !== null ||
        value.created_resource_count !== 0))
  ) {
    throw new Error("invalid_create_result");
  }
  return {
    code: value.code as LaneFamilyCreateResult["code"],
    rootLaneId: created ? (value.root_lane_id as string) : null,
    configurationVersion: created ? 1 : null,
    createdResourceCount: value.created_resource_count,
  };
}
