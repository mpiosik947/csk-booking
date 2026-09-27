type RpcResult = { data: unknown; error: unknown };
export type AcceptanceClaim = {
  code: "ready"; claim_id: string; registration_id: string;
  tenant_id: string; recipient_user_id: string; idempotency_key: string;
};
export type AcceptanceEmailOutcome = "sent" | "already_sent" | "pending" | "failed" | "uncertain" | "retry_exhausted";
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const code = (value: unknown) => value && typeof value === "object" && "code" in value ? value.code : null;

/** Only technical status escapes this boundary. No recipient, token, or provider error text. */
export async function deliverEventAcceptance(registrationId: string, deps: {
  claim: (id: string) => Promise<RpcResult>;
  send: (claim: AcceptanceClaim) => Promise<{ data: { id?: string } | null; error: unknown }>;
  complete: (claimId: string, success: boolean, providerId: string | null) => Promise<RpcResult>;
}): Promise<AcceptanceEmailOutcome> {
  if (!uuid.test(registrationId)) return "failed";
  let result: RpcResult;
  try { result = await deps.claim(registrationId); } catch { return "pending"; }
  if (result.error) return "pending";
  if (code(result.data) === "already_sent") return "already_sent";
  if (code(result.data) === "retry_exhausted") return "retry_exhausted";
  if (code(result.data) !== "ready") return "pending";
  const claim = result.data as AcceptanceClaim;
  if (![claim.claim_id, claim.tenant_id, claim.recipient_user_id, claim.registration_id].every(v => typeof v === "string" && uuid.test(v)) ||
      claim.registration_id !== registrationId ||
      claim.idempotency_key !== `event-reserve-acceptance/${claim.tenant_id}/${registrationId}`) return "uncertain";
  let providerId: string | null = null;
  try {
    const sent = await deps.send(claim);
    if (!sent.error && typeof sent.data?.id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(sent.data.id)) providerId = sent.data.id;
  } catch { /* Provider may have accepted the request: retry keeps the same logical key. */ }
  try {
    const completed = await deps.complete(claim.claim_id, providerId !== null, providerId);
    if (completed.error || code(completed.data) !== (providerId ? "sent" : "failed")) return "uncertain";
    return providerId ? "sent" : "failed";
  } catch { return "uncertain"; }
}
