import type { LaneHierarchyDisplayItem } from "../../../lib/admin/lane-hierarchy";

type HierarchyResourcePresentation = Pick<
  LaneHierarchyDisplayItem,
  "displayName" | "depth" | "isActive" | "isPosition"
>;

export function ResourceTypeBadge({
  isPosition,
}: {
  isPosition: boolean;
}) {
  return (
    <span className="inline-flex shrink-0 rounded-full border border-[#3d4638] bg-[#171a17] px-2.5 py-1 text-[0.68rem] font-bold uppercase tracking-[0.12em] text-[#c7cbbf]">
      {isPosition ? "Stanowisko" : "Oś"}
    </span>
  );
}

export function ResourceStatusBadge({ isActive }: { isActive: boolean }) {
  return (
    <span
      className={
        isActive
          ? "inline-flex shrink-0 rounded-full border border-[#3f6848] bg-[#1b2a1d] px-2.5 py-1 text-[0.68rem] font-bold uppercase tracking-[0.1em] text-[#a9d4ad]"
          : "inline-flex shrink-0 rounded-full border border-[#343a31] bg-[#171a17] px-2.5 py-1 text-[0.68rem] font-bold uppercase tracking-[0.1em] text-[#858c7f]"
      }
    >
      {isActive ? "Aktywne" : "Nieaktywne"}
    </span>
  );
}

export function HierarchyResourceLabel({
  resource,
  compact = false,
  showStatus = false,
  tree = false,
}: {
  resource: HierarchyResourcePresentation;
  compact?: boolean;
  showStatus?: boolean;
  tree?: boolean;
}) {
  return (
    <div
      className={`flex min-w-0 max-w-full flex-wrap items-center gap-2 ${
        tree && resource.depth === 1 ? "sm:pl-3" : ""
      }`}
    >
      {tree && resource.depth === 1 ? (
        <span aria-hidden="true" className="shrink-0 text-[#78865f]">
          ↳
        </span>
      ) : null}
      <span
        className={`min-w-0 break-words ${
          compact
            ? "text-xs font-semibold text-[#f2efe4]"
            : "text-sm font-semibold text-[#f2efe4]"
        }`}
      >
        {resource.displayName}
      </span>
      <ResourceTypeBadge isPosition={resource.isPosition} />
      {showStatus ? <ResourceStatusBadge isActive={resource.isActive} /> : null}
    </div>
  );
}
