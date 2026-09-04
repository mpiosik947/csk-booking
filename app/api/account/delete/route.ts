import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { executeAccountDeletion } from "@/lib/server/account-lifecycle.js";
import {
  getAuthUserFailureMessage,
  verifyAuthUser,
} from "@/lib/server/auth-user-verification";

const REQUIRED_CONFIRMATION = "USUŃ KONTO";

function jsonError(
  code:
    | "invalid_request"
    | "unauthorized"
    | "auth_unavailable"
    | "auth_deletion_pending"
    | "internal_error",
  status: number,
  message: string
) {
  return NextResponse.json(
    { ok: false, code, error: message },
    { status, headers: { "Cache-Control": "no-store" } }
  );
}

export async function POST(request: Request) {
  try {
    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return jsonError("unauthorized", 401, "Musisz zalogować się ponownie.");
    }

    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return jsonError("internal_error", 500, "Nie udało się usunąć konta.");
    }

    let parsedBody: unknown;

    try {
      parsedBody = await request.json();
    } catch {
      return jsonError("invalid_request", 400, "Potwierdzenie usunięcia jest wymagane.");
    }

    if (
      parsedBody === null ||
      typeof parsedBody !== "object" ||
      Array.isArray(parsedBody) ||
      Object.keys(parsedBody).length !== 1 ||
      !("confirmation" in parsedBody) ||
      parsedBody.confirmation !== REQUIRED_CONFIRMATION
    ) {
      return jsonError("invalid_request", 400, "Potwierdzenie usunięcia jest nieprawidłowe.");
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

    const authAdmin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const result = await executeAccountDeletion({
      anonymizeBusinessData: () => supabase.rpc("anonymize_my_account_v1"),
      deleteAuthUser: () => authAdmin.auth.admin.deleteUser(authResult.user.id),
    });

    if (!result.ok) {
      if (result.code === "auth_deletion_pending") {
        return jsonError(
          result.code,
          result.status,
          "Dane konta zostały usunięte, ale zamknięcie logowania wymaga ponowienia. Spróbuj ponownie."
        );
      }

      return jsonError("internal_error", 500, "Nie udało się usunąć konta.");
    }

    return NextResponse.json(
      { ok: true, code: "deleted", message: "Konto zostało usunięte." },
      { status: 200, headers: { "Cache-Control": "no-store" } }
    );
  } catch {
    console.error("Account deletion endpoint failed");
    return jsonError("internal_error", 500, "Nie udało się usunąć konta.");
  }
}
