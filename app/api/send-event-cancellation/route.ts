import { createClient } from "@supabase/supabase-js";
import { verifyAuthUser } from "@/lib/server/auth-user-verification";
import { sendEventCancellationReceipt } from "@/lib/server/event-cancellation-email";

/** Receipt only: never cancels, promotes or accepts a registration. */
export async function POST(request: Request) {
  const respond = (code: string, status: number) => Response.json({ code }, { status, headers: { "Cache-Control": "no-store" } });
  try {
    const token = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
    if (!token) return respond("unauthorized", 401);
    const body = await request.json().catch(() => null);
    if (!body || typeof body !== "object" || Array.isArray(body) || Object.keys(body).join() !== "registrationId" ||
      typeof body.registrationId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.registrationId)) return respond("invalid_request", 400);
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !key) return respond("unavailable", 503);
    const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } } });
    const auth = await verifyAuthUser(() => db.auth.getUser(token));
    if (!auth.ok) return respond(auth.code, auth.status);
    const result = await sendEventCancellationReceipt(db, body.registrationId);
    return respond(result, result === "sent" || result === "already_sent" ? 200 : result === "unavailable" ? 403 : 409);
  } catch { return respond("unavailable", 503); }
}
