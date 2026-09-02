import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import {
  getAuthUserFailureMessage,
  verifyAuthUser,
} from "@/lib/server/auth-user-verification";
import {
  getConfirmEventReserveStatus,
  isConfirmEventReserveResult,
  parseConfirmEventReservePayload,
} from "@/lib/server/event-reserve-confirmation-contract";
import {
  sendConfirmedPlaceEmail,
  type ConfirmedRegistration,
} from "@/lib/server/event-reserve-confirmation-email";

function getAuthenticatedSupabaseClient(accessToken: string) {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !anonKey) {
    throw new Error("Brak konfiguracji Supabase Auth.");
  }

  return createClient(supabaseUrl, anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
    global: {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    },
  });
}

function getRpcErrorResponse(error: { code?: string }) {
  if (error.code === "42501") {
    return NextResponse.json(
      {
        code: "forbidden",
        error: "Nie możesz potwierdzić tego zapisu na szkolenie.",
      },
      { status: 403 }
    );
  }

  if (error.code === "22023") {
    return NextResponse.json(
      { code: "invalid_token", error: "Nieprawidłowy link potwierdzający." },
      { status: 400 }
    );
  }

  return NextResponse.json(
    {
      code: "internal_error",
      error: "Nie udało się potwierdzić miejsca. Spróbuj ponownie.",
    },
    { status: 500 }
  );
}

export async function POST(request: Request) {
  try {
    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return NextResponse.json(
        { code: "unauthorized", error: "Musisz się zalogować." },
        { status: 401 }
      );
    }

    const supabase = getAuthenticatedSupabaseClient(accessToken);
    const authResult = await verifyAuthUser(() =>
      supabase.auth.getUser(accessToken)
    );

    if (!authResult.ok) {
      return NextResponse.json(
        {
          code: authResult.code,
          error: getAuthUserFailureMessage(authResult),
        },
        { status: authResult.status }
      );
    }

    let parsedBody: unknown;

    try {
      parsedBody = await request.json();
    } catch {
      return NextResponse.json(
        { code: "invalid_token", error: "Nieprawidłowy link potwierdzający." },
        { status: 400 }
      );
    }

    const payload = parseConfirmEventReservePayload(parsedBody);

    if (!payload.ok) {
      return NextResponse.json(
        { code: "invalid_token", error: "Nieprawidłowy link potwierdzający." },
        { status: 400 }
      );
    }

    const { data: rpcData, error: rpcError } = await supabase.rpc(
      "confirm_event_reserve_promotion",
      { p_token: payload.token }
    );

    if (rpcError) {
      console.error("Event reserve confirmation RPC failed", {
        code: rpcError.code,
      });
      return getRpcErrorResponse(rpcError);
    }

    if (!isConfirmEventReserveResult(rpcData)) {
      console.error("Event reserve confirmation RPC returned invalid data");
      return NextResponse.json(
        {
          code: "internal_error",
          error: "Nie udało się potwierdzić wyniku operacji.",
        },
        { status: 500 }
      );
    }

    const status = getConfirmEventReserveStatus(rpcData.code);

    if (!rpcData.ok || rpcData.code !== "confirmed") {
      return NextResponse.json(
        {
          ok: false,
          code: rpcData.code,
          message: rpcData.message,
        },
        { status }
      );
    }

    const { data: registrationData, error: registrationError } = await supabase
      .from("event_registrations")
      .select(
        `
          id,
          customer_email,
          customer_name,
          events (
            title,
            event_date,
            start_time,
            end_time,
            location,
            price
          )
        `
      )
      .eq("id", rpcData.registration_id)
      .eq("user_id", authResult.user.id)
      .maybeSingle();

    if (!registrationError && registrationData) {
      await sendConfirmedPlaceEmail(
        registrationData as unknown as ConfirmedRegistration
      ).catch(() => null);
    }

    return NextResponse.json({
      ok: true,
      code: rpcData.code,
      message: rpcData.message,
    });
  } catch {
    console.error("Event reserve confirmation endpoint failed");
    return NextResponse.json(
      {
        code: "internal_error",
        error: "Nie udało się potwierdzić miejsca. Spróbuj ponownie.",
      },
      { status: 500 }
    );
  }
}
