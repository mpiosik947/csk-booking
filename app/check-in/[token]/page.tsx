import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { createClient } from "@supabase/supabase-js";

type CheckInPageProps = {
  params: Promise<{ token: string }>;
};

type PublicCheckInStatus = {
  ok: boolean;
  code: "ready" | "already_checked_in" | "unavailable";
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  referrer: "no-referrer",
  robots: { index: false, follow: false },
};

function getPublicSupabaseClient() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !anonKey) {
    throw new Error("Brak publicznej konfiguracji Supabase.");
  }

  return createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function parsePublicCheckInStatus(value: unknown): PublicCheckInStatus | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();

  if (keys.length !== 2 || keys[0] !== "code" || keys[1] !== "ok") {
    return null;
  }

  if (
    typeof record.ok !== "boolean" ||
    (record.code !== "ready" &&
      record.code !== "already_checked_in" &&
      record.code !== "unavailable")
  ) {
    return null;
  }

  if (
    (record.code === "unavailable" && record.ok) ||
    (record.code !== "unavailable" && !record.ok)
  ) {
    return null;
  }

  return { ok: record.ok, code: record.code };
}

async function loadPublicCheckInStatus(token: string) {
  if (!UUID_PATTERN.test(token)) {
    return null;
  }

  try {
    const supabase = getPublicSupabaseClient();
    const { data, error } = await supabase.rpc(
      "get_public_check_in_status_v1",
      { p_token: token }
    );

    if (error) {
      console.error("Public check-in status lookup failed", {
        code: error.code,
      });
      return null;
    }

    return parsePublicCheckInStatus(data);
  } catch {
    return null;
  }
}

function CheckInUnavailable() {
  return (
    <main className="flex min-h-screen items-center bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl shadow-black/20 sm:p-9">
        <Image
          src="/login-brand.png"
          alt="Centrum Szkolenia Krutla"
          width={1536}
          height={1024}
          className="mx-auto h-auto w-full max-w-[260px] sm:max-w-[300px]"
          priority
        />

        <h1 className="mt-6 text-center text-3xl font-bold sm:text-4xl">
          Check-in niedostępny
        </h1>

        <div
          role="alert"
          className="mt-6 rounded-2xl border border-[#744545] bg-[#2a1b1b] p-5 text-sm leading-6 text-[#e0a0a0]"
        >
          Kod jest nieprawidłowy, nieaktywny albo wygasł. Check-in jest dostępny
          od 24 godzin przed rozpoczęciem do 2 godzin po zakończeniu wizyty.
        </div>

        <Link
          href="/"
          className="mt-6 inline-flex min-h-12 w-full items-center justify-center rounded-xl bg-[#536143] px-5 py-3 text-center text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:w-auto"
        >
          Wróć na stronę główną
        </Link>
      </section>
    </main>
  );
}

export default async function CheckInPage({ params }: CheckInPageProps) {
  const { token } = await params;
  const status = await loadPublicCheckInStatus(token);

  if (!status?.ok) {
    return <CheckInUnavailable />;
  }

  const alreadyCheckedIn = status.code === "already_checked_in";

  return (
    <main className="flex min-h-screen items-center bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl shadow-black/20 sm:p-9">
        <Image
          src="/login-brand.png"
          alt="Centrum Szkolenia Krutla"
          width={1536}
          height={1024}
          className="mx-auto h-auto w-full max-w-[260px] sm:max-w-[300px]"
          priority
        />

        <h1 className="mt-6 text-center text-3xl font-bold sm:text-4xl">
          Check-in rezerwacji
        </h1>

        <p className="mx-auto mt-4 max-w-xl text-center text-sm leading-6 text-[#a9ada4] sm:text-base">
          Pokaż ten ekran obsłudze. Dane rezerwacji są dostępne wyłącznie po
          zalogowaniu uprawnionego operatora.
        </p>

        {alreadyCheckedIn ? (
          <div
            role="status"
            aria-live="polite"
            className="mt-7 rounded-2xl border border-[#3f6848] bg-[#1b2a1d] p-5 text-sm leading-6 text-[#a9d4ad]"
          >
            Obecność została już potwierdzona. Ponowne otwarcie kodu nie wykonuje
            drugiego check-in.
          </div>
        ) : (
          <div
            role="status"
            aria-live="polite"
            className="mt-7 rounded-2xl border border-[#806a32] bg-[#2b2618] p-5 text-sm leading-6 text-[#e1c477]"
          >
            Kod jest gotowy do sprawdzenia przez obsługę. Ten ekran nie
            potwierdza obecności automatycznie.
          </div>
        )}

        <div className="mt-6">
          <Link
            href="/"
            className="inline-flex min-h-11 w-full items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:w-auto"
          >
            Wróć na stronę główną
          </Link>
        </div>
      </section>
    </main>
  );
}
