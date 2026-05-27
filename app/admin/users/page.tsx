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

export default function AdminUsersPage() {
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [loading, setLoading] = useState(true);
  const [savingUserId, setSavingUserId] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [search, setSearch] = useState("");

  async function loadProfiles() {
    setLoading(true);
    setMessage("");

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

    if (!phrase) {
      return profiles;
    }

    return profiles.filter((profile) => {
      const email = profile.email?.toLowerCase() ?? "";
      const name = profile.full_name?.toLowerCase() ?? "";
      const phone = profile.phone?.toLowerCase() ?? "";
      const role = profile.role?.toLowerCase() ?? "";
      const status = profile.verification_status?.toLowerCase() ?? "";

      return (
        email.includes(phrase) ||
        name.includes(phrase) ||
        phone.includes(phrase) ||
        role.includes(phrase) ||
        status.includes(phrase)
      );
    });
  }, [profiles, search]);

  async function updateProfile(
    profile: Profile,
    changes: Partial<Pick<Profile, "role" | "verification_status" | "admin_note">>
  ) {
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

        <div className="mb-6 grid gap-4 rounded-2xl border border-zinc-800 bg-zinc-900 p-5 md:grid-cols-[1fr_auto] md:items-center">
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
        </div>

        {message && (
          <div className="mb-6 rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200">
            {message}
          </div>
        )}

        <div className="overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900">
          <div className="border-b border-zinc-800 px-5 py-4">
            <p className="text-sm text-zinc-400">
              Liczba użytkowników:{" "}
              <span className="font-bold text-white">
                {filteredProfiles.length}
              </span>
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

                return (
                  <article
                    key={profile.user_id}
                    className="rounded-2xl border border-zinc-800 bg-zinc-950 p-5"
                  >
                    <div className="grid gap-5 xl:grid-cols-[1.2fr_0.8fr_0.8fr_1.2fr_auto] xl:items-start">
                      <div>
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
                            <option key={role} value={role}>
                              {getRoleLabel(role)}
                            </option>
                          ))}
                        </select>
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
                            <option key={status} value={status}>
                              {getStatusLabel(status)}
                            </option>
                          ))}
                        </select>
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