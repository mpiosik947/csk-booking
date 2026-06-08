import { NextResponse } from "next/server";
import { Resend } from "resend";

type ReservationConfirmationPayload = {
  customerEmail?: string;
  customerName?: string;
  reservationDate?: string;
  startTime?: string;
  endTime?: string;
  laneName?: string;
  price?: number;
  checkInToken?: string;
};

function formatPrice(price?: number) {
  if (typeof price !== "number") {
    return "Do ustalenia";
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

    const body = (await request.json()) as ReservationConfirmationPayload;

    const {
      customerEmail,
      customerName,
      reservationDate,
      startTime,
      endTime,
      laneName,
      price,
      checkInToken,
    } = body;

    if (!customerEmail) {
      return NextResponse.json(
        { error: "Brak adresu email klienta." },
        { status: 400 }
      );
    }

    const resend = new Resend(resendApiKey);

    const displayName = customerName?.trim() || "Kliencie";
    const formattedDate = formatDate(reservationDate);
    const formattedPrice = formatPrice(price);

    const rawSiteUrl =
      process.env.NEXT_PUBLIC_SITE_URL ?? new URL(request.url).origin;

    const siteUrl = rawSiteUrl
      .replace(/^NEXT_PUBLIC_SITE_URL=/, "")
      .replace(/\/$/, "");

    const checkInUrl = checkInToken
      ? `${siteUrl}/check-in/${checkInToken}`
      : null;

    const checkInHtml = checkInUrl
      ? `
            <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
              <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
                <strong style="color:#ffffff;">Szybki check-in:</strong><br />
                Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie.
              </p>

              <a href="${checkInUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">
                Otwórz check-in
              </a>

              <p style="margin:12px 0 0 0;font-size:12px;line-height:1.5;color:#a3e635;word-break:break-all;">
                ${checkInUrl}
              </p>
            </div>
        `
      : "";

    const checkInText = checkInUrl
      ? `

Szybki check-in:
Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie.
${checkInUrl}
`
      : "";

    const subject = "Potwierdzenie rezerwacji — CSK Booking";

    const html = `
      <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
        <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
          <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
            <p style="margin:0 0 18px 0;color:#22c55e;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
              CSK Booking
            </p>

            <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
              Potwierdzenie rezerwacji
            </h1>

            <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
              Cześć ${displayName}, Twoja rezerwacja została przyjęta.
            </p>

            <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Data:</strong> ${formattedDate}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Godzina:</strong> ${startTime ?? "-"} - ${endTime ?? "-"}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Oś:</strong> ${laneName ?? "-"}
              </p>
              <p style="margin:0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Płatność:</strong> ${formattedPrice}, płatność na miejscu
              </p>
            </div>

            ${checkInHtml}

            <p style="margin:0 0 14px 0;font-size:14px;line-height:1.6;color:#a1a1aa;">
              Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.
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
CSK Booking — potwierdzenie rezerwacji

Cześć ${displayName},

Twoja rezerwacja została przyjęta.

Data: ${formattedDate}
Godzina: ${startTime ?? "-"} - ${endTime ?? "-"}
Oś: ${laneName ?? "-"}
Płatność: ${formattedPrice}, płatność na miejscu
${checkInText}
Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.
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
