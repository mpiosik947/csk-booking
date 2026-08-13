import type { BookingDayGroup } from "./booking-day-group";

export type PublicBookingPricing = {
  day_group: BookingDayGroup;
  min_shooters: number;
  max_shooters: number;
  hourly_price: number;
  label: string;
};

export type PublicBookingConfigurationRow = {
  lane_id: string;
  parent_lane_id: string | null;
  resource_kind: "lane" | "position";
  name: string;
  display_name: string;
  display_order: number;
  effective_online_bookable: boolean;
  whole_lane_bookable: boolean;
  positions_bookable: boolean;
  max_people_online: number | null;
  booking_step_minutes: number;
  currency_code: string;
  durations_minutes: number[];
  pricing: PublicBookingPricing[];
};

export type BookingLane = {
  id: string;
  name: string;
  max_people_online: number;
  booking_step_minutes: number;
  display_order: number;
  currency_code: string;
};

export type BookingDuration = {
  lane_id: string;
  duration_minutes: number;
};

export type BookingPricingRule = PublicBookingPricing & {
  lane_id: string;
};

export type BookingConfiguration = {
  lanes: BookingLane[];
  durations: BookingDuration[];
  pricingRules: BookingPricingRule[];
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const RESOURCE_KEYS = [
  "booking_step_minutes",
  "currency_code",
  "display_name",
  "display_order",
  "durations_minutes",
  "effective_online_bookable",
  "lane_id",
  "max_people_online",
  "name",
  "parent_lane_id",
  "positions_bookable",
  "pricing",
  "resource_kind",
  "whole_lane_bookable",
];

const PRICING_KEYS = [
  "day_group",
  "hourly_price",
  "label",
  "max_shooters",
  "min_shooters",
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expected: string[]) {
  const keys = Object.keys(value).sort();
  return (
    keys.length === expected.length &&
    keys.every((key, index) => key === expected[index])
  );
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isPositiveInteger(value: unknown): value is number {
  return Number.isInteger(value) && Number(value) > 0;
}

function isPricingCoverageValid(
  pricing: PublicBookingPricing[],
  maxPeopleOnline: number
) {
  const dayGroups: BookingDayGroup[] = ["mon_thu", "fri_sun"];

  return dayGroups.every((dayGroup) => {
    const rules = pricing
      .filter((rule) => rule.day_group === dayGroup)
      .slice()
      .sort(
        (left, right) =>
          left.min_shooters - right.min_shooters ||
          left.max_shooters - right.max_shooters
      );

    if (rules.length === 0 || rules[0].min_shooters !== 1) {
      return false;
    }

    for (let index = 0; index < rules.length; index += 1) {
      const rule = rules[index];
      const previousRule = rules[index - 1];

      if (
        rule.min_shooters > rule.max_shooters ||
        rule.max_shooters > maxPeopleOnline ||
        (previousRule &&
          rule.min_shooters !== previousRule.max_shooters + 1)
      ) {
        return false;
      }
    }

    return rules.at(-1)?.max_shooters === maxPeopleOnline;
  });
}

function parsePricing(
  value: unknown,
  maxPeopleOnline: number
): PublicBookingPricing[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const pricing: PublicBookingPricing[] = [];

  for (const item of value) {
    if (!isRecord(item) || !hasExactKeys(item, PRICING_KEYS)) {
      return null;
    }

    if (
      (item.day_group !== "mon_thu" && item.day_group !== "fri_sun") ||
      !isPositiveInteger(item.min_shooters) ||
      !isPositiveInteger(item.max_shooters) ||
      typeof item.hourly_price !== "number" ||
      !Number.isFinite(item.hourly_price) ||
      item.hourly_price < 0 ||
      typeof item.label !== "string"
    ) {
      return null;
    }

    pricing.push({
      day_group: item.day_group,
      min_shooters: item.min_shooters,
      max_shooters: item.max_shooters,
      hourly_price: item.hourly_price,
      label: item.label,
    });
  }

  return isPricingCoverageValid(pricing, maxPeopleOnline) ? pricing : null;
}

function parseResource(value: unknown): PublicBookingConfigurationRow | null {
  if (!isRecord(value) || !hasExactKeys(value, RESOURCE_KEYS)) {
    return null;
  }

  if (
    typeof value.lane_id !== "string" ||
    !UUID_PATTERN.test(value.lane_id) ||
    (value.parent_lane_id !== null &&
      (typeof value.parent_lane_id !== "string" ||
        !UUID_PATTERN.test(value.parent_lane_id))) ||
    (value.resource_kind !== "lane" && value.resource_kind !== "position") ||
    (value.resource_kind === "lane" && value.parent_lane_id !== null) ||
    (value.resource_kind === "position" && value.parent_lane_id === null) ||
    value.parent_lane_id === value.lane_id ||
    !isNonEmptyString(value.name) ||
    !isNonEmptyString(value.display_name) ||
    typeof value.display_order !== "number" ||
    !Number.isInteger(value.display_order) ||
    typeof value.effective_online_bookable !== "boolean" ||
    typeof value.whole_lane_bookable !== "boolean" ||
    typeof value.positions_bookable !== "boolean" ||
    (value.max_people_online !== null &&
      !isPositiveInteger(value.max_people_online)) ||
    !isPositiveInteger(value.booking_step_minutes) ||
    typeof value.currency_code !== "string" ||
    !/^[A-Z]{3}$/.test(value.currency_code) ||
    !Array.isArray(value.durations_minutes) ||
    !value.durations_minutes.every(isPositiveInteger) ||
    new Set(value.durations_minutes).size !== value.durations_minutes.length
  ) {
    return null;
  }

  const pricing =
    value.max_people_online === null
      ? Array.isArray(value.pricing) && value.pricing.length === 0
        ? []
        : null
      : parsePricing(value.pricing, value.max_people_online);

  if (
    !pricing ||
    (value.effective_online_bookable &&
      (value.max_people_online === null ||
        value.durations_minutes.length === 0 ||
        pricing.length === 0))
  ) {
    return null;
  }

  return {
    lane_id: value.lane_id,
    parent_lane_id: value.parent_lane_id,
    resource_kind: value.resource_kind,
    name: value.name,
    display_name: value.display_name,
    display_order: value.display_order,
    effective_online_bookable: value.effective_online_bookable,
    whole_lane_bookable: value.whole_lane_bookable,
    positions_bookable: value.positions_bookable,
    max_people_online: value.max_people_online,
    booking_step_minutes: value.booking_step_minutes,
    currency_code: value.currency_code,
    durations_minutes: [...value.durations_minutes],
    pricing,
  };
}

export function parsePublicBookingConfiguration(
  value: unknown
): PublicBookingConfigurationRow[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const resources: PublicBookingConfigurationRow[] = [];
  const laneIds = new Set<string>();

  for (const item of value) {
    const resource = parseResource(item);

    if (!resource || laneIds.has(resource.lane_id)) {
      return null;
    }

    laneIds.add(resource.lane_id);
    resources.push(resource);
  }

  const resourcesById = new Map(
    resources.map((resource) => [resource.lane_id, resource])
  );

  for (const resource of resources) {
    if (resource.resource_kind === "position") {
      const parent = resourcesById.get(resource.parent_lane_id ?? "");

      if (
        !parent ||
        parent.resource_kind !== "lane" ||
        parent.parent_lane_id !== null ||
        !parent.positions_bookable ||
        !resource.effective_online_bookable ||
        resource.whole_lane_bookable ||
        resource.positions_bookable
      ) {
        return null;
      }
    } else {
      const hasSelectableChildren = resources.some(
        (candidate) =>
          candidate.resource_kind === "position" &&
          candidate.parent_lane_id === resource.lane_id &&
          candidate.effective_online_bookable
      );

      if (
        resource.effective_online_bookable !== resource.whole_lane_bookable ||
        resource.positions_bookable !== hasSelectableChildren
      ) {
        return null;
      }
    }
  }

  return resources;
}

export function adaptPublicBookingConfiguration(
  resources: PublicBookingConfigurationRow[]
): BookingConfiguration {
  const resourcesById = new Map(
    resources.map((resource) => [resource.lane_id, resource])
  );
  const selectableResources = resources.filter(
    (
      resource
    ): resource is PublicBookingConfigurationRow & {
      max_people_online: number;
    } =>
      resource.effective_online_bookable &&
      resource.max_people_online !== null
  );
  const selectableChildrenByParent = new Map<string, number>();

  for (const resource of selectableResources) {
    if (resource.resource_kind === "position" && resource.parent_lane_id) {
      selectableChildrenByParent.set(
        resource.parent_lane_id,
        (selectableChildrenByParent.get(resource.parent_lane_id) ?? 0) + 1
      );
    }
  }

  selectableResources.sort((left, right) => {
    const leftRoot =
      left.resource_kind === "position"
        ? resourcesById.get(left.parent_lane_id ?? "") ?? left
        : left;
    const rightRoot =
      right.resource_kind === "position"
        ? resourcesById.get(right.parent_lane_id ?? "") ?? right
        : right;

    return (
      leftRoot.display_order - rightRoot.display_order ||
      leftRoot.display_name.localeCompare(rightRoot.display_name, "pl") ||
      leftRoot.lane_id.localeCompare(rightRoot.lane_id) ||
      Number(left.resource_kind === "position") -
        Number(right.resource_kind === "position") ||
      left.display_order - right.display_order ||
      left.display_name.localeCompare(right.display_name, "pl") ||
      left.lane_id.localeCompare(right.lane_id)
    );
  });

  const getBookingLabel = (resource: PublicBookingConfigurationRow) =>
    resource.resource_kind === "lane" &&
    (selectableChildrenByParent.get(resource.lane_id) ?? 0) > 0
      ? `${resource.display_name} — Cała oś`
      : resource.display_name;

  return {
    lanes: selectableResources.map((resource) => ({
      id: resource.lane_id,
      name: getBookingLabel(resource),
      max_people_online: resource.max_people_online,
      booking_step_minutes: resource.booking_step_minutes,
      display_order: resource.display_order,
      currency_code: resource.currency_code,
    })),
    durations: selectableResources.flatMap((resource) =>
      resource.durations_minutes.map((durationMinutes) => ({
        lane_id: resource.lane_id,
        duration_minutes: durationMinutes,
      }))
    ),
    pricingRules: selectableResources.flatMap((resource) =>
      resource.pricing.map((pricingRule) => ({
        lane_id: resource.lane_id,
        ...pricingRule,
      }))
    ),
  };
}
