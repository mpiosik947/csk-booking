export const EVENT_REGISTRATION_STATUS = {
  REGISTERED: "registered",
  APPROVED: "approved",
  RESERVE: "reserve",
  CANCELLED: "cancelled",
  PARTICIPANT: "participant",
} as const;

export type EventRegistrationStatus =
  (typeof EVENT_REGISTRATION_STATUS)[keyof typeof EVENT_REGISTRATION_STATUS];

export type EventRegistrationStatusTone =
  | "registered"
  | "approved"
  | "reserve"
  | "cancelled"
  | "legacy"
  | "unknown";

export type EventRegistrationStatusPresentation = {
  status: EventRegistrationStatus | null;
  label: string;
  tone: EventRegistrationStatusTone;
  occupiesPlace: boolean;
  userCanCancel: boolean;
  adminCanApprove: boolean;
  adminCanMarkPayment: boolean;
  adminCanCancel: boolean;
};

const STATUS_PRESENTATIONS: Record<
  EventRegistrationStatus,
  EventRegistrationStatusPresentation
> = {
  [EVENT_REGISTRATION_STATUS.REGISTERED]: {
    status: EVENT_REGISTRATION_STATUS.REGISTERED,
    label: "Zapisany",
    tone: "registered",
    occupiesPlace: true,
    userCanCancel: true,
    adminCanApprove: true,
    adminCanMarkPayment: true,
    adminCanCancel: true,
  },
  [EVENT_REGISTRATION_STATUS.APPROVED]: {
    status: EVENT_REGISTRATION_STATUS.APPROVED,
    label: "Zatwierdzony",
    tone: "approved",
    occupiesPlace: true,
    userCanCancel: true,
    adminCanApprove: false,
    adminCanMarkPayment: true,
    adminCanCancel: true,
  },
  [EVENT_REGISTRATION_STATUS.RESERVE]: {
    status: EVENT_REGISTRATION_STATUS.RESERVE,
    label: "Lista rezerwowa",
    tone: "reserve",
    occupiesPlace: false,
    userCanCancel: true,
    adminCanApprove: false,
    adminCanMarkPayment: true,
    adminCanCancel: true,
  },
  [EVENT_REGISTRATION_STATUS.CANCELLED]: {
    status: EVENT_REGISTRATION_STATUS.CANCELLED,
    label: "Anulowany",
    tone: "cancelled",
    occupiesPlace: false,
    userCanCancel: false,
    adminCanApprove: false,
    adminCanMarkPayment: false,
    adminCanCancel: false,
  },
  [EVENT_REGISTRATION_STATUS.PARTICIPANT]: {
    status: EVENT_REGISTRATION_STATUS.PARTICIPANT,
    label: "Uczestnik",
    tone: "legacy",
    occupiesPlace: false,
    userCanCancel: true,
    adminCanApprove: false,
    adminCanMarkPayment: false,
    adminCanCancel: true,
  },
};

const UNKNOWN_PRESENTATION: EventRegistrationStatusPresentation = {
  status: null,
  label: "Nieznany status",
  tone: "unknown",
  occupiesPlace: false,
  userCanCancel: false,
  adminCanApprove: false,
  adminCanMarkPayment: false,
  adminCanCancel: false,
};

export function normalizeEventRegistrationStatus(
  status: string | null | undefined
): EventRegistrationStatus | null {
  const normalized = status?.trim().toLowerCase();

  if (!normalized || !(normalized in STATUS_PRESENTATIONS)) {
    return null;
  }

  return normalized as EventRegistrationStatus;
}

export function getEventRegistrationStatusPresentation(
  status: string | null | undefined
) {
  const normalized = normalizeEventRegistrationStatus(status);
  return normalized ? STATUS_PRESENTATIONS[normalized] : UNKNOWN_PRESENTATION;
}

export function getEventRegistrationStatusBadgeClass(
  status: string | null | undefined
) {
  const { tone } = getEventRegistrationStatusPresentation(status);

  if (tone === "approved") {
    return "rounded-full border border-[#3f6848] bg-[#1b2a1d] px-3 py-1 text-xs font-semibold text-[#a9d4ad]";
  }

  if (tone === "registered") {
    return "rounded-full border border-[#3f5f76] bg-[#17232b] px-3 py-1 text-xs font-semibold text-[#9fc7df]";
  }

  if (tone === "reserve") {
    return "rounded-full border border-[#806a32] bg-[#2b2618] px-3 py-1 text-xs font-semibold text-[#e1c477]";
  }

  if (tone === "cancelled") {
    return "rounded-full border border-[#744545] bg-[#2a1b1b] px-3 py-1 text-xs font-semibold text-[#e0a0a0]";
  }

  return "rounded-full border border-[#343a31] bg-[#171a17] px-3 py-1 text-xs font-semibold text-[#858c7f]";
}
