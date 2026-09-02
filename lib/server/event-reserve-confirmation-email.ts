import "server-only";

import { Resend } from "resend";

export type ConfirmedEvent = {
  title: string | null;
  event_date: string | null;
  start_time: string | null;
  end_time: string | null;
  location: string | null;
  price: number | null;
};

export type ConfirmedRegistration = {
  id: string;
  customer_email: string | null;
  customer_name: string | null;
  events: ConfirmedEvent | ConfirmedEvent[] | null;
};

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

export async function sendConfirmedPlaceEmail(
  registration: ConfirmedRegistration
) {
  const resendApiKey = process.env.RESEND_API_KEY;
  const from = process.env.RESERVATION_EMAIL_FROM;

  if (!resendApiKey || !from || !registration.customer_email) {
    return;
  }

  const eventRelation = registration.events;
  const event = Array.isArray(eventRelation)
    ? eventRelation[0] ?? null
    : eventRelation;
  const displayName = registration.customer_name?.trim() || "Uczestniku";
  const formattedDate = formatDate(event?.event_date);
  const formattedStartTime = formatTime(event?.start_time);
  const formattedEndTime = formatTime(event?.end_time);
  const formattedPrice = formatPrice(event?.price);

  const rawSiteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "";
  const siteUrl = rawSiteUrl
    .replace(/^NEXT_PUBLIC_SITE_URL=/, "")
    .replace(/\/$/, "");

  const myEventsUrl = `${siteUrl}/my-events`;
  const subject = "Twoje miejsce na szkoleniu zostało potwierdzone — CSK Booking";

  const html = `
    <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
      <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
        <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
          <p style="margin:0 0 18px 0;color:#22c55e;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
            CSK Booking
          </p>

          <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
            Twoje miejsce zostało potwierdzone
          </h1>

          <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
            Cześć ${displayName}, Twoje miejsce na szkoleniu zostało potwierdzone.
          </p>

          <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
            <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
              <strong style="color:#ffffff;">Szkolenie:</strong> ${event?.title ?? "-"}
            </p>
            <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
              <strong style="color:#ffffff;">Data:</strong> ${formattedDate}
            </p>
            <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
              <strong style="color:#ffffff;">Godzina:</strong> ${formattedStartTime} - ${formattedEndTime}
            </p>
            <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
              <strong style="color:#ffffff;">Miejsce:</strong> ${event?.location ?? "-"}
            </p>
            <p style="margin:0;font-size:15px;color:#d4d4d8;">
              <strong style="color:#ffffff;">Płatność:</strong> ${formattedPrice}, płatność na miejscu
            </p>
          </div>

          <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
            <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
              Szczegóły zapisu znajdziesz w panelu uczestnika.
            </p>

            <a href="${myEventsUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">
              Moje szkolenia
            </a>
          </div>

          <p style="margin:0;font-size:14px;line-height:1.6;color:#a1a1aa;">
            Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed szkoleniem.
          </p>
        </div>

        <p style="margin:18px 0 0 0;text-align:center;font-size:12px;color:#71717a;">
          Centrum Szkolenia Krutla · CSK Booking
        </p>
      </div>
    </div>
  `;

  const text = `
CSK Booking — Twoje miejsce na szkoleniu zostało potwierdzone

Cześć ${displayName},

Twoje miejsce na szkoleniu zostało potwierdzone.

Szkolenie: ${event?.title ?? "-"}
Data: ${formattedDate}
Godzina: ${formattedStartTime} - ${formattedEndTime}
Miejsce: ${event?.location ?? "-"}
Płatność: ${formattedPrice}, płatność na miejscu

Moje szkolenia:
${myEventsUrl}

Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed szkoleniem.

Centrum Szkolenia Krutla
CSK Booking
  `;

  await new Resend(resendApiKey).emails.send({
    from,
    to: registration.customer_email,
    subject,
    html,
    text,
  });
}
