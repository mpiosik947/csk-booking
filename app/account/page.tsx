"use client";
import PlatformBrand from "@/app/_components/PlatformBrand";

import { useEffect, useState } from "react";
import Link from "next/link";
import {
  getPasswordLengthError,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
} from "../../lib/password-policy";
import {
  getPasswordUpdateErrorMessage,
  reportClientError,
} from "../../lib/safe-client-error";
import { supabase } from "../../lib/supabase";

type ProfileData = {
  first_name: string | null;
  last_name: string | null;
  full_name: string | null;
  phone: string | null;
  postal_code: string | null;
  city: string | null;
  street: string | null;
  house_number: string | null;
  apartment_number: string | null;
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

};

type PermissionValues = {
  permissionSport: boolean;
  permissionCollector: boolean;
  permissionHunting: boolean;
  permissionTraining: boolean;
  permissionPersonalProtection: boolean;
  permissionOther: boolean;
  qualificationInstructor: boolean;
  qualificationRangeOfficer: boolean;
  qualificationPzssLicense: boolean;
  qualificationHunter: boolean;
};

type UpdateMyProfileResult = {
  ok: boolean;
  changed: boolean;
  code: string;
  declarations_changed?: boolean;
  verification_status?: string | null;
  permissions_verified?: boolean;
  permissions_verified_at?: string | null;
};

function havePermissionValuesChanged(
  initialValues: PermissionValues | null,
  currentValues: PermissionValues
) {
  if (!initialValues) {
    return false;
  }

  return (
    initialValues.permissionSport !== currentValues.permissionSport ||
    initialValues.permissionCollector !== currentValues.permissionCollector ||
    initialValues.permissionHunting !== currentValues.permissionHunting ||
    initialValues.permissionTraining !== currentValues.permissionTraining ||
    initialValues.permissionPersonalProtection !==
      currentValues.permissionPersonalProtection ||
    initialValues.permissionOther !== currentValues.permissionOther ||
    initialValues.qualificationInstructor !==
      currentValues.qualificationInstructor ||
    initialValues.qualificationRangeOfficer !==
      currentValues.qualificationRangeOfficer ||
    initialValues.qualificationPzssLicense !==
      currentValues.qualificationPzssLicense ||
    initialValues.qualificationHunter !== currentValues.qualificationHunter
  );
}

function getMessageClass(message: string) {
  if (
    message.includes("zapisane") ||
    message.includes("zmienione") ||
    message.includes("eksport")
  ) {
    return "rounded-xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm font-semibold text-[#a9d4ad]";
  }

  return "rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]";
}

function onlyDigits(value: string, maxLength: number) {
  return value.replace(/\D/g, "").slice(0, maxLength);
}

function splitPostalCode(postalCode: string | null | undefined) {
  const digits = onlyDigits(postalCode ?? "", 5);

  return {
    partOne: digits.slice(0, 2),
    partTwo: digits.slice(2, 5),
  };
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
    <label className="flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border border-[#303A2D] bg-[#111712] p-4 text-sm text-[#A6ADA5] transition hover:border-[#697A2F]">
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        className="mt-1 accent-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
      />

      <span>
        <span className="block font-semibold text-[#F4F3EE]">{title}</span>

        {description && (
          <span className="mt-1 block text-xs leading-5 text-[#A6ADA5]">
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
  const [exportingData, setExportingData] = useState(false);
  const [deletingAccount, setDeletingAccount] = useState(false);
  const [showDeleteConfirmation, setShowDeleteConfirmation] = useState(false);
  const [deleteConfirmation, setDeleteConfirmation] = useState("");

  const [email, setEmail] = useState("");
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");

  const [postalCodePartOne, setPostalCodePartOne] = useState("");
  const [postalCodePartTwo, setPostalCodePartTwo] = useState("");
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
  const [initialPermissionValues, setInitialPermissionValues] =
    useState<PermissionValues | null>(null);


  const [newPassword, setNewPassword] = useState("");
  const [repeatPassword, setRepeatPassword] = useState("");

  const [message, setMessage] = useState("");
  const [isLoggedIn, setIsLoggedIn] = useState(false);

  async function loadUser() {
    setLoading(true);
    setMessage("");

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError) {
      reportClientError("Account user read failed", userError);
      setMessage("Nie udało się pobrać danych konta. Spróbuj ponownie.");
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

    setFirstName(metadata.first_name ?? "");
    setLastName(metadata.last_name ?? "");
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
        first_name,
        last_name,
        full_name,
        phone,
        postal_code,
        city,
        street,
        house_number,
        apartment_number,

        permission_sport,
        permission_collector,
        permission_hunting,
        permission_training,
        permission_personal_protection,
        permission_other,

        qualification_instructor,
        qualification_range_officer,
        qualification_pzss_license,
        qualification_hunter
      `
      )
      .eq("user_id", user.id)
      .maybeSingle();

    if (profileError) {
      reportClientError("Account profile read failed", profileError);
      setMessage("Nie udało się pobrać profilu. Spróbuj ponownie.");
      setLoading(false);
      return;
    }

    if (profile) {
      const profileData = profile as ProfileData;

      setFirstName(profileData.first_name ?? metadata.first_name ?? "");
      setLastName(profileData.last_name ?? metadata.last_name ?? "");
      setFullName(profileData.full_name ?? metadata.full_name ?? "");
      setPhone(profileData.phone ?? metadata.phone ?? "");

      const postalCodeParts = splitPostalCode(profileData.postal_code);
      setPostalCodePartOne(postalCodeParts.partOne);
      setPostalCodePartTwo(postalCodeParts.partTwo);

      setCity(profileData.city ?? "");
      setStreet(profileData.street ?? "");
      setHouseNumber(profileData.house_number ?? "");
      setApartmentNumber(profileData.apartment_number ?? "");

      const loadedPermissionValues: PermissionValues = {
        permissionSport: Boolean(profileData.permission_sport),
        permissionCollector: Boolean(profileData.permission_collector),
        permissionHunting: Boolean(profileData.permission_hunting),
        permissionTraining: Boolean(profileData.permission_training),
        permissionPersonalProtection: Boolean(
          profileData.permission_personal_protection
        ),
        permissionOther: Boolean(profileData.permission_other),
        qualificationInstructor: Boolean(profileData.qualification_instructor),
        qualificationRangeOfficer: Boolean(
          profileData.qualification_range_officer
        ),
        qualificationPzssLicense: Boolean(
          profileData.qualification_pzss_license
        ),
        qualificationHunter: Boolean(profileData.qualification_hunter),
      };

      setPermissionSport(loadedPermissionValues.permissionSport);
      setPermissionCollector(loadedPermissionValues.permissionCollector);
      setPermissionHunting(loadedPermissionValues.permissionHunting);
      setPermissionTraining(loadedPermissionValues.permissionTraining);
      setPermissionPersonalProtection(
        loadedPermissionValues.permissionPersonalProtection
      );
      setPermissionOther(loadedPermissionValues.permissionOther);

      setQualificationInstructor(
        loadedPermissionValues.qualificationInstructor
      );
      setQualificationRangeOfficer(
        loadedPermissionValues.qualificationRangeOfficer
      );
      setQualificationPzssLicense(
        loadedPermissionValues.qualificationPzssLicense
      );
      setQualificationHunter(loadedPermissionValues.qualificationHunter);
      setInitialPermissionValues(loadedPermissionValues);

    } else {
      setInitialPermissionValues({
        permissionSport: false,
        permissionCollector: false,
        permissionHunting: false,
        permissionTraining: false,
        permissionPersonalProtection: false,
        permissionOther: false,
        qualificationInstructor: false,
        qualificationRangeOfficer: false,
        qualificationPzssLicense: false,
        qualificationHunter: false,
      });
    }

    setLoading(false);
  }

  useEffect(() => {
    // Run the initial async read after the effect; avoid synchronous state updates.
    void Promise.resolve().then(loadUser);
  }, []);

  function validateProfile() {
    if (!phone.trim()) {
      return "Uzupełnij numer telefonu.";
    }

    if (postalCodePartOne.length !== 2 || postalCodePartTwo.length !== 3) {
      return "Uzupełnij kod pocztowy w formacie XX-XXX.";
    }

    if (!city.trim()) {
      return "Uzupełnij miasto.";
    }

    if (!street.trim()) {
      return "Uzupełnij ulicę.";
    }

    if (!houseNumber.trim()) {
      return "Uzupełnij numer domu.";
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
      setMessage("Nie udało się pobrać zalogowanego użytkownika.");
      return;
    }

    const postalCode = `${postalCodePartOne}-${postalCodePartTwo}`;
    const currentPermissionValues: PermissionValues = {
      permissionSport,
      permissionCollector,
      permissionHunting,
      permissionTraining,
      permissionPersonalProtection,
      permissionOther,
      qualificationInstructor,
      qualificationRangeOfficer,
      qualificationPzssLicense,
      qualificationHunter,
    };
    const permissionsChanged = havePermissionValuesChanged(
      initialPermissionValues,
      currentPermissionValues
    );

    const { error: authError } = await supabase.auth.updateUser({
      data: {
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
      reportClientError("Account metadata update failed", authError);
      setMessage("Nie udało się zapisać danych konta. Spróbuj ponownie.");
      return;
    }

    const { data: profileResultData, error: profileError } = await supabase.rpc(
      "update_my_profile_v2",
      {
        p_phone: phone.trim(),
        p_postal_code: postalCode,
        p_city: city.trim(),
        p_street: street.trim(),
        p_house_number: houseNumber.trim(),
        p_apartment_number: apartmentNumber.trim() || null,
        p_permission_sport: permissionSport,
        p_permission_collector: permissionCollector,
        p_permission_hunting: permissionHunting,
        p_permission_training: permissionTraining,
        p_permission_personal_protection: permissionPersonalProtection,
        p_permission_other: permissionOther,
        p_qualification_instructor: qualificationInstructor,
        p_qualification_range_officer: qualificationRangeOfficer,
        p_qualification_pzss_license: qualificationPzssLicense,
        p_qualification_hunter: qualificationHunter,
      }
    );

    setSavingProfile(false);

    const profileResult = profileResultData as UpdateMyProfileResult | null;
    if (profileError || !profileResult?.ok) {
      reportClientError("Account profile update failed", profileError);
      setMessage(
        "Dane konta zapisane, ale nie udało się zaktualizować profilu. Spróbuj ponownie."
      );
      return;
    }

    if (permissionsChanged || profileResult.declarations_changed) {
      setInitialPermissionValues(currentPermissionValues);
      setMessage(
        "Dane zostały zapisane. Zmiana deklarowanych uprawnień wymaga ponownej weryfikacji przez pracownika."
      );
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

    const passwordLengthError = getPasswordLengthError(newPassword);
    if (passwordLengthError) {
      setMessage(passwordLengthError);
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
      reportClientError("Account password update failed", error);
      setMessage(getPasswordUpdateErrorMessage(error, "account"));
      return;
    }

    setNewPassword("");
    setRepeatPassword("");
    setMessage("Hasło zostało zmienione.");
  }

  async function exportMyData() {
    if (exportingData || deletingAccount) {
      return;
    }

    setMessage("");
    setExportingData(true);

    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        setMessage("Sesja wygasła. Zaloguj się ponownie.");
        return;
      }

      const response = await fetch("/api/account/export", {
        method: "GET",
        headers: { Authorization: `Bearer ${session.access_token}` },
        cache: "no-store",
      });

      if (!response.ok) {
        setMessage("Nie udało się przygotować eksportu.");
        return;
      }

      const blob = await response.blob();
      const downloadUrl = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = downloadUrl;
      link.download = "csk-booking-my-data.json";
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(downloadUrl);
      setMessage("Przygotowano eksport Twoich danych.");
    } catch {
      setMessage("Nie udało się przygotować eksportu.");
    } finally {
      setExportingData(false);
    }
  }

  async function deleteMyAccount() {
    if (deletingAccount || deleteConfirmation !== "USUŃ KONTO") {
      return;
    }

    setMessage("");
    setDeletingAccount(true);

    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        setMessage("Sesja wygasła. Zaloguj się ponownie.");
        return;
      }

      const response = await fetch("/api/account/delete", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ confirmation: deleteConfirmation }),
      });
      if (!response.ok) {
        setMessage("Nie udało się usunąć konta.");
        return;
      }

      await supabase.auth.signOut();
      window.location.assign("/");
    } catch {
      setMessage("Nie udało się usunąć konta.");
    } finally {
      setDeletingAccount(false);
    }
  }

  const displayName =
    [firstName.trim(), lastName.trim()].filter(Boolean).join(" ") ||
    fullName.trim();
  const hasMissingStructuredName =
    !firstName.trim() || !lastName.trim();

  return (
    <main className="platform-ui min-h-screen bg-[#080B09] px-4 py-6 text-[#F4F3EE] sm:px-6 sm:py-8">
      <section className="mx-auto w-full max-w-6xl rounded-[2rem] border border-[#303A2D] bg-[#111712] p-5 shadow-2xl shadow-black/30 sm:p-8">
        <header className="mb-8 flex flex-col gap-5 border-b border-[#303A2D] pb-6 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0">
            <div className="mb-4"><PlatformBrand compact /></div>

            <h1 className="text-3xl font-bold text-[#F4F3EE] sm:text-4xl">
              Moje konto
            </h1>
            <Link href="/continuity" className="mt-3 inline-block underline text-[#F5A900]">Historia i obsługa istniejących zobowiązań</Link>

            {displayName && (
              <p className="mt-3 break-words text-lg font-semibold text-[#F4F3EE]">
                {displayName}
              </p>
            )}

            <p className="mt-3 max-w-3xl text-[#A6ADA5]">
              Zarządzaj swoimi danymi użytkownika, adresem, deklarowanymi
              uprawnieniami i bezpieczeństwem konta.
            </p>
          </div>

          <Link
            href="/dashboard"
            className="inline-flex min-h-11 shrink-0 items-center justify-center rounded-xl border border-[#303A2D] bg-[#182019] px-5 py-3 text-center text-sm font-semibold text-[#A6ADA5] transition hover:border-[#697A2F] hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
          >
            ← Panel klienta
          </Link>
        </header>

        {loading && (
          <div role="status" className="rounded-2xl border border-[#303A2D] bg-[#182019] p-6 text-[#A6ADA5]">
            Ładowanie konta...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-8 text-center">
            <h2 className="mb-3 text-2xl font-bold text-[#e0a0a0]">
              Logowanie wymagane
            </h2>

            <p className="mx-auto mb-6 max-w-xl text-[#e0a0a0]">
              Aby przejść do swojego konta, musisz się zalogować.
            </p>

            <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
              <Link
                href="/login"
                className="min-h-12 rounded-xl bg-[#697A2F] px-5 py-3 font-semibold text-[#F4F3EE] transition hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Zaloguj się
              </Link>

              <Link
                href="/register"
                className="min-h-12 rounded-xl border border-[#744545] px-5 py-3 font-semibold text-[#e0a0a0] transition hover:bg-[#3a2222] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Utwórz konto
              </Link>
            </div>
          </div>
        )}

        {!loading && isLoggedIn && (
          <div className="grid gap-6">
            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
              <h2 className="mb-5 text-xl font-semibold text-[#F4F3EE]">
                Dane konta
              </h2>

              <div className="grid gap-5">
                <div>
                  <label
                    htmlFor="account-email"
                    className="mb-2 block text-sm text-[#A6ADA5]"
                  >
                    Adres e-mail
                  </label>

                  <input
                    id="account-email"
                    type="email"
                    value={email}
                    disabled
                    className="min-h-12 w-full cursor-default rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#A6ADA5] outline-none disabled:opacity-100"
                  />
                </div>

                <div className="grid gap-5 md:grid-cols-2">
                  <div>
                    <label
                      htmlFor="account-first-name"
                      className="mb-2 block text-sm text-[#A6ADA5]"
                    >
                      Imię
                    </label>

                    <input
                      id="account-first-name"
                      type="text"
                      autoComplete="given-name"
                      value={firstName}
                      readOnly
                      aria-readonly="true"
                      className="min-h-12 w-full cursor-default rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#A6ADA5] outline-none"
                    />
                  </div>

                  <div>
                    <label
                      htmlFor="account-last-name"
                      className="mb-2 block text-sm text-[#A6ADA5]"
                    >
                      Nazwisko
                    </label>

                    <input
                      id="account-last-name"
                      type="text"
                      autoComplete="family-name"
                      value={lastName}
                      readOnly
                      aria-readonly="true"
                      className="min-h-12 w-full cursor-default rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#A6ADA5] outline-none"
                    />
                  </div>
                </div>

                <p className="rounded-xl border border-[#303A2D] bg-[#111712] p-4 text-sm leading-6 text-[#A6ADA5]">
                  Imię i nazwisko są przypisane do konta i mogą zostać
                  zmienione wyłącznie przez obsługę.
                </p>

                {hasMissingStructuredName && (
                  <div className="rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]">
                    Dane imienia i nazwiska wymagają uzupełnienia przez obsługę.
                  </div>
                )}

              </div>
            </section>

            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
              <h2 className="mb-5 text-xl font-semibold text-[#F4F3EE]">
                Dane kontaktowe
              </h2>

              <div className="grid gap-5">
                <div>
                  <label
                    htmlFor="account-phone"
                    className="mb-2 block text-sm text-[#A6ADA5]"
                  >
                    Numer telefonu *
                  </label>

                  <input
                    id="account-phone"
                    type="tel"
                    value={phone}
                    onChange={(event) => setPhone(event.target.value)}
                    className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#F4F3EE] outline-none placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                  />
                </div>

              </div>
            </section>

            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#F4F3EE]">
                    Deklarowane uprawnienia
                  </h2>

                  <p className="mb-5 text-sm leading-6 text-[#A6ADA5]">
                    Zaznacz, jakie uprawnienia posiadasz. Nie wpisuj numerów
                    dokumentów. Dokumenty okazujesz wyłącznie do wglądu
                    pracownikowi podczas wizyty.
                  </p>

                  <div className="mb-5 rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]">
                    Zmiana deklarowanych uprawnień lub kwalifikacji spowoduje
                    ponowną weryfikację konta przez pracownika.
                  </div>

                  <div className="mb-5 rounded-xl border border-[#303A2D] bg-[#111712] p-4 text-sm text-[#A6ADA5]">
                    <p className="font-semibold">
                      Minimalizacja danych osobowych
                    </p>

                    <p className="mt-1 text-[#A6ADA5]">
                      System zapisuje tylko deklarowany typ uprawnień i fakt
                      późniejszej weryfikacji. Numery dokumentów nie są tutaj
                      wymagane.
                    </p>
                  </div>

                  <div className="grid gap-4 md:grid-cols-2">
                    <CheckboxField
                      checked={permissionSport}
                      onChange={setPermissionSport}
                      title="Pozwolenie sportowe"
                      description="Zaznacz, jeżeli posiadasz uprawnienia/pozwolenie do celów sportowych."
                    />

                    <CheckboxField
                      checked={permissionCollector}
                      onChange={setPermissionCollector}
                      title="Pozwolenie kolekcjonerskie"
                      description="Zaznacz, jeżeli posiadasz uprawnienia/pozwolenie do celów kolekcjonerskich."
                    />

                    <CheckboxField
                      checked={permissionHunting}
                      onChange={setPermissionHunting}
                      title="Pozwolenie myśliwskie / łowieckie"
                      description="Zaznacz, jeżeli posiadasz uprawnienia związane z łowiectwem."
                    />

                    <CheckboxField
                      checked={permissionTraining}
                      onChange={setPermissionTraining}
                      title="Uprawnienia szkoleniowe / dopuszczenie"
                      description="Zaznacz, jeżeli posiadasz inne uprawnienia związane ze szkoleniem lub użytkowaniem broni."
                    />

                    <CheckboxField
                      checked={permissionPersonalProtection}
                      onChange={setPermissionPersonalProtection}
                      title="Ochrona osobista"
                      description="Zaznacz, jeżeli posiadasz uprawnienia w zakresie ochrony osobistej."
                    />

                    <CheckboxField
                      checked={permissionOther}
                      onChange={setPermissionOther}
                      title="Inne uprawnienia"
                      description="Zaznacz, jeżeli posiadasz inne uprawnienia niewymienione powyżej."
                    />
                  </div>

            </section>

            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#F4F3EE]">
                    Kwalifikacje dodatkowe
                  </h2>

                  <div className="grid gap-4 md:grid-cols-2">
                    <CheckboxField
                      checked={qualificationInstructor}
                      onChange={setQualificationInstructor}
                      title="Instruktor strzelectwa"
                      description="Zaznacz, jeżeli posiadasz kwalifikacje instruktorskie."
                    />

                    <CheckboxField
                      checked={qualificationRangeOfficer}
                      onChange={setQualificationRangeOfficer}
                      title="Prowadzący strzelanie / Range Officer"
                      description="Zaznacz, jeżeli posiadasz uprawnienia prowadzącego strzelanie."
                    />

                    <CheckboxField
                      checked={qualificationPzssLicense}
                      onChange={setQualificationPzssLicense}
                      title="Licencja PZSS"
                      description="Zaznacz, jeżeli posiadasz aktualną licencję PZSS."
                    />

                    <CheckboxField
                      checked={qualificationHunter}
                      onChange={setQualificationHunter}
                      title="Myśliwy"
                      description="Zaznacz, jeżeli jesteś myśliwym i posiadasz odpowiednie uprawnienia."
                    />
                  </div>
            </section>

            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
              <h2 className="mb-4 text-xl font-semibold text-[#F4F3EE]">Weryfikacja w lokalizacji</h2>
              <p className="text-sm leading-6 text-[#A6ADA5]">
                Status weryfikacji uprawnień dotyczy konkretnej strzelnicy. Sprawdź go po wybraniu lokalizacji;
                ten globalny profil nie przedstawia statusu żadnej lokalizacji jako statusu całego konta.
              </p>
            </section>

            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#F4F3EE]">
                    Adres
                  </h2>

                  <p className="mb-5 text-sm leading-6 text-[#A6ADA5]">
                    Podaj dane adresowe bez wpisywania przykładowych wartości.
                    Kod pocztowy wpisz w dwóch polach, zgodnie z formatem
                    XX-XXX.
                  </p>

                  <div>
                    <p className="mb-2 block text-sm text-[#A6ADA5]">
                      Kod pocztowy *
                    </p>

                    <div className="flex max-w-xs items-center gap-3">
                      <input
                        type="text"
                        inputMode="numeric"
                        value={postalCodePartOne}
                        onChange={(event) =>
                          setPostalCodePartOne(onlyDigits(event.target.value, 2))
                        }
                        maxLength={2}
                        aria-label="Pierwsze dwie cyfry kodu pocztowego"
                        className="min-h-12 w-20 rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-center text-[#F4F3EE] outline-none focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                      />

                      <span className="text-[#A6ADA5]">-</span>

                      <input
                        type="text"
                        inputMode="numeric"
                        value={postalCodePartTwo}
                        onChange={(event) =>
                          setPostalCodePartTwo(onlyDigits(event.target.value, 3))
                        }
                        maxLength={3}
                        aria-label="Ostatnie trzy cyfry kodu pocztowego"
                        className="min-h-12 w-24 rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-center text-[#F4F3EE] outline-none focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                      />
                    </div>
                  </div>

                  <div className="mt-5">
                    <label
                      htmlFor="account-city"
                      className="mb-2 block text-sm text-[#A6ADA5]"
                    >
                      Miasto / miejscowość *
                    </label>

                    <input
                      id="account-city"
                      type="text"
                      value={city}
                      onChange={(event) => setCity(event.target.value)}
                      className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#F4F3EE] outline-none placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                    />
                  </div>

                  <div className="mt-5">
                    <label
                      htmlFor="account-street"
                      className="mb-2 block text-sm text-[#A6ADA5]"
                    >
                      Ulica *
                    </label>

                    <input
                      id="account-street"
                      type="text"
                      value={street}
                      onChange={(event) => setStreet(event.target.value)}
                      className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#F4F3EE] outline-none placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                    />

                    <p className="mt-2 text-xs text-[#A6ADA5]">
                      Podaj ulicę, numer domu i opcjonalnie numer mieszkania w
                      osobnych polach poniżej.
                    </p>
                  </div>

                  <div className="mt-5 grid gap-5 md:grid-cols-2">
                    <div>
                      <label
                        htmlFor="account-house-number"
                        className="mb-2 block text-sm text-[#A6ADA5]"
                      >
                        Numer domu *
                      </label>

                      <input
                        id="account-house-number"
                        type="text"
                        value={houseNumber}
                        onChange={(event) => setHouseNumber(event.target.value)}
                        className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#F4F3EE] outline-none placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                      />
                    </div>

                    <div>
                      <label
                        htmlFor="account-apartment-number"
                        className="mb-2 block text-sm text-[#A6ADA5]"
                      >
                        Numer mieszkania
                      </label>

                      <input
                        id="account-apartment-number"
                        type="text"
                        value={apartmentNumber}
                        onChange={(event) =>
                          setApartmentNumber(event.target.value)
                        }
                        className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#F4F3EE] outline-none placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                      />
                    </div>
                  </div>
            </section>

            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#F4F3EE]">
                    Bezpieczeństwo konta
                  </h2>

                  <p className="mb-5 text-sm text-[#A6ADA5]">
                    Zmień hasło do swojego konta. Nowe hasło musi mieć minimum
                    {` ${PASSWORD_MIN_LENGTH} znaków.`}
                  </p>

                  <div className="grid gap-5 md:grid-cols-2">
                    <div>
                      <label
                        htmlFor="account-new-password"
                        className="mb-2 block text-sm text-[#A6ADA5]"
                      >
                        Nowe hasło
                      </label>

                      <input
                        id="account-new-password"
                        type="password"
                        value={newPassword}
                        onChange={(event) =>
                          setNewPassword(event.target.value)
                        }
                        minLength={PASSWORD_MIN_LENGTH}
                        maxLength={PASSWORD_MAX_LENGTH}
                        placeholder={`Minimum ${PASSWORD_MIN_LENGTH} znaków`}
                        className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#F4F3EE] outline-none placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                      />
                    </div>

                    <div>
                      <label
                        htmlFor="account-repeat-password"
                        className="mb-2 block text-sm text-[#A6ADA5]"
                      >
                        Powtórz hasło
                      </label>

                      <input
                        id="account-repeat-password"
                        type="password"
                        value={repeatPassword}
                        onChange={(event) =>
                          setRepeatPassword(event.target.value)
                        }
                        minLength={PASSWORD_MIN_LENGTH}
                        maxLength={PASSWORD_MAX_LENGTH}
                        placeholder="Powtórz nowe hasło"
                        className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-4 py-3 text-[#F4F3EE] outline-none placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                      />
                    </div>
                  </div>

                  <button
                    type="button"
                    onClick={changePassword}
                    disabled={savingPassword}
                    className="mt-5 min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#111712] px-5 py-3 font-semibold text-[#F5A900] transition hover:border-[#697A2F] hover:text-[#F4F3EE] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019] disabled:cursor-not-allowed disabled:text-[#A6ADA5] sm:w-auto"
                  >
                    {savingPassword ? "Zmiana hasła..." : "Zmień hasło"}
                  </button>
            </section>

            <section className="rounded-2xl border border-[#303A2D] bg-[#182019] p-4 sm:p-6">
              <h2 className="mb-4 text-xl font-semibold text-[#F4F3EE]">
                Twoje dane i konto
              </h2>

              <p className="mb-5 text-sm leading-6 text-[#A6ADA5]">
                Możesz pobrać wersjonowany eksport swoich danych albo trwale
                zamknąć konto. Eksport nie zawiera haseł, tokenów ani notatek
                administracyjnych.
              </p>

              <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap">
                <button
                  type="button"
                  onClick={exportMyData}
                  disabled={exportingData || deletingAccount}
                  className="min-h-12 rounded-xl border border-[#303A2D] bg-[#111712] px-5 py-3 font-semibold text-[#F5A900] transition hover:border-[#697A2F] hover:text-[#F4F3EE] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019] disabled:cursor-not-allowed disabled:text-[#A6ADA5]"
                >
                  {exportingData ? "Przygotowywanie eksportu..." : "Pobierz moje dane"}
                </button>

                <button
                  type="button"
                  onClick={() => {
                    setDeleteConfirmation("");
                    setShowDeleteConfirmation(true);
                  }}
                  disabled={deletingAccount || exportingData}
                  className="min-h-12 rounded-xl border border-[#744545] bg-[#2a1b1b] px-5 py-3 font-semibold text-[#e0a0a0] transition hover:bg-[#3a2222] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019] disabled:cursor-not-allowed disabled:opacity-60"
                >
                  Usuń konto
                </button>
              </div>
            </section>

                {message && (
                  <div
                    role={
                      message.includes("zapisane") ||
                      message.includes("zmienione")
                        ? "status"
                        : "alert"
                    }
                    className={getMessageClass(message)}
                  >
                    {message}
                  </div>
                )}

                <button
                  type="button"
                  onClick={saveProfile}
                  disabled={savingProfile}
                  className="platform-primary min-h-12 w-full rounded-xl border border-[#697A2F] bg-[#697A2F] px-4 py-3 font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:border-[#303A2D] disabled:bg-[#303A2D] disabled:text-[#A6ADA5]"
                >
                  {savingProfile ? "Zapisywanie..." : "Zapisz dane"}
                </button>
          </div>
        )}

        {showDeleteConfirmation && (
          <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 px-4 py-6">
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="delete-account-title"
              aria-describedby="delete-account-description"
              className="w-full max-w-xl rounded-[2rem] border border-[#744545] bg-[#111712] p-6 shadow-2xl shadow-black/50 sm:p-8"
            >
              <h2
                id="delete-account-title"
                className="text-2xl font-bold text-[#e0a0a0]"
              >
                Trwale usunąć konto?
              </h2>

              <div
                id="delete-account-description"
                className="mt-4 space-y-3 text-sm leading-6 text-[#A6ADA5]"
              >
                <p>
                  Dane profilu zostaną usunięte. Historyczne rezerwacje i
                  zapisy na szkolenia pozostaną wyłącznie jako zanonimizowane
                  dane operacyjne i statystyczne.
                </p>
                <p>
                  Aktywne tokeny zostaną unieważnione, a notatki zawierające
                  dane konta usunięte. Tej operacji nie można cofnąć.
                </p>
              </div>

              <label
                htmlFor="delete-account-confirmation"
                className="mt-6 block text-sm font-semibold text-[#F4F3EE]"
              >
                Wpisz <span className="text-[#e0a0a0]">USUŃ KONTO</span>, aby
                potwierdzić
              </label>
              <input
                id="delete-account-confirmation"
                type="text"
                value={deleteConfirmation}
                onChange={(event) => setDeleteConfirmation(event.target.value)}
                disabled={deletingAccount}
                autoComplete="off"
                className="mt-2 min-h-12 w-full rounded-xl border border-[#744545] bg-[#182019] px-4 py-3 text-[#F4F3EE] outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
              />

              <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                <button
                  type="button"
                  onClick={() => setShowDeleteConfirmation(false)}
                  disabled={deletingAccount}
                  className="min-h-12 rounded-xl border border-[#303A2D] px-5 py-3 font-semibold text-[#A6ADA5] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] disabled:opacity-60"
                >
                  Anuluj
                </button>
                <button
                  type="button"
                  onClick={deleteMyAccount}
                  disabled={
                    deletingAccount || deleteConfirmation !== "USUŃ KONTO"
                  }
                  className="min-h-12 rounded-xl border border-[#744545] bg-[#7a3030] px-5 py-3 font-semibold text-white transition hover:bg-[#963d3d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:bg-[#303A2D] disabled:text-[#A6ADA5]"
                >
                  {deletingAccount ? "Usuwanie konta..." : "Potwierdź usunięcie"}
                </button>
              </div>
            </div>
          </div>
        )}

        <nav
          aria-label="Pozostałe strony konta"
          className="mt-8 flex flex-col gap-3 border-t border-[#303A2D] pt-6 sm:flex-row"
        >
          <Link
            href="/dashboard"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#303A2D] bg-[#182019] px-5 py-3 text-center text-sm font-semibold text-[#A6ADA5] transition hover:border-[#697A2F] hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
          >
            Wybierz lokalizację dla rezerwacji
          </Link>

          <Link
            href="/dashboard"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#303A2D] bg-[#182019] px-5 py-3 text-center text-sm font-semibold text-[#A6ADA5] transition hover:border-[#697A2F] hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
          >
            Wybierz lokalizację dla szkoleń
          </Link>
        </nav>
      </section>
    </main>
  );
}
