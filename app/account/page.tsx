"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

export default function AccountPage() {
  const [loading, setLoading] = useState(true);
  const [savingProfile, setSavingProfile] = useState(false);
  const [savingPassword, setSavingPassword] = useState(false);

  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");

  const [postalCode, setPostalCode] = useState("");
  const [city, setCity] = useState("");
  const [street, setStreet] = useState("");
  const [houseNumber, setHouseNumber] = useState("");
  const [apartmentNumber, setApartmentNumber] = useState("");

  const [weaponPermitNumber, setWeaponPermitNumber] = useState("");
  const [weaponPermitType, setWeaponPermitType] = useState("");

  const [hasRangeOfficer, setHasRangeOfficer] = useState(false);
  const [rangeOfficerNumber, setRangeOfficerNumber] = useState("");

  const [hasInstructor, setHasInstructor] = useState(false);
  const [instructorNumber, setInstructorNumber] = useState("");

  const [verificationStatus, setVerificationStatus] =
    useState("niezweryfikowane");

  const [newPassword, setNewPassword] = useState("");
  const [repeatPassword, setRepeatPassword] = useState("");

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

      setWeaponPermitNumber(metadata.weapon_permit_number ?? "");
      setWeaponPermitType(metadata.weapon_permit_type ?? "");

      setHasRangeOfficer(metadata.has_range_officer ?? false);
      setRangeOfficerNumber(metadata.range_officer_number ?? "");

      setHasInstructor(metadata.has_instructor ?? false);
      setInstructorNumber(metadata.instructor_number ?? "");

      setVerificationStatus(
        metadata.verification_status ?? "niezweryfikowane"
      );

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

    setSavingProfile(true);

    const { error } = await supabase.auth.updateUser({
      data: {
        full_name: fullName,
        phone,
        postal_code: postalCode,
        city,
        street,
        house_number: houseNumber,
        apartment_number: apartmentNumber,
        weapon_permit_number: weaponPermitNumber,
        weapon_permit_type: weaponPermitType,
        has_range_officer: hasRangeOfficer,
        range_officer_number: hasRangeOfficer ? rangeOfficerNumber : "",
        has_instructor: hasInstructor,
        instructor_number: hasInstructor ? instructorNumber : "",
        verification_status: verificationStatus,
      },
    });

    setSavingProfile(false);

    if (error) {
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    setMessage("Dane zostały zapisane.");
  }

  async function changePassword() {
    setMessage("");

    if (!newPassword || !repeatPassword) {
      setMessage("Uzupełnij oba pola hasła.");
      return;
    }

    if (newPassword.length < 8) {
      setMessage("Hasło musi mieć minimum 8 znaków.");
      return;
    }

    if (newPassword !== repeatPassword) {
      setMessage("Hasła nie są identyczne.");
      return;
    }

    setSavingPassword(true);

    const { error } = await supabase.auth.updateUser({
      password: newPassword,
    });

    setSavingPassword(false);

    if (error) {
      setMessage(`Błąd zmiany hasła: ${error.message}`);
      return;
    }

    setNewPassword("");
    setRepeatPassword("");
    setMessage("Hasło zostało zmienione.");
  }

  function getMessageClass(message: string) {
    if (message.includes("zapisane") || message.includes("zmienione")) {
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
          Zarządzaj swoimi danymi użytkownika, adresem, uprawnieniami i
          bezpieczeństwem konta.
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
          <div className="grid gap-6">
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
                  <h2 className="mb-4 text-xl font-semibold">
                    Bezpieczeństwo konta
                  </h2>

                  <p className="mb-5 text-sm text-zinc-400">
                    Zmień hasło do swojego konta. Nowe hasło musi mieć minimum
                    8 znaków.
                  </p>

                  <div className="grid gap-5 md:grid-cols-2">
                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Nowe hasło
                      </label>

                      <input
                        type="password"
                        value={newPassword}
                        onChange={(event) =>
                          setNewPassword(event.target.value)
                        }
                        placeholder="Minimum 8 znaków"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-yellow-600"
                      />
                    </div>

                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Powtórz hasło
                      </label>

                      <input
                        type="password"
                        value={repeatPassword}
                        onChange={(event) =>
                          setRepeatPassword(event.target.value)
                        }
                        placeholder="Powtórz nowe hasło"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-yellow-600"
                      />
                    </div>
                  </div>

                  <button
                    type="button"
                    onClick={changePassword}
                    disabled={savingPassword}
                    className="mt-5 rounded-xl border border-yellow-700 bg-yellow-950 px-5 py-3 font-semibold text-yellow-300 transition hover:bg-yellow-900 disabled:cursor-not-allowed disabled:opacity-60"
                  >
                    {savingPassword ? "Zmiana hasła..." : "Zmień hasło"}
                  </button>
                </div>

                <div className="mt-2 border-t border-zinc-800 pt-5">
                  <h2 className="mb-4 text-xl font-semibold">
                    Uprawnienia i dane strzeleckie
                  </h2>

                  <p className="mb-5 text-sm text-zinc-400">
                    Dane te pomagają obsłudze szybciej zweryfikować konto
                    podczas pierwszej wizyty na strzelnicy.
                  </p>

                  <div className="mb-5 rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-sm text-yellow-100">
                    <p className="font-semibold text-yellow-300">
                      Status konta: {verificationStatus}
                    </p>

                    <p className="mt-1 text-yellow-100/80">
                      Pełna możliwość rezerwacji osi będzie dostępna po
                      weryfikacji danych przez pracownika CSK podczas wizyty na
                      strzelnicy.
                    </p>
                  </div>

                  <div className="grid gap-5 md:grid-cols-2">
                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Numer pozwolenia na broń
                      </label>

                      <input
                        type="text"
                        value={weaponPermitNumber}
                        onChange={(event) =>
                          setWeaponPermitNumber(event.target.value)
                        }
                        placeholder="Opcjonalnie"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                      />
                    </div>

                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Typ pozwolenia
                      </label>

                      <select
                        value={weaponPermitType}
                        onChange={(event) =>
                          setWeaponPermitType(event.target.value)
                        }
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                      >
                        <option value="">Brak / nie dotyczy</option>
                        <option value="sportowe">Sportowe</option>
                        <option value="kolekcjonerskie">Kolekcjonerskie</option>
                        <option value="lowieckie">Łowieckie</option>
                        <option value="szkoleniowe">Szkoleniowe</option>
                        <option value="ochrona_osobista">
                          Ochrona osobista
                        </option>
                        <option value="inne">Inne</option>
                      </select>
                    </div>
                  </div>

                  <div className="mt-5 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                    <label className="flex items-start gap-3 text-sm text-zinc-300">
                      <input
                        type="checkbox"
                        checked={hasRangeOfficer}
                        onChange={(event) => {
                          setHasRangeOfficer(event.target.checked);

                          if (!event.target.checked) {
                            setRangeOfficerNumber("");
                          }
                        }}
                        className="mt-1"
                      />

                      <span>
                        Posiadam uprawnienia prowadzącego strzelanie
                      </span>
                    </label>

                    {hasRangeOfficer && (
                      <div className="mt-4">
                        <label className="mb-2 block text-sm text-zinc-300">
                          Numer uprawnień prowadzącego strzelanie
                        </label>

                        <input
                          type="text"
                          value={rangeOfficerNumber}
                          onChange={(event) =>
                            setRangeOfficerNumber(event.target.value)
                          }
                          placeholder="Wpisz numer uprawnień"
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-white outline-none focus:border-green-600"
                        />
                      </div>
                    )}
                  </div>

                  <div className="mt-5 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                    <label className="flex items-start gap-3 text-sm text-zinc-300">
                      <input
                        type="checkbox"
                        checked={hasInstructor}
                        onChange={(event) => {
                          setHasInstructor(event.target.checked);

                          if (!event.target.checked) {
                            setInstructorNumber("");
                          }
                        }}
                        className="mt-1"
                      />

                      <span>Posiadam uprawnienia instruktora strzelectwa</span>
                    </label>

                    {hasInstructor && (
                      <div className="mt-4">
                        <label className="mb-2 block text-sm text-zinc-300">
                          Numer uprawnień instruktora
                        </label>

                        <input
                          type="text"
                          value={instructorNumber}
                          onChange={(event) =>
                            setInstructorNumber(event.target.value)
                          }
                          placeholder="Wpisz numer uprawnień"
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-white outline-none focus:border-green-600"
                        />
                      </div>
                    )}
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

                {message && (
                  <div className={getMessageClass(message)}>{message}</div>
                )}

                <button
                  type="button"
                  onClick={saveProfile}
                  disabled={savingProfile}
                  className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {savingProfile ? "Zapisywanie..." : "Zapisz dane"}
                </button>
              </div>
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