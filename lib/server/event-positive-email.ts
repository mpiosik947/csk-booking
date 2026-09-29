import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";

/** Claim commit is dispatch admission. This read only checks that exact attempt's lease.
 * Cancellation after admission cannot recall it. Expired/replaced claims never authorize retries. */
export async function requireEventDispatchLease(db: SupabaseClient, claimId: string, kind: "registration" | "acceptance" | "promotion") {
  const { data, error } = await db.rpc("check_event_email_dispatch_lease_v1", { p_claim_id: claimId, p_kind: kind });
  if (error || data !== true) throw new Error("Event email unavailable");
}
