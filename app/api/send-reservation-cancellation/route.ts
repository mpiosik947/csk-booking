import { NextResponse } from "next/server";
import { Resend } from "resend";
import { createClient } from "@supabase/supabase-js";
import { getProfileDisplayName } from "../../../lib/profile-display-name";
import { isCancelledReservationStatus } from "../../../lib/reservation-status";

type ReservationCancellationPayload = {
  reservationId?: unknown;
};

type OperatorProfile = {
  user_id: string;
  role: string | null;
};

type OwnerProfile = {
  first_name: string | null;
  last_name: string | null;
  full_name: string | null;
  email: string | null;
};

type ReservationRecord = {
  id: string;
  user_id: string;
  customer_name: string | null;
  customer_email: string | null;
  reservation_date: string;
  start_time: string;
  end_time: string;
  reservation_status: string | null;
  lane_id: string | null;
  shooting_lanes: { name: string | null } | { name: string | null }[] | null;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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

function escapeHtml(value: string) {
  const entities: Record<string, string> = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  };

  return value.replace(/[&<>'"]/g, (character) => entities[character]);
}

function getLaneName(reservation: ReservationRecord) {
  const lanes = reservation.shooting_lanes;

  if (Array.isArray(lanes)) {
    return lanes[0]?.name?.trim() || "Brak osi";
  }

  return lanes?.name?.trim() || "Brak osi";
}

function formatDate(date?: string) {
  if (!date) {
    return "Brak daty";
  }

  try {
    return new Intl.DateTimeFormat("pl-PL", {
      year: "numeric",
      month: "long",
      day: "2-digit",
    }).format(new Date(date));
  } catch {
    return date;
  }
}

export async function POST(request: Request) {
  try {
    const resendApiKey = process.env.RESEND_API_KEY;
    const from = process.env.RESERVATION_EMAIL_FROM;

    const authorizationHeader = request.headers.get("authorization");
    const authorizationMatch = authorizationHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = authorizationMatch?.[1]?.trim();

    if (!accessToken) {
      return NextResponse.json(
        { error: "Musisz być zalogowany, aby wysłać wiadomość." },
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
      !("reservationId" in parsedBody)
    ) {
      return NextResponse.json(
        { error: "Nieprawidłowe dane żądania." },
        { status: 400 }
      );
    }

    const body = parsedBody as ReservationCancellationPayload;
    const reservationId =
      typeof body.reservationId === "string" ? body.reservationId.trim() : "";

    if (!reservationId || !UUID_PATTERN.test(reservationId)) {
      return NextResponse.json(
        { error: "Nieprawidłowy identyfikator rezerwacji." },
        { status: 400 }
      );
    }

    const { data: operatorProfileData, error: operatorProfileError } =
      await supabase
        .from("profiles")
        .select("user_id, role")
        .eq("user_id", user.id)
        .maybeSingle();

    if (operatorProfileError) {
      return NextResponse.json(
        { error: "Nie udało się zweryfikować uprawnień." },
        { status: 500 }
      );
    }

    const operatorProfile = operatorProfileData as OperatorProfile | null;
    const operatorRole = operatorProfile?.role?.trim().toLowerCase() ?? "";

    const { data: reservationData, error: reservationError } = await supabase
      .from("reservations")
      .select(
        `
        id,
        user_id,
        customer_name,
        customer_email,
        reservation_date,
        start_time,
        end_time,
        reservation_status,
        lane_id,
        shooting_lanes (
          name
        )
      `
      )
      .eq("id", reservationId)
      .maybeSingle();

    if (reservationError) {
      return NextResponse.json(
        { error: "Nie udało się pobrać rezerwacji." },
        { status: 500 }
      );
    }

    if (!reservationData) {
      return NextResponse.json(
        { error: "Nie znaleziono rezerwacji." },
        { status: 404 }
      );
    }

    const reservation = reservationData as ReservationRecord;
    const isOwner = reservation.user_id === user.id;
    const isStaff = operatorRole === "admin" || operatorRole === "pracownik";

    if (!isOwner && !isStaff) {
      return NextResponse.json(
        { error: "Brak uprawnień do tej operacji." },
        { status: 403 }
      );
    }

    if (!isCancelledReservationStatus(reservation.reservation_status)) {
      return NextResponse.json(
        { error: "Rezerwacja nie została anulowana." },
        { status: 409 }
      );
    }

    const ownerProfileResult = isStaff
      ? await supabase.rpc("get_reservation_customer_profiles_v1", {
          p_reservation_ids: [reservation.id],
        })
      : await supabase
          .from("profiles")
          .select("first_name, last_name, full_name, email")
          .eq("user_id", user.id)
          .maybeSingle();
    const ownerProfileError = ownerProfileResult.error;

    if (ownerProfileError) {
      return NextResponse.json(
        { error: "Nie udało się pobrać danych odbiorcy." },
        { status: 500 }
      );
    }

    const ownerProfile = (isStaff
      ? ((ownerProfileResult.data ?? [])[0] ?? null)
      : ownerProfileResult.data) as OwnerProfile | null;
    const customerEmail =
      reservation.customer_email?.trim() ||
      ownerProfile?.email?.trim() ||
      (isOwner ? user.email?.trim() : "") ||
      "";

    if (!customerEmail || !EMAIL_PATTERN.test(customerEmail)) {
      return NextResponse.json(
        { error: "Nie udało się ustalić adresu e-mail odbiorcy." },
        { status: 400 }
      );
    }

    const profileDisplayName = ownerProfile?.full_name?.trim() ||
      (ownerProfile ? getProfileDisplayName(ownerProfile, "") : "");
    const customerName =
      reservation.customer_name?.trim() ||
      profileDisplayName ||
      reservation.customer_email?.trim() ||
      "Kliencie";
    const reservationDate = reservation.reservation_date;
    const startTime = reservation.start_time;
    const endTime = reservation.end_time;
    const laneName = getLaneName(reservation);
    const cancelledBy: "user" | "admin" = isOwner ? "user" : "admin";

    if (!resendApiKey || !from) {
      return NextResponse.json(
        { error: "Brak konfiguracji wysyłki email." },
        { status: 500 }
      );
    }

    const resend = new Resend(resendApiKey);

    const displayName = customerName;
    const formattedDate = formatDate(reservationDate);
    const safeDisplayName = escapeHtml(displayName);
    const safeFormattedDate = escapeHtml(formattedDate);
    const safeStartTime = escapeHtml(startTime);
    const safeEndTime = escapeHtml(endTime);
    const safeLaneName = escapeHtml(laneName);

    const cancelledByText =
      cancelledBy === "admin"
        ? "Rezerwacja została anulowana przez obsługę CSK."
        : "Twoja rezerwacja została anulowana.";

    const subject = "Anulowanie rezerwacji — CSK Booking";

    const html = `
      <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
        <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
          <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
            <p style="margin:0 0 18px 0;color:#ef4444;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
              CSK Booking
            </p>

            <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
              Anulowanie rezerwacji
            </h1>

            <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
              Cześć ${safeDisplayName}, ${cancelledByText}
            </p>

            <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Data:</strong> ${safeFormattedDate}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Godzina:</strong> ${safeStartTime} - ${safeEndTime}
              </p>
              <p style="margin:0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Oś:</strong> ${safeLaneName}
              </p>
            </div>

            <p style="margin:0;font-size:14px;line-height:1.6;color:#a1a1aa;">
              W przypadku pytań skontaktuj się z obsługą CSK.
            </p>
          </div>

          <p style="margin:18px 0 0 0;text-align:center;font-size:12px;color:#71717a;">
            Centrum Szkolenia Krutla · CSK Booking
          </p>
        </div>
      </div>
    `;

    const text = `
CSK Booking — anulowanie rezerwacji

Cześć ${displayName},

${cancelledByText}

Data: ${formattedDate}
Godzina: ${startTime ?? "-"} - ${endTime ?? "-"}
Oś: ${laneName ?? "-"}

W przypadku pytań skontaktuj się z obsługą CSK.

Centrum Szkolenia Krutla
CSK Booking
    `;

    const { error } = await resend.emails.send({
      from,
      to: customerEmail,
      subject,
      html,
      text,
    });

    if (error) {
      return NextResponse.json(
        { error: "Nie udało się wysłać emaila anulowania." },
        { status: 500 }
      );
    }

    return NextResponse.json({ ok: true });
  } catch {
    return NextResponse.json(
      { error: "Wystąpił błąd podczas wysyłki emaila anulowania." },
      { status: 500 }
    );
  }
}
