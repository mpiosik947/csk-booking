import { createClient } from "@supabase/supabase-js";
import { verifyAuthUser } from "@/lib/server/auth-user-verification";
import { sendEventCancellationBatch } from "@/lib/server/event-wide-cancellation";

export const maxDuration = 120;
export async function POST(request: Request) {
  const respond = (body: object, status: number) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
  try {
    const token = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
    if (!token) return respond({ code: "unauthorized" }, 401);
    const body = await request.json().catch(() => null);
    if (!body || Object.keys(body).sort().join() !== "eventId,retry" || typeof body.retry !== "boolean" ||
      typeof body.eventId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.eventId)) return respond({ code: "invalid_request" }, 400);
    const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
      auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const auth = await verifyAuthUser(() => db.auth.getUser(token));
    if (!auth.ok) return respond({ code: auth.code }, auth.status);
    if (!body.retry) {
      const cancelled = await db.rpc("admin_cancel_event_v1", { p_event_id: body.eventId });
      if (cancelled.error) return respond({ code: "unavailable" }, 403);
    }
    try { return respond({ code: "cancelled", delivery: await sendEventCancellationBatch(db, body.eventId) }, 200); }
    catch { return respond({ code: "delivery_unavailable" }, 503); }
  } catch { return respond({ code: "unavailable" }, 503); }
}
