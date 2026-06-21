import { NextResponse } from "next/server";
import { Resend } from "resend";

type ReservationCancellationPayload = {
  customerEmail?: string;
  customerName?: string;
  reservationDate?: string;
  startTime?: string;
  endTime?: string;
  laneName?: string;
  cancelledBy?: "user" | "admin";
};

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

    const body = (await request.json()) as ReservationCancellationPayload;

    const {
      customerEmail,
      customerName,
      reservationDate,
      startTime,
      endTime,
      laneName,
      cancelledBy,
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

    const cancelledByText =
      cancelledBy === "admin"
        ? "Rezerwacja została anulowana przez obsługę CSK."
        : "Twoja rezerwacja została anulowana.";

    const subject = "Anulowanie rezerwacji — CSK Booking";

    const html = `
      <div style="margin:0;padding:0;background:#09090b;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
        <div style="max-width:620px;margin:0 auto;padding:32px 20px;">
          <div style="border:1px solid #27272a;background:#18181b;border-radius:18px;padding:32px;">
            <p style="margin:0 0 18px 0;color:#ef4444;font-size:12px;letter-spacing:4px;text-transform:uppercase;font-weight:bold;">
              CSK Booking
            </p>

            <h1 style="margin:0 0 16px 0;font-size:28px;line-height:1.25;color:#ffffff;">
              Anulowanie rezerwacji
            </h1>

            <p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;color:#d4d4d8;">
              Cześć ${displayName}, ${cancelledByText}
            </p>

            <div style="margin:24px 0;padding:18px;border:1px solid #3f3f46;border-radius:14px;background:#09090b;">
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Data:</strong> ${formattedDate}
              </p>
              <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Godzina:</strong> ${startTime ?? "-"} - ${endTime ?? "-"}
              </p>
              <p style="margin:0;font-size:15px;color:#d4d4d8;">
                <strong style="color:#ffffff;">Oś:</strong> ${laneName ?? "-"}
              </p>
            </div>

            <p style="margin:0;font-size:14px;line-height:1.6;color:#a1a1aa;">
              W przypadku pytań skontaktuj się z obsługą CSK.
            </p>
          </div>

          <p style="margin:18px 0 0 0;text-align:center;font-size:12px;color:#71717a;">
            Centrum Szkolenia Krutla · CSK Booking
          </p>
        </div>
      </div>
    `;

    const text = `
CSK Booking — anulowanie rezerwacji

Cześć ${displayName},

${cancelledByText}

Data: ${formattedDate}
Godzina: ${startTime ?? "-"} - ${endTime ?? "-"}
Oś: ${laneName ?? "-"}

W przypadku pytań skontaktuj się z obsługą CSK.

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
        { error: "Nie udało się wysłać emaila anulowania." },
        { status: 500 }
      );
    }

    return NextResponse.json({ ok: true });
  } catch {
    return NextResponse.json(
      { error: "Wystąpił błąd podczas wysyłki emaila anulowania." },
      { status: 500 }
    );
  }
}
