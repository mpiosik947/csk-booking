import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { Resend } from "resend";
import {
  deliverConfirmationEmail,
  getConfirmationEmailConfiguration,
  getConfirmationServiceRoleClient,
} from "@/lib/server/confirmation-email-delivery";

type EventRegistrationConfirmationPayload = {
  registrationId?: unknown;
};

type EventRegistrationRow = {
  event_id: string;
  customer_name: string | null;
  registration_status: string;
};

type EventRow = {
  title: string | null;
  event_date: string | null;
  start_time: string | null;
  end_time: string | null;
  location: string | null;
  price: number | null;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ALLOWED_REGISTRATION_STATUSES = new Set(["registered", "reserve"]);

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

  if (price <= 0) {
    return "Bezpłatnie";
  }

  return `${price.toFixed(2)} zł`;
}

function formatDate(date: string | null) {
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

function formatRegistrationStatus(status: string) {
  return status === "reserve" ? "Lista rezerwowa" : "Zapisany";
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
      return jsonError("unauthorized", 401);
    }

    let parsedBody: unknown;

    try {
      parsedBody = await request.json();
    } catch {
      console.error("Event registration confirmation invalid request body");
      return jsonError("invalid_request", 400);
    }

    if (
      !parsedBody ||
      typeof parsedBody !== "object" ||
      Array.isArray(parsedBody)
    ) {
      console.error("Event registration confirmation invalid request contract");
      return jsonError("invalid_request", 400);
    }

    const bodyKeys = Object.keys(parsedBody);

    if (bodyKeys.length !== 1 || bodyKeys[0] !== "registrationId") {
      console.error("Event registration confirmation invalid request contract");
      return jsonError("invalid_request", 400);
    }

    const body = parsedBody as EventRegistrationConfirmationPayload;
    const registrationId =
      typeof body.registrationId === "string"
        ? body.registrationId.trim()
        : "";

    if (!registrationId || !UUID_PATTERN.test(registrationId)) {
      console.error("Event registration confirmation invalid registration id");
      return jsonError("invalid_request", 400);
    }

    const { data: registrationData, error: registrationError } = await supabase
      .from("event_registrations")
      .select("event_id,customer_name,registration_status")
      .eq("id", registrationId)
      .eq("user_id", user.id)
      .maybeSingle();

    if (registrationError) {
      console.error("Event registration confirmation registration read failed", {
        code: registrationError.code,
      });
      return jsonError("internal_error", 500);
    }

    if (!registrationData) {
      return jsonError("not_found", 404);
    }

    const registration = registrationData as EventRegistrationRow;
    const registrationStatus = registration.registration_status
      .trim()
      .toLowerCase();

    if (!ALLOWED_REGISTRATION_STATUSES.has(registrationStatus)) {
      return jsonError("invalid_status", 409);
    }

    const { data: eventData, error: eventError } = await supabase
      .from("events")
      .select("title,event_date,start_time,end_time,location,price")
      .eq("id", registration.event_id)
      .maybeSingle();

    if (eventError) {
      console.error("Event registration confirmation event read failed", {
        code: eventError.code,
      });
      return jsonError("internal_error", 500);
    }

    if (!eventData) {
      return jsonError("not_found", 404);
    }

    const recipientEmail = user.email?.trim();

    if (!recipientEmail) {
      console.error("Event registration confirmation recipient unavailable");
      return jsonError("delivery_failed", 502);
    }

    const event = eventData as EventRow;
    const displayName = registration.customer_name?.trim() || "Uczestniku";
    const formattedDate = formatDate(event.event_date);
    const formattedPrice = formatPrice(event.price);
    const formattedStatus = formatRegistrationStatus(registrationStatus);
    const eventTitle = event.title?.trim() || "-";
    const startTime = event.start_time?.trim() || "-";
    const endTime = event.end_time?.trim() || "-";
    const location = event.location?.trim() || "-";

    const rawSiteUrl =
      process.env.NEXT_PUBLIC_SITE_URL ?? new URL(request.url).origin;
    const siteUrl = rawSiteUrl
      .replace(/^NEXT_PUBLIC_SITE_URL=/, "")
      .replace(/\/$/, "");
    const myEventsUrl = `${siteUrl}/my-events`;

    const safeDisplayName = escapeHtml(displayName);
    const safeEventTitle = escapeHtml(eventTitle);
    const safeFormattedDate = escapeHtml(formattedDate);
    const safeStartTime = escapeHtml(startTime);
    const safeEndTime = escapeHtml(endTime);
    const safeLocation = escapeHtml(location);
    const safeFormattedStatus = escapeHtml(formattedStatus);
    const safeFormattedPrice = escapeHtml(formattedPrice);
    const safeMyEventsUrl = escapeHtml(myEventsUrl);

    const subject = "Potwierdzenie zapisu na szkolenie — CSK Booking";
    const html = `
      <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
        <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
          <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
            <p style="margin:0 0 18px 0;color:#22c55e;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
              CSK Booking
            </p>

            <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
              Potwierdzenie zapisu na szkolenie
            </h1>

            <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
              Cześć ${safeDisplayName}, Twój zapis na szkolenie został przyjęty.
            </p>

            <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Szkolenie:</strong> ${safeEventTitle}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Data:</strong> ${safeFormattedDate}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Godzina:</strong> ${safeStartTime} - ${safeEndTime}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Miejsce:</strong> ${safeLocation}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Status:</strong> ${safeFormattedStatus}
              </p>
              <p style="margin:0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Płatność:</strong> ${safeFormattedPrice}, płatność na miejscu
              </p>
            </div>

            <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
              <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
                Szczegóły swojego zapisu znajdziesz w panelu uczestnika.
              </p>

              <a href="${safeMyEventsUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">
                Moje szkolenia
              </a>
            </div>

            <p style="margin:0 0 14px 0;font-size:14px;line-height:1.6;color:#a1a1aa;">
              Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed szkoleniem.
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
CSK Booking — potwierdzenie zapisu na szkolenie

Cześć ${displayName},

Twój zapis na szkolenie został przyjęty.

Szkolenie: ${eventTitle}
Data: ${formattedDate}
Godzina: ${startTime} - ${endTime}
Miejsce: ${location}
Status: ${formattedStatus}
Płatność: ${formattedPrice}, płatność na miejscu

Moje szkolenia:
${myEventsUrl}

Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed szkoleniem.
W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.

Centrum Szkolenia Krutla
CSK Booking
    `;

    const configuration = getConfirmationEmailConfiguration();

    if (!configuration) {
      console.error(
        "Event registration confirmation email configuration missing"
      );
      return jsonError("internal_error", 500);
    }

    const resend = new Resend(configuration.resendApiKey);
    const completionClient =
      getConfirmationServiceRoleClient(configuration);
    const outcome = await deliverConfirmationEmail({
      prepare: async () =>
        supabase.rpc("prepare_confirmation_email", {
          p_message_type: "event_registration_confirmation",
          p_record_id: registrationId,
        }),
      send: async (idempotencyKey) => {
        return resend.emails.send(
          {
            from: configuration.from,
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
    console.error("Event registration confirmation endpoint failed");
    return jsonError("internal_error", 500);
  }
}
