import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import {
  buildCalendarFeed,
  getReservationSelectColumns,
  parseCalendarFeedRole,
  type CalendarEventRow,
  type CalendarLaneBlockRow,
  type CalendarLaneRow,
  type CalendarReservationRow,
} from "@/lib/admin/calendar/feed";
import { parseCalendarFeedQuery } from "@/lib/admin/calendar/query";
import { getWarsawCalendarDate } from "@/lib/admin/calendar/time";
import type { CalendarFeedErrorCode } from "@/lib/admin/calendar/types";

const RESPONSE_HEADERS = { "Cache-Control": "private, no-store" };

function getAuthenticatedSupabaseClient(accessToken: string) {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !anonKey) {
    throw new Error("Missing Supabase Auth configuration.");
  }

  return createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

function jsonError(code: CalendarFeedErrorCode, message: string, status: number) {
  return NextResponse.json(
    { ok: false, code, message },
    { status, headers: RESPONSE_HEADERS }
  );
}

export async function GET(request: Request) {
  try {
    const authorization = request.headers.get("authorization");
    const accessToken = authorization?.match(/^Bearer ([^\s]+)$/i)?.[1];
    if (!accessToken) {
      return jsonError("unauthorized", "Wymagane jest zalogowanie.", 401);
    }

    const supabase = getAuthenticatedSupabaseClient(accessToken);
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(accessToken);

    if (userError || !user) {
      return jsonError("unauthorized", "Wymagane jest zalogowanie.", 401);
    }

    const parsedQuery = parseCalendarFeedQuery(new URL(request.url).searchParams);
    if (!parsedQuery.ok) {
      return NextResponse.json(parsedQuery.error, {
        status: 400,
        headers: RESPONSE_HEADERS,
      });
    }

    const { data: roleData, error: roleError } = await supabase.rpc("get_my_role");
    if (roleError) {
      console.error("Calendar feed role lookup failed", { code: roleError.code });
      return jsonError("calendar_feed_failed", "Nie udało się pobrać kalendarza.", 500);
    }

    const role = parseCalendarFeedRole(roleData);
    if (!role) {
      return jsonError("forbidden", "Brak uprawnień do kalendarza.", 403);
    }

    const query = parsedQuery.value;
    const laneRequest = supabase
      .from("shooting_lanes")
      .select(
        "id,name,is_active,display_order,booking_step_minutes,resource_kind,parent_lane_id"
      );
    const { data: laneData, error: laneError } = await laneRequest;

    if (laneError) {
      console.error("Calendar feed lane query failed", { code: laneError.code });
      return jsonError("calendar_feed_failed", "Nie udało się pobrać kalendarza.", 500);
    }
    if (query.laneId !== "all" && (laneData?.length ?? 0) === 0) {
      return jsonError("lane_not_found", "Nie znaleziono osi.", 404);
    }

    let reservations: CalendarReservationRow[] = [];
    if (role !== "instruktor" && query.types.includes("reservation")) {
      let reservationRequest = supabase
        .from("reservations")
        .select(getReservationSelectColumns(role))
        .gte("reservation_date", query.rangeStart)
        .lte("reservation_date", query.rangeEnd)
        .in(
          "reservation_status",
          query.includeHistoricalStatuses
            ? ["confirmed", "completed", "no_show"]
            : ["confirmed"]
        );
      if (query.laneId !== "all") {
        reservationRequest = reservationRequest.eq("lane_id", query.laneId);
      }
      const { data, error } = await reservationRequest;
      if (error) {
        console.error("Calendar feed reservation query failed", { code: error.code });
        return jsonError("calendar_feed_failed", "Nie udało się pobrać kalendarza.", 500);
      }
      reservations = (data ?? []) as unknown as CalendarReservationRow[];
    }

    let laneBlocks: CalendarLaneBlockRow[] = [];
    if (query.types.includes("lane_block")) {
      let blockRequest = supabase
        .from("lane_blocks")
        .select("id,lane_id,block_date,start_time,end_time,reason,is_active")
        .gte("block_date", query.rangeStart)
        .lte("block_date", query.rangeEnd);
      if (!query.includeHistoricalStatuses) blockRequest = blockRequest.eq("is_active", true);
      if (query.laneId !== "all") blockRequest = blockRequest.eq("lane_id", query.laneId);
      const { data, error } = await blockRequest;
      if (error) {
        console.error("Calendar feed lane block query failed", { code: error.code });
        return jsonError("calendar_feed_failed", "Nie udało się pobrać kalendarza.", 500);
      }
      laneBlocks = (data ?? []) as unknown as CalendarLaneBlockRow[];
    }

    let events: CalendarEventRow[] = [];
    if (query.types.includes("event")) {
      const { data, error } = await supabase
        .from("events")
        .select("id,title,event_date,start_time,end_time,location,max_participants,is_active,event_lanes(lane_id,shooting_lanes(id,name))")
        .gte("event_date", query.rangeStart)
        .lte("event_date", query.rangeEnd)
        .eq("is_active", true);
      if (error) {
        console.error("Calendar feed event query failed", { code: error.code });
        return jsonError("calendar_feed_failed", "Nie udało się pobrać kalendarza.", 500);
      }
      events = (data ?? []) as unknown as CalendarEventRow[];
    }

    const feed = buildCalendarFeed(
      query,
      role,
      {
        lanes: (laneData ?? []) as unknown as CalendarLaneRow[],
        reservations,
        laneBlocks,
        events,
      },
      getWarsawCalendarDate()
    );

    if (query.laneId !== "all" && !feed.lanes.some((lane) => lane.id === query.laneId)) {
      return jsonError("lane_not_found", "Oś jest nieaktywna i nie ma historii w tym zakresie.", 404);
    }

    return NextResponse.json(feed, { headers: RESPONSE_HEADERS });
  } catch {
    console.error("Calendar feed endpoint failed");
    return jsonError("calendar_feed_failed", "Nie udało się pobrać kalendarza.", 500);
  }
}
