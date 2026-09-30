import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { Resend } from "resend";
import { getOperationalEmailSenderConfiguration, resolveEventRegistrationEmailTenantContext } from "./operational-email";
import { eventWideCancellationContent } from "./event-wide-cancellation-core";

/** Exactly one bounded batch per explicit staff request; never discovers unrelated events. */
export async function sendEventCancellationBatch(actor: SupabaseClient, eventId: string) {
  const { from, resendApiKey, replyTo } = getOperationalEmailSenderConfiguration();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!from || !resendApiKey || !url || !key) throw new Error("Unavailable");
  const { data: claims, error } = await actor.rpc("claim_event_cancellation_batch_v1", { p_event_id: eventId });
  if (error || !Array.isArray(claims) || claims.length > 5) throw new Error("Unavailable");
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const resend = new Resend(resendApiKey);
  let sent = 0;
  for (const claim of claims) {
    let providerId: string | null = null;
    try {
      if (claim.idempotency_key !== `event-cancellation/${eventId}/${claim.registration_id}`) throw new Error("Unavailable");
      const { data, error: readError } = await db.from("event_registrations")
        .select("customer_email,events(id,tenant_id,cancelled_at,title,event_date,start_time,end_time,location)")
        .eq("id", claim.registration_id).eq("event_id", eventId).eq("tenant_id", claim.tenant_id)
        .eq("user_id", claim.recipient_user_id).is("pii_anonymized_at", null).maybeSingle();
      const event = Array.isArray(data?.events) ? data.events[0] : data?.events;
      if (readError || !data?.customer_email || !event?.cancelled_at || event.tenant_id !== claim.tenant_id) throw new Error("Unavailable");
      const tenant = await resolveEventRegistrationEmailTenantContext(claim.registration_id);
      if (tenant.tenantId !== claim.tenant_id) throw new Error("Unavailable");
      const options = { idempotencyKey: claim.idempotency_key, signal: AbortSignal.timeout(10000) };
      const response = await resend.emails.send({ from, to: data.customer_email, ...eventWideCancellationContent(tenant, event), replyTo }, options);
      if (!response.error && response.data?.id) providerId = response.data.id;
    } catch { /* No body, recipient or provider error payload logging. */ }
    const done = await db.rpc("complete_event_cancellation_email_v1", {
      p_claim_id: claim.claim_id, p_success: providerId !== null, p_provider_message_id: providerId,
    });
    if (!done.error && done.data?.code === "sent") sent++;
  }
  return { sent, attempted: claims.length, pending: claims.length === 5 || sent < claims.length };
}
