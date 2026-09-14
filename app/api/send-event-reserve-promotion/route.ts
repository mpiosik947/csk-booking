import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { promoteEventReserve } from "../../../lib/server/event-reserve-promotion";
import {
  getAuthUserFailureMessage,
  verifyAuthUser,
} from "@/lib/server/auth-user-verification";

type EventReservePromotionPayload = {
  eventId?: unknown;
};

type AuthorizedEvent = {
  id: string;
  tenant_id: string;
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

export async function POST(request: Request) {
  try {
    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }

    const authenticatedSupabase = getAuthenticatedSupabaseClient(accessToken);
    const authResult = await verifyAuthUser(() =>
      authenticatedSupabase.auth.getUser(accessToken)
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
      !("eventId" in parsedBody)
    ) {
      return NextResponse.json(
        { error: "Nieprawidłowe dane żądania." },
        { status: 400 }
      );
    }

    const body = parsedBody as EventReservePromotionPayload;
    const eventId =
      typeof body.eventId === "string" ? body.eventId.trim() : "";

    if (!eventId || !UUID_PATTERN.test(eventId)) {
      return NextResponse.json(
        { error: "Nieprawidłowy identyfikator szkolenia." },
        { status: 400 }
      );
    }

    const { data: eventData, error: eventError } = await authenticatedSupabase
      .from("events")
      .select("id, tenant_id")
      .eq("id", eventId)
      .maybeSingle();

    if (eventError) {
      return NextResponse.json(
        { error: "Nie udało się zweryfikować szkolenia." },
        { status: 500 }
      );
    }

    const event = eventData as AuthorizedEvent | null;

    if (!event?.id || !event.tenant_id || !UUID_PATTERN.test(event.tenant_id)) {
      return NextResponse.json(
        { error: "Nie znaleziono szkolenia." },
        { status: 404 }
      );
    }

    const { data: hasAllowedTenantRole, error: tenantRoleError } =
      await authenticatedSupabase.rpc("has_tenant_role_v1", {
        p_tenant_id: event.tenant_id,
        p_roles: ["admin", "employee"],
      });

    if (tenantRoleError) {
      return NextResponse.json(
        { error: "Nie udało się zweryfikować uprawnień." },
        { status: 500 }
      );
    }

    if (hasAllowedTenantRole !== true) {
      return NextResponse.json({ error: "Forbidden" }, { status: 403 });
    }

    const promotionResult = await promoteEventReserve(eventId);

    if (!promotionResult.success) {
      return NextResponse.json(
        {
          error:
            promotionResult.error ??
            "Nie udało się wysłać powiadomień do listy rezerwowej.",
          reserveFound: promotionResult.reserveFound,
          emailsSent: promotionResult.notifiedCount,
        },
        { status: promotionResult.statusCode ?? 500 }
      );
    }

    return NextResponse.json({
      ok: true,
      reserveFound: promotionResult.reserveFound,
      emailsSent: promotionResult.notifiedCount,
      ...(promotionResult.noFreePlace ? { noFreePlace: true } : {}),
    });
  } catch {
    return NextResponse.json(
      { error: "Wystąpił błąd podczas wysyłki powiadomień do listy rezerwowej." },
      { status: 500 }
    );
  }
}
