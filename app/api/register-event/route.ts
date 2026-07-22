import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

type RegisterEventPayload = {
  eventId?: unknown;
  asReserve?: unknown;
};

type RegisterEventRpcResult = {
  ok: boolean;
  changed: boolean;
  code: RegisterEventCode;
  registration_id?: string;
  registration_status?: string;
};

type RegisterEventCode =
  | "registered"
  | "reserve"
  | "already_registered"
  | "already_reserve"
  | "already_active"
  | "event_inactive"
  | "profile_incomplete"
  | "event_not_found"
  | "event_ended"
  | "conflict";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const SUCCESS_CODES = new Set<RegisterEventCode>([
  "registered",
  "reserve",
  "already_registered",
  "already_reserve",
  "already_active",
]);

const CHANGED_CODES = new Set<RegisterEventCode>(["registered", "reserve"]);

const KNOWN_CODES = new Set<RegisterEventCode>([
  ...SUCCESS_CODES,
  "event_inactive",
  "profile_incomplete",
  "event_not_found",
  "event_ended",
  "conflict",
]);

const RESPONSE_MESSAGES: Record<RegisterEventCode, string> = {
  registered: "Zapis na szkolenie został utworzony.",
  reserve: "Dodano Cię do listy rezerwowej.",
  already_registered: "Jesteś już zapisany na to szkolenie.",
  already_reserve: "Jesteś już na liście rezerwowej tego szkolenia.",
  already_active: "Masz już aktywny zapis na to szkolenie.",
  event_inactive: "To szkolenie nie jest już aktywne.",
  profile_incomplete:
    "Uzupełnij imię, nazwisko, adres e-mail i telefon w profilu przed zapisem.",
  event_not_found: "Nie znaleziono szkolenia.",
  event_ended: "Nie można zapisać się na rozpoczęte szkolenie.",
  conflict: "Nie udało się jednoznacznie potwierdzić zapisu. Odśwież stronę.",
};

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

function isRegisterEventRpcResult(
  value: unknown
): value is RegisterEventRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Partial<RegisterEventRpcResult>;

  if (
    typeof result.ok !== "boolean" ||
    typeof result.changed !== "boolean" ||
    typeof result.code !== "string" ||
    !KNOWN_CODES.has(result.code as RegisterEventCode)
  ) {
    return false;
  }

  const code = result.code as RegisterEventCode;

  if (SUCCESS_CODES.has(code)) {
    const expectedChanged = CHANGED_CODES.has(code);

    return (
      result.ok === true &&
      result.changed === expectedChanged &&
      typeof result.registration_id === "string" &&
      UUID_PATTERN.test(result.registration_id) &&
      typeof result.registration_status === "string" &&
      result.registration_status.trim().length > 0
    );
  }

  return result.ok === false && result.changed === false;
}

function getStatusForCode(code: RegisterEventCode) {
  if (SUCCESS_CODES.has(code)) {
    return 200;
  }

  if (code === "event_not_found") {
    return 404;
  }

  if (code === "event_ended" || code === "conflict") {
    return 409;
  }

  return 400;
}

export async function POST(request: Request) {
  try {
    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return NextResponse.json(
        { error: "Musisz być zalogowany, aby zapisać się na szkolenie." },
        { status: 401 }
      );
    }

    const supabase = getAuthenticatedSupabaseClient(accessToken);
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(accessToken);

    if (userError || !user) {
      return NextResponse.json(
        { error: "Sesja wygasła. Zaloguj się ponownie." },
        { status: 401 }
      );
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
      Array.isArray(parsedBody)
    ) {
      return NextResponse.json(
        { error: "Nieprawidłowe dane żądania." },
        { status: 400 }
      );
    }

    const bodyKeys = Object.keys(parsedBody);
    const allowedBodyKeys = new Set(["eventId", "asReserve"]);

    if (
      !("eventId" in parsedBody) ||
      bodyKeys.some((key) => !allowedBodyKeys.has(key))
    ) {
      return NextResponse.json(
        { error: "Nieprawidłowe dane żądania." },
        { status: 400 }
      );
    }

    const body = parsedBody as RegisterEventPayload;
    const eventId =
      typeof body.eventId === "string" ? body.eventId.trim() : "";

    if (!eventId || !UUID_PATTERN.test(eventId)) {
      return NextResponse.json(
        { error: "Nieprawidłowy identyfikator szkolenia." },
        { status: 400 }
      );
    }

    if (body.asReserve !== undefined && typeof body.asReserve !== "boolean") {
      return NextResponse.json(
        { error: "Nieprawidłowy tryb zapisu." },
        { status: 400 }
      );
    }

    const { data: rpcData, error: rpcError } = await supabase.rpc(
      "register_for_event",
      {
        p_event_id: eventId,
        p_as_reserve: body.asReserve ?? false,
      }
    );

    if (rpcError) {
      console.error("Event registration RPC failed", {
        code: rpcError.code,
      });

      return NextResponse.json(
        { error: "Nie udało się zapisać na szkolenie. Spróbuj ponownie." },
        { status: 500 }
      );
    }

    if (!isRegisterEventRpcResult(rpcData)) {
      console.error("Event registration RPC returned invalid data");

      return NextResponse.json(
        { error: "Nie udało się potwierdzić wyniku zapisu." },
        { status: 500 }
      );
    }

    const status = getStatusForCode(rpcData.code);
    const message = RESPONSE_MESSAGES[rpcData.code];

    if (status !== 200) {
      return NextResponse.json(
        {
          ok: rpcData.ok,
          changed: rpcData.changed,
          code: rpcData.code,
          error: message,
        },
        { status }
      );
    }

    return NextResponse.json({
      ok: rpcData.ok,
      changed: rpcData.changed,
      code: rpcData.code,
      registrationId: rpcData.registration_id,
      registrationStatus: rpcData.registration_status,
      message,
    });
  } catch {
    console.error("Event registration endpoint failed");

    return NextResponse.json(
      { error: "Nie udało się zapisać na szkolenie. Spróbuj ponownie." },
      { status: 500 }
    );
  }
}
