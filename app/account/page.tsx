"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type ProfileData = {
  full_name: string | null;
  phone: string | null;
  postal_code: string | null;
  city: string | null;
  street: string | null;
  house_number: string | null;
  apartment_number: string | null;
  verification_status: string | null;

  permission_sport: boolean | null;
  permission_collector: boolean | null;
  permission_hunting: boolean | null;
  permission_training: boolean | null;
  permission_personal_protection: boolean | null;
  permission_other: boolean | null;

  qualification_instructor: boolean | null;
  qualification_range_officer: boolean | null;
  qualification_pzss_license: boolean | null;
  qualification_hunter: boolean | null;

  permissions_verified: boolean | null;
  permissions_verified_at: string | null;
  permissions_verification_note: string | null;
};

function getVerificationLabel(status: string) {
  switch (status) {
    case "verified":
      return "Zweryfikowane";
    case "pending":
      return "Oczekuje na weryfikacj�";
    case "rejected":
      return "Wymaga poprawy";
    case "niezweryfikowane":
      return "Niezweryfikowane";
    default:
      return status || "Niezweryfikowane";
  }
}

function getVerificationClass(status: string, permissionsVerified: boolean) {
  if (status === "verified" && permissionsVerified) {
    return "rounded-xl border border-green-800 bg-green-950 p-4 text-sm text-green-100";
  }

  if (status === "rejected") {
    return "rounded-xl border border-red-800 bg-red-950 p-4 text-sm text-red-100";
  }

  return "rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-sm text-yellow-100";
}

function getMessageClass(message: string) {
  if (message.includes("zapisane") || message.includes("zmienione")) {
    return "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
  }

  return "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
}

function CheckboxField({
  checked,
  onChange,
  title,
  description,
}: {
  checked: boolean;
  onChange: (checked: boolean) => void;
  title: string;
  description?: string;
}) {
  return (
    <label className="flex cursor-pointer items-start gap-3 rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-300 transition hover:border-green-800">
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        className="mt-1"
      />

      <span>
        <span className="block font-semibold text-zinc-100">{title}</span>

        {description && (
          <span className="mt-1 block text-xs leading-5 text-zinc-500">
            {description}
          </span>
        )}
      </span>
    </label>
  );
}

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

  const [permissionSport, setPermissionSport] = useState(false);
  const [permissionCollector, setPermissionCollector] = useState(false);
  const [permissionHunting, setPermissionHunting] = useState(false);
  const [permissionTraining, setPermissionTraining] = useState(false);
  const [permissionPersonalProtection, setPermissionPersonalProtection] =
    useState(false);
  const [permissionOther, setPermissionOther] = useState(false);

  const [qualificationInstructor, setQualificationInstructor] = useState(false);
  const [qualificationRangeOfficer, setQualificationRangeOfficer] =
    useState(false);
  const [qualificationPzssLicense, setQualificationPzssLicense] =
    useState(false);
  const [qualificationHunter, setQualificationHunter] = useState(false);

  const [verificationStatus, setVerificationStatus] =
    useState("niezweryfikowane");
  const [permissionsVerified, setPermissionsVerified] = useState(false);
  const [permissionsVerifiedAt, setPermissionsVerifiedAt] = useState("");
  const [permissionsVerificationNote, setPermissionsVerificationNote] =
    useState("");

  const [newPassword, setNewPassword] = useState("");
  const [repeatPassword, setRepeatPassword] = useState("");

  const [message, setMessage] = useState("");
  const [isLoggedIn, setIsLoggedIn] = useState(false);

  useEffect(() => {
    loadUser();
  }, []);

  async function loadUser() {
    setLoading(true);
    setMessage("");

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError) {
      setMessage(`B��d pobierania u�ytkownika: ${userError.message}`);
      setIsLoggedIn(false);
      setLoading(false);
      return;
    }

    if (!user) {
      setIsLoggedIn(false);
      setLoading(false);
      return;
    }

    setIsLoggedIn(true);
    setEmail(user.email ?? "");

    const metadata = user.user_metadata ?? {};

    setFullName(metadata.full_name ?? metadata.name ?? "");
    setPhone(
      metadata.phone ??
        metadata.telefon ??
        metadata.phone_number ??
        metadata.mobile ??
        ""
    );

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select(
        `
        full_name,
        phone,
        postal_code,
        city,
        street,
        house_number,
        apartment_number,
        verification_status,

        permission_sport,
        permission_collector,
        permission_hunting,
        permission_training,
        permission_personal_protection,
        permission_other,

        qualification_instructor,
        qualification_range_officer,
        qualification_pzss_license,
        qualification_hunter,

        permissions_verified,
        permissions_verified_at,
        permissions_verification_note
      `
      )
      .eq("user_id", user.id)
      .maybeSingle();

    if (profileError) {
      setMessage(`B��d pobierania profilu: ${profileError.message}`);
      setLoading(false);
      return;
    }

    if (profile) {
      const profileData = profile as ProfileData;

      setFullName(profileData.full_name ?? metadata.full_name ?? "");
      setPhone(profileData.phone ?? metadata.phone ?? "");

      setPostalCode(profileData.postal_code ?? "");
      setCity(profileData.city ?? "");
      setStreet(profileData.street ?? "");
      setHouseNumber(profileData.house_number ?? "");
      setApartmentNumber(profileData.apartment_number ?? "");

      setVerificationStatus(
        profileData.verification_status ?? "niezweryfikowane"
      );

      setPermissionSport(Boolean(profileData.permission_sport));
      setPermissionCollector(Boolean(profileData.permission_collector));
      setPermissionHunting(Boolean(profileData.permission_hunting));
      setPermissionTraining(Boolean(profileData.permission_training));
      setPermissionPersonalProtection(
        Boolean(profileData.permission_personal_protection)
      );
      setPermissionOther(Boolean(profileData.permission_other));

      setQualificationInstructor(Boolean(profileData.qualification_instructor));
      setQualificationRangeOfficer(
        Boolean(profileData.qualification_range_officer)
      );
      setQualificationPzssLicense(
        Boolean(profileData.qualification_pzss_license)
      );
      setQualificationHunter(Boolean(profileData.qualification_hunter));

      setPermissionsVerified(Boolean(profileData.permissions_verified));
      setPermissionsVerifiedAt(profileData.permissions_verified_at ?? "");
      setPermissionsVerificationNote(
        profileData.permissions_verification_note ?? ""
      );
    }

    setLoading(false);
  }

  function validateProfile() {
    if (!fullName.trim()) {
      return "Uzupe�nij imi� i nazwisko.";
    }

    if (!phone.trim()) {
      return "Uzupe�nij numer telefonu.";
    }

    if (!postalCode.trim()) {
      return "Uzupe�nij kod pocztowy.";
    }

    if (!city.trim()) {
      return "Uzupe�nij miasto.";
    }

    if (!street.trim()) {
      return "Uzupe�nij ulic�.";
    }

    if (!houseNumber.trim()) {
      return "Uzupe�nij numer domu.";
    }

    return "";
  }

  async function saveProfile() {
    setMessage("");

    const validationError = validateProfile();

    if (validationError) {
      setMessage(validationError);
      return;
    }

    setSavingProfile(true);

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError || !user) {
      setSavingProfile(false);
      setMessage("Nie uda�o si� pobra� zalogowanego u�ytkownika.");
      return;
    }

    const { error: authError } = await supabase.auth.updateUser({
      data: {
        full_name: fullName.trim(),
        phone: phone.trim(),

        permission_sport: permissionSport,
        permission_collector: permissionCollector,
        permission_hunting: permissionHunting,
        permission_training: permissionTraining,
        permission_personal_protection: permissionPersonalProtection,
        permission_other: permissionOther,

        qualification_instructor: qualificationInstructor,
        qualification_range_officer: qualificationRangeOfficer,
        qualification_pzss_license: qualificationPzssLicense,
        qualification_hunter: qualificationHunter,
      },
    });

    if (authError) {
      setSavingProfile(false);
      setMessage(`B��d zapisu danych konta: ${authError.message}`);
      return;
    }

    const { error: profileError } = await supabase
      .from("profiles")
      .update({
        full_name: fullName.trim(),
        phone: phone.trim(),
        postal_code: postalCode.trim(),
        city: city.trim(),
        street: street.trim(),
        house_number: houseNumber.trim(),
        apartment_number: apartmentNumber.trim() || null,

        permission_sport: permissionSport,
        permission_collector: permissionCollector,
        permission_hunting: permissionHunting,
        permission_training: permissionTraining,
        permission_personal_protection: permissionPersonalProtection,
        permission_other: permissionOther,

        qualification_instructor: qualificationInstructor,
        qualification_range_officer: qualificationRangeOfficer,
        qualification_pzss_license: qualificationPzssLicense,
        qualification_hunter: qualificationHunter,

        updated_at: new Date().toISOString(),
      })
      .eq("user_id", user.id);

    setSavingProfile(false);

    if (profileError) {
      setMessage(
        `Dane konta zapisane, ale nie uda�o si� zaktualizowa� profilu: ${profileError.message}`
      );
      return;
    }

    setMessage("Dane zosta�y zapisane.");
  }

  async function changePassword() {
    setMessage("");

    if (!newPassword || !repeatPassword) {
      setMessage("Uzupe�nij oba pola has�a.");
      return;
    }

    if (newPassword.length < 8) {
      setMessage("Has�o musi mie� minimum 8 znak�w.");
      return;
    }

    if (newPassword !== repeatPassword) {
      setMessage("Has�a nie s� identyczne.");
      return;
    }

    setSavingPassword(true);

    const { error } = await supabase.auth.updateUser({
      password: newPassword,
    });

    setSavingPassword(false);

    if (error) {
      setMessage(`B��d zmiany has�a: ${error.message}`);
      return;
    }

    setNewPassword("");
    setRepeatPassword("");
    setMessage("Has�o zosta�o zmienione.");
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-4xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-3 text-4xl font-bold">Moje konto</h1>

        <p className="mb-8 text-zinc-400">
          Zarz�dzaj swoimi danymi u�ytkownika, adresem, deklarowanymi
          uprawnieniami i bezpiecze�stwem konta.
        </p>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            �adowanie konta...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="rounded-2xl border border-red-800 bg-red-950 p-8 text-center">
            <h2 className="mb-3 text-2xl font-bold text-red-200">
              Logowanie wymagane
            </h2>

            <p className="mx-auto mb-6 max-w-xl text-red-100">
              Aby przej�� do swojego konta, musisz si� zalogowa�.
            </p>

            <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
              >
                Zaloguj si�
              </a>

              <a
                href="/register"
                className="rounded-xl border border-red-300 px-5 py-3 font-semibold text-red-100 transition hover:bg-red-900"
              >
                Utw�rz konto
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
                      Imi� i nazwisko *
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
                    Status weryfikacji
                  </h2>

                  <div
                    className={getVerificationClass(
                      verificationStatus,
                      permissionsVerified
                    )}
                  >
                    <p className="font-semibold">
                      Konto: {getVerificationLabel(verificationStatus)}
                    </p>

                    <p className="mt-1">
                      Uprawnienia:{" "}
                      {permissionsVerified
                        ? "sprawdzone przez obs�ug�"
                        : "do sprawdzenia podczas wizyty"}
                    </p>

                    {permissionsVerifiedAt && (
                      <p className="mt-1 text-xs opacity-80">
                        Data weryfikacji:{" "}
                        {new Date(permissionsVerifiedAt).toLocaleString(
                          "pl-PL"
                        )}
                      </p>
                    )}

                    {permissionsVerificationNote && (
                      <p className="mt-3 rounded-lg border border-zinc-700 bg-zinc-950/60 p-3 text-xs leading-5">
                        {permissionsVerificationNote}
                      </p>
                    )}

                    <p className="mt-3 text-xs opacity-80">
                      Pe�na mo�liwo�� korzystania z systemu mo�e wymaga�
                      sprawdzenia uprawnie� przez pracownika CSK podczas wizyty
                      na strzelnicy.
                    </p>
                  </div>
                </div>

                <div className="mt-2 border-t border-zinc-800 pt-5">
                  <h2 className="mb-4 text-xl font-semibold">
                    Deklarowane uprawnienia
                  </h2>

                  <p className="mb-5 text-sm leading-6 text-zinc-400">
                    Zaznacz, jakie uprawnienia posiadasz. Nie wpisuj numer�w
                    dokument�w. Dokumenty okazujesz wy��cznie do wgl�du
                    pracownikowi podczas wizyty.
                  </p>

                  <div className="mb-5 rounded-xl border border-green-900 bg-green-950/40 p-4 text-sm text-green-200">
                    <p className="font-semibold">
                      Minimalizacja danych osobowych
                    </p>

                    <p className="mt-1 text-green-300">
                      System zapisuje tylko deklarowany typ uprawnie� i fakt
                      p�niejszej weryfikacji. Numery dokument�w nie s� tutaj
                      wymagane.
                    </p>
                  </div>

                  <div className="grid gap-4 md:grid-cols-2">
                    <CheckboxField
                      checked={permissionSport}
                      onChange={setPermissionSport}
                      title="Pozwolenie sportowe"
                      description="Zaznacz, je�eli posiadasz uprawnienia/pozwolenie do cel�w sportowych."
                    />

                    <CheckboxField
                      checked={permissionCollector}
                      onChange={setPermissionCollector}
                      title="Pozwolenie kolekcjonerskie"
                      description="Zaznacz, je�eli posiadasz uprawnienia/pozwolenie do cel�w kolekcjonerskich."
                    />

                    <CheckboxField
                      checked={permissionHunting}
                      onChange={setPermissionHunting}
                      title="Pozwolenie my�liwskie / �owieckie"
                      description="Zaznacz, je�eli posiadasz uprawnienia zwi�zane z �owiectwem."
                    />

                    <CheckboxField
                      checked={permissionTraining}
                      onChange={setPermissionTraining}
                      title="Uprawnienia szkoleniowe / dopuszczenie"
                      description="Zaznacz, je�eli posiadasz inne uprawnienia zwi�zane ze szkoleniem lub u�ytkowaniem broni."
                    />

                    <CheckboxField
                      checked={permissionPersonalProtection}
                      onChange={setPermissionPersonalProtection}
                      title="Ochrona osobista"
                      description="Zaznacz, je�eli posiadasz uprawnienia w zakresie ochrony osobistej."
                    />

                    <CheckboxField
                      checked={permissionOther}
                      onChange={setPermissionOther}
                      title="Inne uprawnienia"
                      description="Zaznacz, je�eli posiadasz inne uprawnienia niewymienione powy�ej."
                    />
                  </div>

                  <h3 className="mt-8 mb-4 text-lg font-semibold">
                    Dodatkowe kwalifikacje
                  </h3>

                  <div className="grid gap-4 md:grid-cols-2">
                    <CheckboxField
                      checked={qualificationInstructor}
                      onChange={setQualificationInstructor}
                      title="Instruktor strzelectwa"
                      description="Zaznacz, je�eli posiadasz kwalifikacje instruktorskie."
                    />

                    <CheckboxField
                      checked={qualificationRangeOfficer}
                      onChange={setQualificationRangeOfficer}
                      title="Prowadz�cy strzelanie / Range Officer"
                      description="Zaznacz, je�eli posiadasz uprawnienia prowadz�cego strzelanie."
                    />

                    <CheckboxField
                      checked={qualificationPzssLicense}
                      onChange={setQualificationPzssLicense}
                      title="Licencja PZSS"
                      description="Zaznacz, je�eli posiadasz aktualn� licencj� PZSS."
                    />

                    <CheckboxField
                      checked={qualificationHunter}
                      onChange={setQualificationHunter}
                      title="My�liwy"
                      description="Zaznacz, je�eli jeste� my�liwym i posiadasz odpowiednie uprawnienia."
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
                      placeholder="ul. Przyk�adowa"
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

                <div className="mt-2 border-t border-zinc-800 pt-5">
                  <h2 className="mb-4 text-xl font-semibold">
                    Bezpiecze�stwo konta
                  </h2>

                  <p className="mb-5 text-sm text-zinc-400">
                    Zmie� has�o do swojego konta. Nowe has�o musi mie� minimum
                    8 znak�w.
                  </p>

                  <div className="grid gap-5 md:grid-cols-2">
                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Nowe has�o
                      </label>

                      <input
                        type="password"
                        value={newPassword}
                        onChange={(event) =>
                          setNewPassword(event.target.value)
                        }
                        placeholder="Minimum 8 znak�w"
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-yellow-600"
                      />
                    </div>

                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Powt�rz has�o
                      </label>

                      <input
                        type="password"
                        value={repeatPassword}
                        onChange={(event) =>
                          setRepeatPassword(event.target.value)
                        }
                        placeholder="Powt�rz nowe has�o"
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
                    {savingPassword ? "Zmiana has�a..." : "Zmie� has�o"}
                  </button>
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
            � Panel klienta
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