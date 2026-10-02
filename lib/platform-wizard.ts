export type Plan = { plan_key: string; display_name: string; status: "active"; features: { feature_key: string; description: string }[] };
export type Account = { user_id: string; email: string };
export type Payload = { p_name: string; p_city: string; p_tenant_slug: string; p_public_slug: string; p_plan_key: string; p_initial_admin_user_id: string };
export type ErrorKind = "retry" | "plan" | "admin" | "slug" | "conflict" | "denied" | "invalid";
export type Attempt = { version: 1; requestId: string; payload: Payload; adminEmail: string; state: "uncertain" | "confirmed" | "failed"; tenantId?: string; failure?: ErrorKind };
export type Readiness = { create_ready: boolean; activation_ready: boolean; public_ready: boolean; booking_ready: boolean; booking_required: boolean; publication_gate_enforced: boolean; checks: Record<string, boolean> };
export type Detail = { tenant: { tenant_id: string; name: string; technical_slug: string; status: string }; public_profile: { display_name: string; city: string; public_slug: string; is_public: boolean } | null; plan: { plan_key: string; status: string; assignment_status: string; enabled_feature_keys: string[] } | null; admins: { user_id: string; email: string | null }[]; readiness: Readiness };
const object = (v: unknown): Record<string, unknown> | null => v !== null && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
export const uuid = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
export const reservedSlugs = ["account", "admin", "api", "auth", "booking", "check-in", "dashboard", "events", "forgot-password", "login", "my-events", "my-reservations", "privacy", "register", "reset-password", "t", "terms", "platform-admin", "continuity", "tenant-setup"];
export const normalizeSlug = (v: string) => v.trim().toLowerCase();
export function slugError(v: string): string {
  if (reservedSlugs.includes(v)) return "Ta nazwa adresu jest zarezerwowana.";
  return v.length >= 2 && v.length <= 63 && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(v) ? "" : "Adres: 2–63 znaki, małe litery, cyfry i pojedyncze łączniki.";
}
export const identityValid = (v: string) => Array.from(v.trim()).length >= 1 && Array.from(v.trim()).length <= 120;
export const storageKey = (actor: string) => `strzelajtu:onboard:v1:${actor}`;
export function readPlans(value: unknown): Plan[] | null {
  if (!Array.isArray(value)) return null;
  const result: Plan[] = [];
  for (const item of value) {
    const p = object(item);
    if (!p || typeof p.plan_key !== "string" || typeof p.display_name !== "string" || p.status !== "active" || !Array.isArray(p.features)) return null;
    const features: Plan["features"] = [];
    for (const item of p.features) { const f = object(item); if (!f || typeof f.feature_key !== "string" || typeof f.description !== "string") return null; features.push({ feature_key: f.feature_key, description: f.description }); }
    result.push({ plan_key: p.plan_key, display_name: p.display_name, status: "active", features });
  }
  return result;
}
export function readAccount(v: unknown): Account | null { const a = object(v); return a && uuid(a.user_id) && typeof a.email === "string" ? { user_id: a.user_id, email: a.email } : null; }
export function readReadiness(v: unknown): Readiness | null {
  const r = object(v), checks = object(r?.checks);
  if (!r || !checks || Object.values(checks).some(x => typeof x !== "boolean") || ["create_ready", "activation_ready", "public_ready", "booking_ready", "booking_required", "publication_gate_enforced"].some(k => typeof r[k] !== "boolean")) return null;
  return { create_ready: r.create_ready as boolean, activation_ready: r.activation_ready as boolean, public_ready: r.public_ready as boolean, booking_ready: r.booking_ready as boolean, booking_required: r.booking_required as boolean, publication_gate_enforced: r.publication_gate_enforced as boolean, checks: checks as Record<string, boolean> };
}
export function readDetail(v: unknown, id: string): Detail | null {
  const d = object(v), t = object(d?.tenant), p = object(d?.public_profile), plan = object(d?.plan), readiness = readReadiness(d?.readiness);
  if (!d || !t || t.tenant_id !== id || !uuid(id) || typeof t.name !== "string" || typeof t.technical_slug !== "string" || slugError(t.technical_slug) || typeof t.status !== "string" || !readiness || !Array.isArray(d.admins)) return null;
  if (d.public_profile !== null && (!p || typeof p.display_name !== "string" || typeof p.city !== "string" || typeof p.public_slug !== "string" || typeof p.is_public !== "boolean")) return null;
  if (d.plan !== null && (!plan || typeof plan.plan_key !== "string" || typeof plan.status !== "string" || typeof plan.assignment_status !== "string" || !Array.isArray(plan.enabled_feature_keys) || plan.enabled_feature_keys.some(x => typeof x !== "string"))) return null;
  const admins: Detail["admins"] = [];
  for (const item of d.admins) { const a = object(item); if (!a || !uuid(a.user_id) || !(a.email === null || typeof a.email === "string")) return null; admins.push({ user_id: a.user_id, email: a.email as string | null }); }
  return { tenant: { tenant_id: id, name: t.name, technical_slug: t.technical_slug, status: t.status }, public_profile: p ? { display_name: p.display_name as string, city: p.city as string, public_slug: p.public_slug as string, is_public: p.is_public as boolean } : null, plan: plan ? { plan_key: plan.plan_key as string, status: plan.status as string, assignment_status: plan.assignment_status as string, enabled_feature_keys: plan.enabled_feature_keys as string[] } : null, admins, readiness };
}
export function readAttempt(raw: string): Attempt | null {
  try {
    const a = object(JSON.parse(raw)), p = object(a?.payload);
    if (!a || a.version !== 1 || !uuid(a.requestId) || !p || typeof a.adminEmail !== "string" || a.adminEmail.length > 254 || !["uncertain", "confirmed", "failed"].includes(String(a.state))) return null;
    if (["p_name", "p_city", "p_tenant_slug", "p_public_slug", "p_plan_key", "p_initial_admin_user_id"].some(k => typeof p[k] !== "string") || Object.keys(p).length !== 6) return null;
    const payload = p as Payload;
    if (!identityValid(payload.p_name) || !identityValid(payload.p_city) || slugError(payload.p_tenant_slug) || slugError(payload.p_public_slug) || payload.p_tenant_slug === payload.p_public_slug || !uuid(payload.p_initial_admin_user_id) || !/^[a-z][a-z0-9_]{1,62}$/.test(payload.p_plan_key)) return null;
    if (a.state === "confirmed" && !uuid(a.tenantId)) return null;
    if (a.failure !== undefined && !["retry", "plan", "admin", "slug", "conflict", "denied", "invalid"].includes(String(a.failure))) return null;
    return { version: 1, requestId: a.requestId, payload: { ...payload }, adminEmail: a.adminEmail, state: a.state as Attempt["state"], ...(uuid(a.tenantId) ? { tenantId: a.tenantId } : {}), ...(a.failure ? { failure: a.failure as ErrorKind } : {}) };
  } catch { return null; }
}
export function receiptId(v: unknown, a: Attempt): string | null {
  const r = object(v), p = a.payload;
  return r && uuid(r.tenant_id) && r.creation_request_id === a.requestId && r.name === p.p_name && r.city === p.p_city && r.tenant_slug === p.p_tenant_slug && r.public_slug === p.p_public_slug && r.plan_key === p.p_plan_key && r.initial_admin_user_id === p.p_initial_admin_user_id && r.initial_status === "dormant" && r.initial_is_public === false ? r.tenant_id : null;
}
export function classifyError(error: unknown): { kind: ErrorKind; message: string } {
  const e = object(error), code = String(e?.code ?? ""), message = String(e?.message ?? "");
  if (message.includes("Creation request payload conflict")) return { kind: "conflict", message: "Ta próba utworzenia została rozpoczęta z innymi danymi. Rozpocznij nowe tworzenie." };
  if (code === "42501") return { kind: "denied", message: "Brak uprawnień do tej operacji. Sprawdź dostęp do platformy." };
  if (code === "23505" || /slug_conflict|namespace_conflict/.test(message)) return { kind: "slug", message: "Wybrany adres jest już zajęty." };
  if (message.includes("Plan unavailable")) return { kind: "plan", message: "Wybrany plan nie jest już dostępny." };
  if (message.includes("Account cannot be assigned")) return { kind: "admin", message: "Wybrane konto nie może zostać administratorem." };
  if (["22023", "23514"].includes(code)) return { kind: "invalid", message: "Adres zawiera niedozwoloną nazwę lub format. Sprawdź także nazwę i miejscowość." };
  return { kind: "retry", message: "Nie udało się potwierdzić wyniku. Sprawdź / ponów utworzenie z zachowaną próbą." };
}
