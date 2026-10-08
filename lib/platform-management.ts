import { uuid } from "./platform-wizard.ts";

// Project only the reviewed RPC fields; never carry opaque DB objects into the UI.
const object = (v: unknown): Record<string, unknown> | null => v !== null && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
const strings = (v: unknown): v is string[] => Array.isArray(v) && v.every(x => typeof x === "string");
const count = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
export const tenantLabels = { dormant: "W przygotowaniu", active: "Aktywny", suspended: "Zawieszony", archived: "Zarchiwizowany" };
export const memberLabels = { active: "Aktywny", suspended: "Zawieszony", pending: "Oczekujący" };
export const roleLabels = { admin: "Administrator", user: "Użytkownik", employee: "Pracownik", instructor: "Instruktor" };
export type TenantStatus = keyof typeof tenantLabels;
export type Role = keyof typeof roleLabels;
export type MemberStatus = keyof typeof memberLabels;
type Tenant = { tenant_id: string; name: string; status: TenantStatus };
function tenant(v: unknown, id: string): Tenant | null {
  const t = object(v);
  return t && t.tenant_id === id && uuid(id) && typeof t.name === "string" && Object.hasOwn(tenantLabels, String(t.status))
    ? { tenant_id: id, name: t.name, status: t.status as TenantStatus } : null;
}
export type Candidate = { user_id: string; email: string; membership: { exists: false; role: null; status: null } | { exists: true; role: Role; status: MemberStatus } };
export function readCandidate(v: unknown, email: string): Candidate | null {
  const a = object(v), m = object(a?.membership);
  if (!a || !uuid(a.user_id) || typeof a.email !== "string" || a.email.trim().toLowerCase() !== email.trim().toLowerCase() || !m) return null;
  if (m.exists === false && m.role === null && m.status === null) return { user_id: a.user_id, email: a.email, membership: { exists: false, role: null, status: null } };
  if (m.exists === true && Object.hasOwn(roleLabels, String(m.role)) && Object.hasOwn(memberLabels, String(m.status))) return { user_id: a.user_id, email: a.email, membership: { exists: true, role: m.role as Role, status: m.status as MemberStatus } };
  return null;
}
export function expectedState(candidate: Candidate) {
  const m = candidate.membership;
  return m.exists ? { role: m.role, status: m.status } : null;
}
export type AdminAction = "add" | "reactivate" | "demote" | "suspend";
export function candidateActions(a: Candidate): AdminAction[] {
  const m = a.membership;
  if (!m.exists) return ["add"];
  if (m.status === "pending") return [];
  if (m.role === "admin") return m.status === "suspended" ? ["reactivate"] : ["demote", "suspend"];
  return m.status === "active" ? ["add"] : [];
}
export type Admins = { tenant: Tenant; active_admin_count: number; admins: { user_id: string; email: string | null; membership_role: "admin"; membership_status: MemberStatus; updated_at: string }[] };
export function readAdmins(v: unknown, id: string): Admins | null {
  const d = object(v), t = tenant(d?.tenant, id);
  if (!d || !t || !count(d.active_admin_count) || !Array.isArray(d.admins)) return null;
  const admins: Admins["admins"] = [];
  for (const item of d.admins) {
    const a = object(item);
    if (!a || !uuid(a.user_id) || !(a.email === null || typeof a.email === "string") || a.membership_role !== "admin" || !Object.hasOwn(memberLabels, String(a.membership_status)) || typeof a.updated_at !== "string" || !Number.isFinite(Date.parse(a.updated_at))) return null;
    admins.push({ user_id: a.user_id, email: a.email, membership_role: "admin", membership_status: a.membership_status as MemberStatus, updated_at: a.updated_at });
  }
  return { tenant: t, active_admin_count: d.active_admin_count, admins };
}
export type Notice = { code: string; feature_key?: string; count?: number };
function notices(v: unknown): Notice[] | null {
  if (!Array.isArray(v)) return null;
  const result: Notice[] = [];
  for (const item of v) {
    const n = object(item);
    if (!n || typeof n.code !== "string" || (n.count !== undefined && !count(n.count)) || (n.feature_key !== undefined && typeof n.feature_key !== "string")) return null;
    result.push({ code: n.code, ...(typeof n.feature_key === "string" ? { feature_key: n.feature_key } : {}), ...(count(n.count) ? { count: n.count } : {}) });
  }
  return result;
}
export type PlanPreview = { tenant: Tenant; current_plan: { plan_key: string; assignment_status: string; enabled_feature_keys: string[] } | null; target_plan: { plan_key: string; enabled_feature_keys: string[] }; features_added: string[]; features_removed: string[]; blockers: Notice[]; warnings: Notice[]; can_apply: boolean; revision: string };
export function readPlanPreview(v: unknown, id: string, target: string): PlanPreview | null {
  const d = object(v), t = tenant(d?.tenant, id), current = object(d?.current_plan), next = object(d?.target_plan), blockers = notices(d?.blockers), warnings = notices(d?.warnings);
  if (!d || !t || !next || next.plan_key !== target || !strings(next.enabled_feature_keys) || !strings(d.features_added) || !strings(d.features_removed) || !blockers || !warnings || typeof d.can_apply !== "boolean" || typeof d.revision !== "string" || !/^(0|[1-9][0-9]{0,18})$/.test(d.revision)) return null;
  if (d.current_plan !== null && (!current || typeof current.plan_key !== "string" || typeof current.assignment_status !== "string" || !strings(current.enabled_feature_keys))) return null;
  return { tenant: t, current_plan: current ? { plan_key: current.plan_key as string, assignment_status: current.assignment_status as string, enabled_feature_keys: current.enabled_feature_keys as string[] } : null, target_plan: { plan_key: target, enabled_feature_keys: next.enabled_feature_keys }, features_added: d.features_added, features_removed: d.features_removed, blockers, warnings, can_apply: d.can_apply, revision: d.revision };
}
export const operationalLabels: Record<string, string> = { future_reservations: "Przyszłe rezerwacje", future_events: "Przyszłe wydarzenia", open_registrations: "Otwarte zapisy", active_lane_blocks: "Aktywne blokady osi", active_custom_domains: "Aktywne domeny własne", settlement_records: "Rekordy rozliczeń", pending_deliveries: "Oczekujące powiadomienia", in_flight_positive_deliveries: "Powiadomienia w trakcie wysyłki" };
export type Lifecycle = { tenant: Tenant & { is_public: boolean }; current_plan: { plan_key: string; status: string; plan_status: string } | null; admin_summary: { active_admin_count: number }; operational_counts: Record<string, number>; warnings: string[]; blockers: string[]; can_archive: boolean; revision: number };
export function readLifecycle(v: unknown, id: string): Lifecycle | null {
  const d = object(v), t = tenant(d?.tenant, id), rawTenant = object(d?.tenant), plan = object(d?.current_plan), admins = object(d?.admin_summary), counts = object(d?.operational_counts);
  if (!d || !t || !rawTenant || typeof rawTenant.is_public !== "boolean" || !admins || !count(admins.active_admin_count) || !counts || Object.keys(operationalLabels).some(k => !count(counts[k])) || !strings(d.warnings) || !strings(d.blockers) || typeof d.can_archive !== "boolean" || !count(d.revision)) return null;
  if (d.current_plan !== null && (!plan || ["plan_key", "status", "plan_status"].some(k => typeof plan[k] !== "string"))) return null;
  return { tenant: { ...t, is_public: rawTenant.is_public }, current_plan: plan ? { plan_key: plan.plan_key as string, status: plan.status as string, plan_status: plan.plan_status as string } : null, admin_summary: { active_admin_count: admins.active_admin_count }, operational_counts: Object.fromEntries(Object.keys(operationalLabels).map(k => [k, counts[k] as number])), warnings: d.warnings, blockers: d.blockers, can_archive: d.can_archive, revision: d.revision };
}
export type Eligibility = { tenant: Tenant; can_hard_delete: false; blockers: Notice[]; warnings: string[] };
export function readEligibility(v: unknown, id: string): Eligibility | null {
  const d = object(v), t = tenant(d?.tenant, id), e = object(d?.eligibility), blockers = notices(d?.blockers);
  if (!d || !t || e?.can_hard_delete !== false || !blockers || !strings(d.warnings) || !blockers.some(b => b.code === "HARD_DELETE_POLICY_DEFERRED")) return null;
  return { tenant: t, can_hard_delete: false, blockers, warnings: d.warnings };
}
export const planName = (key: string | undefined | null) => key === "booking_only_v1" ? "Pakiet minimum" : key === "current_full_v1" ? "Pakiet całość" : key ?? "Brak planu";
const features: Record<string, string> = { booking: "Rezerwacje", events: "Wydarzenia", staff: "Pracownicy", instructors: "Instruktorzy", checkin: "Check-in", lane_blocks: "Blokady osi", custom_domain: "Domena własna", branding: "Branding", reports: "Raporty", advanced_calendar: "Kalendarz" };
export const featureName = (key: string) => Object.hasOwn(features, key) ? features[key] : "Dodatkowa funkcja";
const messages: Record<string, string> = {
  EVENTS_OPEN: "Przyszłe wydarzenia wymagają obsługi.", EVENT_REGISTRATIONS_OPEN: "Zapisy na wydarzenia wymagają rozliczenia.", EVENT_EMAIL_OBLIGATIONS: "Powiadomienia o wydarzeniach wymagają obsługi.", STAFF_ACTIVE: "Aktywni pracownicy potrzebują narzędzi obsługi.", CHECKIN_OBLIGATION: "Obecność na rezerwacjach wymaga rozliczenia.", LANE_BLOCKS_ACTIVE: "Istnieją aktywne lub przyszłe blokady osi.", BOOKING_OBLIGATIONS: "Istnieją rezerwacje wymagające obsługi.", INSTRUCTORS_ACTIVE: "Przyszłe przypisania instruktorów wymagają obsługi.", INSTRUCTOR_OBLIGATIONS: "Powiadomienia instruktorów wymagają obsługi.", CUSTOM_DOMAIN_ACTIVE: "Wyłącz domenę własną przed zmianą planu.", PUBLIC_REEXPOSURE: "Sprawdź zachowaną widoczność lub wycofaj publikację przed włączeniem funkcji.", DOMAIN_REEXPOSURE: "Wyłącz zachowaną domenę przed włączeniem publicznego dostępu.", TARGET_PLAN_UNKNOWN: "Wybrany plan jest niedostępny.", TARGET_PLAN_INACTIVE: "Wybrany plan nie jest aktywny.", CAPABILITY_REMOVED: "Funkcja przestanie być dostępna; zachowane dane pozostaną.", RETAINED_PUBLIC_FLAGS: "Zachowane ustawienia widoczności wymagają sprawdzenia.",
  LAST_ACTIVE_ADMIN: "Nie można wykonać tej operacji, ponieważ obiekt musi mieć co najmniej jednego aktywnego administratora.", INSTRUCTOR_HAS_OPEN_OBLIGATIONS: "Nie można awansować tego instruktora, ponieważ ma nierozliczone obowiązki instruktorskie.", MEMBERSHIP_PENDING: "Członkostwo oczekuje na rozstrzygnięcie. Operacja jest niedostępna.", MEMBERSHIP_SUSPENDED: "Członkostwo jest zawieszone. Awans jest niedostępny.", ACCOUNT_UNAVAILABLE: "Konto nie jest dostępne do tej operacji.", NOT_TENANT_ADMIN: "Konto nie jest administratorem obiektu.", NOT_ACTIVE_TENANT_ADMIN: "Ta operacja wymaga aktywnego administratora. Odśwież dane użytkownika.", INVALID_ADMIN_REQUEST: "Odśwież dane przed rozpoczęciem nowej operacji.", ADMIN_MANAGEMENT_BUSY: "Trwa inna zmiana administratorów. Odśwież dane i spróbuj ponownie.", REQUEST_REPLAY_MISMATCH: "Ta próba dotyczy innych danych. Odśwież stan przed rozpoczęciem nowej operacji.",
  TENANT_STATE_CONFLICT: "Bieżący status obiektu nie pozwala na tę operację.", TENANT_PUBLICATION_CONFLICT: "Stan publikacji nie pozwala na tę operację.", TENANT_NO_ACTIVE_ADMIN: "Obiekt wymaga aktywnego administratora.", TENANT_DELIVERY_IN_FLIGHT: "Trwa wysyłka powiadomień. Spróbuj po jej zakończeniu.", TENANT_LIFECYCLE_BUSY: "Trwa inna zmiana statusu obiektu. Odśwież dane i spróbuj ponownie.", TENANT_UNAVAILABLE: "Obiekt jest niedostępny.", TENANT_STRUCTURE_INVALID: "Konfiguracja obiektu wymaga sprawdzenia.", TENANT_PLAN_INVALID: "Przywrócenie wymaga aktywnego planu.", TENANT_ARCHIVED: "Obiekt jest zarchiwizowany. Najpierw przywróć go do konfiguracji.", INVALID_LIFECYCLE_REQUEST: "Odśwież status przed rozpoczęciem nowej operacji.",
  HISTORY_RETAINED: "Historia i konfiguracja zostaną zachowane.", CLOSURE_CONTINUITY_ONLY: "Po archiwizacji pozostanie obsługa istniejących zobowiązań.", RESTORE_REQUIRES_SEPARATE_PUBLICATION: "Przywrócenie wymaga osobnej aktywacji i publikacji.",
  HARD_DELETE_POLICY_DEFERRED: "Trwałe usuwanie jest obecnie wyłączone na poziomie platformy", TENANT_NOT_ARCHIVED: "Obiekt nie jest zarchiwizowany", TENANT_PUBLIC: "Obiekt jest opublikowany", AUDIT_LOGS_EXIST: "Istnieje historia audytowa", PLATFORM_AUDIT_EXISTS: "Istnieje historia operacji platformowych", CREATION_LEDGER_EXISTS: "Istnieje historia utworzenia obiektu", PLAN_ASSIGNMENT_EXISTS: "Istnieje historia przypisania planu", GLOBAL_ACCOUNTS_NOT_TENANT_OWNED: "Konta użytkowników należą do platformy.", SNAPSHOT_ONLY_NOT_DELETE_AUTHORIZATION: "Ten odczyt nie stanowi zgody na usunięcie.", DEPENDENCY_COUNTS_UNAVAILABLE: "Nie udało się ustalić wszystkich zależności.",
  EMAIL_HISTORY_EXISTS: "Istnieje historia powiadomień", EVENT_INSTRUCTORS_EXIST: "Istnieją przypisania instruktorów", EVENT_LANES_EXIST: "Istnieją przypisania osi do wydarzeń", EVENT_REGISTRATIONS_EXIST: "Istnieją zapisy na wydarzenia", EVENTS_EXIST: "Istnieją wydarzenia", SETTLEMENTS_EXIST: "Istnieje historia rozliczeń", LANE_BLOCKS_EXIST: "Istnieją blokady osi", PLATFORM_ADMIN_MANAGEMENT_REQUESTS_EXIST: "Istnieje historia zmian administratorów", PLATFORM_PLAN_CHANGE_REQUESTS_EXIST: "Istnieje historia zmian planu", PLATFORM_TENANT_LIFECYCLE_REQUESTS_EXIST: "Istnieje historia zmian statusu", RESERVATIONS_EXIST: "Istnieją rezerwacje", SHOOTING_LANES_EXIST: "Istnieje konfiguracja osi", CUSTOM_DOMAIN_EXISTS: "Istnieje konfiguracja domen", TENANT_MEMBERSHIPS_EXIST: "Istnieją członkostwa obiektu", TENANT_PUBLIC_PRICING_ITEMS_EXIST: "Istnieje konfiguracja cennika", TENANT_PUBLIC_PROFILES_EXIST: "Istnieje profil publiczny", TENANT_USER_ADMIN_NOTES_EXIST: "Istnieją dane administracyjne członkostw", TENANT_USER_VERIFICATIONS_EXIST: "Istnieje historia weryfikacji", LANE_BOOKING_DURATIONS_EXIST: "Istnieje konfiguracja czasu rezerwacji", LANE_BOOKING_FAMILY_CONFIGURATION_VERSIONS_EXIST: "Istnieje historia konfiguracji rezerwacji", LANE_BOOKING_RULES_EXIST: "Istnieją reguły rezerwacji", LANE_PRICING_RULES_EXIST: "Istnieją reguły cenowe", REMINDER_SCHEDULES_EXIST: "Istnieją harmonogramy przypomnień", REMINDER_HISTORY_EXISTS: "Istnieje historia przypomnień", TENANT_PROFILE_LINKS_EXIST: "Istnieją powiązania profili",
};
export const fallback = "Nie udało się wykonać operacji. Odśwież dane i spróbuj ponownie.";
export const noticeLabel = (code: string, deletion = false) => Object.hasOwn(messages, code) ? messages[code] : (deletion ? "Zależność techniczna blokuje trwałe usunięcie." : "Operacja wymaga sprawdzenia konfiguracji obiektu.");
export function managementError(error: unknown): { kind: "denied" | "plan-stale" | "member-stale" | "lifecycle-stale" | "rejected" | "uncertain"; message: string } {
  const e = object(error), code = String(e?.code ?? ""), message = String(e?.message ?? "");
  if (["42501", "PGRST301", "PGRST302", "PGRST303"].includes(code)) return { kind: "denied", message: "Brak dostępu do zarządzania platformą. Zaloguj się ponownie." };
  if (code === "PT409" && message === "PLAN_STALE") return { kind: "plan-stale", message: "Dane obiektu zmieniły się. Podgląd został odświeżony." };
  if (code === "PT409" && message === "STALE_MEMBERSHIP_STATE") return { kind: "member-stale", message: "Członkostwo zmieniło się. Dane konta zostały odświeżone. Potwierdź nową operację." };
  if (code === "PT409" && message === "TENANT_REVISION_STALE") return { kind: "lifecycle-stale", message: "Status obiektu zmienił się. Dane zostały odświeżone." };
  const aliases: Record<string, string> = { "Tenant unavailable": "TENANT_UNAVAILABLE", "Target plan unavailable": "TARGET_PLAN_INACTIVE", "Plan request payload conflict": "REQUEST_REPLAY_MISMATCH", "Account cannot be selected": "ACCOUNT_UNAVAILABLE" };
  const stable = Object.hasOwn(aliases, message) ? aliases[message] : message;
  if (/^[0-9A-Z]{5}$/.test(code) && !code.startsWith("08") && !code.startsWith("PGRST") && code !== "57014") return { kind: "rejected", message: Object.hasOwn(messages, stable) ? messages[stable] : (message === "Plan change blocked" ? "Zmiana planu jest zablokowana. Odśwież podgląd." : fallback) };
  return { kind: "uncertain", message: fallback };
}
