import { NextResponse } from "next/server";
import { Resend } from "resend";

type EventRegistrationConfirmationPayload = {
  customerEmail?: string;
  customerName?: string;
  eventTitle?: string;
  eventDate?: string;
  startTime?: string;
  endTime?: string;
  location?: string;
  price?: number;
  registrationStatus?: string;
};

function formatPrice(price?: number) {
  if (typeof price !== "number") {
    return "Do ustalenia";
  }

  if (price <= 0) {
    return "Bezpłatnie";
  }

  return `${price.toFixed(2)} zł`;
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

function formatRegistrationStatus(status?: string) {
  if (status === "reserve") {
    return "Lista rezerwowa";
  }

  return "Zapisany";
}

export async function POST(request: Request) {
  try {
    const resendApiKey = process.env.RESEND_API_KEY;
    const from = process.env.RESERVATION_EMAIL_FROM;

    if (!resendApiKey || !from) {
      return NextResponse.json(
        { error: "Brak konfiguracji wysyłki email." },
        { status: 500 }
      );
    }

    const body = (await request.json()) as EventRegistrationConfirmationPayload;

    const {
      customerEmail,
      customerName,
      eventTitle,
      eventDate,
      startTime,
      endTime,
      location,
      price,
      registrationStatus,
    } = body;

    if (!customerEmail) {
      return NextResponse.json(
        { error: "Brak adresu email uczestnika." },
        { status: 400 }
      );
    }

    const resend = new Resend(resendApiKey);

    const displayName = customerName?.trim() || "Uczestniku";
    const formattedDate = formatDate(eventDate);
    const formattedPrice = formatPrice(price);
    const formattedStatus = formatRegistrationStatus(registrationStatus);

    const rawSiteUrl =
      process.env.NEXT_PUBLIC_SITE_URL ?? new URL(request.url).origin;

    const siteUrl = rawSiteUrl
      .replace(/^NEXT_PUBLIC_SITE_URL=/, "")
      .replace(/\/$/, "");

    const myEventsUrl = `${siteUrl}/my-events`;

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
              Cześć ${displayName}, Twój zapis na szkolenie został przyjęty.
            </p>

            <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Szkolenie:</strong> ${eventTitle ?? "-"}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Data:</strong> ${formattedDate}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Godzina:</strong> ${startTime ?? "-"} - ${endTime ?? "-"}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Miejsce:</strong> ${location ?? "-"}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Status:</strong> ${formattedStatus}
              </p>
              <p style="margin:0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Płatność:</strong> ${formattedPrice}, płatność na miejscu
              </p>
            </div>

            <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
              <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
                Szczegóły swojego zapisu znajdziesz w panelu uczestnika.
              </p>

              <a href="${myEventsUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">
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

Szkolenie: ${eventTitle ?? "-"}
Data: ${formattedDate}
Godzina: ${startTime ?? "-"} - ${endTime ?? "-"}
Miejsce: ${location ?? "-"}
Status: ${formattedStatus}
Płatność: ${formattedPrice}, płatność na miejscu

Moje szkolenia:
${myEventsUrl}

Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed szkoleniem.
W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.

Centrum Szkolenia Krutla
CSK Booking
    `;

    const { error } = await resend.emails.send({
      from,
      to: customerEmail,
      subject,
      html,
      text,
    });

    if (error) {
      return NextResponse.json(
        { error: "Nie udało się wysłać emaila potwierdzającego." },
        { status: 500 }
      );
    }

    return NextResponse.json({ ok: true });
  } catch {
    return NextResponse.json(
      { error: "Wystąpił błąd podczas wysyłki emaila." },
      { status: 500 }
    );
  }
}
