import "server-only";
import { createClient } from "@supabase/supabase-js";
import { deliverEventAcceptance } from "./event-acceptance-delivery-core";
import { sendConfirmedPlaceEmail, type ConfirmedRegistration } from "./event-reserve-confirmation-email";

/** Controlled server retry entrypoint; never a browser RPC or automatic worker.
 * The initial route calls this only after the owner-authorized acceptance RPC.
 * Operators may explicitly retry the exact registration ID; the DB derives all authority.
 */
export async function retryEventAcceptanceEmail(registrationId: string) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return "pending" as const;
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  return deliverEventAcceptance(registrationId, {
    claim: async id => await db.rpc("claim_event_reserve_acceptance_email_v1", { p_registration_id: id }),
    send: async claim => {
      const { data, error } = await db.from("event_registrations")
        .select("id,tenant_id,event_id,user_id,customer_email,customer_name,events(tenant_id,title,event_date,start_time,end_time,location,price)")
        .eq("id", claim.registration_id).eq("tenant_id", claim.tenant_id).eq("user_id", claim.recipient_user_id)
        .eq("registration_status", "registered").is("pii_anonymized_at", null).maybeSingle();
      const event = Array.isArray(data?.events) ? data.events[0] : data?.events;
      if (error || !data || !event || event.tenant_id !== claim.tenant_id) throw new Error("Receipt unavailable");
      return sendConfirmedPlaceEmail(data as unknown as ConfirmedRegistration, claim.idempotency_key);
    },
    complete: async (claimId, success, providerId) => await db.rpc("complete_event_reserve_acceptance_email_v1", {
      p_claim_id: claimId, p_success: success, p_provider_message_id: providerId,
    }),
  });
}
