import { NextResponse } from "next/server";
import { requireEventDispatchLease } from "@/lib/server/event-positive-email";
import { resolveEventRegistrationEmailTenantContext, operationalEmailBrand, operationalEmailHistoryUrl } from "@/lib/server/operational-email";
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
      return jsonError(authResult.code, authResult.status);
    }

    const user = authResult.user;

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

    const configuration = getConfirmationEmailConfiguration();
    const rateLimitSecret = getConfirmationRateLimitSecret();

    if (!configuration || !rateLimitSecret) {
      console.error(
        "Event registration confirmation server configuration missing"
      );
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
      console.error("Event registration confirmation rate limit failed");
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



    const tenant = await resolveEventRegistrationEmailTenantContext(registrationId);
    const brand = operationalEmailBrand(tenant, "Potwierdzenie zapisu na szkolenie");
    const subject = brand.subject;
    const myEventsUrl = operationalEmailHistoryUrl(tenant, "events");
    const html = operationalEmailLayout({
      tenantDisplayName: tenant.displayName,
      title: "Potwierdzenie zapisu na szkolenie",
      intro: `Cześć ${displayName}, Twój zapis na szkolenie został przyjęty.`,
      details: [
        { label: "Szkolenie", value: eventTitle },
        { label: "Data", value: formattedDate },
        { label: "Godzina", value: `${startTime} - ${endTime}` },
        { label: "Miejsce", value: location },
        { label: "Płatność", value: `${formattedPrice}, płatność na miejscu` },
        { label: "Status", value: formattedStatus },
      ],
      actions: [{ label: "Moje szkolenia", url: myEventsUrl, description: "Szczegóły swojego zapisu znajdziesz w panelu uczestnika." },
      ],
      notes: [
        "Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed szkoleniem.",
        "W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.",
      ],
    });

    const text = `
${brand.headerText}

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

${brand.footerText}
    `;

    const resend = new Resend(configuration.resendApiKey);
    const outcome = await deliverConfirmationEmail({
      prepare: async () =>
        supabase.rpc("prepare_confirmation_email", {
          p_message_type: "event_registration_confirmation",
          p_record_id: registrationId,
        }),
      send: async (idempotencyKey, claimId) => {
        await requireEventDispatchLease(completionClient, claimId, "registration");
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
    console.error("Event registration confirmation endpoint failed");
    return jsonError("internal_error", 500);
  }
}
