export type CalendarLaneScopeResource = {
  id: string;
  parentLaneId: string | null;
  isPosition: boolean;
};

export function getCalendarLaneScopeIds(
  lanes: CalendarLaneScopeResource[],
  laneId: string | "all",
) {
  if (laneId === "all") return lanes.map((lane) => lane.id);

  const selectedLane = lanes.find((lane) => lane.id === laneId);
  if (!selectedLane) return [];
  if (selectedLane.isPosition) return [selectedLane.id];

  return lanes
    .filter(
      (lane) => lane.id === selectedLane.id || lane.parentLaneId === selectedLane.id,
    )
    .map((lane) => lane.id);
}
