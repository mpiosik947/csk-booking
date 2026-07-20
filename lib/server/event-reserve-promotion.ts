import "server-only";

import { randomUUID } from "crypto";
import { headers } from "next/headers";
import { Resend } from "resend";
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
  | "token_update"
  | "resend_send"
  | "sent_at_update";

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
  const message =
    stage === "sent_at_update"
      ? "Event reserve promotion email may have been sent but timestamp update failed"
      : "Event reserve promotion recipient failed";

  console.error(message, {
    eventId,
    registrationId,
    stage,
    ...getSafeErrorDetails(error),
  });
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

export async function promoteEventReserve(
  eventId: string
): Promise<EventReservePromotionResult> {
  try {
    const resendApiKey = process.env.RESEND_API_KEY;
    const from = process.env.RESERVATION_EMAIL_FROM;

    if (!resendApiKey || !from) {
      return {
        attempted: true,
        success: false,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: true,
        reason: "email_configuration_missing",
        statusCode: 500,
        error: "Brak konfiguracji wysyłki email.",
      };
    }

    const siteUrl = await getSiteUrl();
    const supabase = getAdminSupabaseClient();
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
      return {
        attempted: true,
        success: false,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: true,
        reason: "event_not_found",
        statusCode: 404,
        error: "Nie znaleziono szkolenia.",
      };
    }

    const eventItem = eventData as EventRecord;
    const { count: participantsCount, error: participantsCountError } =
      await supabase
        .from("event_registrations")
        .select("id", { count: "exact", head: true })
        .eq("event_id", eventId)
        .in("registration_status", ["registered", "approved"]);

    if (participantsCountError) {
      return {
        attempted: true,
        success: false,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: true,
        reason: "participant_count_failed",
        statusCode: 500,
        error: "Nie udało się sprawdzić liczby uczestników.",
      };
    }

    const maxParticipants = Number(eventItem.max_participants ?? 0);

    if ((participantsCount ?? 0) >= maxParticipants) {
      return {
        attempted: true,
        success: true,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: false,
        reason: null,
        noFreePlace: true,
      };
    }

    const { data: reserveData, error: reserveError } = await supabase
      .from("event_registrations")
      .select("id, customer_email, customer_name")
      .eq("event_id", eventId)
      .eq("registration_status", "reserve")
      .order("created_at", { ascending: true });

    if (reserveError) {
      return {
        attempted: true,
        success: false,
        reserveFound: false,
        notifiedCount: 0,
        failedCount: 0,
        warning: true,
        reason: "reserve_query_failed",
        statusCode: 500,
        error: "Nie udało się pobrać listy rezerwowej.",
      };
    }

    const reserveRegistrations =
      (reserveData as ReserveRegistration[] | null) ?? [];
    const reserveList = reserveRegistrations.filter((registration) =>
      Boolean(registration.customer_email)
    );
    const missingEmailCount = reserveRegistrations.length - reserveList.length;

    if (reserveRegistrations.length === 0) {
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

    if (reserveList.length === 0) {
      for (const registration of reserveRegistrations) {
        logPromotionFailure(
          eventId,
          registration.id,
          "resend_send",
          { code: "missing_customer_email" }
        );
      }

      return {
        attempted: true,
        success: false,
        reserveFound: true,
        notifiedCount: 0,
        failedCount: missingEmailCount,
        warning: true,
        reason: "missing_customer_email",
        statusCode: 500,
        error: "Brak adresu email dla osób z listy rezerwowej.",
      };
    }

    const formattedDate = formatDate(eventItem.event_date);
    const formattedStartTime = formatTime(eventItem.start_time);
    const formattedEndTime = formatTime(eventItem.end_time);
    const formattedPrice = formatPrice(eventItem.price);
    let emailsSent = 0;
    let failedCount = missingEmailCount;
    const failureReasons = new Set<string>();

    if (missingEmailCount > 0) {
      failureReasons.add("missing_customer_email");

      for (const registration of reserveRegistrations) {
        if (!registration.customer_email) {
          logPromotionFailure(
            eventId,
            registration.id,
            "resend_send",
            { code: "missing_customer_email" }
          );
        }
      }
    }

    for (const registration of reserveList) {
      const token = randomUUID();
      const expiresAt = new Date(
        Date.now() + 24 * 60 * 60 * 1000
      ).toISOString();
      const confirmUrl = `${siteUrl}/events/confirm/${token}`;
      const displayName = registration.customer_name?.trim() || "Uczestniku";

      const { data: tokenUpdateData, error: tokenUpdateError } = await supabase
        .from("event_registrations")
        .update({
          promotion_token: token,
          promotion_token_expires_at: expiresAt,
        })
        .eq("id", registration.id)
        .eq("registration_status", "reserve")
        .select("id")
        .maybeSingle();

      if (tokenUpdateError || !tokenUpdateData) {
        failedCount += 1;
        failureReasons.add("token_update_failed");
        logPromotionFailure(
          eventId,
          registration.id,
          "token_update",
          tokenUpdateError ?? { code: "registration_not_updated" }
        );
        continue;
      }

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
                Cześć ${displayName}, na szkoleniu z Twojej listy rezerwowej pojawiła się możliwość potwierdzenia udziału.
              </p>
              <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Szkolenie:</strong> ${eventItem.title ?? "-"}</p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Data:</strong> ${formattedDate}</p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Godzina:</strong> ${formattedStartTime} - ${formattedEndTime}</p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Miejsce:</strong> ${eventItem.location ?? "-"}</p>
                <p style="margin:0;font-size:15px;color:#d4d4d8;"><strong style="color:#ffffff;">Płatność:</strong> ${formattedPrice}, płatność na miejscu</p>
              </div>
              <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
                <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
                  Kliknij przycisk poniżej, aby potwierdzić udział. Miejsce otrzyma pierwsza osoba z listy rezerwowej, która skutecznie potwierdzi udział.
                </p>
                <a href="${confirmUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">Potwierdź udział</a>
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

      try {
        const { error: emailError } = await resend.emails.send({
          from,
          to: registration.customer_email as string,
          subject,
          html,
          text,
        });

        if (emailError) {
          failedCount += 1;
          failureReasons.add("email_send_failed");
          logPromotionFailure(
            eventId,
            registration.id,
            "resend_send",
            emailError
          );
          continue;
        }
      } catch (error) {
        failedCount += 1;
        failureReasons.add("email_send_failed");
        logPromotionFailure(
          eventId,
          registration.id,
          "resend_send",
          error
        );
        continue;
      }

      const { data: sentAtUpdateData, error: sentAtUpdateError } =
        await supabase
          .from("event_registrations")
          .update({ promotion_email_sent_at: new Date().toISOString() })
          .eq("id", registration.id)
          .eq("registration_status", "reserve")
          .select("id")
          .maybeSingle();

      if (sentAtUpdateError || !sentAtUpdateData) {
        failedCount += 1;
        failureReasons.add("sent_at_update_failed");
        logPromotionFailure(
          eventId,
          registration.id,
          "sent_at_update",
          sentAtUpdateError ?? { code: "registration_not_updated" }
        );
        continue;
      }

      emailsSent += 1;
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
