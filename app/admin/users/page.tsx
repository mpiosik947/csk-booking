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

  weapon_permit_number: string | null;
  weapon_permit_type: string | null;
  weapon_permit_issuer: string | null;

  has_range_officer: boolean | null;
  range_officer_number: string | null;

  has_instructor: boolean | null;
  instructor_number: string | null;
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

function isUnverifiedStatus(status: string | null) {
  return (
    !status ||
    status === "niezweryfikowane" ||
    status === "unverified" ||
    status === "brak statusu"
  );
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
  if (!profile.weapon_permit_number) missing.push("numer pozwolenia");
  if (!profile.weapon_permit_type) missing.push("typ pozwolenia");
  if (!profile.weapon_permit_issuer) missing.push("organ wydający");

  if (profile.has_range_officer && !profile.range_officer_number) {
    missing.push("numer prowadzącego strzelanie");
  }

  if (profile.has_instructor && !profile.instructor_number) {
    missing.push("numer instruktora");
  }

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
    profile.weapon_permit_number,
    profile.weapon_permit_type,
    profile.weapon_permit_issuer,
  ];

  const filled = fields.filter((field) => field && field.trim()).length;

  return Math.round((filled / fields.length) * 100);
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

export default function AdminUsersPage() {
  const [currentUserId, setCurrentUserId] = useState("");
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

    if (!user) return;

    const { data: profile } = await supabase
      .from("profiles")
      .select("role,full_name,email")
      .eq("user_id", user.id)
      .single();

    if (profile?.role) {
      setCurrentUserRole(profile.role as UserRole);
      setCurrentUserName(profile.full_name || profile.email || "Nieznany użytkownik");
    }
  }

  async function loadProfiles() {
    setLoading(true);
    setMessage("");

    await loadCurrentUser();

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
        weapon_permit_number,
        weapon_permit_type,
        weapon_permit_issuer,
        has_range_officer,
        range_officer_number,
        has_instructor,
        instructor_number
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
      const permit = profile.weapon_permit_number?.toLowerCase() ?? "";
      const issuer = profile.weapon_permit_issuer?.toLowerCase() ?? "";

      const matchesSearch =
        !phrase ||
        email.includes(phrase) ||
        name.includes(phrase) ||
        phone.includes(phrase) ||
        role.includes(phrase) ||
        status.includes(phrase) ||
        permit.includes(phrase) ||
        issuer.includes(phrase);

      const matchesStatus =
        statusFilter === "all" ||
        status === statusFilter ||
        (statusFilter === "unverified" && isUnverifiedStatus(status));

      const matchesRole = roleFilter === "all" || role === roleFilter;

      return matchesSearch && matchesStatus && matchesRole;
    });
  }, [profiles, search, statusFilter, roleFilter]);

  const counters = useMemo(() => {
    return {
      all: profiles.length,
      pending: profiles.filter(
        (profile) => profile.verification_status === "pending"
      ).length,
      unverified: profiles.filter((profile) =>
        isUnverifiedStatus(profile.verification_status)
      ).length,
      verified: profiles.filter(
        (profile) => profile.verification_status === "verified"
      ).length,
      rejected: profiles.filter(
        (profile) => profile.verification_status === "rejected"
      ).length,
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

  function getAuditAction(
    changes: Partial<
      Pick<Profile, "role" | "verification_status" | "admin_note">
    >
  ) {
    if (changes.role) return "PROFILE_ROLE_CHANGED";
    if (changes.verification_status) return "PROFILE_VERIFICATION_CHANGED";

    if (Object.prototype.hasOwnProperty.call(changes, "admin_note")) {
      return "PROFILE_ADMIN_NOTE_UPDATED";
    }

    return "PROFILE_UPDATED";
  }

  async function createAuditLog(
    profile: Profile,
    changes: Partial<
      Pick<Profile, "role" | "verification_status" | "admin_note">
    >
  ) {
    if (!currentUserId) return null;

    const hasAdminNoteChange = Object.prototype.hasOwnProperty.call(
      changes,
      "admin_note"
    );

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
          admin_note_exists: Boolean(profile.admin_note),
        },
        after: {
          role: changes.role ?? profile.role,
          verification_status:
            changes.verification_status ?? profile.verification_status,
          admin_note_changed: hasAdminNoteChange,
        },
      },
    });

    return error?.message ?? null;
  }

  async function updateProfile(
    profile: Profile,
    changes: Partial<
      Pick<Profile, "role" | "verification_status" | "admin_note">
    >
  ) {
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

    const { error } = await supabase
      .from("profiles")
      .update({
        ...changes,
        updated_at: new Date().toISOString(),
      })
      .eq("user_id", profile.user_id);

    setSavingUserId(null);

    if (error) {
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    const updatedAt = new Date().toISOString();

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
              Zarządzanie rolami, weryfikacją kont, pełnymi danymi użytkownika i
              notatkami administratora.
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
                placeholder="E-mail, imię, telefon, rola, status, pozwolenie, organ..."
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

                        <button
                          type="button"
                          onClick={() =>
                            setExpandedUserId(isExpanded ? null : profile.user_id)
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
                          Weryfikacja
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
                            onClick={() =>
                              updateProfile(profile, {
                                verification_status: "verified",
                              })
                            }
                            className="rounded-xl border border-green-700 px-3 py-2 text-xs font-bold text-green-300 transition hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Zweryfikuj
                          </button>

                          <button
                            type="button"
                            disabled={isSaving || isOwnAccount}
                            onClick={() =>
                              updateProfile(profile, {
                                verification_status: "pending",
                              })
                            }
                            className="rounded-xl border border-yellow-700 px-3 py-2 text-xs font-bold text-yellow-300 transition hover:bg-yellow-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Cofnij do oczekujących
                          </button>

                          <button
                            type="button"
                            disabled={isSaving || isOwnAccount}
                            onClick={() =>
                              updateProfile(profile, {
                                verification_status: "rejected",
                              })
                            }
                            className="rounded-xl border border-red-700 px-3 py-2 text-xs font-bold text-red-300 transition hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            Odrzuć
                          </button>
                        </div>
                      </div>

                      <div>
                        <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Notatka admina / pracownika
                        </label>

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
                          placeholder="Np. dokumenty sprawdzone, kontakt telefoniczny, uwagi..."
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
                          Zapisz notatkę
                        </button>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-sm">
                        <p className="text-zinc-500">Aktualna rola</p>

                        <p className="mt-1 font-bold text-green-400">
                          {getRoleLabel(profile.role)}
                        </p>

                        <p className="mt-4 text-zinc-500">Status</p>

                        <p className="mt-1 font-bold text-zinc-200">
                          {getStatusLabel(profile.verification_status)}
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
                              Pełne dane do weryfikacji
                            </h3>

                            <p className="mt-1 text-sm text-zinc-400">
                              Kompletność danych:{" "}
                              <span className="font-bold text-white">
                                {completion}%
                              </span>
                            </p>
                          </div>

                          {missingFields.length === 0 ? (
                            <span className="rounded-full border border-green-700 bg-green-950 px-4 py-2 text-sm font-bold text-green-300">
                              Dane kompletne
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

                        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Dane podstawowe
                            </p>

                            <p className="text-sm text-zinc-500">Imię i nazwisko</p>
                            <p className="mb-3 font-semibold">
                              {valueOrMissing(profile.full_name)}
                            </p>

                            <p className="text-sm text-zinc-500">E-mail</p>
                            <p className="mb-3 font-semibold">
                              {valueOrMissing(profile.email)}
                            </p>

                            <p className="text-sm text-zinc-500">Telefon</p>
                            <p className="font-semibold">
                              {valueOrMissing(profile.phone)}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Adres
                            </p>

                            <p className="text-sm text-zinc-500">Kod pocztowy</p>
                            <p className="mb-3 font-semibold">
                              {valueOrMissing(profile.postal_code)}
                            </p>

                            <p className="text-sm text-zinc-500">Miasto</p>
                            <p className="mb-3 font-semibold">
                              {valueOrMissing(profile.city)}
                            </p>

                            <p className="text-sm text-zinc-500">Ulica</p>
                            <p className="mb-3 font-semibold">
                              {valueOrMissing(profile.street)}
                            </p>

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
                              Pozwolenie na broń
                            </p>

                            <p className="text-sm text-zinc-500">
                              Numer pozwolenia
                            </p>
                            <p className="mb-3 font-semibold">
                              {valueOrMissing(profile.weapon_permit_number)}
                            </p>

                            <p className="text-sm text-zinc-500">
                              Typ pozwolenia
                            </p>
                            <p className="mb-3 font-semibold">
                              {valueOrMissing(profile.weapon_permit_type)}
                            </p>

                            <p className="text-sm text-zinc-500">
                              Organ wydający
                            </p>
                            <p className="font-semibold">
                              {valueOrMissing(profile.weapon_permit_issuer)}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Prowadzący strzelanie
                            </p>

                            <p className="text-sm text-zinc-500">
                              Posiada uprawnienia
                            </p>
                            <p className="mb-3 font-semibold">
                              {yesNo(profile.has_range_officer)}
                            </p>

                            <p className="text-sm text-zinc-500">
                              Numer uprawnień
                            </p>
                            <p className="font-semibold">
                              {valueOrMissing(profile.range_officer_number)}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              Instruktor
                            </p>

                            <p className="text-sm text-zinc-500">
                              Posiada uprawnienia
                            </p>
                            <p className="mb-3 font-semibold">
                              {yesNo(profile.has_instructor)}
                            </p>

                            <p className="text-sm text-zinc-500">
                              Numer uprawnień
                            </p>
                            <p className="font-semibold">
                              {valueOrMissing(profile.instructor_number)}
                            </p>
                          </div>

                          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                            <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                              System
                            </p>

                            <p className="text-sm text-zinc-500">Status konta</p>
                            <p className="mb-3 font-semibold">
                              {getStatusLabel(profile.verification_status)}
                            </p>

                            <p className="text-sm text-zinc-500">Rola</p>
                            <p className="mb-3 font-semibold">
                              {getRoleLabel(profile.role)}
                            </p>

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