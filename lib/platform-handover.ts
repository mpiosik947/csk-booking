import { uuid } from "./platform-wizard.ts";
import { readReadiness, type Readiness } from "./platform-draft-readiness.ts";

export type HandoverAttempt = { tenantId: string; userId: string; revision: string; requestId: string; email: string };
export type HandoverReceipt = { tenantId: string; userId: string; actorId: string; revision: string; requestId: string; handedAt: string };
export type HandoverState = { tenantId: string; name: string; slug: string; status: string; publicAccess: "live" | "coming_soon"; isPublic: boolean; adminCount: number; receipt: HandoverReceipt | null; adminEmail: string | null; readiness: Readiness | null };
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const revision = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
export const handoverStorageKey = (actor: string, tenant: string) => `strzelajtu:handover:v1:${actor}:${tenant}`;

export function readHandoverReceipt(value: unknown, tenantId: string): HandoverReceipt | null {
  if (!object(value) || value.tenant_id !== tenantId || !uuid(tenantId) || !uuid(value.selected_admin_user_id) || !uuid(value.actor_user_id) || !uuid(value.request_id) || !revision(value.configuration_revision) || typeof value.handed_over_at !== "string" || !Number.isFinite(Date.parse(value.handed_over_at))) return null;
  return { tenantId, userId: value.selected_admin_user_id, actorId: value.actor_user_id, requestId: value.request_id, revision: value.configuration_revision, handedAt: value.handed_over_at };
}
export function matchesHandover(receipt: HandoverReceipt, attempt: HandoverAttempt, actorId: string): boolean {
  return receipt.tenantId === attempt.tenantId && receipt.userId === attempt.userId && receipt.actorId === actorId && receipt.requestId === attempt.requestId && receipt.revision === attempt.revision;
}
export function readHandover(value: unknown, tenantId: string): HandoverState | null {
  if (!object(value) || value.tenant_id !== tenantId || !uuid(tenantId) || typeof value.name !== "string" || typeof value.tenant_slug !== "string" || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value.tenant_slug) || !["dormant", "active", "suspended", "archived"].includes(String(value.status)) || !["live", "coming_soon"].includes(String(value.public_access_state)) || typeof value.is_public !== "boolean" || !Number.isSafeInteger(value.active_admin_count) || Number(value.active_admin_count) < 0) return null;
  const receipt = value.handover === null ? null : readHandoverReceipt(value.handover, tenantId);
  const readiness = value.handover === null ? readReadiness(value.readiness, tenantId) : null;
  if (value.handover !== null && (!receipt || !object(value.handover) || (value.handover.selected_admin_email !== null && typeof value.handover.selected_admin_email !== "string") || value.readiness !== null)) return null;
  if (value.handover === null && !readiness) return null;
  return { tenantId, name: value.name, slug: value.tenant_slug, status: String(value.status), publicAccess: value.public_access_state as HandoverState["publicAccess"], isPublic: value.is_public, adminCount: Number(value.active_admin_count), receipt, adminEmail: object(value.handover) ? value.handover.selected_admin_email as string | null : null, readiness };
}
export function parseHandoverAttempt(raw: string, tenantId: string): HandoverAttempt | null {
  try { const a: unknown = JSON.parse(raw); return object(a) && a.tenantId === tenantId && uuid(tenantId) && uuid(a.userId) && uuid(a.requestId) && revision(a.revision) && typeof a.email === "string" && a.email.length <= 254 ? { tenantId, userId: a.userId, requestId: a.requestId, revision: a.revision, email: a.email } : null; } catch { return null; }
}
export function handoverError(error: { code?: string; status?: number; message?: string }): { kind: "denied" | "conflict" | "blocked" | "uncertain"; message: string } {
  if ([401, 403].includes(error.status ?? 0) || ["42501", "401", "403", "PGRST301", "PGRST302", "PGRST303"].includes(error.code ?? "")) return { kind: "denied", message: "Brak dostępu do przekazania obiektu. Wróć do listy obiektów." };
  if (error.code === "PT409") return { kind: "conflict", message: "Stan obiektu lub próby zmienił się. Odczytaj aktualne dane i sprawdź gotowość przed kolejnym potwierdzeniem." };
  if (["55000", "22023", "23514", "23505"].includes(error.code ?? "")) return { kind: "blocked", message: "Przekazanie zablokowane. Wymagana jest aktualna walidacja, dostępne konto i brak wcześniejszych członkostw." };
  return { kind: "uncertain", message: "Nie potwierdzono wyniku przekazania. Zachowano dokładną próbę; odczytaj wynik lub ponów ją." };
}
