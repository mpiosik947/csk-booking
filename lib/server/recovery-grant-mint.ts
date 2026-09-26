import "server-only";
import { createClient } from "@supabase/supabase-js";
import { newRecoveryGrant, recoveryGrantHash } from "./recovery-context";

// Construct before consuming proof. Never expose this client or a mint route to browsers.
export function recoveryGrantMinter() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("Recovery provisioning unavailable");
  const client = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  // Called ONLY immediately after verified recovery PKCE or verifyOtp(type=recovery).
  return async (verifiedSessionId: string) => {
    const raw = newRecoveryGrant();
    const { data, error } = await client.rpc("create_recovery_grant_v1", {
      p_session_id: verifiedSessionId, p_grant_hash: recoveryGrantHash(raw),
    });
    if (error || data !== true) throw new Error("Recovery provisioning failed");
    return raw;
  };
}
