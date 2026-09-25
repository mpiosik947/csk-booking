"use client";
import PlatformBrand from "@/app/_components/PlatformBrand";

import { useEffect, useState } from "react";
import Link from "next/link";
import { supabase } from "../../lib/supabase";
import {
  getProfileDisplayName,
  hasStructuredProfileName,
} from "../../lib/profile-display-name";

type ProfileData = {
  first_name: string | null;
  last_name: string | null;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  postal_code: string | null;
  city: string | null;
  street: string | null;
  house_number: string | null;
};

type TenantAccess = {
  tenant_id: string;
  tenant_slug: string;
  tenant_name: string;
  tenant_role: "admin" | "employee" | "instructor" | "user";
};

function isTenantAccess(value: unknown): value is TenantAccess {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Partial<TenantAccess>;
  return typeof item.tenant_id === "string" &&
    typeof item.tenant_slug === "string" && /^[a-z0-9-]+$/.test(item.tenant_slug) &&
    typeof item.tenant_name === "string" &&
    ["admin", "employee", "instructor", "user"].includes(item.tenant_role ?? "");
}

function hasValue(value: string | null | undefined) {
  return Boolean(value && value.trim().length > 0);
}

export default function DashboardPage() {
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [profileComplete, setProfileComplete] = useState(false);

  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [emailConfirmed, setEmailConfirmed] = useState(false);
  const [tenants, setTenants] = useState<TenantAccess[]>([]);
  const [tenantLoadFailed, setTenantLoadFailed] = useState(false);

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
      setFullName(
        getProfileDisplayName({
          first_name: metadata.first_name,
          last_name: metadata.last_name,
          full_name: metadata.full_name ?? metadata.name,
          email: user.email,
        })
      );

      const { data: profile } = await supabase
        .from("profiles")
        .select(
          "first_name, last_name, full_name, email, phone, postal_code, city, street, house_number"
        )
        .eq("user_id", user.id)
        .single();

      if (profile) {
        const profileData = profile as ProfileData;

        const displayedName = getProfileDisplayName({
          first_name: profileData.first_name,
          last_name: profileData.last_name,
          full_name: profileData.full_name,
          email: profileData.email ?? user.email,
        });

        setFullName(displayedName);
        setProfileComplete(
          hasStructuredProfileName(profileData) &&
            hasValue(profileData.phone) &&
            hasValue(profileData.postal_code) &&
            hasValue(profileData.city) &&
            hasValue(profileData.street) &&
            hasValue(profileData.house_number)
        );
      }


      const { data: tenantRows, error: tenantError } = await supabase.rpc(
        "get_my_active_tenants_v1"
      );
      if (tenantError || !Array.isArray(tenantRows) || !tenantRows.every(isTenantAccess)) {
        setTenantLoadFailed(true);
        setTenants([]);
      } else {
        setTenantLoadFailed(false);
        setTenants(tenantRows);
      }

      setLoading(false);
    }

    loadUser();
  }, []);

  if (loading) {
    return (
      <main className="platform-ui flex min-h-screen items-center bg-[#080B09] px-4 py-6 text-[#F4F3EE] sm:px-6 sm:py-8">
        <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#303A2D] bg-[#111712] p-6 shadow-2xl shadow-black/20 sm:p-8">
          <div
            role="status"
            aria-live="polite"
            className="rounded-2xl border border-[#303A2D] bg-[#182019] p-5 text-[#A6ADA5]"
          >
            Ładowanie panelu klienta...
          </div>
        </section>
      </main>
    );
  }

  if (!isLoggedIn) {
    return (
      <main className="platform-ui flex min-h-screen items-center bg-[#080B09] px-4 py-6 text-[#F4F3EE] sm:px-6 sm:py-8">
        <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#303A2D] bg-[#111712] p-6 text-center shadow-2xl shadow-black/20 sm:p-9">
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
              <Link prefetch={false}
                href="/login"
                className="inline-flex min-h-12 items-center justify-center rounded-xl bg-[#697A2F] px-6 py-3 font-semibold text-[#F4F3EE] transition hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
              >
                Zaloguj się
              </Link>

              <Link prefetch={false}
                href="/register"
                className="inline-flex min-h-12 items-center justify-center rounded-xl border border-[#303A2D] px-6 py-3 font-semibold text-[#A6ADA5] transition hover:border-[#F5A900] hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
              >
                Utwórz konto
              </Link>
            </div>
          </div>
        </section>
      </main>
    );
  }

  return (
    <main className="platform-ui min-h-screen bg-[#080B09] px-4 py-6 text-[#F4F3EE] sm:px-6 sm:py-8">
      <section className="mx-auto max-w-6xl rounded-[2rem] border border-[#303A2D] bg-[#111712] p-5 shadow-2xl shadow-black/20 sm:p-8">
        <header className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div className="mb-4"><PlatformBrand compact /></div>

            <h1 className="text-3xl font-bold sm:text-4xl">Panel klienta</h1>

            <p className="mt-3 leading-7 text-[#A6ADA5]">
              Witaj,{" "}
              <span className="font-semibold text-[#F5A900]">{fullName}</span>.
              Zarządzaj swoimi rezerwacjami i szkoleniami.
            </p>
          </div>

          <div className="w-full rounded-2xl border border-[#303A2D] bg-[#182019] px-5 py-4 text-sm text-[#A6ADA5] lg:max-w-sm lg:text-right">
            Zalogowany jako:{" "}
            <span className="break-all font-semibold text-[#F4F3EE]">
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

            <Link prefetch={false}
              href="/account"
              className="mt-5 inline-flex min-h-11 items-center rounded-xl bg-[#6f5a2e] px-5 py-3 text-sm font-semibold text-[#F4F3EE] transition hover:bg-[#9a7c3e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2b2618]"
            >
              Uzupełnij profil
            </Link>
          </div>
        )}

        {profileComplete && (
          <div
            role="status"
            className="mt-6 rounded-2xl border border-[#806a32] bg-[#2b2618] p-5 sm:p-6"
          >
            <h2 className="text-xl font-bold text-[#e1c477]">
              Profil uzupełniony
            </h2>

            <p className="mt-2 max-w-3xl leading-7 text-[#e1c477]">
              Weryfikacja uprawnień zależy od wybranej lokalizacji. Globalny panel
              nie przedstawia statusu jednej strzelnicy jako statusu konta.
            </p>
          </div>
        )}

        <section aria-labelledby="locations-heading" className="mt-8">
          <h2
            id="locations-heading"
            className="text-xl font-semibold text-[#F4F3EE]"
          >
            Twoje lokalizacje
          </h2>

          {tenantLoadFailed && (
            <p role="alert" className="mt-4 rounded-2xl border border-[#744545] bg-[#2a1b1b] p-4 text-[#e0a0a0]">
              Nie udało się pobrać listy lokalizacji. Odśwież stronę i spróbuj ponownie.
            </p>
          )}
          {!tenantLoadFailed && tenants.length === 0 && (
            <p className="mt-4 rounded-2xl border border-[#806a32] bg-[#2b2618] p-4 text-[#e1c477]">
              Nie masz jeszcze aktywnego dostępu do żadnej lokalizacji.
            </p>
          )}
          <div className="mt-4 grid gap-4">
            {tenants.map((tenant) => (
              <article key={tenant.tenant_id} className="rounded-2xl border border-[#697A2F] bg-[#20251d] p-5 sm:p-6">
                <h3 className="text-2xl font-bold text-[#F4F3EE]">{tenant.tenant_name}</h3>
                <p className="mt-2 text-sm text-[#A6ADA5]">Wybierz operację w tej lokalizacji.</p>
                <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
                  <Link href={`/t/${tenant.tenant_slug}/booking`} className="min-h-11 rounded-xl bg-[#697A2F] px-4 py-3 text-center text-sm font-semibold">Zarezerwuj oś</Link>
                  <Link href={`/t/${tenant.tenant_slug}/events`} className="min-h-11 rounded-xl border border-[#6f5a2e] px-4 py-3 text-center text-sm font-semibold text-[#F5A900]">Eventy</Link>
                  <Link href={`/t/${tenant.tenant_slug}/my-reservations`} className="min-h-11 rounded-xl border border-[#303A2D] px-4 py-3 text-center text-sm font-semibold">Moje rezerwacje</Link>
                  <Link href={`/t/${tenant.tenant_slug}/my-events`} className="min-h-11 rounded-xl border border-[#303A2D] px-4 py-3 text-center text-sm font-semibold">Moje szkolenia</Link>
                  {tenant.tenant_role !== "user" && (
                    <Link href={`/t/${tenant.tenant_slug}/admin`} className="min-h-11 rounded-xl border border-[#806a32] px-4 py-3 text-center text-sm font-semibold text-[#e1c477]">Panel obsługi</Link>
                  )}
                </div>
              </article>
            ))}
          </div>
        </section>

        <section aria-labelledby="account-actions-heading" className="mt-8">
          <h2
            id="account-actions-heading"
            className="text-xl font-semibold text-[#F4F3EE]"
          >
            Twoje konto
          </h2>

          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <Link prefetch={false}
              href="/account"
              className="min-h-24 rounded-2xl border border-[#303A2D] bg-[#182019] p-5 transition hover:border-[#697A2F] hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
            >
              <h3 className="font-semibold text-[#F4F3EE]">Moje konto</h3>
              <p className="mt-2 text-sm leading-6 text-[#A6ADA5]">
                Edytuj swoje dane użytkownika, imię, nazwisko oraz numer telefonu.
              </p>
            </Link>

            <Link prefetch={false}
              href="/terms"
              className="min-h-24 rounded-2xl border border-[#303A2D] bg-[#182019] p-5 transition hover:border-[#697A2F] hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
            >
              <h3 className="font-semibold text-[#F4F3EE]">Regulamin i RODO</h3>
              <p className="mt-2 text-sm leading-6 text-[#A6ADA5]">
                Regulamin strzelnicy, zasady bezpieczeństwa oraz polityka
                prywatności.
              </p>
            </Link>
          </div>
        </section>

        <div className="mt-8 flex justify-end border-t border-[#303A2D] pt-6">
          <Link
            href="/"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#303A2D] bg-[#182019] px-5 py-3 text-sm font-semibold text-[#A6ADA5] transition hover:border-[#697A2F] hover:bg-[#20251d] hover:text-[#F4F3EE] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
          >
            ← Wróć do StrzelajTu.pl
          </Link>
        </div>
      </section>
    </main>
  );
}
