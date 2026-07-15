"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type Role = "admin" | "pracownik" | "instruktor" | "user";

type ProfileData = {
  role: Role | null;
  full_name: string | null;
  phone: string | null;
  postal_code: string | null;
  city: string | null;
  street: string | null;
  house_number: string | null;
  verification_status: string | null;
  permissions_verified: boolean | null;
};

function hasValue(value: string | null | undefined) {
  return Boolean(value && value.trim().length > 0);
}

export default function DashboardPage() {
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [role, setRole] = useState<Role>("user");

  const [profileComplete, setProfileComplete] = useState(false);
  const [verificationStatus, setVerificationStatus] = useState("");
  const [permissionsVerified, setPermissionsVerified] = useState(false);

  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [emailConfirmed, setEmailConfirmed] = useState(false);

  useEffect(() => {
    async function loadUser() {
      const params = new URLSearchParams(window.location.search);
      setEmailConfirmed(params.get("emailConfirmed") === "1");

      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setIsLoggedIn(false);
        setLoading(false);
        return;
      }

      const metadata = user.user_metadata ?? {};

      setIsLoggedIn(true);
      setEmail(user.email ?? "");
      setFullName(metadata.full_name ?? metadata.name ?? "Użytkownik");

      const { data: profile } = await supabase
        .from("profiles")
        .select(
          "role, full_name, phone, postal_code, city, street, house_number, verification_status, permissions_verified"
        )
        .eq("user_id", user.id)
        .single();

      if (profile) {
        const profileData = profile as ProfileData;

        if (profileData.role) {
          setRole(profileData.role);
        }

        const displayedName =
          profileData.full_name ??
          metadata.full_name ??
          metadata.name ??
          "Użytkownik";

        setFullName(displayedName);
        setVerificationStatus(profileData.verification_status ?? "");
        setPermissionsVerified(Boolean(profileData.permissions_verified));

        setProfileComplete(
          hasValue(profileData.full_name) &&
            hasValue(profileData.phone) &&
            hasValue(profileData.postal_code) &&
            hasValue(profileData.city) &&
            hasValue(profileData.street) &&
            hasValue(profileData.house_number)
        );
      }

      setLoading(false);
    }

    loadUser();
  }, []);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
        <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl shadow-black/20 sm:p-8">
          <div
            role="status"
            aria-live="polite"
            className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 text-[#a9ada4]"
          >
            Ładowanie panelu klienta...
          </div>
        </section>
      </main>
    );
  }

  if (!isLoggedIn) {
    return (
      <main className="flex min-h-screen items-center bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
        <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 text-center shadow-2xl shadow-black/20 sm:p-9">
          <div>
            <h1 className="text-3xl font-bold sm:text-4xl">
              Logowanie wymagane
            </h1>

            <p
              role="alert"
              className="mx-auto mt-6 max-w-xl rounded-2xl border border-[#744545] bg-[#2a1b1b] p-5 leading-7 text-[#e0a0a0]"
            >
              Aby przejść do panelu klienta, musisz najpierw zalogować się na
              swoje konto.
            </p>

            <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="inline-flex min-h-12 items-center justify-center rounded-xl bg-[#536143] px-6 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="inline-flex min-h-12 items-center justify-center rounded-xl border border-[#30372c] px-6 py-3 font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        </section>
      </main>
    );
  }

  const canAccessAdmin =
    role === "admin" || role === "pracownik" || role === "instruktor";

  const accountVerified =
    verificationStatus === "verified" || permissionsVerified === true;

  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto max-w-6xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/20 sm:p-8">
        <header className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <p className="mb-3 text-xs font-semibold uppercase tracking-[0.22em] text-[#858c7f]">
              CSK Booking
            </p>

            <h1 className="text-3xl font-bold sm:text-4xl">Panel klienta</h1>

            <p className="mt-3 leading-7 text-[#a9ada4]">
              Witaj,{" "}
              <span className="font-semibold text-[#d7c895]">{fullName}</span>.
              Zarządzaj swoimi rezerwacjami i szkoleniami.
            </p>
          </div>

          <div className="w-full rounded-2xl border border-[#30372c] bg-[#191e19] px-5 py-4 text-sm text-[#a9ada4] lg:max-w-sm lg:text-right">
            Zalogowany jako:{" "}
            <span className="break-all font-semibold text-[#f2efe4]">
              {email}
            </span>
          </div>
        </header>

        {emailConfirmed && (
          <div
            role="status"
            aria-live="polite"
            className="mt-6 rounded-2xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-[#a9d4ad]"
          >
            Adres e-mail został potwierdzony. Konto jest aktywne.
          </div>
        )}

        {!profileComplete && (
          <div className="mt-6 rounded-2xl border border-[#806a32] bg-[#2b2618] p-5 sm:p-6">
            <h2 className="text-xl font-bold text-[#e1c477]">
              Uzupełnij profil
            </h2>

            <p className="mt-2 max-w-3xl leading-7 text-[#e1c477]">
              Uzupełnij dane przed pierwszą wizytą. Dzięki temu obsługa szybciej
              zweryfikuje konto i rezerwacja przebiegnie sprawniej.
            </p>

            <a
              href="/account"
              className="mt-5 inline-flex min-h-11 items-center rounded-xl bg-[#6f5a2e] px-5 py-3 text-sm font-semibold text-[#f2efe4] transition hover:bg-[#9a7c3e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2b2618]"
            >
              Uzupełnij profil
            </a>
          </div>
        )}

        {profileComplete && !accountVerified && (
          <div
            role="status"
            className="mt-6 rounded-2xl border border-[#806a32] bg-[#2b2618] p-5 sm:p-6"
          >
            <h2 className="text-xl font-bold text-[#e1c477]">
              Profil uzupełniony
            </h2>

            <p className="mt-2 max-w-3xl leading-7 text-[#e1c477]">
              Konto oczekuje na weryfikację podczas pierwszej wizyty. Profil
              uzupełniony nie oznacza jeszcze konta zweryfikowanego.
            </p>
          </div>
        )}

        <section aria-labelledby="main-actions-heading" className="mt-8">
          <h2
            id="main-actions-heading"
            className="text-xl font-semibold text-[#f2efe4]"
          >
            Główne akcje
          </h2>

          <div className="mt-4 grid gap-4 md:grid-cols-2">
            <a
              href="/booking"
              className="group min-h-40 rounded-2xl border border-[#536143] bg-[#20251d] p-6 transition hover:border-[#78865f] hover:bg-[#293026] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
            >
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h3 className="text-2xl font-bold text-[#f2efe4]">
                    Zarezerwuj oś
                  </h3>
                  <p className="mt-3 leading-7 text-[#a9ada4]">
                    Wybierz datę, oś, godzinę oraz czas rezerwacji. Płatność na
                    miejscu.
                  </p>
                </div>
                <span aria-hidden="true" className="text-2xl text-[#d7c895]">
                  →
                </span>
              </div>
            </a>

            <a
              href="/events"
              className="group min-h-40 rounded-2xl border border-[#6f5a2e] bg-[#221f18] p-6 transition hover:border-[#9a7c3e] hover:bg-[#2b271d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
            >
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h3 className="text-2xl font-bold text-[#f2efe4]">
                    Eventy / Szkolenia
                  </h3>
                  <p className="mt-3 leading-7 text-[#a9ada4]">
                    Zobacz planowane szkolenia, wydarzenia i zapisz się na wybrany
                    termin.
                  </p>
                </div>
                <span aria-hidden="true" className="text-2xl text-[#d7c895]">
                  →
                </span>
              </div>
            </a>
          </div>
        </section>

        <section aria-labelledby="account-actions-heading" className="mt-8">
          <h2
            id="account-actions-heading"
            className="text-xl font-semibold text-[#f2efe4]"
          >
            Twoje konto
          </h2>

          <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <a
              href="/my-reservations"
              className="min-h-24 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 transition hover:border-[#536143] hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
            >
              <h3 className="font-semibold text-[#f2efe4]">Moje rezerwacje</h3>
              <p className="mt-2 text-sm leading-6 text-[#858c7f]">
                Sprawdź swoje terminy, statusy rezerwacji oraz płatności.
              </p>
            </a>

            <a
              href="/my-events"
              className="min-h-24 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 transition hover:border-[#536143] hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
            >
              <h3 className="font-semibold text-[#f2efe4]">Moje szkolenia</h3>
              <p className="mt-2 text-sm leading-6 text-[#858c7f]">
                Sprawdź szkolenia, na które jesteś zapisany oraz status
                uczestnictwa.
              </p>
            </a>

            <a
              href="/account"
              className="min-h-24 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 transition hover:border-[#536143] hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
            >
              <h3 className="font-semibold text-[#f2efe4]">Moje konto</h3>
              <p className="mt-2 text-sm leading-6 text-[#858c7f]">
                Edytuj swoje dane użytkownika, imię, nazwisko oraz numer telefonu.
              </p>
            </a>

            <a
              href="/terms"
              className="min-h-24 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 transition hover:border-[#536143] hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
            >
              <h3 className="font-semibold text-[#f2efe4]">Regulamin i RODO</h3>
              <p className="mt-2 text-sm leading-6 text-[#858c7f]">
                Regulamin strzelnicy, zasady bezpieczeństwa oraz polityka
                prywatności.
              </p>
            </a>
          </div>
        </section>

        {canAccessAdmin && (
          <section
            aria-labelledby="admin-action-heading"
            className="mt-6 rounded-2xl border border-[#30372c] bg-[#191e19] p-5"
          >
            <h2
              id="admin-action-heading"
              className="text-lg font-semibold text-[#d7c895]"
            >
              Panel administracyjny
            </h2>
            <p className="mt-2 text-sm leading-6 text-[#a9ada4]">
              Zarządzanie rezerwacjami, eventami, check-in oraz obsługą systemu.
            </p>
            <a
              href="/admin"
              className="mt-4 inline-flex min-h-11 items-center rounded-xl border border-[#536143] px-5 py-3 text-sm font-semibold text-[#d7c895] transition hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
            >
              Panel administracyjny
            </a>
          </section>
        )}

        <div className="mt-8 flex justify-end border-t border-[#30372c] pt-6">
          <a
            href="/"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3 text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:bg-[#20251d] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Strona główna
          </a>
        </div>
      </section>
    </main>
  );
}
