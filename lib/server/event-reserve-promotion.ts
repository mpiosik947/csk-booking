import "server-only";

import { headers } from "next/headers";
import { Resend } from "resend";
import { escapeEmailHref, escapeHtml } from "./email-html";
import { createClient } from "@supabase/supabase-js";

type EventRecord = {
  id: string;
  title: string | null;
  event_date: string | null;
  start_time: string | null;
  end_time: string | null;
  location: string | null;
  price: number | null;
  max_participants: number | null;
};

type ReserveRegistration = {
  id: string;
  customer_email: string | null;
  customer_name: string | null;
};

type PreparedPromotion = {
  registration_id: string;
  claim_id: string;
  promotion_token: string;
  promotion_token_expires_at: string;
  token_reused: boolean;
};

type CompletedPromotion = {
  registration_id: string;
  changed: boolean;
  success: boolean;
  claim_cleared: boolean;
  email_sent_recorded: boolean;
};

export type EventReservePromotionResult = {
  attempted: true;
  success: boolean;
  reserveFound: boolean;
  notifiedCount: number;
  failedCount: number;
  warning: boolean;
  reason: string | null;
  noFreePlace?: boolean;
  statusCode?: 404 | 500;
  error?: string;
};

type PromotionFailureStage =
  | "prepare_rpc"
  | "recipient_query"
  | "resend_send"
  | "complete_rpc";

type PromotionErrorCode =
  | "email_send_failed"
  | "email_provider_error"
  | "invalid_recipient"
  | "unexpected_error";

function getSafeErrorDetails(error: unknown) {
  if (!error || typeof error !== "object") {
    return {};
  }

  const errorRecord = error as Record<string, unknown>;
  const errorCode =
    typeof errorRecord.code === "string"
      ? errorRecord.code
      : typeof errorRecord.name === "string"
        ? errorRecord.name
        : undefined;
  const httpStatus =
    typeof errorRecord.statusCode === "number"
      ? errorRecord.statusCode
      : typeof errorRecord.status === "number"
        ? errorRecord.status
        : undefined;

  return {
    ...(errorCode ? { errorCode } : {}),
    ...(httpStatus ? { httpStatus } : {}),
  };
}

function logPromotionFailure(
  eventId: string,
  registrationId: string,
  stage: PromotionFailureStage,
  error: unknown
) {
  console.error("Event reserve promotion recipient failed", {
    eventId,
    registrationId,
    stage,
    ...getSafeErrorDetails(error),
  });
}

function isPreparedPromotion(value: unknown): value is PreparedPromotion {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const promotion = value as Partial<PreparedPromotion>;

  return (
    typeof promotion.registration_id === "string" &&
    typeof promotion.claim_id === "string" &&
    typeof promotion.promotion_token === "string" &&
    typeof promotion.promotion_token_expires_at === "string" &&
    typeof promotion.token_reused === "boolean"
  );
}

function isCompletedPromotion(value: unknown): value is CompletedPromotion {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const promotion = value as Partial<CompletedPromotion>;

  return (
    typeof promotion.registration_id === "string" &&
    typeof promotion.changed === "boolean" &&
    typeof promotion.success === "boolean" &&
    typeof promotion.claim_cleared === "boolean" &&
    typeof promotion.email_sent_recorded === "boolean"
  );
}

function normalizePromotionError(error: unknown): PromotionErrorCode {
  if (!error || typeof error !== "object") {
    return "unexpected_error";
  }

  const errorRecord = error as Record<string, unknown>;
  const code =
    typeof errorRecord.code === "string"
      ? errorRecord.code.toLowerCase()
      : typeof errorRecord.name === "string"
        ? errorRecord.name.toLowerCase()
        : "";
  const status =
    typeof errorRecord.statusCode === "number"
      ? errorRecord.statusCode
      : typeof errorRecord.status === "number"
        ? errorRecord.status
        : undefined;

  if (
    status === 400 ||
    status === 422 ||
    code.includes("invalid_recipient") ||
    code.includes("validation")
  ) {
    return "invalid_recipient";
  }

  if (
    status === 429 ||
    (typeof status === "number" && status >= 500) ||
    code.includes("rate_limit") ||
    code.includes("provider")
  ) {
    return "email_provider_error";
  }

  return "email_send_failed";
}

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

async function getSiteUrl() {
  const configuredSiteUrl = process.env.NEXT_PUBLIC_SITE_URL
    ?.replace(/^NEXT_PUBLIC_SITE_URL=/, "")
    .replace(/\/$/, "");

  if (configuredSiteUrl) {
    return configuredSiteUrl;
  }

  const requestHeaders = await headers();
  const host =
    requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host");

  if (!host) {
    throw new Error("Brak konfiguracji adresu aplikacji.");
  }

  const protocol = requestHeaders.get("x-forwarded-proto") ?? "http";
  return `${protocol}://${host}`.replace(/\/$/, "");
}

function formatDate(date?: string | null) {
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

function formatTime(time?: string | null) {
  if (!time) {
    return "-";
  }

  return time.slice(0, 5);
}

function formatPrice(price?: number | null) {
  if (typeof price !== "number") {
    return "Do ustalenia";
  }

  if (price <= 0) {
    return "Bezpłatnie";
  }

  return `${price.toFixed(2)} zł`;
}

// Obecna promocja może ponownie wygenerować tokeny przy ponownym wywołaniu.
// Idempotencja zostanie wzmocniona w osobnym etapie.
export async function promoteEventReserve(
  eventId: string
): Promise<EventReservePromotionResult> {
  try {
    const supabase = getAdminSupabaseClient();
    const { data: prepareData, error: prepareError } = await supabase.rpc(
      "prepare_event_reserve_promotions",
      { p_event_id: eventId }
    );

    if (prepareError) {
      logPromotionFailure(eventId, eventId, "prepare_rpc", prepareError);

      return {
        attempted: true,
        success: false,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: true,
        reason: "promotion_prepare_failed",
        statusCode: prepareError.code === "P0002" ? 404 : 500,
        error:
          prepareError.code === "P0002"
            ? "Nie znaleziono szkolenia."
            : "Nie udało się przygotować promocji listy rezerwowej.",
      };
    }

    if (!Array.isArray(prepareData)) {
      logPromotionFailure(eventId, eventId, "prepare_rpc", {
        code: "invalid_prepare_result",
      });

      return {
        attempted: true,
        success: false,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: true,
        reason: "promotion_prepare_failed",
        statusCode: 500,
        error: "Nie udało się potwierdzić wyniku przygotowania promocji.",
      };
    }

    const preparedPromotions = prepareData.filter(isPreparedPromotion);
    const invalidPreparedCount =
      prepareData.length - preparedPromotions.length;

    const completePromotion = async (
      promotion: PreparedPromotion,
      success: boolean,
      errorCode: PromotionErrorCode | null
    ) => {
      const { data, error } = await supabase.rpc(
        "complete_event_reserve_promotion",
        {
          p_registration_id: promotion.registration_id,
          p_claim_id: promotion.claim_id,
          p_success: success,
          p_error_code: errorCode,
        }
      );

      if (
        error ||
        !isCompletedPromotion(data) ||
        data.registration_id !== promotion.registration_id ||
        data.success !== success ||
        !data.claim_cleared
      ) {
        logPromotionFailure(
          eventId,
          promotion.registration_id,
          "complete_rpc",
          error ?? { code: "invalid_complete_result" }
        );
        return false;
      }

      return true;
    };

    const failPreparedPromotions = async (errorCode: PromotionErrorCode) => {
      await Promise.all(
        preparedPromotions.map((promotion) =>
          completePromotion(promotion, false, errorCode)
        )
      );
    };

    if (invalidPreparedCount > 0) {
      await failPreparedPromotions("unexpected_error");

      return {
        attempted: true,
        success: false,
        reserveFound: preparedPromotions.length > 0,
        notifiedCount: 0,
        failedCount: prepareData.length,
        warning: true,
        reason: "invalid_prepare_result",
        statusCode: 500,
        error: "Nie udało się potwierdzić danych przygotowanej promocji.",
      };
    }

    if (preparedPromotions.length === 0) {
      return {
        attempted: true,
        success: true,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: false,
        reason: null,
      };
    }

    try {
      const resendApiKey = process.env.RESEND_API_KEY;
    const from = process.env.RESERVATION_EMAIL_FROM;

    if (!resendApiKey || !from) {
      await failPreparedPromotions("email_provider_error");

      return {
        attempted: true,
        success: false,
        reserveFound: true,
        notifiedCount: 0,
        failedCount: preparedPromotions.length,
        warning: true,
        reason: "email_configuration_missing",
        statusCode: 500,
        error: "Brak konfiguracji wysyłki email.",
      };
    }

    let siteUrl: string;

    try {
      siteUrl = await getSiteUrl();
    } catch (error) {
      await failPreparedPromotions("unexpected_error");
      console.error("Event reserve promotion URL configuration failed", {
        ...getSafeErrorDetails(error),
      });

      return {
        attempted: true,
        success: false,
        reserveFound: true,
        notifiedCount: 0,
        failedCount: preparedPromotions.length,
        warning: true,
        reason: "site_url_missing",
        statusCode: 500,
        error: "Brak konfiguracji adresu aplikacji.",
      };
    }

    const resend = new Resend(resendApiKey);
    const { data: eventData, error: eventError } = await supabase
      .from("events")
      .select(
        `
          id,
          title,
          event_date,
          start_time,
          end_time,
          location,
          price,
          max_participants
        `
      )
      .eq("id", eventId)
      .maybeSingle();

    if (eventError || !eventData) {
      await failPreparedPromotions("unexpected_error");

      return {
        attempted: true,
        success: false,
        reserveFound: true,
        notifiedCount: 0,
        failedCount: preparedPromotions.length,
        warning: true,
        reason: "event_query_failed",
        statusCode: eventError?.code === "PGRST116" ? 404 : 500,
        error: "Nie udało się pobrać danych szkolenia.",
      };
    }

    const eventItem = eventData as EventRecord;
    const registrationIds = preparedPromotions.map(
      (promotion) => promotion.registration_id
    );
    const { data: registrationData, error: registrationError } = await supabase
      .from("event_registrations")
      .select("id, customer_email, customer_name")
      .in("id", registrationIds);

    if (registrationError) {
      await failPreparedPromotions("unexpected_error");
      logPromotionFailure(
        eventId,
        eventId,
        "recipient_query",
        registrationError
      );

      return {
        attempted: true,
        success: false,
        reserveFound: true,
        notifiedCount: 0,
        failedCount: preparedPromotions.length,
        warning: true,
        reason: "recipient_query_failed",
        statusCode: 500,
        error: "Nie udało się pobrać danych odbiorców promocji.",
      };
    }

    const registrationsById = new Map(
      ((registrationData as ReserveRegistration[] | null) ?? []).map(
        (registration) => [registration.id, registration]
      )
    );
    const formattedDate = formatDate(eventItem.event_date);
    const formattedStartTime = formatTime(eventItem.start_time);
    const formattedEndTime = formatTime(eventItem.end_time);
    const formattedPrice = formatPrice(eventItem.price);
    let emailsSent = 0;
    let failedCount = 0;
    const failureReasons = new Set<string>();

    for (const promotion of preparedPromotions) {
      const registration = registrationsById.get(promotion.registration_id);

      if (!registration?.customer_email?.trim()) {
        failedCount += 1;
        failureReasons.add("invalid_recipient");
        logPromotionFailure(
          eventId,
          promotion.registration_id,
          "resend_send",
          { code: "invalid_recipient" }
        );
        await completePromotion(promotion, false, "invalid_recipient");
        continue;
      }

      const confirmUrl = `${siteUrl}/events/confirm/${promotion.promotion_token}`;
      const displayName = registration.customer_name?.trim() || "Uczestniku";
      const safeDisplayName = escapeHtml(displayName);
      const safeEventTitle = escapeHtml(eventItem.title ?? "-");
      const safeFormattedDate = escapeHtml(formattedDate);
      const safeFormattedStartTime = escapeHtml(formattedStartTime);
      const safeFormattedEndTime = escapeHtml(formattedEndTime);
      const safeLocation = escapeHtml(eventItem.location ?? "-");
      const safeFormattedPrice = escapeHtml(formattedPrice);
      const safeConfirmUrl = escapeEmailHref(confirmUrl);

      const subject = "Zwolniło się miejsce na szkoleniu — CSK Booking";
      const html = `
        <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
          <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
            <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
              <p style="margin:0 0 18px 0;color:#22c55e;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
                CSK Booking
              </p>
              <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
                Zwolniło się miejsce na szkoleniu
              </h1>
              <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
                Cześć ${safeDisplayName}, na szkoleniu z Twojej listy rezerwowej pojawiła się możliwość potwierdzenia udziału.
              </p>
              <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Szkolenie:</strong> ${safeEventTitle}</p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Data:</strong> ${safeFormattedDate}</p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Godzina:</strong> ${safeFormattedStartTime} - ${safeFormattedEndTime}</p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Miejsce:</strong> ${safeLocation}</p>
                <p style="margin:0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Płatność:</strong> ${safeFormattedPrice}, płatność na miejscu</p>
              </div>
              <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
                <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
                  Kliknij przycisk poniżej, aby potwierdzić udział. Miejsce otrzyma pierwsza osoba z listy rezerwowej, która skutecznie potwierdzi udział.
                </p>
                <a href="${safeConfirmUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">Potwierdź udział</a>
              </div>
              <p style="margin:0 0 14px 0;font-size:14px;line-height:1.6;color:#a1a1aa;">Link jest ważny przez 24 godziny. Samo otrzymanie tej wiadomości nie gwarantuje miejsca — decyduje pierwsze skuteczne potwierdzenie.</p>
              <p style="margin:0;font-size:14px;line-height:1.6;color:#a1a1aa;">Jeżeli nie chcesz brać udziału w szkoleniu, zignoruj tę wiadomość.</p>
            </div>
            <p style="margin:18px 0 0 0;text-align:center;font-size:12px;color:#71717a;">Centrum Szkolenia Krutla · CSK Booking</p>
          </div>
        </div>
      `;
      const text = `
CSK Booking — zwolniło się miejsce na szkoleniu

Cześć ${displayName},

Na szkoleniu z Twojej listy rezerwowej pojawiła się możliwość potwierdzenia udziału.

Szkolenie: ${eventItem.title ?? "-"}
Data: ${formattedDate}
Godzina: ${formattedStartTime} - ${formattedEndTime}
Miejsce: ${eventItem.location ?? "-"}
Płatność: ${formattedPrice}, płatność na miejscu

Potwierdź udział:
${confirmUrl}

Link jest ważny przez 24 godziny. Samo otrzymanie tej wiadomości nie gwarantuje miejsca — decyduje pierwsze skuteczne potwierdzenie.

Centrum Szkolenia Krutla
CSK Booking
      `;

      let sendError: unknown = null;

      try {
        const { error: emailError } = await resend.emails.send({
          from,
          to: registration.customer_email,
          subject,
          html,
          text,
        });
        sendError = emailError;
      } catch (error) {
        sendError = error;
      }

      if (sendError) {
        const errorCode = normalizePromotionError(sendError);
        failedCount += 1;
        failureReasons.add(errorCode);
        logPromotionFailure(
          eventId,
          promotion.registration_id,
          "resend_send",
          sendError
        );
        await completePromotion(promotion, false, errorCode);
        continue;
      }

      emailsSent += 1;

      if (!(await completePromotion(promotion, true, null))) {
        failedCount += 1;
        failureReasons.add("complete_failed");
      }
    }

    if (failedCount > 0) {
      const reason =
        failureReasons.size === 1
          ? (Array.from(failureReasons)[0] ?? "promotion_failed")
          : "partial_failure";

      return {
        attempted: true,
        success: false,
        reserveFound: true,
        notifiedCount: emailsSent,
        failedCount,
        warning: true,
        reason,
        statusCode: 500,
        error:
          emailsSent > 0
            ? "Nie udało się powiadomić wszystkich osób z listy rezerwowej."
            : "Nie udało się wysłać żadnego powiadomienia do listy rezerwowej.",
      };
    }

      return {
        attempted: true,
        success: true,
        reserveFound: true,
        notifiedCount: emailsSent,
        failedCount: 0,
        warning: false,
        reason: null,
      };
    } catch (error) {
      await failPreparedPromotions("unexpected_error");
      console.error("Event reserve promotion processing failed", {
        ...getSafeErrorDetails(error),
      });

      return {
        attempted: true,
        success: false,
        reserveFound: true,
        notifiedCount: 0,
        failedCount: preparedPromotions.length,
        warning: true,
        reason: "unexpected_error",
        statusCode: 500,
        error: "Wystąpił błąd podczas obsługi listy rezerwowej.",
      };
    }
  } catch (error) {
    console.error("Event reserve promotion failed", {
      ...getSafeErrorDetails(error),
    });

    return {
      attempted: true,
      success: false,
      reserveFound: false,
      notifiedCount: 0,
      failedCount: 0,
      warning: true,
      reason: "unexpected_error",
      statusCode: 500,
      error: "Wystąpił błąd podczas obsługi listy rezerwowej.",
    };
  }
}
