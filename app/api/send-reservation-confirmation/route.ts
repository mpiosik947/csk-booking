import { resolveReservationEmailTenantContext, operationalEmailBrand, operationalEmailActionUrl, operationalEmailHistoryUrl } from "@/lib/server/operational-email";
import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { Resend } from "resend";
import {
  deliverConfirmationEmail,
  getConfirmationEmailConfiguration,
  getConfirmationServiceRoleClient,
} from "@/lib/server/confirmation-email-delivery";
import {
  checkConfirmationEmailRateLimit,
  getConfirmationRateLimitSecret,
} from "@/lib/server/confirmation-email-rate-limit";
import { verifyAuthUser } from "@/lib/server/auth-user-verification";
import { operationalEmailLayout } from "@/lib/server/operational-email-layout";

type ReservationConfirmationPayload = {
  reservationId?: unknown;
};

type ReservationRow = {
  lane_name: string | null;
  customer_name: string | null;
  reservation_date: string;
  start_time: string;
  end_time: string;
  price: number | null;
  reservation_status: string;
  check_in_token: string | null;
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
    | "auth_unavailable"
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
    const authResult = await verifyAuthUser(() =>
      supabase.auth.getUser(accessToken)
    );

    if (!authResult.ok) {
      console.error("Reservation confirmation authorization failed");
      return jsonError(authResult.code, authResult.status);
    }

    const user = authResult.user;

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

    const configuration = getConfirmationEmailConfiguration();
    const rateLimitSecret = getConfirmationRateLimitSecret();

    if (!configuration || !rateLimitSecret) {
      console.error("Reservation confirmation server configuration missing");
      return jsonError("internal_error", 500);
    }

    const completionClient =
      getConfirmationServiceRoleClient(configuration);
    const rateLimit = await checkConfirmationEmailRateLimit({
      request,
      userId: user.id,
      secret: rateLimitSecret,
      rpc: async (ipHash) =>
        completionClient.rpc("check_confirmation_email_rate_limit", {
          p_user_id: user.id,
          p_ip_hash: ipHash,
        }),
    });

    if (rateLimit.kind === "error") {
      console.error("Reservation confirmation rate limit failed");
      return jsonError("internal_error", 500);
    }

    if (rateLimit.kind === "rate_limited") {
      return NextResponse.json(
        { ok: false, code: "rate_limited" },
        {
          status: 429,
          headers: {
            "Retry-After": String(rateLimit.retryAfterSeconds),
            "Cache-Control": "no-store",
          },
        }
      );
    }

    const { data: reservationData, error: reservationError } = await supabase
      .rpc("read_owned_booking_confirmation_v1", { p_reservation_id: reservationId });

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


    const recipientEmail = user.email?.trim();

    if (!recipientEmail) {
      console.error("Reservation confirmation recipient unavailable");
      return jsonError("delivery_failed", 502);
    }

    const displayName = reservation.customer_name?.trim() || "Kliencie";
    const formattedDate = formatDate(reservation.reservation_date);
    const formattedPrice = formatPrice(reservation.price);
    const startTime = reservation.start_time?.trim() || "-";
    const endTime = reservation.end_time?.trim() || "-";
    const laneName = reservation.lane_name?.trim() || "-";

    const checkInUrl = operationalEmailActionUrl("check-in", checkInToken);


    const tenant = await resolveReservationEmailTenantContext(reservationId);
    const brand = operationalEmailBrand(tenant, "Potwierdzenie rezerwacji");
    const reservationsUrl = operationalEmailHistoryUrl(tenant, "reservations");
    const subject = brand.subject;
    const html = operationalEmailLayout({
      tenantDisplayName: tenant.displayName,
      title: "Potwierdzenie rezerwacji",
      intro: `Cześć ${displayName}, Twoja rezerwacja została przyjęta.`,
      details: [
        { label: "Obiekt", value: tenant.displayName },
        { label: "Status", value: "Potwierdzona" },
        { label: "Data", value: formattedDate },
        { label: "Godzina", value: `${startTime} - ${endTime}` },
        { label: "Oś", value: laneName },
        { label: "Płatność", value: `${formattedPrice}, płatność na miejscu` },
      ],
      actions: [{ label: "Moje rezerwacje", url: reservationsUrl },
      { label: "Otwórz check-in", url: checkInUrl, description: "Szybki check-in: Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie." },
      ],
      notes: [
        "Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.",
        "W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.",
      ],
    });

    const text = `
${brand.headerText}

Cześć ${displayName},

Twoja rezerwacja została przyjęta.

Obiekt: ${tenant.displayName}
Status: Potwierdzona
Data: ${formattedDate}
Godzina: ${startTime} - ${endTime}
Oś: ${laneName}
Płatność: ${formattedPrice}, płatność na miejscu

Moje rezerwacje: ${reservationsUrl}

Szybki check-in:
Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie.
${checkInUrl}

Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.
W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.

${brand.footerText}
    `;

    const resend = new Resend(configuration.resendApiKey);
    const outcome = await deliverConfirmationEmail({
      prepare: async () =>
        supabase.rpc("prepare_confirmation_email", {
          p_message_type: "reservation_confirmation",
          p_record_id: reservationId,
        }),
      send: async (idempotencyKey) => {
        return resend.emails.send(
          {
            from: configuration.from,
            replyTo: configuration.replyTo,
            to: recipientEmail,
            subject,
            html,
            text,
          },
          { idempotencyKey }
        );
      },
      complete: async (input) =>
        completionClient.rpc("complete_confirmation_email", input),
    });

    return NextResponse.json(
      { ok: outcome.ok, code: outcome.code },
      { status: outcome.status }
    );
  } catch {
    console.error("Reservation confirmation endpoint failed");
    return jsonError("internal_error", 500);
  }
}
