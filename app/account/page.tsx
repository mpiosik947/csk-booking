"use client";

import { useEffect, useState } from "react";
import {
  getPasswordLengthError,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
} from "../../lib/password-policy";
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

function getVerificationLabel(status: string) {
  switch (status) {
    case "verified":
      return "Zweryfikowane";
    case "pending":
      return "Oczekuje na weryfikację";
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
    return "rounded-xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm text-[#a9d4ad]";
  }

  if (status === "rejected") {
    return "rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm text-[#e0a0a0]";
  }

  if (status === "pending") {
    return "rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]";
  }

  return "rounded-xl border border-[#343a31] bg-[#171a17] p-4 text-sm text-[#a9ada4]";
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
    <label className="flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border border-[#30372c] bg-[#141814] p-4 text-sm text-[#a9ada4] transition hover:border-[#536143]">
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        className="mt-1 accent-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
      />

      <span>
        <span className="block font-semibold text-[#f2efe4]">{title}</span>

        {description && (
          <span className="mt-1 block text-xs leading-5 text-[#858c7f]">
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
      setMessage(`Błąd pobierania użytkownika: ${userError.message}`);
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
      setMessage(`Błąd pobierania profilu: ${profileError.message}`);
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

      setVerificationStatus(
        profileData.verification_status ?? "niezweryfikowane"
      );

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

      setPermissionsVerified(Boolean(profileData.permissions_verified));
      setPermissionsVerifiedAt(profileData.permissions_verified_at ?? "");
      setPermissionsVerificationNote(
        profileData.permissions_verification_note ?? ""
      );
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
      setMessage(`Błąd zapisu danych konta: ${authError.message}`);
      return;
    }

    const { error: profileError } = await supabase
      .from("profiles")
      .update({
        phone: phone.trim(),
        postal_code: postalCode,
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
        `Dane konta zapisane, ale nie udało się zaktualizować profilu: ${profileError.message}`
      );
      return;
    }

    if (permissionsChanged) {
      setVerificationStatus("pending");
      setPermissionsVerified(false);
      setPermissionsVerifiedAt("");
      setPermissionsVerificationNote("");
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
      setMessage(`Błąd zmiany hasła: ${error.message}`);
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
        const body = (await response.json().catch(() => null)) as
          | { error?: unknown }
          | null;
        setMessage(
          typeof body?.error === "string"
            ? body.error
            : "Nie udało się przygotować eksportu."
        );
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
      const body = (await response.json().catch(() => null)) as
        | { error?: unknown }
        | null;

      if (!response.ok) {
        setMessage(
          typeof body?.error === "string"
            ? body.error
            : "Nie udało się usunąć konta."
        );
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
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto w-full max-w-6xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/30 sm:p-8">
        <header className="mb-8 flex flex-col gap-5 border-b border-[#30372c] pb-6 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0">
            <p className="mb-3 text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">
              CSK BOOKING
            </p>

            <h1 className="text-3xl font-bold text-[#f2efe4] sm:text-4xl">
              Moje konto
            </h1>

            {displayName && (
              <p className="mt-3 break-words text-lg font-semibold text-[#f2efe4]">
                {displayName}
              </p>
            )}

            <p className="mt-3 max-w-3xl text-[#a9ada4]">
              Zarządzaj swoimi danymi użytkownika, adresem, deklarowanymi
              uprawnieniami i bezpieczeństwem konta.
            </p>
          </div>

          <a
            href="/dashboard"
            className="inline-flex min-h-11 shrink-0 items-center justify-center rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Panel klienta
          </a>
        </header>

        {loading && (
          <div role="status" className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
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
              <a
                href="/login"
                className="min-h-12 rounded-xl bg-[#536143] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="min-h-12 rounded-xl border border-[#744545] px-5 py-3 font-semibold text-[#e0a0a0] transition hover:bg-[#3a2222] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        )}

        {!loading && isLoggedIn && (
          <div className="grid gap-6">
            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
              <h2 className="mb-5 text-xl font-semibold text-[#f2efe4]">
                Dane konta
              </h2>

              <div className="grid gap-5">
                <div>
                  <label
                    htmlFor="account-email"
                    className="mb-2 block text-sm text-[#a9ada4]"
                  >
                    Adres e-mail
                  </label>

                  <input
                    id="account-email"
                    type="email"
                    value={email}
                    disabled
                    className="min-h-12 w-full cursor-default rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#858c7f] outline-none disabled:opacity-100"
                  />
                </div>

                <div className="grid gap-5 md:grid-cols-2">
                  <div>
                    <label
                      htmlFor="account-first-name"
                      className="mb-2 block text-sm text-[#a9ada4]"
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
                      className="min-h-12 w-full cursor-default rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#858c7f] outline-none"
                    />
                  </div>

                  <div>
                    <label
                      htmlFor="account-last-name"
                      className="mb-2 block text-sm text-[#a9ada4]"
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
                      className="min-h-12 w-full cursor-default rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#858c7f] outline-none"
                    />
                  </div>
                </div>

                <p className="rounded-xl border border-[#30372c] bg-[#141814] p-4 text-sm leading-6 text-[#a9ada4]">
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

            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
              <h2 className="mb-5 text-xl font-semibold text-[#f2efe4]">
                Dane kontaktowe
              </h2>

              <div className="grid gap-5">
                <div>
                  <label
                    htmlFor="account-phone"
                    className="mb-2 block text-sm text-[#a9ada4]"
                  >
                    Numer telefonu *
                  </label>

                  <input
                    id="account-phone"
                    type="tel"
                    value={phone}
                    onChange={(event) => setPhone(event.target.value)}
                    className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                  />
                </div>

              </div>
            </section>

            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#f2efe4]">
                    Deklarowane uprawnienia
                  </h2>

                  <p className="mb-5 text-sm leading-6 text-[#a9ada4]">
                    Zaznacz, jakie uprawnienia posiadasz. Nie wpisuj numerów
                    dokumentów. Dokumenty okazujesz wyłącznie do wglądu
                    pracownikowi podczas wizyty.
                  </p>

                  <div className="mb-5 rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm text-[#e1c477]">
                    Zmiana deklarowanych uprawnień lub kwalifikacji spowoduje
                    ponowną weryfikację konta przez pracownika.
                  </div>

                  <div className="mb-5 rounded-xl border border-[#30372c] bg-[#141814] p-4 text-sm text-[#a9ada4]">
                    <p className="font-semibold">
                      Minimalizacja danych osobowych
                    </p>

                    <p className="mt-1 text-[#858c7f]">
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

            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#f2efe4]">
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

            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
              <h2 className="mb-4 text-xl font-semibold text-[#f2efe4]">
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
                    ? "sprawdzone przez obsługę"
                    : "do sprawdzenia podczas wizyty"}
                </p>

                {permissionsVerifiedAt && (
                  <p className="mt-1 text-xs opacity-80">
                    Data weryfikacji:{" "}
                    {new Date(permissionsVerifiedAt).toLocaleString("pl-PL")}
                  </p>
                )}

                {permissionsVerificationNote && (
                  <p className="mt-3 break-words rounded-lg border border-[#30372c] bg-[#141814]/60 p-3 text-xs leading-5">
                    {permissionsVerificationNote}
                  </p>
                )}

                <p className="mt-3 text-xs opacity-80">
                  Pełna możliwość korzystania z systemu może wymagać
                  sprawdzenia uprawnień przez pracownika CSK podczas wizyty na
                  strzelnicy.
                </p>
              </div>
            </section>

            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#f2efe4]">
                    Adres
                  </h2>

                  <p className="mb-5 text-sm leading-6 text-[#a9ada4]">
                    Podaj dane adresowe bez wpisywania przykładowych wartości.
                    Kod pocztowy wpisz w dwóch polach, zgodnie z formatem
                    XX-XXX.
                  </p>

                  <div>
                    <p className="mb-2 block text-sm text-[#a9ada4]">
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
                        className="min-h-12 w-20 rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-center text-[#f2efe4] outline-none focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                      />

                      <span className="text-[#858c7f]">-</span>

                      <input
                        type="text"
                        inputMode="numeric"
                        value={postalCodePartTwo}
                        onChange={(event) =>
                          setPostalCodePartTwo(onlyDigits(event.target.value, 3))
                        }
                        maxLength={3}
                        aria-label="Ostatnie trzy cyfry kodu pocztowego"
                        className="min-h-12 w-24 rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-center text-[#f2efe4] outline-none focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                      />
                    </div>
                  </div>

                  <div className="mt-5">
                    <label
                      htmlFor="account-city"
                      className="mb-2 block text-sm text-[#a9ada4]"
                    >
                      Miasto / miejscowość *
                    </label>

                    <input
                      id="account-city"
                      type="text"
                      value={city}
                      onChange={(event) => setCity(event.target.value)}
                      className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                    />
                  </div>

                  <div className="mt-5">
                    <label
                      htmlFor="account-street"
                      className="mb-2 block text-sm text-[#a9ada4]"
                    >
                      Ulica *
                    </label>

                    <input
                      id="account-street"
                      type="text"
                      value={street}
                      onChange={(event) => setStreet(event.target.value)}
                      className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                    />

                    <p className="mt-2 text-xs text-[#858c7f]">
                      Podaj ulicę, numer domu i opcjonalnie numer mieszkania w
                      osobnych polach poniżej.
                    </p>
                  </div>

                  <div className="mt-5 grid gap-5 md:grid-cols-2">
                    <div>
                      <label
                        htmlFor="account-house-number"
                        className="mb-2 block text-sm text-[#a9ada4]"
                      >
                        Numer domu *
                      </label>

                      <input
                        id="account-house-number"
                        type="text"
                        value={houseNumber}
                        onChange={(event) => setHouseNumber(event.target.value)}
                        className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                      />
                    </div>

                    <div>
                      <label
                        htmlFor="account-apartment-number"
                        className="mb-2 block text-sm text-[#a9ada4]"
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
                        className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                      />
                    </div>
                  </div>
            </section>

            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
                  <h2 className="mb-4 text-xl font-semibold text-[#f2efe4]">
                    Bezpieczeństwo konta
                  </h2>

                  <p className="mb-5 text-sm text-[#a9ada4]">
                    Zmień hasło do swojego konta. Nowe hasło musi mieć minimum
                    {` ${PASSWORD_MIN_LENGTH} znaków.`}
                  </p>

                  <div className="grid gap-5 md:grid-cols-2">
                    <div>
                      <label
                        htmlFor="account-new-password"
                        className="mb-2 block text-sm text-[#a9ada4]"
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
                        className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                      />
                    </div>

                    <div>
                      <label
                        htmlFor="account-repeat-password"
                        className="mb-2 block text-sm text-[#a9ada4]"
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
                        className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-4 py-3 text-[#f2efe4] outline-none placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                      />
                    </div>
                  </div>

                  <button
                    type="button"
                    onClick={changePassword}
                    disabled={savingPassword}
                    className="mt-5 min-h-12 w-full rounded-xl border border-[#30372c] bg-[#141814] px-5 py-3 font-semibold text-[#d7c895] transition hover:border-[#536143] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:text-[#858c7f] sm:w-auto"
                  >
                    {savingPassword ? "Zmiana hasła..." : "Zmień hasło"}
                  </button>
            </section>

            <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:p-6">
              <h2 className="mb-4 text-xl font-semibold text-[#f2efe4]">
                Twoje dane i konto
              </h2>

              <p className="mb-5 text-sm leading-6 text-[#a9ada4]">
                Możesz pobrać wersjonowany eksport swoich danych albo trwale
                zamknąć konto. Eksport nie zawiera haseł, tokenów ani notatek
                administracyjnych.
              </p>

              <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap">
                <button
                  type="button"
                  onClick={exportMyData}
                  disabled={exportingData || deletingAccount}
                  className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-5 py-3 font-semibold text-[#d7c895] transition hover:border-[#536143] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:text-[#858c7f]"
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
                  className="min-h-12 rounded-xl border border-[#744545] bg-[#2a1b1b] px-5 py-3 font-semibold text-[#e0a0a0] transition hover:bg-[#3a2222] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:opacity-60"
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
                  className="min-h-12 w-full rounded-xl border border-[#536143] bg-[#536143] px-4 py-3 font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:border-[#30372c] disabled:bg-[#30372c] disabled:text-[#858c7f]"
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
              className="w-full max-w-xl rounded-[2rem] border border-[#744545] bg-[#141814] p-6 shadow-2xl shadow-black/50 sm:p-8"
            >
              <h2
                id="delete-account-title"
                className="text-2xl font-bold text-[#e0a0a0]"
              >
                Trwale usunąć konto?
              </h2>

              <div
                id="delete-account-description"
                className="mt-4 space-y-3 text-sm leading-6 text-[#a9ada4]"
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
                className="mt-6 block text-sm font-semibold text-[#f2efe4]"
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
                className="mt-2 min-h-12 w-full rounded-xl border border-[#744545] bg-[#191e19] px-4 py-3 text-[#f2efe4] outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              />

              <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                <button
                  type="button"
                  onClick={() => setShowDeleteConfirmation(false)}
                  disabled={deletingAccount}
                  className="min-h-12 rounded-xl border border-[#30372c] px-5 py-3 font-semibold text-[#a9ada4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] disabled:opacity-60"
                >
                  Anuluj
                </button>
                <button
                  type="button"
                  onClick={deleteMyAccount}
                  disabled={
                    deletingAccount || deleteConfirmation !== "USUŃ KONTO"
                  }
                  className="min-h-12 rounded-xl border border-[#744545] bg-[#7a3030] px-5 py-3 font-semibold text-white transition hover:bg-[#963d3d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:bg-[#30372c] disabled:text-[#858c7f]"
                >
                  {deletingAccount ? "Usuwanie konta..." : "Potwierdź usunięcie"}
                </button>
              </div>
            </div>
          </div>
        )}

        <nav
          aria-label="Pozostałe strony konta"
          className="mt-8 flex flex-col gap-3 border-t border-[#30372c] pt-6 sm:flex-row"
        >
          <a
            href="/my-reservations"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Moje rezerwacje
          </a>

          <a
            href="/my-events"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Moje szkolenia
          </a>
        </nav>
      </section>
    </main>
  );
}
