import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { Resend } from "resend";

type ReservationConfirmationPayload = {
  reservationId?: unknown;
};

type ReservationRow = {
  lane_id: string;
  customer_name: string | null;
  reservation_date: string;
  start_time: string;
  end_time: string;
  price: number | null;
  reservation_status: string;
  check_in_token: string | null;
};

type LaneRow = {
  name: string | null;
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

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (character) => {
    const entities: Record<string, string> = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    };

    return entities[character];
  });
}

function formatPrice(price: number | null) {
  if (typeof price !== "number" || !Number.isFinite(price)) {
    return "Do ustalenia";
  }

  return `${price.toFixed(2)} zł`;
}

function formatDate(date: string) {
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

function jsonError(
  code:
    | "invalid_request"
    | "unauthorized"
    | "not_found"
    | "invalid_status"
    | "delivery_failed"
    | "internal_error",
  status: number
) {
  return NextResponse.json({ ok: false, code }, { status });
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
      console.error("Reservation confirmation authorization failed");
      return jsonError("unauthorized", 401);
    }

    let parsedBody: unknown;

    try {
      parsedBody = await request.json();
    } catch {
      console.error("Reservation confirmation invalid request body");
      return jsonError("invalid_request", 400);
    }

    if (
      !parsedBody ||
      typeof parsedBody !== "object" ||
      Array.isArray(parsedBody)
    ) {
      console.error("Reservation confirmation invalid request contract");
      return jsonError("invalid_request", 400);
    }

    const bodyKeys = Object.keys(parsedBody);

    if (bodyKeys.length !== 1 || bodyKeys[0] !== "reservationId") {
      console.error("Reservation confirmation invalid request contract");
      return jsonError("invalid_request", 400);
    }

    const body = parsedBody as ReservationConfirmationPayload;
    const reservationId =
      typeof body.reservationId === "string" ? body.reservationId.trim() : "";

    if (!reservationId || !UUID_PATTERN.test(reservationId)) {
      console.error("Reservation confirmation invalid reservation id");
      return jsonError("invalid_request", 400);
    }

    const { data: reservationData, error: reservationError } = await supabase
      .from("reservations")
      .select(
        "lane_id,customer_name,reservation_date,start_time,end_time,price,reservation_status,check_in_token"
      )
      .eq("id", reservationId)
      .eq("user_id", user.id)
      .maybeSingle();

    if (reservationError) {
      console.error("Reservation confirmation reservation read failed", {
        code: reservationError.code,
      });
      return jsonError("internal_error", 500);
    }

    if (!reservationData) {
      return jsonError("not_found", 404);
    }

    const reservation = reservationData as ReservationRow;
    const reservationStatus = reservation.reservation_status
      .trim()
      .toLowerCase();

    if (reservationStatus !== "confirmed") {
      return jsonError("invalid_status", 409);
    }

    const checkInToken = reservation.check_in_token?.trim();

    if (!checkInToken || !UUID_PATTERN.test(checkInToken)) {
      console.error("Reservation confirmation check-in token unavailable");
      return jsonError("internal_error", 500);
    }

    const { data: laneData, error: laneError } = await supabase
      .from("shooting_lanes")
      .select("name")
      .eq("id", reservation.lane_id)
      .maybeSingle();

    if (laneError) {
      console.error("Reservation confirmation lane read failed", {
        code: laneError.code,
      });
      return jsonError("internal_error", 500);
    }

    if (!laneData) {
      return jsonError("not_found", 404);
    }

    const recipientEmail = user.email?.trim();

    if (!recipientEmail) {
      console.error("Reservation confirmation recipient unavailable");
      return jsonError("delivery_failed", 502);
    }

    const resendApiKey = process.env.RESEND_API_KEY;
    const from = process.env.RESERVATION_EMAIL_FROM;

    if (!resendApiKey || !from) {
      console.error("Reservation confirmation email configuration missing");
      return jsonError("internal_error", 500);
    }

    const lane = laneData as LaneRow;
    const displayName = reservation.customer_name?.trim() || "Kliencie";
    const formattedDate = formatDate(reservation.reservation_date);
    const formattedPrice = formatPrice(reservation.price);
    const startTime = reservation.start_time?.trim() || "-";
    const endTime = reservation.end_time?.trim() || "-";
    const laneName = lane.name?.trim() || "-";

    const rawSiteUrl =
      process.env.NEXT_PUBLIC_SITE_URL ?? new URL(request.url).origin;
    const siteUrl = rawSiteUrl
      .replace(/^NEXT_PUBLIC_SITE_URL=/, "")
      .replace(/\/$/, "");
    const checkInUrl = `${siteUrl}/check-in/${checkInToken}`;

    const safeDisplayName = escapeHtml(displayName);
    const safeFormattedDate = escapeHtml(formattedDate);
    const safeStartTime = escapeHtml(startTime);
    const safeEndTime = escapeHtml(endTime);
    const safeLaneName = escapeHtml(laneName);
    const safeFormattedPrice = escapeHtml(formattedPrice);
    const safeCheckInUrl = escapeHtml(checkInUrl);

    const subject = "Potwierdzenie rezerwacji — CSK Booking";
    const html = `
      <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
        <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
          <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
            <p style="margin:0 0 18px 0;color:#22c55e;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
              CSK Booking
            </p>

            <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
              Potwierdzenie rezerwacji
            </h1>

            <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
              Cześć ${safeDisplayName}, Twoja rezerwacja została przyjęta.
            </p>

            <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Data:</strong> ${safeFormattedDate}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Godzina:</strong> ${safeStartTime} - ${safeEndTime}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Oś:</strong> ${safeLaneName}
              </p>
              <p style="margin:0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Płatność:</strong> ${safeFormattedPrice}, płatność na miejscu
              </p>
            </div>

            <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
              <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
                <strong style="color:#ffffff;">Szybki check-in:</strong><br />
                Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie.
              </p>

              <a href="${safeCheckInUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">
                Otwórz check-in
              </a>

              <p style="margin:12px 0 0 0;font-size:12px;line-height:1.5;color:#a3e635;word-break:break-all;">
                ${safeCheckInUrl}
              </p>
            </div>

            <p style="margin:0 0 14px 0;font-size:14px;line-height:1.6;color:#a1a1aa;">
              Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.
            </p>

            <p style="margin:0;font-size:14px;line-height:1.6;color:#a1a1aa;">
              W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.
            </p>
          </div>

          <p style="margin:18px 0 0 0;text-align:center;font-size:12px;color:#71717a;">
            Centrum Szkolenia Krutla · CSK Booking
          </p>
        </div>
      </div>
    `;

    const text = `
CSK Booking — potwierdzenie rezerwacji

Cześć ${displayName},

Twoja rezerwacja została przyjęta.

Data: ${formattedDate}
Godzina: ${startTime} - ${endTime}
Oś: ${laneName}
Płatność: ${formattedPrice}, płatność na miejscu

Szybki check-in:
Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie.
${checkInUrl}

Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.
W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.

Centrum Szkolenia Krutla
CSK Booking
    `;

    const resend = new Resend(resendApiKey);
    const { error: resendError } = await resend.emails.send({
      from,
      to: recipientEmail,
      subject,
      html,
      text,
    });

    if (resendError) {
      console.error("Reservation confirmation delivery failed");
      return jsonError("delivery_failed", 502);
    }

    return NextResponse.json({ ok: true, code: "sent" });
  } catch {
    console.error("Reservation confirmation endpoint failed");
    return jsonError("internal_error", 500);
  }
}
