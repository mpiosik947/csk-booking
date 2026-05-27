"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { supabase } from "../../../lib/supabase";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";
type VerificationStatus = "pending" | "verified" | "rejected";

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
};

const roleOptions: UserRole[] = [
  "admin",
  "pracownik",
  "instruktor",
  "user",
];

const verificationOptions: VerificationStatus[] = [
  "pending",
  "verified",
  "rejected",
];

const statusFilters = [
  { label: "Wszyscy", value: "all" },
  { label: "Oczekujący", value: "pending" },
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
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-400";
  }
}

export default function AdminUsersPage() {
  const [currentUserId, setCurrentUserId] = useState("");
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [loading, setLoading] = useState(true);
  const [savingUserId, setSavingUserId] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [roleFilter, setRoleFilter] = useState("all");

  async function loadCurrentUser() {
    const {
      data: { user },
    } = await supabase.auth.getUser();

    setCurrentUserId(user?.id ?? "");
  }

  async function loadProfiles() {
    setLoading(true);
    setMessage("");

    await loadCurrentUser();

    const { data, error } = await supabase
      .from("profiles")
      .select(
        "id,user_id,email,full_name,phone,role,verification_status,admin_note,created_at,updated_at"
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

      const matchesSearch =
        !phrase ||
        email.includes(phrase) ||
        name.includes(phrase) ||
        phone.includes(phrase) ||
        role.includes(phrase) ||
        status.includes(phrase);

      const matchesStatus =
        statusFilter === "all" || status === statusFilter;

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

  async function updateProfile(
    profile: Profile,
    changes: Partial<
      Pick<Profile, "role" | "verification_status" | "admin_note">
    >
  ) {
    const isOwnAccount = profile.user_id === currentUserId;

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

    setProfiles((currentProfiles) =>
      currentProfiles.map((item) =>
        item.user_id === profile.user_id
          ? {
              ...item,
              ...changes,
              updated_at: new Date().toISOString(),
            }
          : item
      )
    );

    setMessage("Zapisano zmiany.");
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

            <h1 className="text-4xl font-bold">
              Użytkownicy
            </h1>

            <p className="mt-3 max-w-2xl text-zinc-400">
              Zarządzanie rolami, weryfikacją kont i notatkami administratora.
            </p>
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
                placeholder="E-mail, imię, telefon, rola, status..."
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
            <div className="p-8 text-zinc-400">
              Ładowanie użytkowników...
            </div>
          ) : filteredProfiles.length === 0 ? (
            <div className="p-8 text-zinc-400">
              Brak użytkowników do wyświetlenia.
            </div>
          ) : (
            <div className="grid gap-4 p-4">
              {filteredProfiles.map((profile) => {
                const isSaving = savingUserId === profile.user_id;
                const isOwnAccount = profile.user_id === currentUserId;

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
                      </div>

                      <div>
                        <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Rola
                        </label>

                        <select
                          value={profile.role || "user"}
                          disabled={isSaving}
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

                        {isOwnAccount && (
                          <p className="mt-2 text-xs text-green-400">
                            Nie możesz odebrać sam sobie roli admina.
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
                          Notatka admina
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
                        <p className="text-zinc-500">
                          Aktualna rola
                        </p>

                        <p className="mt-1 font-bold text-green-400">
                          {getRoleLabel(profile.role)}
                        </p>

                        <p className="mt-4 text-zinc-500">
                          Status
                        </p>

                        <p className="mt-1 font-bold text-zinc-200">
                          {getStatusLabel(profile.verification_status)}
                        </p>

                        <p className="mt-4 text-zinc-500">
                          Utworzono
                        </p>

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