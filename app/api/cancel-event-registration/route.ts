import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { promoteEventReserve } from "../../../lib/server/event-reserve-promotion";
import {
  getAuthUserFailureMessage,
  verifyAuthUser,
} from "@/lib/server/auth-user-verification";

type CancellationPayload = {
  registrationId?: unknown;
};

type CancellationRpcResult = {
  registration_id: string;
  event_id: string;
  changed: boolean;
  previous_status: string;
  new_status: string;
  operator_role: string;
  freed_participant_place: boolean;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

function isCancellationRpcResult(value: unknown): value is CancellationRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Partial<CancellationRpcResult>;

  return (
    typeof result.registration_id === "string" &&
    UUID_PATTERN.test(result.registration_id) &&
    typeof result.event_id === "string" &&
    UUID_PATTERN.test(result.event_id) &&
    typeof result.changed === "boolean" &&
    typeof result.previous_status === "string" &&
    typeof result.new_status === "string" &&
    typeof result.operator_role === "string" &&
    typeof result.freed_participant_place === "boolean"
  );
}

function getRpcErrorResponse(error: { code?: string; message?: string }) {
  if (error.code === "42501") {
    return NextResponse.json(
      { error: "Brak uprawnień do anulowania tego zapisu na szkolenie." },
      { status: 403 }
    );
  }

  if (error.code === "P0002") {
    return NextResponse.json(
      { error: "Nie znaleziono zapisu na szkolenie." },
      { status: 404 }
    );
  }

  if (error.code === "22023") {
    return NextResponse.json(
      { error: "Nieprawidłowy identyfikator zapisu na szkolenie." },
      { status: 400 }
    );
  }

  if (error.code === "55000") {
    const isCancellationWindowError = error.message
      ?.toLowerCase()
      .includes("72 godziny");

    return NextResponse.json(
      {
        error: isCancellationWindowError
          ? "Zapis można anulować najpóźniej 72 godziny przed rozpoczęciem szkolenia."
          : "Zapisu w tym statusie lub terminie nie można anulować.",
      },
      { status: 409 }
    );
  }

  return NextResponse.json(
    { error: "Nie udało się anulować zapisu na szkolenie." },
    { status: 500 }
  );
}

export async function POST(request: Request) {
  try {
    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }

    const supabase = getAuthenticatedSupabaseClient(accessToken);
    const authResult = await verifyAuthUser(() =>
      supabase.auth.getUser(accessToken)
    );

    if (!authResult.ok) {
      if (authResult.code !== "unauthorized") {
        return NextResponse.json(
          {
            code: authResult.code,
            error: getAuthUserFailureMessage(authResult),
          },
          { status: authResult.status }
        );
      }

      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }

    let parsedBody: unknown;

    try {
      parsedBody = await request.json();
    } catch {
      return NextResponse.json(
        { error: "Nieprawidłowe dane żądania." },
        { status: 400 }
      );
    }

    if (
      !parsedBody ||
      typeof parsedBody !== "object" ||
      Array.isArray(parsedBody) ||
      Object.keys(parsedBody).length !== 1 ||
      !("registrationId" in parsedBody)
    ) {
      return NextResponse.json(
        { error: "Nieprawidłowe dane żądania." },
        { status: 400 }
      );
    }

    const body = parsedBody as CancellationPayload;
    const registrationId =
      typeof body.registrationId === "string"
        ? body.registrationId.trim()
        : "";

    if (!registrationId || !UUID_PATTERN.test(registrationId)) {
      return NextResponse.json(
        { error: "Nieprawidłowy identyfikator zapisu na szkolenie." },
        { status: 400 }
      );
    }

    const { data: rpcData, error: rpcError } = await supabase.rpc(
      "cancel_event_registration",
      { p_registration_id: registrationId }
    );

    if (rpcError) {
      console.error("Event registration cancellation RPC failed", {
        code: rpcError.code,
      });
      return getRpcErrorResponse(rpcError);
    }

    if (!isCancellationRpcResult(rpcData)) {
      console.error("Event registration cancellation returned invalid data");
      return NextResponse.json(
        { error: "Nie udało się potwierdzić wyniku anulowania." },
        { status: 500 }
      );
    }

    const cancellation = {
      registrationId: rpcData.registration_id,
      eventId: rpcData.event_id,
      changed: rpcData.changed,
      previousStatus: rpcData.previous_status,
      newStatus: rpcData.new_status,
      freedParticipantPlace: rpcData.freed_participant_place,
    };

    const shouldPromoteReserve =
      rpcData.changed === true &&
      rpcData.freed_participant_place === true;

    if (!shouldPromoteReserve) {
      return NextResponse.json({
        success: true,
        cancellation,
        promotion: {
          attempted: false,
          succeeded: true,
          warning: false,
        },
        message: rpcData.changed
          ? "Udział został anulowany."
          : "Udział jest anulowany.",
      });
    }

    try {
      const promotionResult = await promoteEventReserve(rpcData.event_id);

      if (!promotionResult.success) {
        console.error(
          "Reserve promotion failed after successful event registration cancellation"
        );

        return NextResponse.json({
          success: true,
          cancellation,
          promotion: {
            attempted: true,
            succeeded: false,
            warning: true,
          },
          message:
            "Udział został anulowany, ale nie udało się wysłać powiadomień do listy rezerwowej.",
        });
      }

      return NextResponse.json({
        success: true,
        cancellation,
        promotion: {
          attempted: true,
          succeeded: true,
          warning: false,
        },
        message:
          promotionResult.notifiedCount > 0
            ? "Udział został anulowany. System wysłał powiadomienie o wolnym miejscu do osób z listy rezerwowej."
            : "Udział został anulowany.",
      });
    } catch {
      console.error(
        "Reserve promotion failed after successful event registration cancellation"
      );

      return NextResponse.json({
        success: true,
        cancellation,
        promotion: {
          attempted: true,
          succeeded: false,
          warning: true,
        },
        message:
          "Udział został anulowany, ale nie udało się wysłać powiadomień do listy rezerwowej.",
      });
    }
  } catch {
    console.error("Event registration cancellation endpoint failed");

    return NextResponse.json(
      { error: "Nie udało się anulować zapisu na szkolenie." },
      { status: 500 }
    );
  }
}
