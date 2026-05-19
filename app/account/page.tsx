"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

export default function AccountPage() {
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");

  const [postalCode, setPostalCode] = useState("");
  const [city, setCity] = useState("");
  const [street, setStreet] = useState("");
  const [houseNumber, setHouseNumber] = useState("");
  const [apartmentNumber, setApartmentNumber] = useState("");

  const [message, setMessage] = useState("");
  const [isLoggedIn, setIsLoggedIn] = useState(false);

  useEffect(() => {
    async function loadUser() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setIsLoggedIn(false);
        setLoading(false);
        return;
      }

      setIsLoggedIn(true);

      const metadata = user.user_metadata ?? {};

      setEmail(user.email ?? "");
      setFullName(metadata.full_name ?? metadata.name ?? "");
      setPhone(
        metadata.phone ??
          metadata.telefon ??
          metadata.phone_number ??
          metadata.phoneNumber ??
          ""
      );

      setPostalCode(metadata.postal_code ?? "");
      setCity(metadata.city ?? "");
      setStreet(metadata.street ?? "");
      setHouseNumber(metadata.house_number ?? "");
      setApartmentNumber(metadata.apartment_number ?? "");

      setLoading(false);
    }

    loadUser();
  }, []);

  async function saveProfile() {
    setMessage("");

    if (!fullName || !phone || !postalCode || !city || !street || !houseNumber) {
      setMessage("Uzupełnij wymagane pola.");
      return;
    }

    setSaving(true);

    const { error } = await supabase.auth.updateUser({
      data: {
        full_name: fullName,
        phone,
        postal_code: postalCode,
        city,
        street,
        house_number: houseNumber,
        apartment_number: apartmentNumber,
      },
    });

    setSaving(false);

    if (error) {
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    setMessage("Dane zostały zapisane.");
  }

  function getMessageClass(message: string) {
    if (message.includes("zapisane")) {
      return "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-4xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-3 text-4xl font-bold">Moje konto</h1>

        <p className="mb-8 text-zinc-400">
          Zarządzaj swoimi danymi użytkownika i adresem.
        </p>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie konta...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="rounded-2xl border border-red-800 bg-red-950 p-8 text-center">
            <h2 className="mb-3 text-2xl font-bold text-red-200">
              Logowanie wymagane
            </h2>

            <p className="mx-auto mb-6 max-w-xl text-red-100">
              Aby przejść do swojego konta, musisz się zalogować.
            </p>

            <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="rounded-xl border border-red-300 px-5 py-3 font-semibold text-red-100 transition hover:bg-red-900"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        )}

        {!loading && isLoggedIn && (
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
            <div className="grid gap-5">
              <div>
                <label className="mb-2 block text-sm text-zinc-300">
                  Adres e-mail
                </label>

                <input
                  type="email"
                  value={email}
                  disabled
                  className="w-full cursor-not-allowed rounded-xl border border-zinc-800 bg-zinc-950 px-4 py-3 text-zinc-500 outline-none"
                />
              </div>

              <div className="grid gap-5 md:grid-cols-2">
                <div>
                  <label className="mb-2 block text-sm text-zinc-300">
                    Imię i nazwisko *
                  </label>

                  <input
                    type="text"
                    value={fullName}
                    onChange={(event) => setFullName(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />
                </div>

                <div>
                  <label className="mb-2 block text-sm text-zinc-300">
                    Numer telefonu *
                  </label>

                  <input
                    type="tel"
                    value={phone}
                    onChange={(event) => setPhone(event.target.value)}
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />
                </div>
              </div>

              <div className="mt-2 border-t border-zinc-800 pt-5">
                <h2 className="mb-4 text-xl font-semibold">Adres</h2>

                <div className="grid gap-5 md:grid-cols-2">
                  <div>
                    <label className="mb-2 block text-sm text-zinc-300">
                      Kod pocztowy *
                    </label>

                    <input
                      type="text"
                      value={postalCode}
                      onChange={(event) => setPostalCode(event.target.value)}
                      placeholder="64-200"
                      className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />
                  </div>

                  <div>
                    <label className="mb-2 block text-sm text-zinc-300">
                      Miasto *
                    </label>

                    <input
                      type="text"
                      value={city}
                      onChange={(event) => setCity(event.target.value)}
                      placeholder="Wolsztyn"
                      className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />
                  </div>
                </div>

                <div className="mt-5">
                  <label className="mb-2 block text-sm text-zinc-300">
                    Ulica *
                  </label>

                  <input
                    type="text"
                    value={street}
                    onChange={(event) => setStreet(event.target.value)}
                    placeholder="ul. Przykładowa"
                    className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                  />
                </div>

                <div className="mt-5 grid gap-5 md:grid-cols-2">
                  <div>
                    <label className="mb-2 block text-sm text-zinc-300">
                      Numer domu *
                    </label>

                    <input
                      type="text"
                      value={houseNumber}
                      onChange={(event) => setHouseNumber(event.target.value)}
                      placeholder="12"
                      className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />
                  </div>

                  <div>
                    <label className="mb-2 block text-sm text-zinc-300">
                      Numer mieszkania
                    </label>

                    <input
                      type="text"
                      value={apartmentNumber}
                      onChange={(event) =>
                        setApartmentNumber(event.target.value)
                      }
                      placeholder="Opcjonalnie"
                      className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                    />
                  </div>
                </div>
              </div>

              {message && <div className={getMessageClass(message)}>{message}</div>}

              <button
                type="button"
                onClick={saveProfile}
                disabled={saving}
                className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {saving ? "Zapisywanie..." : "Zapisz dane"}
              </button>
            </div>
          </div>
        )}

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/dashboard"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel klienta
          </a>

          <a
            href="/my-reservations"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            Moje rezerwacje
          </a>

          <a
            href="/my-events"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Moje szkolenia
          </a>
        </div>
      </section>
    </main>
  );
}