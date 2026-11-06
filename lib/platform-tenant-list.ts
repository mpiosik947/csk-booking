import { tenantLabels, type TenantStatus, readPublicAccess, type PublicAccess } from "./platform-management.ts";
import { readDetail, uuid } from "./platform-wizard.ts";
import { readHandover } from "./platform-handover.ts";
import { checkStep, draftStatus, wizardSteps } from "./platform-onboarding-steps.ts";
import type { Readiness } from "./platform-draft-readiness.ts";

export const groups = { active: "Aktywne", dormant: "W konfiguracji", suspended: "Zawieszone", archived: "Zarchiwizowane" } satisfies Record<TenantStatus, string>;

export type ListTenant = {
  id: string; name: string | null; city: string | null; slug: string; publicSlug: string | null;
  status: TenantStatus; published: boolean | null; draft: boolean; plan: string | null; createdAt: string;
};
export type CardFacts = {
  internalName: string; admins: number; email: string | null; access: PublicAccess["state"] | null;
  proof: Readiness | null; activationReady: boolean | null; planActive: boolean | null;
};
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const nullableText = (v: unknown): v is string | null => v === null || typeof v === "string";

export function readTenantPage(v: unknown, page: number) {
  if (!object(v) || v.page !== page || v.page_size !== 25 || typeof v.total !== "number" || !Number.isSafeInteger(v.total) || v.total < 0 || !Array.isArray(v.items) || v.items.length > 25) return null;
  const items: ListTenant[] = [];
  for (const t of v.items) {
    if (!object(t) || !uuid(t.id) || !nullableText(t.name) || !nullableText(t.city) || typeof t.tenant_slug !== "string" ||
      !nullableText(t.public_slug) || !Object.hasOwn(groups, String(t.status)) || !nullableText(t.plan_key) ||
      typeof t.is_platform_draft !== "boolean" || !(typeof t.is_public === "boolean" || t.is_public === null) ||
      typeof t.created_at !== "string" || !Number.isFinite(Date.parse(t.created_at))) return null;
    items.push({ id:t.id, name:t.name, slug:t.tenant_slug, publicSlug:t.public_slug, city:t.city, status:t.status as TenantStatus,
      published:t.is_public, draft:t.is_platform_draft, plan:t.plan_key, createdAt:t.created_at });
  }
  return { items, total:v.total };
}

// The draft reader returns its validation, admin count and availability in one snapshot.
export async function cardFacts(tenant: ListTenant, read: (name: string, id: string) => Promise<unknown>): Promise<CardFacts | null> {
  if (tenant.draft && tenant.status === "dormant") {
    const h = readHandover(await read("platform_get_tenant_handover_v1", tenant.id), tenant.id);
    if (!h || h.receipt || h.status !== tenant.status || h.isPublic !== tenant.published) return null;
    return { internalName:h.name, admins:h.adminCount, email:null, access:h.publicAccess, proof:h.readiness, activationReady:null,
      planActive:h.readiness?.checks.find(c => c.key === "plan")?.result === "PASS" };
  }
  const [detail, access] = await Promise.all([
    read("platform_get_tenant_onboarding_detail_v1", tenant.id).then(v => readDetail(v, tenant.id)),
    read("platform_get_tenant_public_access_v1", tenant.id).then(readPublicAccess),
  ]);
  if (!detail || detail.tenant.status !== tenant.status || !!detail.is_platform_draft !== tenant.draft ||
    (detail.public_profile?.is_public ?? null) !== tenant.published || (detail.plan?.plan_key ?? null) !== tenant.plan) return null;
  return { internalName:detail.tenant.name, admins:detail.admins.length, email:detail.admins.length === 1 ? detail.admins[0].email : null,
    access:access?.state ?? null, proof:null, activationReady:detail.readiness.activation_ready,
    planActive:detail.plan?.status === "active" && detail.plan.assignment_status === "active" };
}

export function primaryAction(t: ListTenant, facts?: CardFacts | null) {
  const base = `/platform-admin/tenants/${t.id}`;
  if (t.status === "archived") return { label:"Przywróć", href:base + "#archiwizacja" };
  if (t.draft && t.status === "dormant" && facts?.admins === 0) {
    if (facts.proof?.current && t.plan && facts.planActive && t.published === false && facts.access === "coming_soon") return { label:"Przekaż administratorowi", href:base + "/setup?step=summary" };
    return { label:"Kontynuuj konfigurację", href:base + "/setup" };
  }
  return { label:"Otwórz obiekt", href:base };
}

export function configurationLabel(t: ListTenant, f: CardFacts) {
  if (t.status === "archived") return "Archiwum · konfiguracja zachowana";
  if (t.draft) {
    if (!f.proof) return "Brak odczytu gotowości";
    const blocker = f.proof.checks.find(c => c.severity === "BLOCKER" && c.result === "FAIL");
    if (blocker) return "Do uzupełnienia: " + wizardSteps[checkStep(blocker.key)];
    return draftStatus(false, f.proof);
  }
  return f.activationReady ? "Spełnia warunki aktywacji" : "Wymaga uzupełnienia";
}

export function lifecycleLabel(t: ListTenant, f?: CardFacts | null) {
  if (t.status === "dormant" && t.draft) return "Szkic";
  if (t.status === "dormant" && f && f.admins > 0) return "Przekazany administratorowi";
  return tenantLabels[t.status];
}

export function matchesTenant(t: ListTenant, facts: CardFacts | null | undefined, query: string) {
  const term = query.trim().toLocaleLowerCase("pl");
  return [t.name, facts?.internalName, t.slug, t.publicSlug].some(v => v?.toLocaleLowerCase("pl").includes(term));
}
