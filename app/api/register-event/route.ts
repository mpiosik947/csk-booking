import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

type RegisterEventPayload = {
  eventId?: string;
  asReserve?: boolean;
  customerName?: string;
  customerEmail?: string;
  customerPhone?: string;
};

type EventRecord = {
  id: string;
  max_participants: number | null;
  is_active: boolean | null;
};

function getAdminSupabaseClient() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error("Brak konfiguracji Supabase service role.");
  }

  return createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}

export async function POST(request: Request) {
  try {
    const authorizationHeader = request.headers.get("authorization");
    const accessToken = authorizationHeader?.replace("Bearer ", "").trim();

    if (!accessToken) {
      return NextResponse.json(
        { error: "Musisz być zalogowany, aby zapisać się na szkolenie." },
        { status: 401 }
      );
    }

    const supabase = getAdminSupabaseClient();

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(accessToken);

    if (userError || !user) {
      return NextResponse.json(
        { error: "Nie udało się potwierdzić użytkownika." },
        { status: 401 }
      );
    }

    const body = (await request.json()) as RegisterEventPayload;

    const {
      eventId,
      asReserve = false,
      customerName,
      customerEmail,
      customerPhone,
    } = body;

    if (!eventId) {
      return NextResponse.json(
        { error: "Brak ID szkolenia." },
        { status: 400 }
      );
    }

    if (!customerPhone) {
      return NextResponse.json(
        { error: "Brakuje numeru telefonu w Twoim koncie." },
        { status: 400 }
      );
    }

    const { data: eventData, error: eventError } = await supabase
      .from("events")
      .select("id, max_participants, is_active")
      .eq("id", eventId)
      .maybeSingle();

    if (eventError || !eventData) {
      return NextResponse.json(
        { error: "Nie znaleziono szkolenia." },
        { status: 404 }
      );
    }

    const eventItem = eventData as EventRecord;

    if (eventItem.is_active === false) {
      return NextResponse.json(
        { error: "To szkolenie nie jest już aktywne." },
        { status: 400 }
      );
    }

    const { data: existingRegistration, error: existingError } = await supabase
      .from("event_registrations")
      .select("id")
      .eq("event_id", eventId)
      .eq("user_id", user.id)
      .neq("registration_status", "cancelled")
      .maybeSingle();

    if (existingError) {
      return NextResponse.json(
        { error: "Nie udało się sprawdzić istniejącego zapisu." },
        { status: 500 }
      );
    }

    if (existingRegistration) {
      return NextResponse.json(
        { error: "Jesteś już zapisany na to szkolenie lub listę rezerwową." },
        { status: 409 }
      );
    }

    const { count: participantsCount, error: participantsError } =
      await supabase
        .from("event_registrations")
        .select("id", { count: "exact", head: true })
        .eq("event_id", eventId)
        .in("registration_status", ["registered", "approved"]);

    if (participantsError) {
      return NextResponse.json(
        { error: "Nie udało się sprawdzić liczby uczestników." },
        { status: 500 }
      );
    }

    const { count: reserveCount, error: reserveError } = await supabase
      .from("event_registrations")
      .select("id", { count: "exact", head: true })
      .eq("event_id", eventId)
      .eq("registration_status", "reserve");

    if (reserveError) {
      return NextResponse.json(
        { error: "Nie udało się sprawdzić listy rezerwowej." },
        { status: 500 }
      );
    }

    const maxParticipants = Number(eventItem.max_participants ?? 0);
    const isFull = (participantsCount ?? 0) >= maxParticipants;
    const hasReserveList = (reserveCount ?? 0) > 0;

    const registrationStatus =
      asReserve || isFull || hasReserveList ? "reserve" : "registered";

    const { data: insertedRegistration, error: insertError } = await supabase
      .from("event_registrations")
      .insert({
        event_id: eventId,
        user_id: user.id,
        customer_name: customerName ?? "",
        customer_email: customerEmail ?? user.email ?? "",
        customer_phone: customerPhone,
        registration_status: registrationStatus,
        payment_status: "pay_on_site",
      })
      .select("id, registration_status")
      .single();

    if (insertError) {
      return NextResponse.json(
        { error: `Błąd zapisu: ${insertError.message}` },
        { status: 500 }
      );
    }

    return NextResponse.json({
      ok: true,
      registrationId: insertedRegistration.id,
      registrationStatus,
    });
  } catch {
    return NextResponse.json(
      { error: "Wystąpił błąd podczas zapisu na szkolenie." },
      { status: 500 }
    );
  }
}
