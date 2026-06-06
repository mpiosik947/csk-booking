"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { supabase } from "../../../lib/supabase";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";

type VerificationStatus =
  | "pending"
  | "verified"
  | "rejected"
  | "niezweryfikowane"
  | "unverified";

type Profile = {
  id: string;
  user_id: string;
  email: string | null;
  full_name: string | null;
  phone: string | null;
  role: UserRole | string | null;
  verification_status: VerificationStatus | string | null;
  admin_note: string | null;
  created_at: string | null;
  updated_at: string | null;

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

  permissions_verified: boolean | null;
  permissions_verified_at: string | null;
  permissions_verified_by: string | null;
  permissions_verification_note: string | null;
};

const roleOptions: UserRole[] = ["admin", "pracownik", "instruktor", "user"];

const verificationOptions: VerificationStatus[] = [
  "pending",
  "verified",
  "rejected",
];

const statusFilters = [
  { label: "Wszyscy", value: "all" },
  { label: "Oczekujący", value: "pending" },
  { label: "Niezweryfikowani", value: "unverified" },
  { label: "Zweryfikowani", value: "verified" },
  { label: "Odrzuceni", value: "rejected" },
];

const roleFilters = [
  { label: "Wszystkie role", value: "all" },
  { label: "Admin", value: "admin" },
  { label: "Pracownik", value: "pracownik" },
  { label: "Instruktor", value: "instruktor" },
  { label: "Użytkownik", value: "user" },
];

const VERIFIED_NOTE =
  "Sprawdzono uprawnienia klienta podczas pierwszej wizyty. Dokumenty okazane do wglądu, bez kopiowania i zapisywania numerów. Klient zapoznany z regulaminem i zasadami bezpieczeństwa. Konto zweryfikowane.";

const INCOMPLETE_NOTE =
  "Nie zakończono pełnej weryfikacji uprawnień. Klient poinformowany o konieczności okazania wymaganych dokumentów przy kolejnej wizycie. Konto pozostaje niezweryfikowane.";

function isFullyVerified(profile: Profile) {
  return (
    profile.verification_status === "verified" &&
    profile.permissions_verified === true
  );
}

function isNotFullyVerified(profile: Profile) {
  return !isFullyVerified(profile);
}

function isPendingStatus(profile: Profile) {
  return profile.verification_status === "pending";
}

function isRejectedStatus(profile: Profile) {
  return profile.verification_status === "rejected";
}

function valueOrMissing(value: string | null | undefined) {
  return value && value.trim() ? value : "Brak danych";
}

function yesNo(value: boolean | null) {
  return value ? "Tak" : "Nie";
}

function getMissingFields(profile: Profile) {
  const missing: string[] = [];

  if (!profile.full_name) missing.push("imię i nazwisko");
  if (!profile.phone) missing.push("telefon");
  if (!profile.postal_code) missing.push("kod pocztowy");
  if (!profile.city) missing.push("miasto");
  if (!profile.street) missing.push("ulica");
  if (!profile.house_number) missing.push("numer domu");

  return missing;
}

function getCompletionPercent(profile: Profile) {
  const fields = [
    profile.full_name,
    profile.phone,
    profile.postal_code,
    profile.city,
    profile.street,
    profile.house_number,
  ];

  const filled = fields.filter((field) => field && field.trim()).length;

  return Math.round((filled / fields.length) * 100);
}

function getDeclaredPermissions(profile: Profile) {
  const permissions: string[] = [];

  if (profile.permission_sport) permissions.push("sportowe");
  if (profile.permission_collector) permissions.push("kolekcjonerskie");
  if (profile.permission_hunting) permissions.push("myśliwskie / łowieckie");
  if (profile.permission_training) permissions.push("szkoleniowe / dopuszczenie");
  if (profile.permission_personal_protection) permissions.push("ochrona osobista");
  if (profile.permission_other) permissions.push("inne");

  return permissions;
}

function getDeclaredQualifications(profile: Profile) {
  const qualifications: string[] = [];

  if (profile.qualification_instructor) qualifications.push("instruktor");
  if (profile.qualification_range_officer)
    qualifications.push("prowadzący strzelanie / range officer");
  if (profile.qualification_pzss_license) qualifications.push("licencja PZSS");
  if (profile.qualification_hunter) qualifications.push("myśliwy");

  return qualifications;
}

function getRoleLabel(role: string | null) {
  switch (role) {
    case "admin":
      return "Administrator";
    case "pracownik":
      return "Pracownik";
    case "instruktor":
      return "Instruktor";
    case "user":
      return "Użytkownik";
    default:
      return "Brak roli";
  }
}

function getStatusLabel(status: string | null) {
  switch (status) {
    case "verified":
      return "Zweryfikowany";
    case "pending":
      return "Oczekuje";
    case "rejected":
      return "Odrzucony";
    case "niezweryfikowane":
    case "unverified":
      return "Niezweryfikowany";
    default:
      return "Brak statusu";
  }
}

function getRoleBadgeClass(role: string | null) {
  switch (role) {
    case "admin":
      return "border-green-700 bg-green-950 text-green-300";
    case "pracownik":
      return "border-blue-700 bg-blue-950 text-blue-300";
    case "instruktor":
      return "border-purple-700 bg-purple-950 text-purple-300";
    case "user":
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-400";
  }
}

function getStatusBadgeClass(status: string | null) {
  switch (status) {
    case "verified":
      return "border-green-700 bg-green-950 text-green-300";
    case "pending":
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case "rejected":
      return "border-red-700 bg-red-950 text-red-300";
    case "niezweryfikowane":
    case "unverified":
      return "border-orange-700 bg-orange-950 text-orange-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-400";
  }
}

function getPermissionsBadgeClass(verified: boolean | null) {
  if (verified) {
    return "border-green-700 bg-green-950 text-green-300";
  }

  return "border-yellow-700 bg-yellow-950 text-yellow-300";
}

function InfoLine({
  label,
  value,
}: {
  label: string;
  value: string | number | null | undefined;
}) {
  return (
    <>
      <p className="text-sm text-zinc-500">{label}</p>
      <p className="mb-3 font-semibold">{valueOrMissing(String(value ?? ""))}</p>
    </>
  );
}

function BooleanLine({ label, value }: { label: string; value: boolean | null }) {
  return (
    <div className="flex items-center justify-between gap-4 border-b border-zinc-800 py-2 last:border-b-0">
      <span className="text-sm text-zinc-400">{label}</span>
      <span
        className={
          value
            ? "rounded-full border border-green-700 bg-green-950 px-3 py-1 text-xs font-bold text-green-300"
            : "rounded-full border border-zinc-700 bg-zinc-900 px-3 py-1 text-xs font-bold text-zinc-400"
        }
      >
        {yesNo(value)}
      </span>
    </div>
  );
}

export default function AdminUsersPage() {
  const [currentUserId, setCurrentUserId] = useState("");
  const [currentProfileId, setCurrentProfileId] = useState("");
  const [currentUserRole, setCurrentUserRole] = useState<UserRole>("user");
  const [currentUserName, setCurrentUserName] = useState("");

  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [expandedUserId, setExpandedUserId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [savingUserId, setSavingUserId] = useState<string | null>(null);
  const [message, setMessage] = useState("");

  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [roleFilter, setRoleFilter] = useState("all");

  const isAdmin = currentUserRole === "admin";

 async function loadCurrentUser() {
  const {
    data: { user },
  } = await supabase.auth.getUser();

  setCurrentUserId(user?.id ?? "");

  if (!user) {
    return null;
  }

  const { data: profile, error } = await supabase
    .from("profiles")
    .select("id, role, full_name, email")
    .eq("user_id", user.id)
    .single();

  if (error || !profile) {
    return null;
  }

  if (profile.id) {
    setCurrentProfileId(profile.id);
  }

  const loadedRole = (profile.role as UserRole) || "user";

  setCurrentUserRole(loadedRole);
  setCurrentUserName(
    profile.full_name || profile.email || "Nieznany użytkownik"
  );

  return loadedRole;
}

  async function loadProfiles() {
  setLoading(true);
  setMessage("");

  const loadedRole = await loadCurrentUser();

  if (loadedRole !== "admin") {
    setProfiles([]);
    setMessage("Brak dostępu. Ten moduł jest dostępny tylko dla administratora.");
    setLoading(false);
    return;
  }

  const { data, error } = await supabase
      .from("profiles")
      .select(
        `
        id,
        user_id,
        email,
        full_name,
        phone,
        role,
        verification_status,
        admin_note,
        created_at,
        updated_at,

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
        qualification_hunter,

        permissions_verified,
        permissions_verified_at,
        permissions_verified_by,
        permissions_verification_note
      `
      )
      .order("created_at", { ascending: false });

    setLoading(false);

    if (error) {
      setMessage(`Błąd pobierania użytkowników: ${error.message}`);
      return;
    }

    setProfiles((data ?? []) as Profile[]);
  }

  useEffect(() => {
    loadProfiles();
  }, []);

  const filteredProfiles = useMemo(() => {
    const phrase = search.trim().toLowerCase();

    return profiles.filter((profile) => {
      const email = profile.email?.toLowerCase() ?? "";
      const name = profile.full_name?.toLowerCase() ?? "";
      const phone = profile.phone?.toLowerCase() ?? "";
      const role = profile.role?.toLowerCase() ?? "";
      const status = profile.verification_status?.toLowerCase() ?? "";
      const permissions = getDeclaredPermissions(profile).join(" ").toLowerCase();
      const qualifications = getDeclaredQualifications(profile)
        .join(" ")
        .toLowerCase();

      const matchesSearch =
        !phrase ||
        email.includes(phrase) ||
        name.includes(phrase) ||
        phone.includes(phrase) ||
        role.includes(phrase) ||
        status.includes(phrase) ||
        permissions.includes(phrase) ||
        qualifications.includes(phrase);

      const matchesStatus =
        statusFilter === "all" ||
        (statusFilter === "pending" && isPendingStatus(profile)) ||
        (statusFilter === "unverified" && isNotFullyVerified(profile)) ||
        (statusFilter === "verified" && isFullyVerified(profile)) ||
        (statusFilter === "rejected" && isRejectedStatus(profile));

      const matchesRole = roleFilter === "all" || role === roleFilter;

      return matchesSearch && matchesStatus && matchesRole;
    });
  }, [profiles, search, statusFilter, roleFilter]);

  const counters = useMemo(() => {
    return {
      all: profiles.length,
      pending: profiles.filter((profile) => isPendingStatus(profile)).length,
      unverified: profiles.filter((profile) => isNotFullyVerified(profile))
        .length,
      verified: profiles.filter((profile) => isFullyVerified(profile)).length,
      rejected: profiles.filter((profile) => isRejectedStatus(profile)).length,
      admin: profiles.filter((profile) => profile.role === "admin").length,
      pracownik: profiles.filter((profile) => profile.role === "pracownik")
        .length,
      instruktor: profiles.filter((profile) => profile.role === "instruktor")
        .length,
      user: profiles.filter((profile) => profile.role === "user").length,
    };
  }, [profiles]);

  function getFilterCount(value: string) {
    switch (value) {
      case "pending":
        return counters.pending;
      case "unverified":
        return counters.unverified;
      case "verified":
        return counters.verified;
      case "rejected":
        return counters.rejected;
      case "admin":
        return counters.admin;
      case "pracownik":
        return counters.pracownik;
      case "instruktor":
        return counters.instruktor;
      case "user":
        return counters.user;
      default:
        return counters.all;
    }
  }

  function getAuditAction(changes: Partial<Profile>) {
    if (changes.role) return "PROFILE_ROLE_CHANGED";
    if (changes.verification_status) return "PROFILE_VERIFICATION_CHANGED";

    if (
      Object.prototype.hasOwnProperty.call(changes, "permissions_verified") ||
      Object.prototype.hasOwnProperty.call(
        changes,
        "permissions_verification_note"
      )
    ) {
      return "PROFILE_PERMISSIONS_VERIFICATION_UPDATED";
    }

    if (Object.prototype.hasOwnProperty.call(changes, "admin_note")) {
      return "PROFILE_ADMIN_NOTE_UPDATED";
    }

    return "PROFILE_UPDATED";
  }

  async function createAuditLog(profile: Profile, changes: Partial<Profile>) {
    if (!currentUserId) return null;

    const { error } = await supabase.from("audit_logs").insert({
      actor_user_id: currentUserId,
      actor_name: currentUserName || "Nieznany użytkownik",
      actor_role: currentUserRole,
      action: getAuditAction(changes),
      target_type: "profile",
      target_id: profile.user_id,
      target_name:
        profile.full_name || profile.email || profile.phone || "Nieznany profil",
      details: {
        before: {
          role: profile.role,
          verification_status: profile.verification_status,
          permissions_verified: profile.permissions_verified,
          admin_note_exists: Boolean(profile.admin_note),
          permissions_verification_note_exists: Boolean(
            profile.permissions_verification_note
          ),
        },
        after: {
          role: changes.role ?? profile.role,
          verification_status:
            changes.verification_status ?? profile.verification_status,
          permissions_verified:
            changes.permissions_verified ?? profile.permissions_verified,
          admin_note_changed: Object.prototype.hasOwnProperty.call(
            changes,
            "admin_note"
          ),
          permissions_note_changed: Object.prototype.hasOwnProperty.call(
            changes,
            "permissions_verification_note"
          ),
        },
      },
    });

    return error?.message ?? null;
  }

  async function updateProfile(profile: Profile, changes: Partial<Profile>) {
    const isOwnAccount = profile.user_id === currentUserId;

    if (changes.role && !isAdmin) {
      setMessage("Zablokowano zmianę: tylko administrator może zmieniać role.");
      return;
    }

    if (isOwnAccount && changes.role && changes.role !== "admin") {
      setMessage(
        "Zablokowano zmianę: nie możesz odebrać sam sobie roli administratora."
      );
      return;
    }

    if (
      isOwnAccount &&
      changes.verification_status &&
      changes.verification_status !== "verified"
    ) {
      setMessage(
        "Zablokowano zmianę: nie możesz odrzucić ani cofnąć weryfikacji własnego konta."
      );
      return;
    }

    setSavingUserId(profile.user_id);
    setMessage("");

    const updatedAt = new Date().toISOString();

    const { error } = await supabase
      .from("profiles")
      .update({
        ...changes,
        updated_at: updatedAt,
      })
      .eq("user_id", profile.user_id);

    setSavingUserId(null);

    if (error) {
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    setProfiles((currentProfiles) =>
      currentProfiles.map((item) =>
        item.user_id === profile.user_id
          ? {
              ...item,
              ...changes,
              updated_at: updatedAt,
            }
          : item
      )
    );

    const auditError = await createAuditLog(profile, changes);

    if (auditError) {
      setMessage(
        `Zapisano zmiany, ale nie udało się dodać wpisu audit log: ${auditError}`
      );
      return;
    }

    setMessage("Zapisano zmiany i dodano wpis audit log.");
  }

  function verifyProfileAndPermissions(profile: Profile) {
    const missingFields = getMissingFields(profile);

    if (missingFields.length > 0) {
      const confirmed = window.confirm(
        `Konto posiada braki:\n\n• ${missingFields.join(
          "\n• "
        )}\n\nCzy mimo to oznaczyć konto jako zweryfikowane?`
      );

      if (!confirmed) return;
    }

    updateProfile(profile, {
      verification_status: "verified",
      permissions_verified: true,
      permissions_verified_at: new Date().toISOString(),
      permissions_verified_by: currentProfileId || null,
      permissions_verification_note:
        profile.permissions_verification_note || VERIFIED_NOTE,
    });
  }

  function markVerificationIncomplete(profile: Profile) {
    updateProfile(profile, {
      verification_status: "pending",
      permissions_verified: false,
      permissions_verified_at: null,
      permissions_verified_by: null,
      permissions_verification_note: INCOMPLETE_NOTE,
    });
  }

  function resetFilters() {
    setSearch("");
    setStatusFilter("all");
    setRoleFilter("all");
  }

  return (
    <main className="min-h-screen bg-zinc-950 px-6 py-10 text-white">
      <section className="mx-auto max-w-7xl">
        <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-3 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="text-4xl font-bold">Użytkownicy</h1>

            <p className="mt-3 max-w-2xl text-zinc-400">
              Zarządzanie rolami, weryfikacją kont, deklarowanymi uprawnieniami
              i krótkimi notatkami pracownika — bez zapisywania numerów
              dokumentów.
            </p>

            {!isAdmin && (
              <p className="mt-3 max-w-2xl text-sm text-yellow-400">
                Tryb pracownika: możesz weryfikować konta i zapisywać notatki,
                ale nie możesz zmieniać ról użytkowników.
              </p>
            )}
          </div>

          <Link
            href="/admin"
            className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
          >
            Wróć do panelu
          </Link>
        </div>

        <div className="mb-6 grid gap-4 rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
          <div className="grid gap-4 md:grid-cols-[1fr_auto_auto] md:items-end">
            <div>
              <label className="mb-2 block text-sm font-semibold text-zinc-300">
                Szukaj użytkownika
              </label>

              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="E-mail, imię, telefon, rola, status, uprawnienia..."
                className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none transition focus:border-green-600"
              />
            </div>

            <button
              type="button"
              onClick={loadProfiles}
              disabled={loading}
              className="rounded-xl bg-green-700 px-5 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {loading ? "Odświeżanie..." : "Odśwież"}
            </button>

            <button
              type="button"
              onClick={resetFilters}
              className="rounded-xl border border-zinc-700 px-5 py-3 font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
            >
              Wyczyść filtry
            </button>
          </div>

          <div>
            <p className="mb-3 text-sm font-semibold text-zinc-300">
              Status konta
            </p>

            <div className="flex flex-wrap gap-2">
              {statusFilters.map((filter) => (
                <button
                  key={filter.value}
                  type="button"
                  onClick={() => setStatusFilter(filter.value)}
                  className={
                    statusFilter === filter.value
                      ? "rounded-xl border border-green-600 bg-green-900 px-4 py-2 text-sm font-semibold text-white"
                      : "rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-2 text-sm font-semibold text-zinc-400 transition hover:border-green-700 hover:text-white"
                  }
                >
                  {filter.label} ({getFilterCount(filter.value)})
                </button>
              ))}
            </div>

            <p className="mt-3 text-xs leading-5 text-zinc-500">
              „Niezweryfikowani” pokazuje wszystkie konta, które nie mają
              pełnej weryfikacji konta i uprawnień.
            </p>
          </div>

          <div>
            <p className="mb-3 text-sm font-semibold text-zinc-300">
              Rola użytkownika
            </p>

            <div className="flex flex-wrap gap-2">
              {roleFilters.map((filter) => (
                <button
                  key={filter.value}
                  type="button"
                  onClick={() => setRoleFilter(filter.value)}
                  className={
                    roleFilter === filter.value
                      ? "rounded-xl border border-green-600 bg-green-900 px-4 py-2 text-sm font-semibold text-white"
                      : "rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-2 text-sm font-semibold text-zinc-400 transition hover:border-green-700 hover:text-white"
                  }
                >
                  {filter.label} ({getFilterCount(filter.value)})
                </button>
              ))}
            </div>
          </div>
        </div>

        {message && (
          <div className="mb-6 rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200">
            {message}
          </div>
        )}

        <div className="overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900">
          <div className="border-b border-zinc-800 px-5 py-4">
            <p className="text-sm text-zinc-400">
              Liczba użytkowników w widoku:{" "}
              <span className="font-bold text-white">
                {filteredProfiles.length}
              </span>{" "}
              / {profiles.length}
            </p>
          </div>

          {loading ? (
            <div className="p-8 text-zinc-400">Ładowanie użytkowników...</div>
          ) : filteredProfiles.length === 0 ? (
            <div className="p-8 text-zinc-400">
              Brak użytkowników do wyświetlenia.
            </div>
          ) : (
            <div className="grid gap-4 p-4">
              {filteredProfiles.map((profile) => {
                const isSaving = savingUserId === profile.user_id;
                const isOwnAccount = profile.user_id === currentUserId;
                const isExpanded = expandedUserId === profile.user_id;
                const missingFields = getMissingFields(profile);
                const completion = getCompletionPercent(profile);
                const declaredPermissions = getDeclaredPermissions(profile);
                const declaredQualifications =
                  getDeclaredQualifications(profile);

                return (
                  <article
                    key={profile.user_id}
                    className={
                      isOwnAccount
                        ? "rounded-2xl border border-green-800 bg-zinc-950 p-5"
                        : "rounded-2xl border border-zinc-800 bg-zinc-950 p-5"
                    }
                  >
                    <div className="grid gap-5 xl:grid-cols-[1.2fr_0.8fr_0.8fr_1.2fr_auto] xl:items-start">
                      <div>
                        <div className="mb-3 flex flex-wrap gap-2">
                          <span
                            className={`rounded-full border px-3 py-1 text-xs font-bold ${getRoleBadgeClass(
                              profile.role
                            )}`}
                          >
                            {getRoleLabel(profile.role)}
                          </span>

                          <span
                            className={`rounded-full border px-3 py-1 text-xs font-bold ${getStatusBadgeClass(
                              profile.verification_status
                            )}`}
                          >
                            {getStatusLabel(profile.verification_status)}
                          </span>

                          <span
                            className={`rounded-full border px-3 py-1 text-xs font-bold ${getPermissionsBadgeClass(
                              profile.permissions_verified
                            )}`}
                          >
                            Uprawnienia:{" "}
                            {profile.permissions_verified
                              ? "sprawdzone"
                              : "do sprawdzenia"}
                          </span>

                          <span
                            className={
                              completion >= 80
                                ? "rounded-full border border-green-700 bg-green-950 px-3 py-1 text-xs font-bold text-green-300"
                                : "rounded-full border border-yellow-700 bg-yellow-950 px-3 py-1 text-xs font-bold text-yellow-300"
                            }
                          >
                            Dane: {completion}%
                          </span>

                          {isOwnAccount && (
                            <span className="rounded-full border border-green-700 bg-green-950 px-3 py-1 text-xs font-bold text-green-300">
                              Twoje konto
                            </span>
                          )}

                          {isFullyVerified(profile) ? (
                            <span className="rounded-full border border-green-700 bg-green-950 px-3 py-1 text-xs font-bold text-green-300">
                              Pełna weryfikacja
                            </span>
                          ) : (
                            <span className="rounded-full border border-orange-700 bg-orange-950 px-3 py-1 text-xs font-bold text-orange-300">
                              Niepełna weryfikacja
                            </span>
                          )}
                        </div>

                        <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Konto
                        </p>

                        <h2 className="mt-2 text-lg font-bold">
                          {profile.full_name || "Brak imienia i nazwiska"}
                        </h2>

                        <p className="mt-1 text-sm text-zinc-400">
                          {profile.email || "Brak e-maila"}
                        </p>

                        <p className="mt-1 text-sm text-zinc-500">
                          Tel.: {profile.phone || "brak"}
                        </p>

                        <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-900 p-3 text-xs text-zinc-400">
                          <p className="font-semibold text-zinc-300">
                            Deklarowane uprawnienia:
                          </p>
                          <p className="mt-1">
                            {declaredPermissions.length > 0
                              ? declaredPermissions.join(", ")
                              : "Brak zaznaczonych uprawnień"}
                          </p>
                        </div>

                        <button
                          type="button"
                          onClick={() =>
                            setExpandedUserId(
                              isExpanded ? null : profile.user_id
                            )
                          }
                          className="mt-4 rounded-xl border border-zinc-700 px-4 py-2 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
                        >
                          {isExpanded ? "Ukryj pełne dane" : "Pokaż pełne dane"}
                        </button>
                      </div>

                      <div>
                        <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Rola
                        </label>

                        <select
                          value={profile.role || "user"}
                          disabled={isSaving || !isAdmin}
                          onChange={(event) =>
                            updateProfile(profile, {
                              role: event.target.value as UserRole,
                            })
                          }
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                        >
                          {roleOptions.map((role) => (
                            <option
                              key={role}
                              value={role}
                              disabled={isOwnAccount && role !== "admin"}
                            >
                              {getRoleLabel(role)}
                            </option>
                          ))}
                        </select>

                        {isOwnAccount && isAdmin && (
                          <p className="mt-2 text-xs text-green-400">
                            Nie możesz odebrać sam sobie roli admina.
                          </p>
                        )}

                        {!isAdmin && (
                          <p className="mt-2 text-xs text-yellow-400">
                            Tylko administrator może zmieniać role.
                          </p>
                        )}
                      </div>

                      <div>
                        <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Status konta
                        </label>

                        <select
                          value={profile.verification_status || "pending"}
                          disabled={isSaving}
                          onChange={(event) =>
                            updateProfile(profile, {
                              verification_status:
                                event.target.value as VerificationStatus,
                            })
                          }
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                        >
                          {verificationOptions.map((status) => (
                            <option
                              key={status}
                              value={status}
                              disabled={isOwnAccount && status !== "verified"}
                            >
                              {getStatusLabel(status)}
                            </option>
                          ))}
                        </select>

                        <div className="mt-3 grid gap-2">
                          <button
                            type="button"
                            disabled={isSaving}
                            onClick={() => verifyProfileAndPermissions(profile)}
                            className="rounded-xl border border-green-700 px-3 py-2 text-xs font-bold text-green-300 transition hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Zweryfikuj konto i uprawnienia
                          </button>

                          <button
                            type="button"
                            disabled={isSaving || isOwnAccount}
                            onClick={() => markVerificationIncomplete(profile)}
                            className="rounded-xl border border-yellow-700 px-3 py-2 text-xs font-bold text-yellow-300 transition hover:bg-yellow-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Weryfikacja niepełna
                          </button>

                          <button
                            type="button"
                            disabled={isSaving || isOwnAccount}
                            onClick={() =>
                              updateProfile(profile, {
                                verification_status: "rejected",
                                permissions_verified: false,
                              })
                            }
                            className="rounded-xl border border-red-700 px-3 py-2 text-xs font-bold text-red-300 transition hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Odrzuć konto
                          </button>
                        </div>
                      </div>

                      <div>
                        <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Notatka weryfikacyjna
                        </label>

                        <textarea
                          value={profile.permissions_verification_note || ""}
                          disabled={isSaving}
                          onChange={(event) => {
                            const value = event.target.value;

                            setProfiles((currentProfiles) =>
                              currentProfiles.map((item) =>
                                item.user_id === profile.user_id
                                  ? {
                                      ...item,
                                      permissions_verification_note: value,
                                    }
                                  : item
                              )
                            );
                          }}
                          rows={4}
                          placeholder="Krótka notatka. Nie wpisuj numerów dokumentów."
                          className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                        />

                        <div className="mt-3 grid gap-2 sm:grid-cols-2">
                          <button
                            type="button"
                            disabled={isSaving}
                            onClick={() =>
                              setProfiles((currentProfiles) =>
                                currentProfiles.map((item) =>
                                  item.user_id === profile.user_id
                                    ? {
                                        ...item,
                                        permissions_verification_note:
                                          VERIFIED_NOTE,
                                      }
                                    : item
                                )
                              )
                            }
                            className="rounded-xl border border-green-700 px-3 py-2 text-xs font-bold text-green-300 transition hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Wstaw: zweryfikowano
                          </button>

                          <button
                            type="button"
                            disabled={isSaving}
                            onClick={() =>
                              setProfiles((currentProfiles) =>
                                currentProfiles.map((item) =>
                                  item.user_id === profile.user_id
                                    ? {
                                        ...item,
                                        permissions_verification_note:
                                          INCOMPLETE_NOTE,
                                      }
                                    : item
                                )
                              )
                            }
                            className="rounded-xl border border-yellow-700 px-3 py-2 text-xs font-bold text-yellow-300 transition hover:bg-yellow-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Wstaw: braki
                          </button>
                        </div>

                        <button
                          type="button"
                          disabled={isSaving}
                          onClick={() =>
                            updateProfile(profile, {
                              permissions_verification_note:
                                profile.permissions_verification_note || "",
                            })
                          }
                          className="mt-3 w-full rounded-xl border border-zinc-700 px-4 py-2 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white disabled:cursor-not-allowed disabled:opacity-60"
                        >
                          Zapisz notatkę
                        </button>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-sm">
                        <p className="text-zinc-500">Aktualna rola</p>

                        <p className="mt-1 font-bold text-green-400">
                          {getRoleLabel(profile.role)}
                        </p>

                        <p className="mt-4 text-zinc-500">Status konta</p>

                        <p className="mt-1 font-bold text-zinc-200">
                          {getStatusLabel(profile.verification_status)}
                        </p>

                        <p className="mt-4 text-zinc-500">Uprawnienia</p>

                        <p className="mt-1 font-bold text-zinc-200">
                          {profile.permissions_verified
                            ? "Sprawdzone"
                            : "Do sprawdzenia"}
                        </p>

                        <p className="mt-4 text-zinc-500">Weryfikacja</p>

                        <p
                          className={
                            isFullyVerified(profile)
                              ? "mt-1 font-bold text-green-300"
                              : "mt-1 font-bold text-orange-300"
                          }
                        >
                          {isFullyVerified(profile)
                            ? "Pełna"
                            : "Niepełna"}
                        </p>

                        <p className="mt-4 text-zinc-500">Utworzono</p>

                        <p className="mt-1 text-xs text-zinc-300">
                          {profile.created_at
                            ? new Date(profile.created_at).toLocaleString(
                                "pl-PL"
                              )
                            : "brak danych"}
                        </p>

                        {isSaving && (
                          <p className="mt-4 text-xs font-semibold text-yellow-400">
                            Zapisywanie...
                          </p>
                        )}
                      </div>
                    </div>

                    {isExpanded && (
                      <div className="mt-6 rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                        <div className="mb-5 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
                          <div>
                            <h3 className="text-xl font-bold">
                              Dane do weryfikacji
                            </h3>

                            <p className="mt-1 text-sm text-zinc-400">
                              Kompletność danych podstawowych:{" "}
                              <span className="font-bold text-white">
                                {completion}%
                              </span>
                            </p>
                          </div>

                          {missingFields.length === 0 ? (
                            <span className="rounded-full border border-green-700 bg-green-950 px-4 py-2 text-sm font-bold text-green-300">
                              Dane podstawowe kompletne
                            </span>
                          ) : (
                            <span className="rounded-full border border-yellow-700 bg-yellow-950 px-4 py-2 text-sm font-bold text-yellow-300">
                              Braki: {missingFields.length}
                            </span>
                          )}
                        </div>

                        {missingFields.length > 0 && (
                          <div className="mb-5 rounded-xl border border-yellow-800 bg-yellow-950 p-4 text-sm text-yellow-100">
                            <p className="font-bold text-yellow-300">
                              Brakujące dane:
                            </p>

                            <p className="mt-1">{missingFields.join(", ")}</p>
                          </div>
                        )}

                        <div className="mb-5 rounded-xl border border-green-900 bg-green-950/40 p-4 text-sm text-green-200">
                          <p className="font-semibold">
                            Zasada minimalizacji danych
                          </p>

                          <p className="mt-1 text-green-300">
                            Nie zapisujemy numerów pozwoleń, legitymacji,
                            uprawnień instruktora ani prowadzącego strzelanie.
                            Pracownik sprawdza dokumenty wyłącznie do wglądu i
                            zapisuje tylko wynik weryfikacji.
                          </p>
                        </div>

                        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Dane podstawowe
                            </p>

                            <InfoLine
                              label="Imię i nazwisko"
                              value={profile.full_name}
                            />

                            <InfoLine label="E-mail" value={profile.email} />

                            <InfoLine label="Telefon" value={profile.phone} />
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Adres
                            </p>

                            <InfoLine
                              label="Kod pocztowy"
                              value={profile.postal_code}
                            />

                            <InfoLine label="Miasto" value={profile.city} />

                            <InfoLine label="Ulica" value={profile.street} />

                            <p className="text-sm text-zinc-500">Dom / lokal</p>
                            <p className="font-semibold">
                              {valueOrMissing(profile.house_number)}
                              {profile.apartment_number
                                ? ` / ${profile.apartment_number}`
                                : ""}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Deklarowane pozwolenia / uprawnienia
                            </p>

                            <BooleanLine
                              label="Pozwolenie sportowe"
                              value={profile.permission_sport}
                            />

                            <BooleanLine
                              label="Pozwolenie kolekcjonerskie"
                              value={profile.permission_collector}
                            />

                            <BooleanLine
                              label="Pozwolenie myśliwskie / łowieckie"
                              value={profile.permission_hunting}
                            />

                            <BooleanLine
                              label="Szkoleniowe / dopuszczenie"
                              value={profile.permission_training}
                            />

                            <BooleanLine
                              label="Ochrona osobista"
                              value={profile.permission_personal_protection}
                            />

                            <BooleanLine
                              label="Inne"
                              value={profile.permission_other}
                            />
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Dodatkowe kwalifikacje
                            </p>

                            <BooleanLine
                              label="Instruktor"
                              value={profile.qualification_instructor}
                            />

                            <BooleanLine
                              label="Prowadzący strzelanie / RO"
                              value={profile.qualification_range_officer}
                            />

                            <BooleanLine
                              label="Licencja PZSS"
                              value={profile.qualification_pzss_license}
                            />

                            <BooleanLine
                              label="Myśliwy"
                              value={profile.qualification_hunter}
                            />
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Weryfikacja uprawnień
                            </p>

                            <p className="text-sm text-zinc-500">
                              Status sprawdzenia
                            </p>

                            <p className="mb-3 font-semibold">
                              {profile.permissions_verified
                                ? "Sprawdzone przez obsługę"
                                : "Do sprawdzenia podczas wizyty"}
                            </p>

                            <p className="text-sm text-zinc-500">
                              Data sprawdzenia
                            </p>

                            <p className="mb-3 font-semibold">
                              {profile.permissions_verified_at
                                ? new Date(
                                    profile.permissions_verified_at
                                  ).toLocaleString("pl-PL")
                                : "Brak danych"}
                            </p>

                            <p className="text-sm text-zinc-500">Notatka</p>

                            <p className="whitespace-pre-line text-sm font-semibold leading-6">
                              {valueOrMissing(
                                profile.permissions_verification_note
                              )}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              System
                            </p>

                            <InfoLine
                              label="Status konta"
                              value={getStatusLabel(
                                profile.verification_status
                              )}
                            />

                            <InfoLine
                              label="Rola"
                              value={getRoleLabel(profile.role)}
                            />

                            <p className="text-sm text-zinc-500">
                              Ostatnia aktualizacja
                            </p>

                            <p className="font-semibold">
                              {profile.updated_at
                                ? new Date(profile.updated_at).toLocaleString(
                                    "pl-PL"
                                  )
                                : "Brak danych"}
                            </p>
                          </div>
                        </div>

                        <div className="mt-5 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-2 text-xs uppercase tracking-[0.25em] text-zinc-500">
                            Notatka admina / pracownika
                          </p>

                          <textarea
                            value={profile.admin_note || ""}
                            disabled={isSaving}
                            onChange={(event) => {
                              const value = event.target.value;

                              setProfiles((currentProfiles) =>
                                currentProfiles.map((item) =>
                                  item.user_id === profile.user_id
                                    ? {
                                        ...item,
                                        admin_note: value,
                                      }
                                    : item
                                )
                              );
                            }}
                            rows={3}
                            placeholder="Uwagi organizacyjne, kontakt, informacje wewnętrzne. Bez numerów dokumentów."
                            className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-white outline-none transition focus:border-green-600 disabled:opacity-60"
                          />

                          <button
                            type="button"
                            disabled={isSaving}
                            onClick={() =>
                              updateProfile(profile, {
                                admin_note: profile.admin_note || "",
                              })
                            }
                            className="mt-3 rounded-xl border border-zinc-700 px-4 py-2 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Zapisz notatkę admina
                          </button>
                        </div>
                      </div>
                    )}
                  </article>
                );
              })}
            </div>
          )}
        </div>
      </section>
    </main>
  );
}