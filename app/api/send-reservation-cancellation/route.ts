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
import { escapeEmailHref, escapeHtml } from "@/lib/server/email-html";

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
    const safeDisplayName = escapeHtml(displayName);
    const safeFormattedDate = escapeHtml(formattedDate);
    const safeStartTime = escapeHtml(startTime);
    const safeEndTime = escapeHtml(endTime);
    const safeLaneName = escapeHtml(laneName);

    const cancelledByText =
      cancelledBy === "admin"
        ? "Rezerwacja została anulowana przez obsługę obiektu."
        : "Twoja rezerwacja została anulowana.";

    const tenant = await resolveReservationEmailTenantContext(reservationId);
    const brand = operationalEmailBrand(tenant, "Rezerwacja anulowana");
    const reservationsUrl = operationalEmailHistoryUrl(tenant, "reservations");
    const safeReservationsUrl = escapeEmailHref(reservationsUrl);
    const safeTenantName = escapeHtml(tenant.displayName);
    const subject = brand.subject;

    const html = `
      <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
        <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
          <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
            <p style="margin:0 0 18px 0;color:#ef4444;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
              ${brand.headerHtml}
            </p>

            <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
              Rezerwacja anulowana
            </h1>

            <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
              Cześć ${safeDisplayName}, ${cancelledByText}
            </p>

            <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Obiekt:</strong> ${safeTenantName}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Status:</strong> Anulowana
              </p>
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

            <p style="margin:24px 0;"><a href="${safeReservationsUrl}" style="color:#d9f99d;font-weight:bold;">Moje rezerwacje</a></p>

            <p style="margin:0;font-size:14px;line-height:1.6;color:#a1a1aa;">
              W przypadku pytań skontaktuj się z obsługą obiektu.
            </p>
          </div>

          <p style="margin:18px 0 0 0;text-align:center;font-size:12px;color:#71717a;">
            ${brand.footerHtml}
          </p>
        </div>
      </div>
    `;

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
