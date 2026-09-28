import { NextResponse } from "next/server";
import { resolveReservationEmailTenantContext, operationalEmailBrand, operationalEmailHistoryUrl } from "@/lib/server/operational-email";
import { Resend } from "resend";
import { createClient } from "@supabase/supabase-js";
import {
  deliverConfirmationEmail,
  getConfirmationEmailConfiguration,
  getConfirmationServiceRoleClient,
} from "@/lib/server/confirmation-email-delivery";
import {
  checkConfirmationEmailRateLimit,
  getConfirmationRateLimitSecret,
} from "@/lib/server/confirmation-email-rate-limit";
import {
  verifyAuthUser,
} from "@/lib/server/auth-user-verification";
import { operationalEmailLayout } from "@/lib/server/operational-email-layout";

type ReservationCancellationPayload = {
  reservationId?: unknown;
};

type CancellationEmailData = {
  recipient_email: string | null;
  customer_name: string;
  reservation_date: string;
  start_time: string;
  end_time: string;
  lane_name: string;
  cancelled_by: "user" | "admin";
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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

function jsonError(
  code:
    | "invalid_request"
    | "unauthorized"
    | "auth_unavailable"
    | "not_found"
    | "forbidden"
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
      console.error("Reservation cancellation authorization failed");
      return jsonError(authResult.code, authResult.status);
    }

    const user = authResult.user;

    let parsedBody: unknown;

    try {
      parsedBody = await request.json();
    } catch {
      console.error("Reservation cancellation invalid request body");
      return jsonError("invalid_request", 400);
    }

    if (
      !parsedBody ||
      typeof parsedBody !== "object" ||
      Array.isArray(parsedBody) ||
      Object.keys(parsedBody).length !== 1 ||
      !("reservationId" in parsedBody)
    ) {
      console.error("Reservation cancellation invalid request contract");
      return jsonError("invalid_request", 400);
    }

    const body = parsedBody as ReservationCancellationPayload;
    const reservationId =
      typeof body.reservationId === "string" ? body.reservationId.trim() : "";

    if (!reservationId || !UUID_PATTERN.test(reservationId)) {
      console.error("Reservation cancellation invalid reservation id");
      return jsonError("invalid_request", 400);
    }

    const configuration = getConfirmationEmailConfiguration();
    const rateLimitSecret = getConfirmationRateLimitSecret();

    if (!configuration || !rateLimitSecret) {
      console.error("Reservation cancellation server configuration missing");
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
      console.error("Reservation cancellation rate limit failed");
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

    // JWT-authorized, resource-bound and cancelled-only. Never service-role reads.
    const { data: reservationData, error: reservationError } = await supabase.rpc(
      "get_reservation_cancellation_email_v1", { p_reservation_id: reservationId }
    );
    if (reservationError) {
      if (reservationError.code === "42501") return jsonError("not_found", 404);
      console.error("Reservation cancellation continuity read failed", { code: reservationError.code });
      return jsonError("internal_error", 500);
    }
    if (!reservationData) return jsonError("not_found", 404);
    const reservation = reservationData as CancellationEmailData;
    if (!["user", "admin"].includes(reservation.cancelled_by) ||
        typeof reservation.customer_name !== "string" ||
        typeof reservation.reservation_date !== "string" ||
        typeof reservation.start_time !== "string" ||
        typeof reservation.end_time !== "string" ||
        typeof reservation.lane_name !== "string") {
      return jsonError("internal_error", 500);
    }
    const customerEmail = typeof reservation.recipient_email === "string"
      ? reservation.recipient_email.trim() : "";
    if (!customerEmail || !EMAIL_PATTERN.test(customerEmail)) {
      console.error("Reservation cancellation recipient unavailable");
      return jsonError("delivery_failed", 502);
    }
    const customerName = reservation.customer_name;
    const reservationDate = reservation.reservation_date;
    const startTime = reservation.start_time;
    const endTime = reservation.end_time;
    const laneName = reservation.lane_name;
    const cancelledBy = reservation.cancelled_by;

    const displayName = customerName;
    const formattedDate = formatDate(reservationDate);

    const cancelledByText =
      cancelledBy === "admin"
        ? "Rezerwacja została anulowana przez obsługę obiektu."
        : "Twoja rezerwacja została anulowana.";

    const tenant = await resolveReservationEmailTenantContext(reservationId);
    const brand = operationalEmailBrand(tenant, "Rezerwacja anulowana");
    const reservationsUrl = operationalEmailHistoryUrl(tenant, "reservations");
    const subject = brand.subject;

    const html = operationalEmailLayout({
      tenantDisplayName: tenant.displayName,
      title: "Rezerwacja anulowana",
      intro: `Cześć ${displayName}, ${cancelledByText}`,
      details: [
        { label: "Obiekt", value: tenant.displayName },
        { label: "Status", value: "Anulowana" },
        { label: "Data", value: formattedDate },
        { label: "Godzina", value: `${startTime} - ${endTime}` },
        { label: "Oś", value: laneName },
      ],
      actions: [{ label: "Moje rezerwacje", url: reservationsUrl },
      ],
      notes: [
        "W przypadku pytań skontaktuj się z obsługą obiektu.",
      ],
    });

    const text = `
${brand.headerText}

Cześć ${displayName},

${cancelledByText}

Obiekt: ${tenant.displayName}
Status: Anulowana
Data: ${formattedDate}
Godzina: ${startTime ?? "-"} - ${endTime ?? "-"}
Oś: ${laneName ?? "-"}

Moje rezerwacje: ${reservationsUrl}

W przypadku pytań skontaktuj się z obsługą obiektu.

${brand.footerText}
    `;

    const resend = new Resend(configuration.resendApiKey);
    const outcome = await deliverConfirmationEmail({
      prepare: async () =>
        supabase.rpc("prepare_confirmation_email", {
          p_message_type: "reservation_cancellation",
          p_record_id: reservationId,
        }),
      send: async (idempotencyKey) =>
        resend.emails.send(
          {
            from: configuration.from,
            to: customerEmail,
            subject,
            html,
            text,
          },
          { idempotencyKey }
        ),
      complete: async (input) =>
        completionClient.rpc("complete_confirmation_email", input),
    });

    return NextResponse.json(
      { ok: outcome.ok, code: outcome.code },
      { status: outcome.status }
    );
  } catch {
    console.error("Reservation cancellation endpoint failed");
    return jsonError("internal_error", 500);
  }
}
