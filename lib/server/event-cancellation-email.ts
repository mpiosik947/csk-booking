import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { Resend } from "resend";
import { cancellationEmailContent, deliverEventCancellation } from "./event-cancellation-email-core";
import { resolveEventRegistrationEmailTenantContext, getOperationalEmailSenderConfiguration } from "./operational-email";

export async function sendEventCancellationReceipt(actor: SupabaseClient, registrationId: string) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const { from, resendApiKey } = getOperationalEmailSenderConfiguration();
  if (!url || !key || !from || !resendApiKey) return "pending" as const;
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  return deliverEventCancellation(registrationId, {
    // Owner/staff authority is checked by DB BEFORE any privileged data read.
    prepare: async () => await actor.rpc("prepare_event_registration_cancellation_email_v1", { p_registration_id: registrationId }),
    send: async claim => {
      const { data, error } = await db.from("event_registrations")
        .select("id,tenant_id,user_id,customer_email,events(tenant_id,title,event_date,start_time,end_time)")
        .eq("id", claim.registration_id).eq("tenant_id", claim.tenant_id).eq("user_id", claim.recipient_user_id)
        .eq("registration_status", "cancelled").is("pii_anonymized_at", null).maybeSingle();
      const event = Array.isArray(data?.events) ? data.events[0] : data?.events;
      if (error || !data?.customer_email || !event || event.tenant_id !== claim.tenant_id) throw new Error("Receipt unavailable");
      const tenant = await resolveEventRegistrationEmailTenantContext(claim.registration_id);
      if (tenant.tenantId !== claim.tenant_id) throw new Error("Receipt unavailable");
      return new Resend(resendApiKey).emails.send({ from, to: data.customer_email,
        ...cancellationEmailContent(tenant, event) }, { idempotencyKey: claim.idempotency_key });
    },
    complete: async (claim, success, providerId) => await db.rpc("complete_event_registration_cancellation_email_v1", {
      p_claim_id: claim, p_success: success, p_provider_message_id: providerId,
    }),
  });
}
