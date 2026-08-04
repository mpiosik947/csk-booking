import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import {
  CREATE_RESERVATION_MESSAGES,
  getCreateReservationHttpStatus,
  isCreateReservationRpcResult,
  parseCreateReservationPayload,
} from "@/lib/server/create-reservation-contract";

function getAuthenticatedSupabaseClient(accessToken: string) {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !anonKey) {
    throw new Error("Missing Supabase Auth configuration.");
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

function jsonError(code: "invalid_request" | "unauthorized" | "internal_error", status: number) {
  return NextResponse.json(
    {
      ok: false,
      changed: false,
      code,
      error: CREATE_RESERVATION_MESSAGES[code],
    },
    { status }
  );
}

export async function POST(request: Request) {
  try {
    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return jsonError("unauthorized", 401);
    }

    const supabase = getAuthenticatedSupabaseClient(accessToken);
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(accessToken);

    if (userError || !user) {
      return jsonError("unauthorized", 401);
    }

    let parsedBody: unknown;

    try {
      parsedBody = await request.json();
    } catch {
      return jsonError("invalid_request", 400);
    }

    const body = parseCreateReservationPayload(parsedBody);

    if (!body) {
      return jsonError("invalid_request", 400);
    }

    const { data, error } = await supabase.rpc("create_reservation", {
      p_lane_id: body.laneId,
      p_reservation_date: body.reservationDate,
      p_start_time: body.startTime,
      p_duration_minutes: body.durationMinutes,
      p_shooters_count: body.shootersCount,
      p_creation_request_id: body.creationRequestId,
      p_reservation_note: body.reservationNote,
    });

    if (error) {
      console.error("Create reservation RPC failed", { code: error.code });
      return jsonError("internal_error", 500);
    }

    if (!isCreateReservationRpcResult(data)) {
      console.error("Create reservation RPC returned invalid data");
      return jsonError("internal_error", 500);
    }

    const status = getCreateReservationHttpStatus(data.code);
    const message = CREATE_RESERVATION_MESSAGES[data.code];

    if (status !== 200) {
      return NextResponse.json(
        {
          ok: data.ok,
          changed: data.changed,
          code: data.code,
          error: message,
        },
        { status }
      );
    }

    return NextResponse.json({
      ok: data.ok,
      changed: data.changed,
      code: data.code,
      reservationId: data.reservation_id,
      reservationStatus: data.reservation_status,
      laneName: data.lane_name,
      shootersCount: data.shooters_count,
      durationMinutes: data.duration_minutes,
      pricingDayGroup: data.pricing_day_group,
      pricePerHour: data.price_per_hour,
      totalPrice: data.total_price,
      currencyCode: data.currency_code,
      message,
    });
  } catch {
    console.error("Create reservation endpoint failed");
    return jsonError("internal_error", 500);
  }
}
