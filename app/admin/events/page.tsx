"use client";

import { useEffect, useRef, useState } from "react";
import {
  buildCreateEventPayload,
  buildSetEventActivePayload,
  buildUpdateEventPayload,
  getEditableEventLanes,
  getEventManagementMessage,
  normalizeActiveEventLanes,
  normalizeAdminEvent,
  type AdminEvent,
  type AdminEventLane,
  type CreateEventRpcPayload,
  type EventManagementMessage,
  validateEventForm,
  validateEventRpcResult,
} from "../../../lib/admin/events/event-management";
import { supabase } from "../../../lib/supabase";

type RegistrationAction = "approve" | "cancel";

const EVENTS_LOAD_ERROR_MESSAGE =
  "Nie udało się poprawnie wczytać listy szkoleń.";
const ACTIVE_LANES_LOAD_ERROR_MESSAGE = "Nie udało się wczytać listy osi.";

type CreateFormMessage = Pick<EventManagementMessage, "message" | "kind">;

type CreateConfirmationSnapshot = {
  payload: CreateEventRpcPayload;
  lanes: AdminEventLane[];
};

function formatConfirmationDate(value: string) {
  return new Intl.DateTimeFormat("pl-PL", {
    day: "numeric",
    month: "long",
    year: "numeric",
  }).format(new Date(`${value}T12:00:00`));
}

function formatConfirmationPrice(value: number) {
  return new Intl.NumberFormat("pl-PL", {
    style: "currency",
    currency: "PLN",
  }).format(value);
}

type ApproveRegistrationResult = {
  ok: boolean;
  changed: boolean;
  code: string;
  registration_id?: string;
  event_id?: string;
  previous_status?: string;
  new_status?: string;
};

type CancelRegistrationResult = {
  success: boolean;
  cancellation: {
    registrationId: string;
    eventId: string;
    changed: boolean;
    previousStatus: string;
    newStatus: string;
    freedParticipantPlace: boolean;
  };
  promotion: {
    attempted: boolean;
    succeeded: boolean;
    warning: boolean;
  };
  message: string;
};

type Registration = {
  id: string;
  customer_name: string;
  customer_email: string;
  customer_phone: string;
  registration_status: string;
  payment_status: string;
  created_at: string;
};

function translateRegistrationStatus(status: string) {
  if (status === "registered") return "Zapisany";
  if (status === "approved") return "Zatwierdzony";
  if (status === "cancelled") return "Anulowany";
  if (status === "reserve") return "Rezerwowy";
  return status;
}

function getStatusClass(status: string) {
  if (status === "approved") {
    return "rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400";
  }

  if (status === "registered") {
    return "rounded-full bg-blue-950 px-3 py-1 text-xs font-semibold text-blue-300";
  }

  if (status === "reserve") {
    return "rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300";
  }

  if (status === "cancelled") {
    return "rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300";
  }

  return "rounded-full bg-zinc-950 px-3 py-1 text-xs font-semibold text-zinc-300";
}

function getPaidRegistrationsCount(registrations: Registration[]) {
  return registrations.filter(
    (registration) =>
      registration.registration_status === "registered" ||
      registration.registration_status === "approved"
  ).length;
}

function getReserveRegistrationsCount(registrations: Registration[]) {
  return registrations.filter(
    (registration) => registration.registration_status === "reserve"
  ).length;
}

function getCancelledRegistrationsCount(registrations: Registration[]) {
  return registrations.filter(
    (registration) => registration.registration_status === "cancelled"
  ).length;
}

function getParticipantRegistrations(registrations: Registration[]) {
  return registrations.filter(
    (registration) =>
      registration.registration_status === "registered" ||
      registration.registration_status === "approved"
  );
}

function getReserveRegistrations(registrations: Registration[]) {
  return registrations
    .filter((registration) => registration.registration_status === "reserve")
    .sort(
      (first, second) =>
        new Date(first.created_at).getTime() -
        new Date(second.created_at).getTime()
    );
}

function getCancelledRegistrations(registrations: Registration[]) {
  return registrations.filter(
    (registration) => registration.registration_status === "cancelled"
  );
}

function EventLanesSummary({ lanes }: { lanes: AdminEvent["lanes"] }) {
  return (
    <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
      <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">
        Zajmowane osie
      </p>

      {lanes.length === 0 ? (
        <p className="mt-2 text-sm text-zinc-400">
          Event globalny — nie blokuje osi
        </p>
      ) : (
        <div className="mt-2 flex flex-wrap gap-2">
          {lanes.map((lane) => (
            <span
              key={lane.id}
              className="inline-flex max-w-full flex-wrap items-center gap-2 rounded-full border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm font-semibold text-zinc-200"
            >
              <span className="break-words">{lane.name}</span>
              {!lane.is_active && (
                <span className="rounded-full bg-yellow-950 px-2 py-0.5 text-xs font-semibold text-yellow-300">
                  Nieaktywna
                </span>
              )}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function FieldHelp({ children }: { children: React.ReactNode }) {
  return <p className="mt-2 text-xs leading-relaxed text-zinc-500">{children}</p>;
}

function EventFormSection({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-2xl border border-zinc-800 bg-zinc-950/60 p-4 sm:p-5">
      <h3 className="text-sm font-bold uppercase tracking-[0.16em] text-amber-300">
        {title}
      </h3>
      <div className="mt-4 grid gap-4">{children}</div>
    </section>
  );
}

function LaneSelectionSummary({ lanes }: { lanes: AdminEventLane[] }) {
  if (lanes.length === 0) {
    return (
      <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-3 text-sm">
        <p className="font-semibold text-zinc-200">Event globalny</p>
        <p className="mt-1 text-zinc-400">Nie blokuje żadnej osi.</p>
      </div>
    );
  }

  const laneCountLabel =
    lanes.length === 1
      ? "Zajmuje 1 oś"
      : lanes.length >= 2 && lanes.length <= 4
        ? `Zajmuje ${lanes.length} osie`
        : `Zajmuje ${lanes.length} osi`;

  return (
    <div className="rounded-xl border border-[#6b7d3b] bg-[#29321c] p-3 text-sm">
      <p className="font-semibold text-lime-100">
        {laneCountLabel}
      </p>
      <div className="mt-2 flex flex-wrap gap-2">
        {lanes.map((lane) => (
          <span
            key={lane.id}
            className="max-w-full break-words rounded-full border border-[#6b7d3b] bg-zinc-950 px-3 py-1 text-xs font-semibold text-lime-100"
          >
            {lane.name}
          </span>
        ))}
      </div>
    </div>
  );
}

export default function AdminEventsPage() {
  const [loading, setLoading] = useState(true);
  const [events, setEvents] = useState<AdminEvent[]>([]);
  const [selectedEventId, setSelectedEventId] = useState("");
  const [registrations, setRegistrations] = useState<Registration[]>([]);
  const [message, setMessage] = useState("");
  const [userRole, setUserRole] = useState("");
  const [activeLanes, setActiveLanes] = useState<AdminEventLane[]>([]);
  const [activeLanesLoading, setActiveLanesLoading] = useState(false);
  const [activeLanesLoaded, setActiveLanesLoaded] = useState(false);
  const [activeLanesError, setActiveLanesError] = useState<string | null>(
    null
  );
  const [createLaneIds, setCreateLaneIds] = useState<string[]>([]);
  const [createSubmitting, setCreateSubmitting] = useState(false);
  const [createMessage, setCreateMessage] = useState<CreateFormMessage | null>(
    null
  );
  const [createConfirmation, setCreateConfirmation] =
    useState<CreateConfirmationSnapshot | null>(null);
  const [editMessage, setEditMessage] = useState<CreateFormMessage | null>(
    null
  );
  const [toggleMessage, setToggleMessage] = useState<CreateFormMessage | null>(
    null
  );
  const [eventToggleActions, setEventToggleActions] = useState<
    Record<string, boolean>
  >({});
  const [registrationActions, setRegistrationActions] = useState<
    Record<string, RegistrationAction>
  >({});
  const registrationActionLocksRef = useRef(new Set<string>());
  const eventsLoadRequestRef = useRef(0);
  const activeLanesRequestRef = useRef(0);
  const componentMountedRef = useRef(true);
  const createSubmittingRef = useRef(false);
  const createConfirmationButtonRef = useRef<HTMLButtonElement>(null);
  const editSubmittingRef = useRef(false);
  const eventToggleLocksRef = useRef(new Set<string>());
  const editInitialInactiveLaneIdsRef = useRef<string[]>([]);

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [eventDate, setEventDate] = useState("");
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [location, setLocation] = useState("");
  const [price, setPrice] = useState("");
  const [maxParticipants, setMaxParticipants] = useState("10");

  const [editingEventId, setEditingEventId] = useState("");
  const [editTitle, setEditTitle] = useState("");
  const [editDescription, setEditDescription] = useState("");
  const [editEventDate, setEditEventDate] = useState("");
  const [editStartTime, setEditStartTime] = useState("");
  const [editEndTime, setEditEndTime] = useState("");
  const [editLocation, setEditLocation] = useState("");
  const [editPrice, setEditPrice] = useState("");
  const [editMaxParticipants, setEditMaxParticipants] = useState("");
  const [editLaneIds, setEditLaneIds] = useState<string[]>([]);
  const [editInitialInactiveLaneIds, setEditInitialInactiveLaneIds] = useState<
    string[]
  >([]);
  const [editSubmitting, setEditSubmitting] = useState(false);

  const canManageEvents = userRole === "admin" || userRole === "pracownik";

  useEffect(() => {
    if (!createConfirmation || createSubmitting) {
      return;
    }

    createConfirmationButtonRef.current?.focus();
  }, [createConfirmation, createSubmitting]);

  useEffect(() => {
    if (!createConfirmation) {
      return;
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape" && !createSubmittingRef.current) {
        setCreateConfirmation(null);
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [createConfirmation]);

  useEffect(() => {
    componentMountedRef.current = true;
    void loadEvents();
    void loadRole();

    return () => {
      componentMountedRef.current = false;
      activeLanesRequestRef.current += 1;
    };
  }, []);

  async function loadRole() {
    const { data, error } = await supabase.rpc("get_my_role");

    if (!componentMountedRef.current) {
      return;
    }

    if (error) {
      setUserRole("");
      return;
    }

    const role = typeof data === "string" ? data : "";
    setUserRole(role);

    if (role === "admin" || role === "pracownik") {
      void loadActiveLanes();
    }
  }

  async function loadActiveLanes() {
    const requestId = ++activeLanesRequestRef.current;
    setActiveLanesLoading(true);
    setActiveLanesError(null);

    const { data, error } = await supabase
      .from("shooting_lanes")
      .select("id,name,type,is_active,display_order")
      .eq("is_active", true)
      .order("display_order", { ascending: true })
      .order("name", { ascending: true })
      .order("id", { ascending: true });

    if (
      !componentMountedRef.current ||
      requestId !== activeLanesRequestRef.current
    ) {
      return;
    }

    setActiveLanesLoading(false);

    const normalizedLanes = normalizeActiveEventLanes(data);

    if (error || normalizedLanes === null) {
      setActiveLanesError(ACTIVE_LANES_LOAD_ERROR_MESSAGE);
      return;
    }

    setActiveLanes(normalizedLanes);
    setCreateLaneIds((current) => {
      const activeLaneIds = new Set(normalizedLanes.map((lane) => lane.id));
      return current.filter((laneId) => activeLaneIds.has(laneId));
    });
    setEditLaneIds((current) => {
      const activeLaneIds = new Set(normalizedLanes.map((lane) => lane.id));
      const allowedLaneIds = new Set([
        ...activeLaneIds,
        ...editInitialInactiveLaneIdsRef.current,
      ]);
      return current.filter((laneId) => allowedLaneIds.has(laneId));
    });
    setActiveLanesLoaded(true);
  }

  async function loadEvents() {
    const requestId = ++eventsLoadRequestRef.current;
    const { data, error } = await supabase
      .from("events")
      .select(`
        id,
        title,
        description,
        event_date,
        start_time,
        end_time,
        location,
        price,
        max_participants,
        is_active,
        created_at,
        event_lanes (
          lane_id,
          shooting_lanes (
            id,
            name,
            type,
            is_active,
            display_order
          )
        )
      `)
      .order("event_date", { ascending: true });

    if (
      !componentMountedRef.current ||
      requestId !== eventsLoadRequestRef.current
    ) {
      return;
    }

    setLoading(false);

    if (error) {
      setMessage(EVENTS_LOAD_ERROR_MESSAGE);
      return;
    }

    if (!Array.isArray(data)) {
      setMessage(EVENTS_LOAD_ERROR_MESSAGE);
      return;
    }

    const normalizedEvents: AdminEvent[] = [];

    for (const record of data) {
      const normalized = normalizeAdminEvent(record);

      if (!normalized.ok) {
        setMessage(EVENTS_LOAD_ERROR_MESSAGE);
        return;
      }

      normalizedEvents.push(normalized.value);
    }

    setEvents(normalizedEvents);
    setMessage((current) =>
      current === EVENTS_LOAD_ERROR_MESSAGE ? "" : current
    );
  }

  async function loadRegistrations(eventId: string) {
    setSelectedEventId(eventId);

    const { data, error } = await supabase
      .from("event_registrations")
      .select("*")
      .eq("event_id", eventId)
      .order("created_at", { ascending: false });

    if (error) {
      console.error("Event registrations loading failed", { code: error.code });
      setMessage("Nie udało się pobrać zapisów. Spróbuj ponownie.");
      return;
    }

    setRegistrations((data ?? []) as Registration[]);
  }

  function openCreateConfirmation() {
    if (!canManageEvents || createSubmittingRef.current) {
      return;
    }

    if (activeLanesLoading || !activeLanesLoaded || activeLanesError) {
      setCreateMessage({
        kind: "error",
        message: ACTIVE_LANES_LOAD_ERROR_MESSAGE,
      });
      return;
    }

    const form = validateEventForm({
      title,
      description,
      eventDate,
      startTime,
      endTime,
      location,
      price,
      maxParticipants,
      laneIds: createLaneIds,
    });

    if (!form.ok) {
      setCreateMessage({ kind: "error", message: form.message });
      return;
    }

    const payload = buildCreateEventPayload(form.value);
    const selectedLanes = activeLanes.filter((lane) =>
      payload.p_lane_ids.includes(lane.id)
    );

    setCreateMessage(null);
    setCreateConfirmation({ payload, lanes: selectedLanes });
  }

  function closeCreateConfirmation() {
    if (createSubmittingRef.current) {
      return;
    }

    setCreateConfirmation(null);
  }

  async function confirmCreateEvent() {
    if (
      !canManageEvents ||
      createSubmittingRef.current ||
      !createConfirmation
    ) {
      return;
    }

    const { payload, lanes } = createConfirmation;
    const laneNames = new Map(lanes.map((lane) => [lane.id, lane.name]));
    createSubmittingRef.current = true;
    setCreateSubmitting(true);
    setCreateMessage(null);

    try {
      const { data, error } = await supabase.rpc("admin_create_event", payload);

      if (error) {
        setCreateMessage(
          getEventManagementMessage({ code: "invalid_rpc_response" })
        );
        return;
      }

      const result = validateEventRpcResult(data);
      const resultMessage = getEventManagementMessage(
        result.ok ? result.value : { code: "invalid_rpc_response" },
        laneNames
      );
      setCreateMessage(resultMessage);

      if (!result.ok || result.value.code !== "created") {
        return;
      }

      setTitle("");
      setDescription("");
      setEventDate("");
      setStartTime("");
      setEndTime("");
      setLocation("");
      setPrice("");
      setMaxParticipants("10");
      setCreateLaneIds([]);
      setCreateConfirmation(null);
      void loadEvents();
    } catch {
      setCreateMessage(
        getEventManagementMessage({ code: "invalid_rpc_response" })
      );
    } finally {
      createSubmittingRef.current = false;
      setCreateSubmitting(false);
    }
  }

  function toggleCreateLane(laneId: string) {
    if (createSubmittingRef.current) {
      return;
    }

    setCreateLaneIds((current) => {
      const selectedLaneIds = new Set(current);

      if (selectedLaneIds.has(laneId)) {
        selectedLaneIds.delete(laneId);
      } else {
        selectedLaneIds.add(laneId);
      }

      return activeLanes
        .filter((lane) => selectedLaneIds.has(lane.id))
        .map((lane) => lane.id);
    });
  }

  function startEditing(event: AdminEvent) {
    if (editSubmittingRef.current) {
      return;
    }

    if (!canManageEvents) {
      setMessage("Brak dostępu. Instruktor nie może edytować szkoleń.");
      return;
    }

    setEditingEventId(event.id);
    setEditTitle(event.title);
    setEditDescription(event.description ?? "");
    setEditEventDate(event.event_date);
    setEditStartTime(event.start_time.slice(0, 5));
    setEditEndTime(event.end_time.slice(0, 5));
    setEditLocation(event.location ?? "");
    setEditPrice(String(event.price));
    setEditMaxParticipants(String(event.max_participants));
    setEditLaneIds([...event.laneIds]);
    const initialInactiveLaneIds = event.lanes
      .filter((lane) => !lane.is_active)
      .map((lane) => lane.id);
    editInitialInactiveLaneIdsRef.current = initialInactiveLaneIds;
    setEditInitialInactiveLaneIds(initialInactiveLaneIds);
    setEditMessage(null);
  }

  function resetEditingState() {
    setEditingEventId("");
    setEditTitle("");
    setEditDescription("");
    setEditEventDate("");
    setEditStartTime("");
    setEditEndTime("");
    setEditLocation("");
    setEditPrice("");
    setEditMaxParticipants("");
    setEditLaneIds([]);
    editInitialInactiveLaneIdsRef.current = [];
    setEditInitialInactiveLaneIds([]);
  }

  function cancelEditing() {
    if (editSubmittingRef.current) {
      return;
    }

    resetEditingState();
    setEditMessage(null);
  }

  async function saveEditedEvent(eventId: string) {
    if (!canManageEvents || editSubmittingRef.current) {
      return;
    }

    if (activeLanesLoading || !activeLanesLoaded || activeLanesError) {
      setEditMessage({
        kind: "error",
        message: ACTIVE_LANES_LOAD_ERROR_MESSAGE,
      });
      return;
    }

    const allowedLaneIds = new Set([
      ...activeLanes.map((lane) => lane.id),
      ...editInitialInactiveLaneIds,
    ]);

    if (editLaneIds.some((laneId) => !allowedLaneIds.has(laneId))) {
      setEditMessage({ kind: "error", message: "Sprawdź wybrane osie." });
      return;
    }

    const form = validateEventForm({
      title: editTitle,
      description: editDescription,
      eventDate: editEventDate,
      startTime: editStartTime,
      endTime: editEndTime,
      location: editLocation,
      price: editPrice,
      maxParticipants: editMaxParticipants,
      laneIds: editLaneIds,
    });

    if (!form.ok) {
      setEditMessage({ kind: "error", message: form.message });
      return;
    }

    const payload = buildUpdateEventPayload(eventId, form.value);

    if (!payload.ok) {
      setEditMessage({ kind: "error", message: payload.message });
      return;
    }

    const editingEvent = events.find((event) => event.id === eventId);
    const laneNames = new Map(
      getEditableEventLanes(activeLanes, editingEvent?.lanes ?? []).map(
        (lane) => [lane.id, lane.name]
      )
    );
    editSubmittingRef.current = true;
    setEditSubmitting(true);
    setEditMessage(null);

    try {
      const { data, error } = await supabase.rpc("admin_update_event", payload.value);

      if (error) {
        setEditMessage(
          getEventManagementMessage({ code: "invalid_rpc_response" })
        );
        return;
      }

      const result = validateEventRpcResult(data);
      if (result.ok && result.value.event_id !== eventId) {
        setEditMessage(
          getEventManagementMessage({ code: "invalid_rpc_response" })
        );
        return;
      }

      const resultMessage = getEventManagementMessage(
        result.ok ? result.value : { code: "invalid_rpc_response" },
        laneNames
      );
      setEditMessage(resultMessage);

      if (!result.ok) {
        return;
      }

      if (result.value.code === "updated") {
        void loadEvents();
        resetEditingState();
        return;
      }

      if (result.value.code === "no_change") {
        resetEditingState();
      }
    } catch {
      setEditMessage(
        getEventManagementMessage({ code: "invalid_rpc_response" })
      );
    } finally {
      editSubmittingRef.current = false;
      setEditSubmitting(false);
    }
  }

  function toggleEditLane(
    laneId: string,
    isActive: boolean,
    editableLanes: readonly AdminEventLane[]
  ) {
    if (editSubmittingRef.current) {
      return;
    }

    setEditLaneIds((current) => {
      const selectedLaneIds = new Set(current);

      if (selectedLaneIds.has(laneId)) {
        selectedLaneIds.delete(laneId);
      } else {
        if (!isActive) {
          return current;
        }

        selectedLaneIds.add(laneId);
      }

      return editableLanes
        .filter((lane) => selectedLaneIds.has(lane.id))
        .map((lane) => lane.id);
    });
  }

  async function toggleEvent(eventId: string, currentStatus: boolean) {
    if (!canManageEvents) {
      setToggleMessage(
        getEventManagementMessage({ code: "not_allowed" })
      );
      return;
    }

    if (eventToggleLocksRef.current.has(eventId)) {
      return;
    }

    if (editingEventId === eventId) {
      return;
    }

    const targetStatus = !currentStatus;
    const payload = buildSetEventActivePayload(eventId, targetStatus);

    if (!payload.ok) {
      setToggleMessage({ kind: "error", message: payload.message });
      return;
    }

    const event = events.find((item) => item.id === eventId);
    const laneNames = new Map(
      getEditableEventLanes(activeLanes, event?.lanes ?? []).map((lane) => [
        lane.id,
        lane.name,
      ])
    );
    eventToggleLocksRef.current.add(eventId);
    setEventToggleActions((current) => ({
      ...current,
      [eventId]: targetStatus,
    }));
    setToggleMessage(null);

    try {
      const { data, error } = await supabase.rpc(
        "admin_set_event_active",
        payload.value
      );

      if (!componentMountedRef.current) {
        return;
      }

      if (error) {
        setToggleMessage(
          getEventManagementMessage({ code: "invalid_rpc_response" })
        );
        return;
      }

      const result = validateEventRpcResult(data);
      if (result.ok && result.value.event_id !== eventId) {
        setToggleMessage(
          getEventManagementMessage({ code: "invalid_rpc_response" })
        );
        return;
      }

      if (
        result.ok &&
        ((result.value.code === "activated" && !targetStatus) ||
          (result.value.code === "deactivated" && targetStatus))
      ) {
        setToggleMessage(
          getEventManagementMessage({ code: "invalid_rpc_response" })
        );
        return;
      }

      const resultMessage = getEventManagementMessage(
        result.ok ? result.value : { code: "invalid_rpc_response" },
        laneNames
      );
      setToggleMessage(resultMessage);

      if (
        result.ok &&
        (result.value.code === "activated" ||
          result.value.code === "deactivated")
      ) {
        void loadEvents();
      }
    } catch {
      if (componentMountedRef.current) {
        setToggleMessage(
          getEventManagementMessage({ code: "invalid_rpc_response" })
        );
      }
    } finally {
      eventToggleLocksRef.current.delete(eventId);
      if (componentMountedRef.current) {
        setEventToggleActions((current) => {
          const next = { ...current };
          delete next[eventId];
          return next;
        });
      }
    }
  }

  function beginRegistrationAction(
    registrationId: string,
    action: RegistrationAction
  ) {
    if (registrationActionLocksRef.current.has(registrationId)) {
      return false;
    }

    registrationActionLocksRef.current.add(registrationId);
    setRegistrationActions((current) => ({
      ...current,
      [registrationId]: action,
    }));
    return true;
  }

  function endRegistrationAction(registrationId: string) {
    registrationActionLocksRef.current.delete(registrationId);
    setRegistrationActions((current) => {
      const next = { ...current };
      delete next[registrationId];
      return next;
    });
  }

  function isApproveRegistrationResult(
    value: unknown
  ): value is ApproveRegistrationResult {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }

    const result = value as Record<string, unknown>;
    return (
      typeof result.ok === "boolean" &&
      typeof result.changed === "boolean" &&
      typeof result.code === "string"
    );
  }

  function isCancelRegistrationResult(
    value: unknown
  ): value is CancelRegistrationResult {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }

    const result = value as Record<string, unknown>;
    const cancellation = result.cancellation;
    const promotion = result.promotion;

    if (
      !cancellation ||
      typeof cancellation !== "object" ||
      Array.isArray(cancellation) ||
      !promotion ||
      typeof promotion !== "object" ||
      Array.isArray(promotion)
    ) {
      return false;
    }

    const cancellationResult = cancellation as Record<string, unknown>;
    const promotionResult = promotion as Record<string, unknown>;

    return (
      result.success === true &&
      typeof result.message === "string" &&
      typeof cancellationResult.registrationId === "string" &&
      typeof cancellationResult.eventId === "string" &&
      typeof cancellationResult.changed === "boolean" &&
      typeof cancellationResult.previousStatus === "string" &&
      typeof cancellationResult.newStatus === "string" &&
      typeof cancellationResult.freedParticipantPlace === "boolean" &&
      typeof promotionResult.attempted === "boolean" &&
      typeof promotionResult.succeeded === "boolean" &&
      typeof promotionResult.warning === "boolean"
    );
  }

  async function reloadSelectedRegistrations() {
    if (selectedEventId) {
      await loadRegistrations(selectedEventId);
    }
  }

  async function approveRegistration(registrationId: string) {
    setMessage("");

    if (!canManageEvents) {
      setMessage("Brak uprawnień do zarządzania zapisami uczestników.");
      return;
    }

    if (!beginRegistrationAction(registrationId, "approve")) {
      return;
    }

    try {
      const { data, error } = await supabase.rpc(
        "approve_event_registration",
        { p_registration_id: registrationId }
      );

      if (error) {
        console.error("Event registration approval failed", {
          code: error.code,
        });
        setMessage("Nie udało się zatwierdzić uczestnika. Spróbuj ponownie.");
        return;
      }

      if (!isApproveRegistrationResult(data)) {
        console.error("Event registration approval returned invalid data");
        setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
        return;
      }

      if (data.code === "updated") {
        if (
          !data.ok ||
          !data.changed ||
          data.registration_id !== registrationId ||
          data.event_id !== selectedEventId ||
          data.previous_status !== "registered" ||
          data.new_status !== "approved"
        ) {
          console.error("Event registration approval returned invalid update");
          setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
          await reloadSelectedRegistrations();
          return;
        }

        setRegistrations((current) =>
          current.map((item) =>
            item.id === registrationId
              ? { ...item, registration_status: "approved" }
              : item
          )
        );
        setMessage("Uczestnik został zatwierdzony.");
        return;
      }

      if (data.code === "unchanged") {
        if (
          !data.ok ||
          data.changed ||
          data.registration_id !== registrationId ||
          data.event_id !== selectedEventId ||
          data.previous_status !== "approved" ||
          data.new_status !== "approved"
        ) {
          console.error("Event registration approval returned invalid no-op");
          setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
          await reloadSelectedRegistrations();
          return;
        }

        setMessage("Uczestnik jest już zatwierdzony.");
        return;
      }

      if (data.code === "invalid_transition") {
        setMessage("Zapisu w tym statusie nie można zatwierdzić.");
        await reloadSelectedRegistrations();
        return;
      }

      if (data.code === "unauthorized") {
        setMessage("Nie masz uprawnień do zatwierdzenia uczestnika.");
        return;
      }

      if (
        data.code === "registration_not_found" ||
        data.code === "event_not_found"
      ) {
        setMessage(
          "Nie znaleziono zapisu lub szkolenia. Lista została odświeżona."
        );
        await reloadSelectedRegistrations();
        return;
      }

      console.error("Event registration approval returned unknown code");
      setMessage("Nie udało się potwierdzić wyniku zatwierdzenia.");
    } catch {
      setMessage("Nie udało się zatwierdzić uczestnika. Spróbuj ponownie.");
    } finally {
      endRegistrationAction(registrationId);
    }
  }

  async function cancelRegistration(registrationId: string) {
    setMessage("");

    if (!canManageEvents) {
      setMessage("Brak uprawnień do zarządzania zapisami uczestników.");
      return;
    }

    if (!beginRegistrationAction(registrationId, "cancel")) {
      return;
    }

    try {
      const {
        data: { session },
        error: sessionError,
      } = await supabase.auth.getSession();

      if (sessionError || !session?.access_token) {
        setMessage("Brak aktywnej sesji. Zaloguj się ponownie.");
        return;
      }

      const response = await fetch("/api/cancel-event-registration", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ registrationId }),
      });
      const data: unknown = await response.json().catch(() => null);

      if (!response.ok) {
        if (response.status === 401) {
          setMessage("Brak aktywnej sesji. Zaloguj się ponownie.");
        } else if (response.status === 403) {
          setMessage("Nie masz uprawnień do anulowania tego zapisu.");
        } else if (response.status === 404) {
          setMessage(
            "Nie znaleziono zapisu lub szkolenia. Lista została odświeżona."
          );
          await reloadSelectedRegistrations();
        } else if (response.status === 409) {
          setMessage("Zapisu w tym statusie nie można anulować.");
          await reloadSelectedRegistrations();
        } else {
          setMessage("Nie udało się anulować zapisu. Spróbuj ponownie.");
        }
        return;
      }

      if (
        !isCancelRegistrationResult(data) ||
        data.cancellation.registrationId !== registrationId ||
        data.cancellation.eventId !== selectedEventId ||
        data.cancellation.newStatus !== "cancelled"
      ) {
        console.error("Event registration cancellation returned invalid data");
        setMessage("Nie udało się potwierdzić wyniku anulowania.");
        await reloadSelectedRegistrations();
        return;
      }

      if (data.cancellation.changed) {
        setRegistrations((current) =>
          current.map((item) =>
            item.id === registrationId
              ? { ...item, registration_status: "cancelled" }
              : item
          )
        );
      } else {
        await reloadSelectedRegistrations();
      }

      if (data.promotion.attempted) {
        await reloadSelectedRegistrations();
      }

      setMessage(
        data.promotion.warning
          ? "Zapis anulowano, ale obsługa listy rezerwowej wymaga ponowienia."
          : data.cancellation.changed
            ? "Udział został anulowany."
            : "Udział jest anulowany."
      );
    } catch {
      setMessage("Nie udało się anulować zapisu. Spróbuj ponownie.");
    } finally {
      endRegistrationAction(registrationId);
    }
  }

  async function markRegistrationPaid(registrationId: string) {
    if (!canManageEvents) {
      setMessage("Brak uprawnień do zarządzania zapisami uczestników.");
      return;
    }

    const { error } = await supabase
      .from("event_registrations")
      .update({ payment_status: "paid_on_site" })
      .eq("id", registrationId);

    if (error) {
      setMessage(`Błąd zmiany płatności: ${error.message}`);
      return;
    }

    setRegistrations((current) =>
      current.map((item) =>
        item.id === registrationId
          ? { ...item, payment_status: "paid_on_site" }
          : item
      )
    );

    setMessage("Uczestnik oznaczony jako opłacony.");
  }

  function getMessageClass(message: string) {
    if (
      message.includes("dodane") ||
      message.includes("zaktualizowany") ||
      message.includes("zaktualizowane") ||
      message.includes("opłacony") ||
      message.includes("zatwierdzony") ||
      message.includes("anulowany")
    ) {
      return "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  const selectedCreateLanes = activeLanes.filter((lane) =>
    createLaneIds.includes(lane.id)
  );

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-6 py-12">
        <div className="mb-10">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            ADMIN PANEL
          </p>

          <h1 className="text-4xl font-bold">Eventy i szkolenia</h1>

          <p className="mt-3 text-zinc-400">
            Dodawanie, edycja, aktywacja, lista uczestników, zatwierdzanie
            zapisów i płatności.
          </p>

          {userRole === "instruktor" && (
            <div className="mt-5 rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-sm font-semibold text-yellow-200">
              Tryb instruktora: możesz przeglądać szkolenia i listy uczestników,
              ale nie możesz tworzyć, edytować ani ukrywać szkoleń.
            </div>
          )}
        </div>

        {message && (
          <div className={`mb-6 ${getMessageClass(message)}`}>{message}</div>
        )}

        {toggleMessage && (
          <div
            className={
              toggleMessage.kind === "success"
                ? "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300"
                : toggleMessage.kind === "neutral"
                  ? "mb-6 rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200"
                  : "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300"
            }
          >
            {toggleMessage.message}
          </div>
        )}

        {canManageEvents && (
          <div className="mb-10 rounded-3xl border border-zinc-800 bg-zinc-900/90 p-4 shadow-2xl shadow-black/20 sm:p-6">
            <div className="mb-6">
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-amber-300">
                Nowe wydarzenie
              </p>
              <h2 className="mt-2 text-2xl font-bold sm:text-3xl">Dodaj szkolenie / event</h2>

              <p className="mt-2 text-sm text-zinc-400">
                Uzupełnij dane, termin, limit uczestników i zajmowane osie.
              </p>
              <p className="sr-only">
                Wypełnij dane szkolenia. Wolne miejsca nie są wpisywane ręcznie —
                system liczy je automatycznie na podstawie liczby zapisanych
                uczestników.
              </p>
            </div>

            <div className="grid gap-6">
              <EventFormSection title="Podstawowe informacje">
              <div>
                <label className="mb-2 block text-sm font-semibold text-zinc-200">
                  Nazwa szkolenia
                </label>

                <input
                  type="text"
                  value={title}
                  onChange={(event) => setTitle(event.target.value)}
                  placeholder="Np. Szkolenie pistolet podstawowy"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                />

                <FieldHelp>
                  Wpisz krótką, czytelną nazwę szkolenia widoczną dla klienta.
                </FieldHelp>
              </div>
              </EventFormSection>

              <EventFormSection title="Opis szkolenia">
              <div>
                <label className="mb-2 block text-sm font-semibold text-zinc-200">
                  Opis szkolenia
                </label>

                <textarea
                  value={description}
                  onChange={(event) => setDescription(event.target.value)}
                  rows={5}
                  placeholder="Np. Zakres szkolenia, wymagania, dla kogo jest szkolenie, co zawiera cena..."
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                />

                <FieldHelp>
                  Opisz, czego dotyczy szkolenie i co uczestnik powinien wiedzieć
                  przed zapisem.
                </FieldHelp>
              </div>

              </EventFormSection>

              <EventFormSection title="Termin, uczestnicy i cena">
              <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Data szkolenia
                  </label>

                  <input
                    type="date"
                    value={eventDate}
                    onChange={(event) => setEventDate(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                  />

                  <FieldHelp>
                    Wybierz dzień, w którym odbędzie się szkolenie.
                  </FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Godzina rozpoczęcia
                  </label>

                  <input
                    type="time"
                    value={startTime}
                    onChange={(event) => setStartTime(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                  />

                  <FieldHelp>Podaj godzinę startu, np. 10:00.</FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Godzina zakończenia
                  </label>

                  <input
                    type="time"
                    value={endTime}
                    onChange={(event) => setEndTime(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                  />

                  <FieldHelp>Podaj godzinę zakończenia, np. 14:00.</FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Cena
                  </label>

                  <input
                    type="number"
                    min="0"
                    value={price}
                    onChange={(event) => setPrice(event.target.value)}
                    placeholder="Np. 250"
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                  />

                  <FieldHelp>
                    Wpisz cenę za jednego uczestnika. Dla darmowego szkolenia
                    wpisz 0.
                  </FieldHelp>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-zinc-200">
                    Liczba miejsc
                  </label>

                  <input
                    type="number"
                    min="1"
                    value={maxParticipants}
                    onChange={(event) => setMaxParticipants(event.target.value)}
                    placeholder="Np. 10"
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                  />

                  <FieldHelp>
                    Maksymalna liczba uczestników. Wolne miejsca system wyliczy
                    sam.
                  </FieldHelp>
                </div>
              </div>

              <div className="border-t border-zinc-800 pt-4">
                <p className="mb-3 text-sm font-bold uppercase tracking-[0.16em] text-zinc-300">
                  Lokalizacja
                </p>
                <label className="mb-2 block text-sm font-semibold text-zinc-200">
                  Miejsce / oś
                </label>

                <input
                  type="text"
                  value={location}
                  onChange={(event) => setLocation(event.target.value)}
                  placeholder="Np. Oś 25 m, sala szkoleniowa, oś 100 m"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                />

                <FieldHelp>
                  Wpisz miejsce prowadzenia szkolenia albo konkretną oś.
                </FieldHelp>
              </div>
              </EventFormSection>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-950/60 p-4 sm:p-5">
                <h3 className="text-sm font-semibold text-zinc-200">
                  Zajmowane osie
                </h3>
                <p className="mt-1 text-sm text-zinc-400">
                  Brak zaznaczonych osi oznacza event globalny, który nie blokuje
                  rezerwacji osi.
                </p>

                <div className="mt-3">
                  <LaneSelectionSummary lanes={selectedCreateLanes} />
                </div>

                {activeLanesLoading ? (
                  <p className="mt-3 text-sm text-zinc-400">Ładowanie osi…</p>
                ) : activeLanesError ? (
                  <p className="mt-3 text-sm font-semibold text-red-300">
                    {ACTIVE_LANES_LOAD_ERROR_MESSAGE}
                  </p>
                ) : activeLanesLoaded && activeLanes.length === 0 ? (
                  <p className="mt-3 text-sm text-zinc-400">
                    Brak aktywnych osi.
                  </p>
                ) : (
                  <div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
                    {activeLanes.map((lane) => (
                      <label
                        key={lane.id}
                        className={`flex min-h-11 max-w-full cursor-pointer items-center gap-2 rounded-xl border px-3 py-2 text-sm font-semibold transition ${
                          createLaneIds.includes(lane.id)
                            ? "border-[#6b7d3b] bg-[#29321c] text-lime-100"
                            : "border-zinc-700 bg-zinc-900 text-zinc-200 hover:border-zinc-500"
                        }`}
                      >
                        <input
                          type="checkbox"
                          checked={createLaneIds.includes(lane.id)}
                          onChange={() => toggleCreateLane(lane.id)}
                          disabled={createSubmitting}
                          className="h-4 w-4 shrink-0 accent-[#556b2f] disabled:cursor-not-allowed"
                        />
                        <span className="break-words">{lane.name}</span>
                      </label>
                    ))}
                  </div>
                )}
              </div>

              <div className="rounded-xl border border-[#59663a] bg-[#252b1e] p-4 text-sm text-zinc-200">
                <p className="font-semibold text-amber-200">Informacja o wolnych miejscach</p>
                <p className="mt-1 text-zinc-400">
                  Tego pola nie uzupełniasz ręcznie. System liczy wolne miejsca:
                  liczba miejsc minus zapisani uczestnicy.
                </p>
              </div>

              {createMessage && (
                <div
                  className={
                    createMessage.kind === "success"
                      ? "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300"
                      : createMessage.kind === "neutral"
                        ? "rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200"
                        : "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300"
                  }
                >
                  {createMessage.message}
                </div>
              )}

              {editMessage && (
                <div
                  className={
                    editMessage.kind === "success"
                      ? "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300"
                      : editMessage.kind === "neutral"
                        ? "rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200"
                        : "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300"
                  }
                >
                  {editMessage.message}
                </div>
              )}

              <button
                type="button"
                onClick={openCreateConfirmation}
                disabled={
                  createSubmitting ||
                  activeLanesLoading ||
                  !activeLanesLoaded ||
                  activeLanesError !== null
                }
                className="rounded-xl border border-amber-700/70 bg-[#556b2f] px-4 py-3 font-semibold text-white transition hover:bg-[#657d3d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-400 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {createSubmitting ? "Dodawanie…" : "Dodaj szkolenie"}
              </button>
            </div>
          </div>
        )}

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie szkoleń...
          </div>
        )}

        <div className="grid gap-6">
          {events.map((event) => {
            const selectedRegistrations =
              selectedEventId === event.id ? registrations : [];

            const activeRegistrationsCount =
              getPaidRegistrationsCount(selectedRegistrations);

            const reserveRegistrationsCount =
              getReserveRegistrationsCount(selectedRegistrations);

            const cancelledRegistrationsCount =
              getCancelledRegistrationsCount(selectedRegistrations);

            const participantRegistrations =
              getParticipantRegistrations(selectedRegistrations);

            const reserveRegistrations =
              getReserveRegistrations(selectedRegistrations);

            const cancelledRegistrations =
              getCancelledRegistrations(selectedRegistrations);

            const freePlaces =
              selectedEventId === event.id
                ? Math.max(event.max_participants - activeRegistrationsCount, 0)
                : null;
            const editableLanes = getEditableEventLanes(activeLanes, event.lanes);
            const selectedEditLanes = editableLanes.filter((lane) =>
              editLaneIds.includes(lane.id)
            );
            const toggleTargetStatus = eventToggleActions[event.id];
            const isTogglePending = toggleTargetStatus !== undefined;

            return (
              <div
                key={event.id}
                className="rounded-3xl border border-zinc-800 bg-zinc-900 p-4 shadow-lg shadow-black/10 sm:p-6"
              >
                {editingEventId === event.id && canManageEvents ? (
                  <div className="grid gap-6">
                    <p className="text-xs font-bold uppercase tracking-[0.2em] text-amber-300">
                      Tryb edycji
                    </p>
                    <h2 className="text-2xl font-bold text-lime-100">
                      Edycja szkolenia
                    </h2>

                    <p className="text-sm font-bold uppercase tracking-[0.16em] text-zinc-300">
                      Podstawowe informacje
                    </p>
                    <div>
                      <label className="mb-2 block text-sm font-semibold text-zinc-200">
                        Nazwa szkolenia
                      </label>

                      <input
                        type="text"
                        value={editTitle}
                        onChange={(e) => setEditTitle(e.target.value)}
                        placeholder="Np. Szkolenie pistolet podstawowy"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                      />

                      <FieldHelp>
                        Krótka nazwa szkolenia widoczna dla klienta.
                      </FieldHelp>
                    </div>

                    <div>
                      <label className="mb-2 block text-sm font-semibold text-zinc-200">
                        Opis szkolenia
                      </label>

                      <textarea
                        value={editDescription}
                        onChange={(e) => setEditDescription(e.target.value)}
                        rows={5}
                        placeholder="Opis szkolenia, wymagania, zakres, informacje organizacyjne..."
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                      />

                      <FieldHelp>
                        Opisz zakres szkolenia i najważniejsze informacje dla
                        uczestnika.
                      </FieldHelp>
                    </div>

                    <div>
                      <p className="mb-4 text-sm font-bold uppercase tracking-[0.16em] text-zinc-300">
                        Termin, uczestnicy i cena
                      </p>
                      <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-5">
                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Data szkolenia
                        </label>

                        <input
                          type="date"
                          value={editEventDate}
                          onChange={(e) => setEditEventDate(e.target.value)}
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                        />

                        <FieldHelp>Dzień, w którym odbędzie się szkolenie.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Godzina rozpoczęcia
                        </label>

                        <input
                          type="time"
                          value={editStartTime}
                          onChange={(e) => setEditStartTime(e.target.value)}
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                        />

                        <FieldHelp>Godzina startu szkolenia.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Godzina zakończenia
                        </label>

                        <input
                          type="time"
                          value={editEndTime}
                          onChange={(e) => setEditEndTime(e.target.value)}
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                        />

                        <FieldHelp>Godzina zakończenia szkolenia.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Cena
                        </label>

                        <input
                          type="number"
                          min="0"
                          value={editPrice}
                          onChange={(e) => setEditPrice(e.target.value)}
                          placeholder="Np. 250"
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                        />

                        <FieldHelp>Cena za jednego uczestnika.</FieldHelp>
                      </div>

                      <div>
                        <label className="mb-2 block text-sm font-semibold text-zinc-200">
                          Liczba miejsc
                        </label>

                        <input
                          type="number"
                          min="1"
                          value={editMaxParticipants}
                          onChange={(e) =>
                            setEditMaxParticipants(e.target.value)
                          }
                          placeholder="Np. 10"
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                        />

                        <FieldHelp>
                          Limit uczestników. Wolne miejsca liczy system.
                        </FieldHelp>
                      </div>
                      </div>
                    </div>

                    <div>
                      <p className="mb-3 text-sm font-bold uppercase tracking-[0.16em] text-zinc-300">
                        Lokalizacja
                      </p>
                      <label className="mb-2 block text-sm font-semibold text-zinc-200">
                        Miejsce / oś
                      </label>

                      <input
                        type="text"
                        value={editLocation}
                        onChange={(e) => setEditLocation(e.target.value)}
                        placeholder="Np. Oś 25 m, sala szkoleniowa, oś 100 m"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition placeholder:text-zinc-600 hover:border-zinc-600 focus:border-[#6b7d3b] focus:ring-1 focus:ring-[#6b7d3b]"
                      />

                      <FieldHelp>
                        Miejsce prowadzenia szkolenia albo konkretna oś.
                      </FieldHelp>
                    </div>

                    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                      <p className="text-sm font-semibold text-zinc-200">
                        Zajmowane osie
                      </p>
                      <p className="mt-1 text-sm text-zinc-400">
                        Brak zaznaczonych osi oznacza event globalny.
                      </p>

                      <div className="mt-3">
                        <LaneSelectionSummary lanes={selectedEditLanes} />
                      </div>

                      {activeLanesLoading ? (
                        <p className="mt-3 text-sm text-zinc-400">Ładowanie osi…</p>
                      ) : activeLanesError ? (
                        <p className="mt-3 text-sm text-red-300">
                          {ACTIVE_LANES_LOAD_ERROR_MESSAGE}
                        </p>
                      ) : activeLanesLoaded && editableLanes.length === 0 ? (
                        <p className="mt-3 text-sm text-zinc-400">Brak aktywnych osi.</p>
                      ) : (
                        <div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
                          {editableLanes.map((lane) => {
                            const isSelected = editLaneIds.includes(lane.id);
                            const isInitiallyInactive = editInitialInactiveLaneIds.includes(
                              lane.id
                            );
                            const isDisabled =
                              editSubmitting ||
                              (!lane.is_active &&
                                (!isInitiallyInactive || !isSelected));

                            return (
                              <label
                                key={lane.id}
                                className={`flex min-h-11 max-w-full items-center gap-2 rounded-xl border px-3 py-2 text-sm font-semibold transition ${
                                  isSelected
                                    ? "border-[#6b7d3b] bg-[#29321c] text-lime-100"
                                    : "border-zinc-700 bg-zinc-900 text-zinc-200"
                                } ${isDisabled ? "cursor-not-allowed opacity-60" : "cursor-pointer hover:border-zinc-500"}`}
                              >
                                <input
                                  type="checkbox"
                                  checked={isSelected}
                                  disabled={isDisabled}
                                  onChange={() =>
                                    toggleEditLane(
                                      lane.id,
                                      lane.is_active,
                                      editableLanes
                                    )
                                  }
                                />
                                <span className="break-words">{lane.name}</span>
                                {!lane.is_active ? (
                                  <span className="rounded-full bg-amber-950 px-2 py-0.5 text-xs text-amber-200">
                                    Nieaktywna
                                  </span>
                                ) : null}
                              </label>
                            );
                          })}
                        </div>
                      )}
                    </div>

                    <div className="rounded-xl border border-[#59663a] bg-[#252b1e] p-4 text-sm text-zinc-200">
                      <p className="font-semibold">
                        Wolnych miejsc nie edytujesz ręcznie
                      </p>
                      <p className="mt-1 text-zinc-400">
                        System wylicza je automatycznie z liczby miejsc i liczby
                        zapisanych uczestników.
                      </p>
                    </div>

                    <div className="flex flex-col gap-3 sm:flex-row">
                      <button
                        type="button"
                        onClick={() => saveEditedEvent(event.id)}
                        disabled={editSubmitting}
                        className="rounded-xl border border-amber-700/70 bg-[#556b2f] px-5 py-3 text-sm font-semibold text-white transition hover:bg-[#657d3d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-400 disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        {editSubmitting ? "Zapisywanie…" : "Zapisz zmiany"}
                      </button>

                      <button
                        type="button"
                        onClick={cancelEditing}
                        disabled={editSubmitting}
                        className="rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Anuluj edycję
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                      <div className="max-w-4xl">
                        <span
                          className={
                            event.is_active
                              ? "mb-3 inline-block rounded-full border border-[#6b7d3b] bg-[#29321c] px-3 py-1 text-xs font-semibold text-lime-100"
                              : "mb-3 inline-block rounded-full border border-zinc-700 bg-zinc-800 px-3 py-1 text-xs font-semibold text-zinc-300"
                          }
                        >
                          {event.is_active ? "Aktywny" : "Ukryty"}
                        </span>

                        <h2 className="mb-3 break-words text-2xl font-bold sm:text-3xl">
                          {event.title}
                        </h2>

                        <p className="mb-5 whitespace-pre-line text-zinc-300">
                          {event.description}
                        </p>

                        <div className="grid gap-3 text-sm text-zinc-400 sm:grid-cols-2 xl:grid-cols-5">
                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                            <p className="mb-1 text-zinc-500">Data</p>
                            <p className="font-semibold text-white">
                              {event.event_date}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                            <p className="mb-1 text-zinc-500">Godzina</p>
                            <p className="font-semibold text-white">
                              {event.start_time.slice(0, 5)} -{" "}
                              {event.end_time.slice(0, 5)}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                            <p className="mb-1 text-zinc-500">Miejsce</p>
                            <p className="font-semibold text-white">
                              {event.location}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                            <p className="mb-1 text-zinc-500">Cena</p>
                            <p className="font-semibold text-green-500">
                              {Number(event.price).toFixed(0)} zł
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                            <p className="mb-1 text-zinc-500">Miejsca</p>
                            <p className="font-semibold text-white">
                              Limit: {event.max_participants}
                            </p>
                            {freePlaces !== null && (
                              <p className="mt-1 text-xs font-semibold text-green-400">
                                Wolne: {freePlaces}
                              </p>
                            )}

                            {selectedEventId === event.id && (
                              <div className="mt-3 space-y-1 border-t border-zinc-800 pt-3 text-xs">
                                <p className="font-semibold text-green-400">
                                  Uczestnicy: {activeRegistrationsCount} / {event.max_participants}
                                </p>
                                <p className="font-semibold text-yellow-300">
                                  Lista rezerwowa: {reserveRegistrationsCount}
                                </p>
                                <p className="font-semibold text-red-300">
                                  Anulowani: {cancelledRegistrationsCount}
                                </p>
                              </div>
                            )}
                          </div>
                        </div>

                        <EventLanesSummary lanes={event.lanes} />
                      </div>

                      <div className="flex w-full flex-col gap-3 lg:w-56 lg:shrink-0">
                        {canManageEvents && (
                          <button
                            type="button"
                            onClick={() => startEditing(event)}
                            disabled={editSubmitting || isTogglePending}
                            className="rounded-xl border border-blue-800 px-4 py-3 text-sm font-semibold text-blue-300 transition hover:bg-blue-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Edytuj szkolenie
                          </button>
                        )}

                        <button
                          type="button"
                          onClick={() => loadRegistrations(event.id)}
                          className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold transition hover:bg-zinc-800"
                        >
                          Pokaż zapisanych
                        </button>

                        {canManageEvents && (
                          <button
                            type="button"
                            onClick={() =>
                              toggleEvent(event.id, event.is_active)
                            }
                            disabled={isTogglePending || editingEventId === event.id}
                            className={
                              event.is_active
                                ? "rounded-xl border border-red-800 px-4 py-3 text-sm font-semibold text-red-400 transition hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-60"
                                : "rounded-xl border border-green-800 px-4 py-3 text-sm font-semibold text-green-400 transition hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-60"
                            }
                          >
                            {isTogglePending
                              ? toggleTargetStatus
                                ? "Aktywowanie…"
                                : "Ukrywanie…"
                              : event.is_active
                                ? "Ukryj szkolenie"
                                : "Aktywuj szkolenie"}
                          </button>
                        )}
                      </div>
                    </div>

                    {selectedEventId === event.id && (
                      <div className="mt-6 rounded-2xl border border-zinc-800 bg-zinc-950 p-5">
                        <h3 className="mb-5 text-xl font-bold">
                          Lista zapisanych osób
                        </h3>

                        {registrations.length === 0 ? (
                          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-zinc-400">
                            Brak zapisanych osób.
                          </div>
                        ) : (
                          <div className="grid gap-5">
                            {participantRegistrations.length > 0 && (
                              <div className="rounded-xl border border-green-900 bg-green-950/20 p-4">
                                <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
                                  <div>
                                    <h4 className="text-lg font-bold text-green-300">
                                      Uczestnicy
                                    </h4>
                                    <p className="text-sm text-zinc-400">
                                      Osoby zapisane jako uczestnicy szkolenia.
                                    </p>
                                  </div>

                                  <span className="rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-300">
                                    {participantRegistrations.length} / {event.max_participants}
                                  </span>
                                </div>

                                <div className="overflow-x-auto">
                                  <table className="min-w-full text-sm">
                                    <thead>
                                      <tr className="border-b border-zinc-800 text-left text-zinc-500">
                                        <th className="px-4 py-3">Imię i nazwisko</th>
                                        <th className="px-4 py-3">E-mail</th>
                                        <th className="px-4 py-3">Telefon</th>
                                        <th className="px-4 py-3">Status</th>
                                        <th className="px-4 py-3">Płatność</th>
                                        {canManageEvents && (
                                          <th className="px-4 py-3">Akcje</th>
                                        )}
                                      </tr>
                                    </thead>

                                    <tbody>
                                      {participantRegistrations.map((registration) => (
                                        <tr key={registration.id} className="border-b border-zinc-900">
                                          <td className="px-4 py-4 font-semibold">
                                            {registration.customer_name}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_email}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_phone}
                                          </td>
                                          <td className="px-4 py-4">
                                            <span className={getStatusClass(registration.registration_status)}>
                                              {translateRegistrationStatus(registration.registration_status)}
                                            </span>
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.payment_status === "paid_on_site"
                                              ? "Opłacone"
                                              : "Płatność na miejscu"}
                                          </td>
                                          {canManageEvents && (
                                            <td className="px-4 py-4">
                                              <div className="flex flex-wrap gap-2">
                                              <button
                                                type="button"
                                                onClick={() => approveRegistration(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-green-800 px-3 py-2 text-xs text-green-300 hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                {registrationActions[registration.id] === "approve"
                                                  ? "Zatwierdzanie..."
                                                  : "Zatwierdź"}
                                              </button>

                                              <button
                                                type="button"
                                                onClick={() => markRegistrationPaid(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-blue-800 px-3 py-2 text-xs text-blue-300 hover:bg-blue-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                Opłacone
                                              </button>

                                              <button
                                                type="button"
                                                onClick={() => cancelRegistration(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-red-800 px-3 py-2 text-xs text-red-300 hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                {registrationActions[registration.id] === "cancel"
                                                  ? "Anulowanie..."
                                                  : "Anuluj"}
                                              </button>
                                              </div>
                                            </td>
                                          )}
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              </div>
                            )}

                            {reserveRegistrations.length > 0 && (
                              <div className="rounded-xl border border-yellow-900 bg-yellow-950/20 p-4">
                                <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
                                  <div>
                                    <h4 className="text-lg font-bold text-yellow-300">
                                      Lista rezerwowa
                                    </h4>
                                    <p className="text-sm text-zinc-400">
                                      Kolejność według daty zapisu. Pierwsza osoba na liście ma najwyższy priorytet.
                                    </p>
                                  </div>

                                  <span className="rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300">
                                    {reserveRegistrations.length}
                                  </span>
                                </div>

                                <div className="overflow-x-auto">
                                  <table className="min-w-full text-sm">
                                    <thead>
                                      <tr className="border-b border-zinc-800 text-left text-zinc-500">
                                        <th className="px-4 py-3">Kolejka</th>
                                        <th className="px-4 py-3">Imię i nazwisko</th>
                                        <th className="px-4 py-3">E-mail</th>
                                        <th className="px-4 py-3">Telefon</th>
                                        <th className="px-4 py-3">Status</th>
                                        <th className="px-4 py-3">Płatność</th>
                                        {canManageEvents && (
                                          <th className="px-4 py-3">Akcje</th>
                                        )}
                                      </tr>
                                    </thead>

                                    <tbody>
                                      {reserveRegistrations.map((registration, index) => (
                                        <tr key={registration.id} className="border-b border-zinc-900">
                                          <td className="px-4 py-4 font-bold text-yellow-300">
                                            #{index + 1}
                                          </td>
                                          <td className="px-4 py-4 font-semibold">
                                            {registration.customer_name}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_email}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_phone}
                                          </td>
                                          <td className="px-4 py-4">
                                            <span className={getStatusClass(registration.registration_status)}>
                                              {translateRegistrationStatus(registration.registration_status)}
                                            </span>
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.payment_status === "paid_on_site"
                                              ? "Opłacone"
                                              : "Płatność na miejscu"}
                                          </td>
                                          {canManageEvents && (
                                            <td className="px-4 py-4">
                                              <div className="flex flex-wrap gap-2">
                                              <button
                                                type="button"
                                                onClick={() => markRegistrationPaid(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-blue-800 px-3 py-2 text-xs text-blue-300 hover:bg-blue-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                Opłacone
                                              </button>

                                              <button
                                                type="button"
                                                onClick={() => cancelRegistration(registration.id)}
                                                disabled={Boolean(registrationActions[registration.id])}
                                                className="rounded-lg border border-red-800 px-3 py-2 text-xs text-red-300 hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
                                              >
                                                {registrationActions[registration.id] === "cancel"
                                                  ? "Anulowanie..."
                                                  : "Anuluj"}
                                              </button>
                                              </div>
                                            </td>
                                          )}
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              </div>
                            )}

                            {cancelledRegistrations.length > 0 && (
                              <div className="rounded-xl border border-red-900 bg-red-950/20 p-4">
                                <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
                                  <div>
                                    <h4 className="text-lg font-bold text-red-300">
                                      Anulowani
                                    </h4>
                                    <p className="text-sm text-zinc-400">
                                      Osoby, których zapis został anulowany.
                                    </p>
                                  </div>

                                  <span className="rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300">
                                    {cancelledRegistrations.length}
                                  </span>
                                </div>

                                <div className="overflow-x-auto">
                                  <table className="min-w-full text-sm">
                                    <thead>
                                      <tr className="border-b border-zinc-800 text-left text-zinc-500">
                                        <th className="px-4 py-3">Imię i nazwisko</th>
                                        <th className="px-4 py-3">E-mail</th>
                                        <th className="px-4 py-3">Telefon</th>
                                        <th className="px-4 py-3">Status</th>
                                        <th className="px-4 py-3">Płatność</th>
                                      </tr>
                                    </thead>

                                    <tbody>
                                      {cancelledRegistrations.map((registration) => (
                                        <tr key={registration.id} className="border-b border-zinc-900">
                                          <td className="px-4 py-4 font-semibold">
                                            {registration.customer_name}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_email}
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.customer_phone}
                                          </td>
                                          <td className="px-4 py-4">
                                            <span className={getStatusClass(registration.registration_status)}>
                                              {translateRegistrationStatus(registration.registration_status)}
                                            </span>
                                          </td>
                                          <td className="px-4 py-4 text-zinc-300">
                                            {registration.payment_status === "paid_on_site"
                                              ? "Opłacone"
                                              : "Płatność na miejscu"}
                                          </td>
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              </div>
                            )}
                          </div>
                        )}
                      </div>
                    )}
                  </>
                )}
              </div>
            );
          })}
        </div>

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/admin"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel administratora
          </a>

          <a
            href="/events"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Zobacz stronę szkoleń
          </a>
        </div>

        {createConfirmation && (
          <div
            className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
            onMouseDown={(event) => {
              if (event.target === event.currentTarget) {
                closeCreateConfirmation();
              }
            }}
          >
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="create-event-confirmation-title"
              className="max-h-[calc(100vh-2rem)] w-full max-w-2xl overflow-y-auto rounded-3xl border border-zinc-700 bg-zinc-900 p-5 shadow-2xl sm:p-6"
            >
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-amber-300">
                Nowe wydarzenie
              </p>
              <h2
                id="create-event-confirmation-title"
                className="mt-2 text-2xl font-bold text-white"
              >
                Potwierdź dodanie szkolenia
              </h2>
              <p className="mt-2 text-sm text-zinc-400">
                Sprawdź dane przed utworzeniem wydarzenia.
              </p>

              <div className="mt-6 grid gap-3 text-sm sm:grid-cols-2">
                <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3 sm:col-span-2">
                  <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">
                    Nazwa szkolenia
                  </p>
                  <p className="mt-1 break-words font-semibold text-white">
                    {createConfirmation.payload.p_title}
                  </p>
                </div>
                <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                  <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Data</p>
                  <p className="mt-1 font-semibold text-white">
                    {formatConfirmationDate(createConfirmation.payload.p_event_date)}
                  </p>
                </div>
                <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                  <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Godzina</p>
                  <p className="mt-1 font-semibold text-white">
                    {createConfirmation.payload.p_start_time}–{createConfirmation.payload.p_end_time}
                  </p>
                </div>
                <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                  <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Lokalizacja</p>
                  <p className="mt-1 break-words font-semibold text-white">
                    {createConfirmation.payload.p_location || "Nie podano"}
                  </p>
                </div>
                <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
                  <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Cena i limit</p>
                  <p className="mt-1 font-semibold text-white">
                    {formatConfirmationPrice(createConfirmation.payload.p_price)} · {createConfirmation.payload.p_max_participants} osób
                  </p>
                </div>
              </div>

              {createConfirmation.payload.p_description && (
                <div className="mt-3 rounded-xl border border-zinc-800 bg-zinc-950 p-3 text-sm">
                  <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Opis</p>
                  <p className="mt-1 line-clamp-3 break-words text-zinc-300">
                    {createConfirmation.payload.p_description}
                  </p>
                </div>
              )}

              <div className="mt-3">
                <LaneSelectionSummary lanes={createConfirmation.lanes} />
              </div>

              {createMessage?.kind === "error" && (
                <div className="mt-3 rounded-xl border border-red-800 bg-red-950 p-3 text-sm font-semibold text-red-300">
                  {createMessage.message}
                </div>
              )}

              <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                <button
                  ref={createConfirmationButtonRef}
                  type="button"
                  onClick={closeCreateConfirmation}
                  disabled={createSubmitting}
                  className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-200 transition hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  Wróć do edycji
                </button>
                <button
                  type="button"
                  onClick={confirmCreateEvent}
                  disabled={createSubmitting}
                  className="rounded-xl border border-amber-700/70 bg-[#556b2f] px-4 py-3 text-sm font-semibold text-white transition hover:bg-[#657d3d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-400 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {createSubmitting ? "Dodawanie…" : "Potwierdź i dodaj"}
                </button>
              </div>
            </div>
          </div>
        )}
      </section>
    </main>
  );
}
