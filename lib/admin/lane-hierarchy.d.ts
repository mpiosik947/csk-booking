export type LaneResourceKind = "lane" | "position";

export type LaneHierarchyResource = {
  id: string;
  name: string;
  resourceKind: LaneResourceKind;
  parentLaneId: string | null;
  displayOrder: number;
  isActive: boolean;
};

export type LaneHierarchyDisplayItem = LaneHierarchyResource & {
  displayName: string;
  parentName: string | null;
  depth: 0 | 1;
  isParent: boolean;
  isPosition: boolean;
};

export type LaneHierarchyErrorCode =
  | "invalid_input"
  | "invalid_resource"
  | "duplicate_id"
  | "missing_parent"
  | "invalid_hierarchy"
  | "unsupported_depth";

export type LaneHierarchyResult =
  | { ok: true; value: LaneHierarchyDisplayItem[] }
  | { ok: false; code: LaneHierarchyErrorCode };

export function buildLaneHierarchyDisplayModel(
  value: unknown
): LaneHierarchyResult;
