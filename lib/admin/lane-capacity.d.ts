export type EffectiveLaneCapacityResource = {
  id: string;
  isActive: boolean;
  isParent: boolean;
  isPosition: boolean;
  parentLaneId: string | null;
  onlineBookable: boolean;
  wholeLaneBookable: boolean;
  positionsBookable: boolean;
};

export type EffectiveLaneCapacityResult =
  | { ok: false; code: "invalid_input" }
  | {
      ok: true;
      effectiveCapacity: number;
      unitIds: Set<string>;
      unitIdsByResourceId: Map<string, string[]>;
    };

export function buildEffectiveLaneCapacity(
  resources: EffectiveLaneCapacityResource[],
): EffectiveLaneCapacityResult;
