export type AdminEventRegistration = {
  id: string;
  customer_name: string;
  customer_email: string;
  customer_phone: string;
  registration_status: string;
  payment_status: string;
  created_at: string | null;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ROW_KEYS = [
  "created_at",
  "customer_email",
  "customer_name",
  "customer_phone",
  "id",
  "payment_status",
  "registration_status",
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function parseAdminEventRegistration(
  value: unknown
): AdminEventRegistration | null {
  if (!isRecord(value)) return null;

  const keys = Object.keys(value).sort();
  if (
    keys.length !== ROW_KEYS.length ||
    !keys.every((key, index) => key === ROW_KEYS[index])
  ) {
    return null;
  }

  if (
    typeof value.id !== "string" ||
    !UUID_PATTERN.test(value.id) ||
    typeof value.customer_name !== "string" ||
    typeof value.customer_email !== "string" ||
    typeof value.customer_phone !== "string" ||
    typeof value.registration_status !== "string" ||
    value.registration_status.trim().length === 0 ||
    typeof value.payment_status !== "string" ||
    value.payment_status.trim().length === 0 ||
    (value.created_at !== null &&
      (typeof value.created_at !== "string" ||
        !Number.isFinite(Date.parse(value.created_at))))
  ) {
    return null;
  }

  return {
    id: value.id,
    customer_name: value.customer_name,
    customer_email: value.customer_email,
    customer_phone: value.customer_phone,
    registration_status: value.registration_status,
    payment_status: value.payment_status,
    created_at: value.created_at,
  };
}

export function parseAdminEventRegistrations(value: unknown) {
  if (!Array.isArray(value)) return null;

  const registrations: AdminEventRegistration[] = [];
  const registrationIds = new Set<string>();

  for (const item of value) {
    const registration = parseAdminEventRegistration(item);
    if (!registration || registrationIds.has(registration.id)) return null;

    registrationIds.add(registration.id);
    registrations.push(registration);
  }

  return registrations;
}
