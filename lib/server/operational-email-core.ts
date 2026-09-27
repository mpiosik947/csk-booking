import { PLATFORM_BASE_URL } from "../platform-domain.ts";
import { escapeHtml } from "./email-html.ts";

export type OperationalEmailResource = Readonly<{
  resourceType: "reservation" | "event" | "event_registration";
  resourceId: string;
}>;
export type OperationalEmailTenantContext = Readonly<{
  tenantId: string;
  tenantSlug: string;
  publicSlug: string;
  displayName: string;
  canonicalPublicUrl: string;
}>;
export type OperationalEmailInput<Operation> = Readonly<{
  tenant: OperationalEmailTenantContext;
  operation: Operation;
}>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const slug = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const unavailable = () => new Error("Operational email context unavailable");

export function buildOperationalEmailSubject({ tenantDisplayName, notificationLabel }: {
  tenantDisplayName: string; notificationLabel: string;
}) {
  for (const value of [tenantDisplayName, notificationLabel]) {
    if (!value.trim() || value.length > 200 || /[\r\n\x00-\x1f\x7f]/.test(value)) throw unavailable();
  }
  return `StrzelajTu.pl / ${tenantDisplayName.trim()} — ${notificationLabel.trim()}`;
}
export function operationalEmailBrand(tenant: OperationalEmailTenantContext, label: string) {
  return {
    subject: buildOperationalEmailSubject({ tenantDisplayName: tenant.displayName, notificationLabel: label }),
    headerHtml: `StrzelajTu.pl<br><span>${escapeHtml(tenant.displayName)}</span>`,
    headerText: `StrzelajTu.pl\n${tenant.displayName}`,
    footerHtml: `${escapeHtml(tenant.displayName)} · StrzelajTu.pl`,
    footerText: `${tenant.displayName}\nStrzelajTu.pl`,
  };
}
export function operationalEmailHistoryUrl(tenant: OperationalEmailTenantContext, kind: "events" | "reservations") {
  if (!slug.test(tenant.tenantSlug) || !["events", "reservations"].includes(kind)) throw unavailable();
  return `${PLATFORM_BASE_URL}/t/${tenant.tenantSlug}/my-${kind}`;
}
export function operationalEmailActionUrl(kind: "check-in" | "events/confirm", token: string) {
  if (!["check-in", "events/confirm"].includes(kind) || !uuid.test(token)) throw unavailable();
  return `${PLATFORM_BASE_URL}/${kind}/${token}`;
}
