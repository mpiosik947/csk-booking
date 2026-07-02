import Link from "next/link";
import { createClient } from "@supabase/supabase-js";
import { Resend } from "resend";

type ConfirmEventReservePageProps = {
  params: Promise<{
    token: string;
  }>;
};

type ConfirmReserveResult = {
  ok?: boolean;
  code?: string;
  message?: string;
  event_id?: string;
  registration_id?: string;
};

type ConfirmedEvent = {
  title: string | null;
  event_date: string | null;
  start_time: string | null;
  end_time: string | null;
  location: string | null;
  price: number | null;
};

type ConfirmedRegistration = {
  id: string;
  customer_email: string | null;
  customer_name: string | null;
  events: ConfirmedEvent | ConfirmedEvent[] | null;
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

async function sendConfirmedPlaceEmail(
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

function getCardClass(success: boolean) {
  if (success) {
    return "mx-auto max-w-2xl rounded-2xl border border-green-800 bg-green-950/40 p-6";
  }

  return "mx-auto max-w-2xl rounded-2xl border border-red-900 bg-red-950/40 p-6";
}

function getTitle(result: ConfirmReserveResult | null, hasError: boolean) {
  if (hasError) {
    return "Nie udało się potwierdzić miejsca";
  }

  if (result?.ok) {
    return "Miejsce zostało potwierdzone";
  }

  if (result?.code === "full") {
    return "Miejsce zostało już zajęte";
  }

  if (result?.code === "expired") {
    return "Link wygasł";
  }

  return "Nie udało się potwierdzić miejsca";
}

export default async function ConfirmEventReservePage({
  params,
}: ConfirmEventReservePageProps) {
  const { token } = await params;

  let result: ConfirmReserveResult | null = null;
  let hasError = false;

  try {
    const supabase = getAdminSupabaseClient();

    const { data, error } = await supabase.rpc(
      "confirm_event_reserve_promotion",
      {
        p_token: token,
      }
    );

    if (error) {
      hasError = true;
    } else {
      result = data as ConfirmReserveResult;

      if (result?.ok && result.registration_id) {
        const { data: registrationData } = await supabase
          .from("event_registrations")
          .select(
            `
              id,
              customer_email,
              customer_name,
              events (
                title,
                event_date,
                start_time,
                end_time,
                location,
                price
              )
            `
          )
          .eq("id", result.registration_id)
          .maybeSingle();

        if (registrationData) {
          await sendConfirmedPlaceEmail(
            (registrationData as unknown) as ConfirmedRegistration
          ).catch(() => null);
        }
      }
    }
  } catch {
    hasError = true;
  }

  const success = Boolean(result?.ok) && !hasError;
  const message =
    result?.message ??
    "Link jest nieprawidłowy, wygasł albo miejsce nie jest już dostępne.";

  return (
    <main className="min-h-screen bg-zinc-950 px-4 py-10 text-zinc-100">
      <section className={getCardClass(success)}>
        <p className="mb-3 text-xs font-bold uppercase tracking-[0.35em] text-green-400">
          CSK Booking
        </p>

        <h1 className="mb-4 text-2xl font-bold text-white">
          {getTitle(result, hasError)}
        </h1>

        <p className="mb-6 text-sm leading-6 text-zinc-200">{message}</p>

        {success ? (
          <div className="mb-6 rounded-xl border border-green-800 bg-green-950/60 p-4 text-sm leading-6 text-green-100">
            Twój status został zmieniony z listy rezerwowej na uczestnika
            szkolenia. Szczegóły znajdziesz w panelu klienta.
          </div>
        ) : (
          <div className="mb-6 rounded-xl border border-yellow-800 bg-yellow-950/50 p-4 text-sm leading-6 text-yellow-100">
            Jeśli nadal chcesz wziąć udział w szkoleniu, sprawdź swój panel lub
            skontaktuj się z organizatorem.
          </div>
        )}

        <div className="flex flex-col gap-3 sm:flex-row">
          <Link
            href="/my-events"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Moje szkolenia
          </Link>

          <Link
            href="/events"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            Lista szkoleń
          </Link>
        </div>
      </section>
    </main>
  );
}
