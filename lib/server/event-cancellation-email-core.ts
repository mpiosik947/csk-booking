import { operationalEmailBrand, operationalEmailHistoryUrl, type OperationalEmailTenantContext } from "./operational-email-core.ts";
import { operationalEmailLayout } from "./operational-email-layout.ts";

export function cancellationEmailContent(tenant: OperationalEmailTenantContext, event: {
  title: string | null; event_date: string | null; start_time: string | null; end_time: string | null;
}) {
  const brand = operationalEmailBrand(tenant, "Zapis na wydarzenie anulowany");
  const url = operationalEmailHistoryUrl(tenant, "events");
  const lines = ["Twój udział w wydarzeniu został anulowany.",
    `Wydarzenie: ${event.title ?? "-"}`, `Data: ${event.event_date ?? "-"}`,
    `Godzina: ${event.start_time?.slice(0, 5) ?? "-"}–${event.end_time?.slice(0, 5) ?? "-"}`,
    `Obiekt: ${tenant.displayName}`];
  return { subject: brand.subject,
    text: `${brand.headerText}\n\n${lines.join("\n")}\n\nMoje szkolenia: ${url}`,
    html: operationalEmailLayout({
      tenantDisplayName: tenant.displayName,
      title: "Zapis na wydarzenie anulowany",
      intro: lines[0],
      details: [
        { label: "Wydarzenie", value: event.title ?? "-" },
        { label: "Data", value: event.event_date ?? "-" },
        { label: "Godzina", value: `${event.start_time?.slice(0, 5) ?? "-"}–${event.end_time?.slice(0, 5) ?? "-"}` },
        { label: "Obiekt", value: tenant.displayName },
      ],
      actions: [{ label: "Moje szkolenia", url }],
    }) };
}

type RpcResult = { data: unknown; error: unknown };
export type CancellationClaim = { claim_id: string; registration_id: string; tenant_id: string; recipient_user_id: string; idempotency_key: string };
export type CancellationReceiptOutcome = "sent" | "already_sent" | "unavailable" | "pending" | "failed" | "uncertain" | "retired" | "retry_exhausted";
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const code = (v: unknown) => v && typeof v === "object" && "code" in v ? v.code : null;

export async function deliverEventCancellation(id: string, deps: {
  prepare: () => Promise<RpcResult>;
  send: (claim: CancellationClaim) => Promise<{ data: { id?: string } | null; error: unknown }>;
  complete: (claim: string, success: boolean, providerId: string | null) => Promise<RpcResult>;
}): Promise<CancellationReceiptOutcome> {
  if (!uuid.test(id)) return "unavailable";
  let result: RpcResult;
  try { result = await deps.prepare(); } catch { return "pending"; }
  if (result.error) return "unavailable";
  const status = code(result.data);
  if (status === "already_sent" || status === "retired" || status === "retry_exhausted") return status;
  if (status !== "ready") return "pending";
  const claim = result.data as CancellationClaim;
  if (![claim.claim_id, claim.registration_id, claim.tenant_id, claim.recipient_user_id].every(v => typeof v === "string" && uuid.test(v)) ||
    claim.registration_id !== id || claim.idempotency_key !== `event-registration-cancellation/${claim.tenant_id}/${id}`) return "uncertain";
  let providerId: string | null = null;
  try {
    const sent = await deps.send(claim);
    if (!sent.error && typeof sent.data?.id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(sent.data.id)) providerId = sent.data.id;
  } catch { /* A timeout may mean provider success: never claim exactly-once. */ }
  try {
    const done = await deps.complete(claim.claim_id, providerId !== null, providerId);
    if (done.error || code(done.data) !== (providerId ? "sent" : "failed")) return "uncertain";
    return providerId ? "sent" : "failed";
  } catch { return "uncertain"; }
}

/** This boundary is entered only AFTER the authoritative cancellation succeeds. */
export async function attemptCancellationReceipt(send: () => Promise<unknown>) {
  try { await send(); } catch { /* Receipt failure must never prevent reserve promotion. */ }
}
