import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import {
  getAuthUserFailureMessage,
  verifyAuthUser,
} from "./auth-user-verification";
import { ICS_CACHE_CONTROL, ICS_CONTENT_TYPE } from "./icalendar";

export const CALENDAR_RECORD_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function calendarError(
  code: "invalid_request" | "unauthorized" | "auth_unavailable" | "not_found" | "invalid_status" | "internal_error",
  status: number,
  message: string,
) {
  return NextResponse.json(
    { ok: false, code, error: message },
    { status, headers: { "Cache-Control": "no-store" } },
  );
}

export async function getCalendarRequestContext(request: Request) {
  const authorization = request.headers.get("authorization");
  const accessToken = authorization?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();

  if (!accessToken) {
    return { ok: false as const, response: calendarError("unauthorized", 401, "Musisz zalogować się ponownie.") };
  }

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!supabaseUrl || !anonKey) {
    return { ok: false as const, response: calendarError("internal_error", 500, "Nie udało się przygotować kalendarza.") };
  }

  const supabase = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
  const authResult = await verifyAuthUser(() => supabase.auth.getUser(accessToken));

  if (!authResult.ok) {
    return {
      ok: false as const,
      response: calendarError(
        authResult.code,
        authResult.status,
        getAuthUserFailureMessage(authResult),
      ),
    };
  }

  return { ok: true as const, supabase, user: authResult.user };
}

export function calendarFile(content: string, filename: string) {
  return new Response(content, {
    status: 200,
    headers: {
      "Content-Type": ICS_CONTENT_TYPE,
      "Content-Disposition": `attachment; filename="${filename}"`,
      "Cache-Control": ICS_CACHE_CONTROL,
      "X-Content-Type-Options": "nosniff",
    },
  });
}
