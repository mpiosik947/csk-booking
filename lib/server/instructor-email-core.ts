import { PLATFORM_BASE_URL } from "../platform-domain.ts";
import { operationalEmailBrand, type OperationalEmailTenantContext } from "./operational-email-core.ts";
import { operationalEmailLayout } from "./operational-email-layout.ts";

export type InstructorEmailKind = "instructor_assignment" | "instructor_removal" | "instructor_event_cancellation";
export type InstructorEmailEvent = {
  event_id: string; title: string; event_date: string; start_time: string; end_time: string; location: string | null;
};
export function instructorEmailContent(tenant: OperationalEmailTenantContext, kind: InstructorEmailKind, event: InstructorEmailEvent) {
  const labels = {
    instructor_assignment: ["przypisano Cię do szkolenia", "Zostałeś przypisany do szkolenia"],
    instructor_removal: ["zmiana obsady szkolenia", "Nie jesteś już przypisany do szkolenia"],
    instructor_event_cancellation: ["szkolenie zostało anulowane", "Wydarzenie zostało anulowane"],
  } as const;
  if (!Object.hasOwn(labels, kind)) throw new Error("Unavailable");
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(tenant.tenantSlug) ||
    !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(event.event_id)) throw new Error("Unavailable");
  const [subject, title] = labels[kind];
  const brand = operationalEmailBrand(tenant, subject);
  const details = [{ label: "Obiekt", value: tenant.displayName }, { label: "Szkolenie", value: event.title },
    { label: "Data", value: event.event_date }, { label: "Godzina", value: `${event.start_time.slice(0, 5)}–${event.end_time.slice(0, 5)}` },
    { label: "Miejsce", value: event.location ?? "-" }];
  const actions = kind === "instructor_assignment"
    ? [{ label: "Zobacz szkolenie", url: `${PLATFORM_BASE_URL}/t/${tenant.tenantSlug}/instructor/events/${event.event_id}` }] : [];
  return { subject: brand.subject,
    text: `${brand.headerText}\n\n${title}.\n${details.map(d => `${d.label}: ${d.value}`).join("\n")}\n${actions.map(a => `\n${a.label}: ${a.url}`).join("")}`,
    html: operationalEmailLayout({ tenantDisplayName: tenant.displayName, title,
      intro: "Powiadomienie dotyczące obsady instruktorskiej szkolenia.", details, actions }),
  };
}

export type InstructorDeliveryDependencies = {
  claim: () => Promise<{ claim_id: string; delivery_id: string }[]>;
  read: (claim: string) => Promise<({ kind: InstructorEmailKind; assignment_id: string; tenant_id: string;
    recipient_email: string; idempotency_key: string } & InstructorEmailEvent) | null>;
  tenant: (event: string) => Promise<OperationalEmailTenantContext>;
  send: (email: string, content: ReturnType<typeof instructorEmailContent>, key: string) => Promise<string | null>;
  complete: (claim: string, success: boolean, providerId: string | null) => Promise<boolean>;
};
/** One explicit bounded batch. Stable identity on uncertainty; never asserts exactly-once. */
export async function deliverInstructorEmailBatch(deps: InstructorDeliveryDependencies) {
  const claims = await deps.claim();
  if (!Array.isArray(claims) || claims.length > 5) throw new Error("Unavailable");
  let sent = 0;
  for (const claim of claims) {
    let providerId: string | null = null;
    try {
      const attempt = await deps.read(claim.claim_id);
      if (!attempt || attempt.idempotency_key !== `${attempt.kind}/${attempt.assignment_id}`) throw new Error("Unavailable");
      const tenant = await deps.tenant(attempt.event_id);
      if (tenant.tenantId !== attempt.tenant_id) throw new Error("Unavailable");
      const content = instructorEmailContent(tenant, attempt.kind, attempt);
      // Revalidate the exact lease after metadata resolution, not a new admission.
      const current = await deps.read(claim.claim_id);
      if (!current || JSON.stringify(current) !== JSON.stringify(attempt)) throw new Error("Unavailable");
      providerId = await deps.send(attempt.recipient_email, content, attempt.idempotency_key);
    } catch { /* Recipient, body, tokens and provider payloads are never logged. */ }
    try { if (await deps.complete(claim.claim_id, providerId !== null, providerId) && providerId) sent++; }
    catch { /* Provider success + marker failure remains uncertain, not sent. */ }
  }
  return { sent, attempted: claims.length, pending: claims.length === 5 || sent < claims.length };
}
