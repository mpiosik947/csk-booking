import { randomUUID } from "crypto";
import { NextResponse } from "next/server";
import { Resend } from "resend";
import { createClient } from "@supabase/supabase-js";

type EventReservePromotionPayload = {
  eventId?: string;
};

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

    const body = (await request.json()) as EventReservePromotionPayload;
    const eventId = body.eventId;

    if (!eventId) {
      return NextResponse.json(
        { error: "Brak ID szkolenia." },
        { status: 400 }
      );
    }

    const rawSiteUrl =
      process.env.NEXT_PUBLIC_SITE_URL ?? new URL(request.url).origin;

    const siteUrl = rawSiteUrl
      .replace(/^NEXT_PUBLIC_SITE_URL=/, "")
      .replace(/\/$/, "");

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
      return NextResponse.json(
        { error: "Nie znaleziono szkolenia." },
        { status: 404 }
      );
    }

    const eventItem = eventData as EventRecord;

    const { count: participantsCount, error: participantsCountError } =
      await supabase
        .from("event_registrations")
        .select("id", { count: "exact", head: true })
        .eq("event_id", eventId)
        .in("registration_status", ["registered", "approved"]);

    if (participantsCountError) {
      return NextResponse.json(
        { error: "Nie udało się sprawdzić liczby uczestników." },
        { status: 500 }
      );
    }

    const maxParticipants = Number(eventItem.max_participants ?? 0);

    if ((participantsCount ?? 0) >= maxParticipants) {
      return NextResponse.json({
        ok: true,
        reserveFound: false,
        emailsSent: 0,
        noFreePlace: true,
      });
    }

    const { data: reserveData, error: reserveError } = await supabase
      .from("event_registrations")
      .select("id, customer_email, customer_name")
      .eq("event_id", eventId)
      .eq("registration_status", "reserve")
      .order("created_at", { ascending: true });

    if (reserveError) {
      return NextResponse.json(
        { error: "Nie udało się pobrać listy rezerwowej." },
        { status: 500 }
      );
    }

    const reserveList = ((reserveData as ReserveRegistration[] | null) ?? []).filter(
      (registration) => Boolean(registration.customer_email)
    );

    if (reserveList.length === 0) {
      return NextResponse.json({
        ok: true,
        reserveFound: false,
        emailsSent: 0,
      });
    }

    const formattedDate = formatDate(eventItem.event_date);
    const formattedStartTime = formatTime(eventItem.start_time);
    const formattedEndTime = formatTime(eventItem.end_time);
    const formattedPrice = formatPrice(eventItem.price);

    let emailsSent = 0;
    const errors: string[] = [];

    for (const registration of reserveList) {
      const token = randomUUID();
      const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
      const confirmUrl = `${siteUrl}/events/confirm/${token}`;
      const displayName = registration.customer_name?.trim() || "Uczestniku";

      const { error: updateError } = await supabase
        .from("event_registrations")
        .update({
          promotion_token: token,
          promotion_token_expires_at: expiresAt,
          promotion_email_sent_at: new Date().toISOString(),
          promotion_confirmed_at: null,
        })
        .eq("id", registration.id)
        .eq("registration_status", "reserve");

      if (updateError) {
        errors.push(updateError.message);
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
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                  <strong style="color:#ffffff;">Szkolenie:</strong> ${eventItem.title ?? "-"}
                </p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                  <strong style="color:#ffffff;">Data:</strong> ${formattedDate}
                </p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                  <strong style="color:#ffffff;">Godzina:</strong> ${formattedStartTime} - ${formattedEndTime}
                </p>
                <p style="margin:0 0 10px 0;font-size:15px;color:#d4d4d8;">
                  <strong style="color:#ffffff;">Miejsce:</strong> ${eventItem.location ?? "-"}
                </p>
                <p style="margin:0;font-size:15px;color:#d4d4d8;">
                  <strong style="color:#ffffff;">Płatność:</strong> ${formattedPrice}, płatność na miejscu
                </p>
              </div>

              <div style="margin:24px 0;padding:18px;border:1px solid #365314;border-radius:14px;background:#13210d;">
                <p style="margin:0 0 12px 0;font-size:15px;line-height:1.6;color:#d9f99d;">
                  Kliknij przycisk poniżej, aby potwierdzić udział. Miejsce otrzyma pierwsza osoba z listy rezerwowej, która skutecznie potwierdzi udział.
                </p>

                <a href="${confirmUrl}" style="display:inline-block;padding:12px 16px;border-radius:10px;background:#22c55e;color:#052e16;text-decoration:none;font-weight:bold;font-size:14px;">
                  Potwierdź udział
                </a>
              </div>

              <p style="margin:0 0 14px 0;font-size:14px;line-height:1.6;color:#a1a1aa;">
                Link jest ważny przez 24 godziny. Samo otrzymanie tej wiadomości nie gwarantuje miejsca — decyduje pierwsze skuteczne potwierdzenie.
              </p>

              <p style="margin:0;font-size:14px;line-height:1.6;color:#a1a1aa;">
                Jeżeli nie chcesz brać udziału w szkoleniu, zignoruj tę wiadomość.
              </p>
            </div>

            <p style="margin:18px 0 0 0;text-align:center;font-size:12px;color:#71717a;">
              Centrum Szkolenia Krutla · CSK Booking
            </p>
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

      const { error: emailError } = await resend.emails.send({
        from,
        to: registration.customer_email as string,
        subject,
        html,
        text,
      });

      if (emailError) {
        errors.push("Nie udało się wysłać emaila do uczestnika z listy rezerwowej.");
        continue;
      }

      emailsSent += 1;
    }

    if (emailsSent === 0) {
      return NextResponse.json(
        {
          error:
            "Nie udało się wysłać żadnego powiadomienia do listy rezerwowej.",
          reserveFound: true,
          emailsSent,
          errors,
        },
        { status: 500 }
      );
    }

    return NextResponse.json({
      ok: true,
      reserveFound: true,
      emailsSent,
      errors,
    });
  } catch {
    return NextResponse.json(
      { error: "Wystąpił błąd podczas wysyłki powiadomień do listy rezerwowej." },
      { status: 500 }
    );
  }
}
