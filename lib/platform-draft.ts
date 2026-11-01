import { identityValid, slugError, uuid, type ErrorKind } from "./platform-wizard.ts";

export type Payload = { p_name: string; p_city: string; p_tenant_slug: string; p_public_slug: string; p_plan_key: string | null };
export type Attempt = { version: 2; requestId: string; payload: Payload; state: "uncertain" | "confirmed" | "failed"; tenantId?: string; failure?: ErrorKind };
export const storageKey = (actor: string) => `strzelajtu:draft:v2:${actor}`;
export function readAttempt(raw: string): Attempt | null {
  try {
    const a = JSON.parse(raw), p = a?.payload;
    if (!a || a.version !== 2 || !uuid(a.requestId) || !p || typeof p !== "object" || Array.isArray(p) || Object.keys(p).length !== 5 || !["uncertain", "confirmed", "failed"].includes(a.state)) return null;
    if (["p_name", "p_city", "p_tenant_slug", "p_public_slug"].some(k => typeof p[k] !== "string") || !identityValid(p.p_name) || !identityValid(p.p_city) || slugError(p.p_tenant_slug) || slugError(p.p_public_slug) || p.p_tenant_slug === p.p_public_slug || !(p.p_plan_key === null || (typeof p.p_plan_key === "string" && /^[a-z][a-z0-9_]{1,62}$/.test(p.p_plan_key)))) return null;
    if (a.state === "confirmed" && !uuid(a.tenantId)) return null;
    if (a.failure !== undefined && !["retry", "plan", "slug", "conflict", "denied", "invalid"].includes(a.failure)) return null;
    return { version: 2, requestId: a.requestId, payload: { ...p }, state: a.state, ...(uuid(a.tenantId) ? { tenantId: a.tenantId } : {}), ...(a.failure ? { failure: a.failure } : {}) };
  } catch { return null; }
}
export function receiptId(value: unknown, a: Attempt): string | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const r = value as Record<string, unknown>, p = a.payload;
  return uuid(r.tenant_id) && r.creation_request_id === a.requestId && r.name === p.p_name && r.city === p.p_city && r.tenant_slug === p.p_tenant_slug && r.public_slug === p.p_public_slug && r.plan_key === p.p_plan_key && r.initial_status === "dormant" && r.initial_is_public === false && r.initial_public_access_state === "coming_soon" ? r.tenant_id : null;
}
