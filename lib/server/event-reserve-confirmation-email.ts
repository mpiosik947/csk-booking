import "server-only";
import { resolveEventRegistrationEmailTenantContext, operationalEmailBrand, operationalEmailHistoryUrl, getOperationalEmailSenderConfiguration } from "./operational-email";

import { Resend } from "resend";
import { operationalEmailLayout } from "./operational-email-layout";

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
  registration: ConfirmedRegistration,
  idempotencyKey: string
) {
  const { resendApiKey, from } = getOperationalEmailSenderConfiguration();

  if (!resendApiKey || !from || !registration.customer_email) {
    throw new Error("Receipt configuration unavailable");
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

  const tenant = await resolveEventRegistrationEmailTenantContext(registration.id);
  const brand = operationalEmailBrand(tenant, "Twoje miejsce na szkoleniu zostało potwierdzone");
  const subject = brand.subject;
  const myEventsUrl = operationalEmailHistoryUrl(tenant, "events");

  const html = operationalEmailLayout({
    tenantDisplayName: tenant.displayName,
    title: "Twoje miejsce zostało potwierdzone",
    intro: `Cześć ${displayName}, Twoje miejsce na szkoleniu zostało potwierdzone.`,
    details: [
      { label: "Szkolenie", value: event?.title ?? "-" },
      { label: "Data", value: formattedDate },
      { label: "Godzina", value: `${formattedStartTime} - ${formattedEndTime}` },
      { label: "Miejsce", value: event?.location ?? "-" },
      { label: "Płatność", value: `${formattedPrice}, płatność na miejscu` },
    ],
    actions: [{ label: "Moje szkolenia", url: myEventsUrl, description: "Szczegóły zapisu znajdziesz w panelu uczestnika." },
    ],
    notes: [
      "Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed szkoleniem.",
    ],
  });

  const text = `
${brand.headerText}

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

${brand.footerText}
  `;

  return new Resend(resendApiKey).emails.send({
    from,
    to: registration.customer_email,
    subject,
    html,
    text,
  }, { idempotencyKey });
}
