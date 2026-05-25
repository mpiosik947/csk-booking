"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

const ADMIN_EMAIL = "m.piosik94@gmail.com";

type Profile = {
  id: string;
  user_id: string;
  full_name: string | null;
  phone: string | null;
  weapon_permit_number: string | null;
  weapon_permit_type: string | null;
  has_range_officer: boolean | null;
  range_officer_number: string | null;
  has_instructor: boolean | null;
  instructor_number: string | null;
  verification_status: string | null;
  verified_at: string | null;
  verified_by: string | null;
  verification_note: string | null;
  unverified_at: string | null;
  unverified_by: string | null;
  admin_note: string | null;
  created_at: string | null;
};

export default function AdminUsersPage() {
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [message, setMessage] = useState("");
  const [savingId, setSavingId] = useState("");

  useEffect(() => {
    async function loadUsers() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setMessage("Musisz być zalogowany jako administrator.");
        setLoading(false);
        return;
      }

      if (user.email !== ADMIN_EMAIL) {
        setMessage("Brak dostępu. To konto nie ma uprawnień administratora.");
        setLoading(false);
        return;
      }

      setIsAdmin(true);

      const { data, error } = await supabase
        .from("profiles")
        .select(
          `
          id,
          user_id,
          full_name,
          phone,
          weapon_permit_number,
          weapon_permit_type,
          has_range_officer,
          range_officer_number,
          has_instructor,
          instructor_number,
          verification_status,
          verified_at,
          verified_by,
          verification_note,
          unverified_at,
          unverified_by,
          admin_note,
          created_at
        `
        )
        .order("created_at", { ascending: false });

      if (error) {
        setMessage(`Błąd pobierania użytkowników: ${error.message}`);
        setLoading(false);
        return;
      }

      setProfiles((data as Profile[]) ?? []);
      setLoading(false);
    }

    loadUsers();
  }, []);

  async function updateVerification(
    profileId: string,
    status: "zweryfikowane" | "niezweryfikowane"
  ) {
    setMessage("");
    setSavingId(profileId);

    const {
      data: { user },
    } = await supabase.auth.getUser();

    const now = new Date().toISOString();

    const updateData =
      status === "zweryfikowane"
        ? {
            verification_status: status,
            verified_at: now,
            verified_by: user?.id ?? null,
            unverified_at: null,
            unverified_by: null,
            updated_at: now,
          }
        : {
            verification_status: status,
            unverified_at: now,
            unverified_by: user?.email ?? user?.id ?? null,
            updated_at: now,
          };

    const { error } = await supabase
      .from("profiles")
      .update(updateData)
      .eq("id", profileId);

    setSavingId("");

    if (error) {
      setMessage(`Błąd zmiany statusu: ${error.message}`);
      return;
    }

    setProfiles((current) =>
      current.map((profile) =>
        profile.id === profileId
          ? {
              ...profile,
              ...updateData,
            }
          : profile
      )
    );

    setMessage(
      status === "zweryfikowane"
        ? "Konto zostało zweryfikowane."
        : "Cofnięto weryfikację konta."
    );
  }

  function updateAdminNote(profileId: string, note: string) {
    setProfiles((current) =>
      current.map((profile) =>
        profile.id === profileId ? { ...profile, admin_note: note } : profile
      )
    );
  }

  function updateVerificationNote(profileId: string, note: string) {
    setProfiles((current) =>
      current.map((profile) =>
        profile.id === profileId
          ? { ...profile, verification_note: note }
          : profile
      )
    );
  }

  async function saveAdminNote(
    profileId: string,
    adminNote: string,
    verificationNote: string
  ) {
    setMessage("");
    setSavingId(profileId);

    const { error } = await supabase
      .from("profiles")
      .update({
        admin_note: adminNote,
        verification_note: verificationNote,
        updated_at: new Date().toISOString(),
      })
      .eq("id", profileId);

    setSavingId("");

    if (error) {
      setMessage(`Błąd zapisu notatki: ${error.message}`);
      return;
    }

    setMessage("Notatki zostały zapisane.");
  }

  function getStatusBadge(status?: string | null) {
    if (status === "zweryfikowane") {
      return (
        <span className="rounded-full border border-green-700 bg-green-950 px-3 py-1 text-xs font-semibold text-green-300">
          Zweryfikowane
        </span>
      );
    }

    return (
      <span className="rounded-full border border-yellow-700 bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300">
        Niezweryfikowane
      </span>
    );
  }

  function getMessageClass(message: string) {
    if (
      message.includes("zweryfikowane") ||
      message.includes("Cofnięto") ||
      message.includes("zapisane")
    ) {
      return "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-6 py-10">
        <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="text-3xl font-bold">Użytkownicy</h1>

            <p className="mt-2 text-zinc-400">
              Weryfikacja kont klientów, danych strzeleckich i uprawnień.
            </p>
          </div>

          <div className="flex flex-col gap-3 sm:flex-row">
            <a
              href="/admin"
              className="rounded-xl border border-zinc-700 px-4 py-3 text-center text-sm font-semibold transition hover:bg-zinc-900"
            >
              ← Panel admina
            </a>

            <a
              href="/"
              className="rounded-xl border border-zinc-700 px-4 py-3 text-center text-sm font-semibold transition hover:bg-zinc-900"
            >
              Strona główna
            </a>
          </div>
        </div>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie użytkowników...
          </div>
        )}

        {!loading && message && (
          <div className={getMessageClass(message)}>{message}</div>
        )}

        {!loading && isAdmin && (
          <div className="grid gap-5">
            {profiles.length === 0 ? (
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
                Brak użytkowników do wyświetlenia.
              </div>
            ) : (
              profiles.map((profile) => (
                <div
                  key={profile.id}
                  className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
                >
                  <div className="mb-5 flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div>
                      <h2 className="text-2xl font-bold">
                        {profile.full_name || "Brak imienia i nazwiska"}
                      </h2>

                      <p className="mt-1 text-sm text-zinc-400">
                        Tel: {profile.phone || "brak"}
                      </p>

                      <p className="mt-1 text-xs text-zinc-500">
                        ID użytkownika: {profile.user_id}
                      </p>
                    </div>

                    <div>{getStatusBadge(profile.verification_status)}</div>
                  </div>

                  <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                      <p className="text-xs text-zinc-500">
                        Numer pozwolenia
                      </p>
                      <p className="mt-1 font-semibold">
                        {profile.weapon_permit_number || "Brak"}
                      </p>
                    </div>

                    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                      <p className="text-xs text-zinc-500">Typ pozwolenia</p>
                      <p className="mt-1 font-semibold">
                        {profile.weapon_permit_type || "Brak"}
                      </p>
                    </div>

                    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                      <p className="text-xs text-zinc-500">
                        Prowadzący strzelanie
                      </p>
                      <p className="mt-1 font-semibold">
                        {profile.has_range_officer
                          ? profile.range_officer_number || "Tak"
                          : "Nie"}
                      </p>
                    </div>

                    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                      <p className="text-xs text-zinc-500">Instruktor</p>
                      <p className="mt-1 font-semibold">
                        {profile.has_instructor
                          ? profile.instructor_number || "Tak"
                          : "Nie"}
                      </p>
                    </div>
                  </div>

                  <div className="mt-5 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                    <h3 className="mb-3 text-lg font-semibold">
                      Historia weryfikacji
                    </h3>

                    <div className="grid gap-3 text-sm text-zinc-400 md:grid-cols-2">
                      <div>
                        <p className="text-zinc-500">Zweryfikowano</p>
                        <p className="font-semibold text-zinc-200">
                          {profile.verified_at
                            ? new Date(profile.verified_at).toLocaleString(
                                "pl-PL"
                              )
                            : "Brak"}
                        </p>
                      </div>

                      <div>
                        <p className="text-zinc-500">Zweryfikował</p>
                        <p className="font-semibold text-zinc-200">
                          {profile.verified_by || "Brak"}
                        </p>
                      </div>

                      <div>
                        <p className="text-zinc-500">Cofnięto weryfikację</p>
                        <p className="font-semibold text-zinc-200">
                          {profile.unverified_at
                            ? new Date(profile.unverified_at).toLocaleString(
                                "pl-PL"
                              )
                            : "Brak"}
                        </p>
                      </div>

                      <div>
                        <p className="text-zinc-500">Cofnął</p>
                        <p className="font-semibold text-zinc-200">
                          {profile.unverified_by || "Brak"}
                        </p>
                      </div>
                    </div>
                  </div>

                  <div className="mt-5 grid gap-5 md:grid-cols-2">
                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Notatka admina
                      </label>

                      <textarea
                        value={profile.admin_note ?? ""}
                        onChange={(event) =>
                          updateAdminNote(profile.id, event.target.value)
                        }
                        rows={4}
                        placeholder="Np. dokumenty sprawdzone, wymaga kontaktu, klient stały..."
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                      />
                    </div>

                    <div>
                      <label className="mb-2 block text-sm text-zinc-300">
                        Notatka weryfikacyjna
                      </label>

                      <textarea
                        value={profile.verification_note ?? ""}
                        onChange={(event) =>
                          updateVerificationNote(profile.id, event.target.value)
                        }
                        rows={4}
                        placeholder="Np. pozwolenie okazane, dane zgodne, dokumenty sprawdzone..."
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                      />
                    </div>
                  </div>

                  <div className="mt-5 flex flex-col gap-3 sm:flex-row">
                    <button
                      type="button"
                      onClick={() =>
                        updateVerification(profile.id, "zweryfikowane")
                      }
                      disabled={
                        savingId === profile.id ||
                        profile.verification_status === "zweryfikowane"
                      }
                      className="rounded-xl bg-green-700 px-5 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      {savingId === profile.id
                        ? "Zapisywanie..."
                        : "Zweryfikuj konto"}
                    </button>

                    <button
                      type="button"
                      onClick={() =>
                        updateVerification(profile.id, "niezweryfikowane")
                      }
                      disabled={
                        savingId === profile.id ||
                        profile.verification_status !== "zweryfikowane"
                      }
                      className="rounded-xl border border-red-700 px-5 py-3 font-semibold text-red-300 transition hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      Cofnij weryfikację
                    </button>

                    <button
                      type="button"
                      onClick={() =>
                        saveAdminNote(
                          profile.id,
                          profile.admin_note ?? "",
                          profile.verification_note ?? ""
                        )
                      }
                      disabled={savingId === profile.id}
                      className="rounded-xl border border-zinc-700 px-5 py-3 font-semibold text-zinc-300 transition hover:bg-zinc-950 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      Zapisz notatki
                    </button>
                  </div>
                </div>
              ))
            )}
          </div>
        )}
      </section>
    </main>
  );
}