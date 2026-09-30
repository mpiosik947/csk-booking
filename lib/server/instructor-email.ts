import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { Resend } from "resend";
import { getOperationalEmailSenderConfiguration, resolveEventEmailTenantContext } from "./operational-email";
import { deliverInstructorEmailBatch } from "./instructor-email-core";

export async function sendInstructorEmailBatch(actor: SupabaseClient, eventId: string) {
  const authorized = await actor.rpc("authorize_instructor_email_batch_v1", { p_event_id: eventId });
  if (authorized.error || authorized.data !== true) throw new Error("Unavailable");
  const { from, resendApiKey } = getOperationalEmailSenderConfiguration();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!from || !resendApiKey || !url || !key) throw new Error("Unavailable");
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const resend = new Resend(resendApiKey);
  return deliverInstructorEmailBatch({
    claim: async () => {
      const result = await db.rpc("claim_instructor_email_batch_v1", { p_event_id: eventId });
      if (result.error) throw new Error("Unavailable");
      return result.data;
    },
    read: async claim => {
      const result = await db.rpc("read_instructor_email_attempt_v1", { p_claim_id: claim });
      if (result.error || result.data?.event_id !== eventId) return null;
      return result.data;
    },
    tenant: resolveEventEmailTenantContext,
    send: async (to, content, idempotencyKey) => {
      const options = { idempotencyKey, signal: AbortSignal.timeout(10000) };
      const result = await resend.emails.send({ from, to, ...content }, options);
      return !result.error && result.data?.id ? result.data.id : null;
    },
    complete: async (claim, success, providerId) => {
      const result = await db.rpc("complete_instructor_email_v1", {
        p_claim_id: claim, p_success: success, p_provider_message_id: providerId,
      });
      return !result.error && result.data?.code === "sent";
    },
  });
}
