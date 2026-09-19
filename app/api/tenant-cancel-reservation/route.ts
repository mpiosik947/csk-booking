import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { tenantResourceMatches } from "@/lib/server/tenant-resource-scope";
import { verifyAuthUser } from "@/lib/server/auth-user-verification";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Tenant-route cancellation only; the existing DB RPC remains authoritative. */
export async function POST(request: Request) {
  const authorization = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  if (!authorization) return NextResponse.json({ code: "unauthorized" }, { status: 401 });
  const slug = new URL(request.url).searchParams.get("tenant");
  if (!slug) return NextResponse.json({ code: "invalid_request" }, { status: 400 });
  let body: unknown;
  try { body = await request.json(); } catch { return NextResponse.json({ code: "invalid_request" }, { status: 400 }); }
  if (!body || typeof body !== "object" || Array.isArray(body) ||
      Object.keys(body).sort().join(",") !== "reservationId") {
    return NextResponse.json({ code: "invalid_request" }, { status: 400 });
  }
  const id = (body as { reservationId?: unknown }).reservationId;
  if (typeof id !== "string" || !UUID.test(id)) {
    return NextResponse.json({ code: "invalid_request" }, { status: 400 });
  }
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return NextResponse.json({ code: "unavailable" }, { status: 503 });
  const client = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${authorization}` } },
  });
  const actor = await verifyAuthUser(() => client.auth.getUser(authorization));
  if (!actor.ok) return NextResponse.json({ code: actor.code }, { status: actor.status });
  if (!await tenantResourceMatches(client, slug, "reservations", id)) {
    return NextResponse.json({ code: "not_found" }, { status: 404 });
  }
  const { data, error } = await client.rpc("cancel_reservation", { p_reservation_id: id });
  if (error) return NextResponse.json({ code: "cancel_failed" }, { status: 409 });
  return NextResponse.json(data, { headers: { "Cache-Control": "private, no-store" } });
}
