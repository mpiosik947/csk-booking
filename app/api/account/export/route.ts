import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { isAccountExportPayload } from "@/lib/server/account-lifecycle.js";
import {
  getAuthUserFailureMessage,
  verifyAuthUser,
} from "@/lib/server/auth-user-verification";

function jsonError(
  code: "invalid_request" | "unauthorized" | "auth_unavailable" | "internal_error",
  status: number,
  message: string
) {
  return NextResponse.json(
    { ok: false, code, error: message },
    { status, headers: { "Cache-Control": "no-store" } }
  );
}

export async function GET(request: Request) {
  try {
    const url = new URL(request.url);

    if ([...url.searchParams.keys()].length > 0) {
      return jsonError(
        "invalid_request",
        400,
        "Eksport nie przyjmuje identyfikatora użytkownika ani innych parametrów."
      );
    }

    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return jsonError("unauthorized", 401, "Musisz zalogować się ponownie.");
    }

    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

    if (!supabaseUrl || !anonKey) {
      return jsonError("internal_error", 500, "Nie udało się przygotować eksportu.");
    }

    const supabase = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    });

    const authResult = await verifyAuthUser(() =>
      supabase.auth.getUser(accessToken)
    );

    if (!authResult.ok) {
      return jsonError(
        authResult.code,
        authResult.status,
        getAuthUserFailureMessage(authResult)
      );
    }

    const { data, error } = await supabase.rpc("export_my_data_v1");

    if (error) {
      console.error("Account export RPC failed", { code: error.code });
      return jsonError("internal_error", 500, "Nie udało się przygotować eksportu.");
    }

    if (!isAccountExportPayload(data)) {
      console.error("Account export RPC returned invalid data");
      return jsonError("internal_error", 500, "Nie udało się przygotować eksportu.");
    }

    return new Response(JSON.stringify(data, null, 2), {
      status: 200,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Disposition": 'attachment; filename="csk-booking-my-data.json"',
        "Cache-Control": "no-store, max-age=0",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch {
    console.error("Account export endpoint failed");
    return jsonError("internal_error", 500, "Nie udało się przygotować eksportu.");
  }
}
