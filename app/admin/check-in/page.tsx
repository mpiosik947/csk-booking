"use client";

import { Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { supabase } from "../../../lib/supabase";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";

type Reservation = {
  id: string;
  check_in_token: string | null;
  user_id: string | null;
  customer_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  reservation_date: string | null;
  start_time: string | null;
  end_time: string | null;
  reservation_status: string | null;
  attendance_status: string | null;
  payment_status: string | null;
  checked_in_at: string | null;
  price: number | null;
  shooting_lanes?: {
    name: string | null;
  }[] | null;
};

type Profile = {
  id: string;
  user_id: string;
  email: string | null;
  full_name: string | null;
  phone: string | null;
  role: UserRole | string | null;
  verification_status: string | null;
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

function todayISODate() {
  return new Date().toISOString().slice(0, 10);
}

function normalizeTime(time: string | null) {
  if (!time) return "";
  return time.slice(0, 5);
}

function getLaneName(reservation: Reservation) {
  return reservation.shooting_lanes?.[0]?.name || "Nieznana oś";
}

function getReservationStatusLabel(status: string | null) {
  switch (status) {
    case "confirmed":
      return "Potwierdzona";
    case "completed":
      return "Zakończona";
    case "no_show":
      return "No-show";
    case "cancelled_by_admin":
    case "cancelled_by_user":
    case "cancelled":
    case "canceled":
      return "Anulowana";
    default:
      return status || "Brak statusu";
  }
}

function getPaymentStatusLabel(status: string | null) {
  switch (status) {
    case "pay_on_site":
      return "Płatność na miejscu";
    case "paid":
      return "Opłacona";
    case "unpaid":
      return "Nieopłacona";
    case "free":
      return "Darmowa";
    case "voucher":
      return "Voucher";
    default:
      return status || "Brak statusu";
  }
}

function getVerificationStatusLabel(status: string | null) {
  switch (status) {
    case "verified":
      return "Zweryfikowane";
    case "pending":
      return "Oczekuje";
    case "rejected":
      return "Odrzucone";
    case "niezweryfikowane":
    case "unverified":
      return "Niezweryfikowane";
    default:
      return "Brak statusu";
  }
}

function isVerifiedProfile(profile: Profile | null | undefined) {
  return profile?.verification_status === "verified";
}

function valueOrMissing(value: string | null | undefined) {
  return value && value.trim() ? value : "Brak danych";
}

function yesNo(value: boolean | null) {
  return value ? "Tak" : "Nie";
}

function getMissingFields(profile: Profile | null | undefined) {
  const missing: string[] = [];

  if (!profile) {
    return ["brak profilu użytkownika"];
  }

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

function getCompletionPercent(profile: Profile | null | undefined) {
  if (!profile) return 0;

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

function getStatusClass(status: string | null) {
  switch (status) {
    case "completed":
      return "border-blue-700 bg-blue-950 text-blue-300";
    case "confirmed":
      return "border-green-700 bg-green-950 text-green-300";
    case "no_show":
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case "cancelled_by_admin":
    case "cancelled_by_user":
    case "cancelled":
    case "canceled":
      return "border-red-700 bg-red-950 text-red-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }
}

function getPaymentClass(status: string | null) {
  switch (status) {
    case "paid":
      return "border-green-700 bg-green-950 text-green-300";
    case "pay_on_site":
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case "unpaid":
      return "border-red-700 bg-red-950 text-red-300";
    case "free":
      return "border-blue-700 bg-blue-950 text-blue-300";
    case "voucher":
      return "border-purple-700 bg-purple-950 text-purple-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }
}

function getVerificationClass(profile: Profile | null | undefined) {
  if (isVerifiedProfile(profile)) {
    return "border-green-700 bg-green-950 text-green-300";
  }

  return "border-orange-700 bg-orange-950 text-orange-300";
}

function CheckInContent() {
  const params = useSearchParams();
  const token = params.get("token");

  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [selectedReservation, setSelectedReservation] =
    useState<Reservation | null>(null);
  const [profilesByUserId, setProfilesByUserId] = useState<
    Record<string, Profile>
  >({});

  const [currentUserId, setCurrentUserId] = useState("");
  const [currentUserName, setCurrentUserName] = useState("");
  const [currentUserRole, setCurrentUserRole] = useState<UserRole | "">("");

  const [dateFilter, setDateFilter] = useState(todayISODate());
  const [search, setSearch] = useState("");

  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const [savingId, setSavingId] = useState<string | null>(null);

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
      .maybeSingle();

    if (profile?.role) {
      setCurrentUserRole(String(profile.role) as UserRole);
      setCurrentUserName(
        profile.full_name || profile.email || "Nieznany użytkownik"
      );
    }
  }

  async function loadProfilesForReservations(items: Reservation[]) {
    const userIds = Array.from(
      new Set(
        items
          .map((reservation) => reservation.user_id)
          .filter((id): id is string => Boolean(id))
      )
    );

    if (userIds.length === 0) {
      setProfilesByUserId({});
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
        weapon_permit_number,
        weapon_permit_type,
        weapon_permit_issuer,
        has_range_officer,
        range_officer_number,
        has_instructor,
        instructor_number
      `
      )
      .in("user_id", userIds);

    if (error) {
      setMessage(`Błąd pobierania profili: ${error.message}`);
      return;
    }

    const map: Record<string, Profile> = {};

    for (const profile of (data ?? []) as Profile[]) {
      map[profile.user_id] = profile;
    }

    setProfilesByUserId(map);
  }

  async function createAuditLog({
    action,
    reservation,
    profile,
    details,
  }: {
    action: string;
    reservation?: Reservation;
    profile?: Profile | null;
    details?: Record<string, unknown>;
  }) {
    if (!currentUserId) return null;

    const { error } = await supabase.from("audit_logs").insert({
      actor_user_id: currentUserId,
      actor_name: currentUserName || "Nieznany użytkownik",
      actor_role: currentUserRole || "unknown",
      action,
      target_type: reservation ? "reservation" : "profile",
      target_id: reservation?.id || profile?.user_id || null,
      target_name:
        reservation?.customer_name ||
        profile?.full_name ||
        profile?.email ||
        "Nieznany cel",
      details: details ?? {},
    });

    return error?.message ?? null;
  }

  async function loadReservations() {
    setLoading(true);
    setMessage("");

    await loadCurrentUser();

    let query = supabase
      .from("reservations")
      .select(
        `
        id,
        check_in_token,
        user_id,
        customer_name,
        customer_email,
        customer_phone,
        reservation_date,
        start_time,
        end_time,
        reservation_status,
        attendance_status,
        payment_status,
        checked_in_at,
        price,
        shooting_lanes (
          name
        )
      `
      )
      .order("start_time", { ascending: true });

    if (dateFilter) {
      query = query.eq("reservation_date", dateFilter);
    }

    const { data, error } = await query;

    setLoading(false);

    if (error) {
      setMessage(`Błąd pobierania rezerwacji: ${error.message}`);
      return;
    }

    const loadedReservations = (data ?? []) as unknown as Reservation[];

    setReservations(loadedReservations);
    await loadProfilesForReservations(loadedReservations);
  }

  async function loadReservationByToken(checkInToken: string) {
    setLoading(true);
    setMessage("");

    await loadCurrentUser();

    const { data, error } = await supabase
      .from("reservations")
      .select(
        `
        id,
        check_in_token,
        user_id,
        customer_name,
        customer_email,
        customer_phone,
        reservation_date,
        start_time,
        end_time,
        reservation_status,
        attendance_status,
        payment_status,
        checked_in_at,
        price,
        shooting_lanes (
          name
        )
      `
      )
      .eq("check_in_token", checkInToken)
      .single();

    setLoading(false);

    if (error) {
      setMessage("Nie znaleziono rezerwacji dla tego kodu QR.");
      return;
    }

    const reservation = data as unknown as Reservation;

    setSelectedReservation(reservation);
    await loadProfilesForReservations([reservation]);
  }

  useEffect(() => {
    if (token) {
      loadReservationByToken(token);
      return;
    }

    loadReservations();
  }, [token, dateFilter]);

  const filteredReservations = useMemo(() => {
    const phrase = search.trim().toLowerCase();

    if (!phrase) {
      return reservations;
    }

    return reservations.filter((reservation) => {
      const profile = reservation.user_id
        ? profilesByUserId[reservation.user_id]
        : null;

      const name = reservation.customer_name?.toLowerCase() ?? "";
      const email = reservation.customer_email?.toLowerCase() ?? "";
      const phone = reservation.customer_phone?.toLowerCase() ?? "";
      const lane = getLaneName(reservation).toLowerCase();
      const status = reservation.reservation_status?.toLowerCase() ?? "";
      const payment = reservation.payment_status?.toLowerCase() ?? "";
      const verification = profile?.verification_status?.toLowerCase() ?? "";
      const permit = profile?.weapon_permit_number?.toLowerCase() ?? "";
      const issuer = profile?.weapon_permit_issuer?.toLowerCase() ?? "";

      return (
        name.includes(phrase) ||
        email.includes(phrase) ||
        phone.includes(phrase) ||
        lane.includes(phrase) ||
        status.includes(phrase) ||
        payment.includes(phrase) ||
        verification.includes(phrase) ||
        permit.includes(phrase) ||
        issuer.includes(phrase)
      );
    });
  }, [reservations, search, profilesByUserId]);

  async function updateReservation(
    reservation: Reservation,
    changes: Partial<
      Pick<
        Reservation,
        | "reservation_status"
        | "attendance_status"
        | "payment_status"
        | "checked_in_at"
      >
    >,
    auditAction = "RESERVATION_UPDATED"
  ) {
    setSavingId(reservation.id);
    setMessage("");

    const { error } = await supabase
      .from("reservations")
      .update(changes)
      .eq("id", reservation.id);

    if (error) {
      setSavingId(null);
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id ? { ...item, ...changes } : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation({
        ...selectedReservation,
        ...changes,
      });
    }

    const profile = reservation.user_id
      ? profilesByUserId[reservation.user_id]
      : null;

    const auditError = await createAuditLog({
      action: auditAction,
      reservation,
      profile,
      details: {
        before: {
          reservation_status: reservation.reservation_status,
          attendance_status: reservation.attendance_status,
          payment_status: reservation.payment_status,
          checked_in_at: reservation.checked_in_at,
        },
        after: changes,
      },
    });

    setSavingId(null);

    if (auditError) {
      setMessage(
        `Zapisano zmianę, ale nie udało się dodać wpisu audit log: ${auditError}`
      );
      return;
    }

    setMessage("Zapisano zmianę.");
  }

  async function markCompleted(reservation: Reservation) {
    const now = new Date().toISOString();

    await updateReservation(
      reservation,
      {
        attendance_status: "present",
        reservation_status: "completed",
        checked_in_at: now,
      },
      "CHECK_IN_COMPLETED"
    );
  }

  async function verifyAccountAndStartVisit(reservation: Reservation) {
    if (!reservation.user_id) {
      setMessage("Ta rezerwacja nie jest powiązana z kontem użytkownika.");
      return;
    }

    const profile = profilesByUserId[reservation.user_id];

    if (!profile) {
      setMessage("Nie znaleziono profilu użytkownika do weryfikacji.");
      return;
    }

    const missingFields = getMissingFields(profile);

    if (missingFields.length > 0) {
      const confirmed = window.confirm(
        `Konto posiada braki:\n\n• ${missingFields.join(
          "\n• "
        )}\n\nCzy mimo to zweryfikować konto i rozpocząć wizytę?`
      );

      if (!confirmed) return;
    }

    setSavingId(reservation.id);
    setMessage("");

    const now = new Date().toISOString();

    const { error: profileError } = await supabase
      .from("profiles")
      .update({
        verification_status: "verified",
        updated_at: now,
      })
      .eq("user_id", reservation.user_id);

    if (profileError) {
      setSavingId(null);
      setMessage(`Błąd weryfikacji konta: ${profileError.message}`);
      return;
    }

    const { error: reservationError } = await supabase
      .from("reservations")
      .update({
        attendance_status: "present",
        reservation_status: "completed",
        checked_in_at: now,
      })
      .eq("id", reservation.id);

    if (reservationError) {
      setSavingId(null);
      setMessage(
        `Konto zweryfikowane, ale błąd check-in: ${reservationError.message}`
      );
      return;
    }

    const updatedProfile: Profile = {
      ...profile,
      verification_status: "verified",
      updated_at: now,
    };

    const updatedReservation: Reservation = {
      ...reservation,
      attendance_status: "present",
      reservation_status: "completed",
      checked_in_at: now,
    };

    setProfilesByUserId((current) => ({
      ...current,
      [reservation.user_id as string]: updatedProfile,
    }));

    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id ? updatedReservation : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation(updatedReservation);
    }

    const auditError = await createAuditLog({
      action: "FIRST_VISIT_PROFILE_VERIFIED_AND_CHECKED_IN",
      reservation,
      profile,
      details: {
        profile_before: {
          verification_status: profile.verification_status,
          completion_percent: getCompletionPercent(profile),
          missing_fields: missingFields,
        },
        profile_after: {
          verification_status: "verified",
        },
        reservation_before: {
          reservation_status: reservation.reservation_status,
          attendance_status: reservation.attendance_status,
          checked_in_at: reservation.checked_in_at,
        },
        reservation_after: {
          reservation_status: "completed",
          attendance_status: "present",
          checked_in_at: now,
        },
      },
    });

    setSavingId(null);

    if (auditError) {
      setMessage(
        `Konto zweryfikowane i wizyta rozpoczęta, ale nie udało się dodać wpisu audit log: ${auditError}`
      );
      return;
    }

    setMessage("Konto zweryfikowane i wizyta rozpoczęta.");
  }

  async function markNoShow(reservation: Reservation) {
    await updateReservation(
      reservation,
      {
        attendance_status: "no_show",
        reservation_status: "no_show",
      },
      "RESERVATION_NO_SHOW"
    );
  }

  async function cancelByAdmin(reservation: Reservation) {
    await updateReservation(
      reservation,
      {
        reservation_status: "cancelled_by_admin",
      },
      "RESERVATION_CANCELLED_BY_ADMIN"
    );
  }

  const mainList =
    token && selectedReservation ? [selectedReservation] : filteredReservations;

  return (
    <div className="mx-auto max-w-7xl">
      <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            CSK Booking
          </p>

          <h1 className="text-4xl font-bold">Check-in i obsługa wizyt</h1>

          <p className="mt-3 max-w-2xl text-zinc-400">
            Obsługa dzisiejszych rezerwacji, obecności, no-show, płatności i
            zakończonych wizyt.
          </p>
        </div>

        <a
          href="/admin"
          className="rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
        >
          ← Panel admina
        </a>
      </div>

      {!token && (
        <div className="mb-6 grid gap-4 rounded-2xl border border-zinc-800 bg-zinc-900 p-5 md:grid-cols-[auto_1fr_auto] md:items-end">
          <div>
            <label className="mb-2 block text-sm font-semibold text-zinc-300">
              Data wizyt
            </label>

            <input
              type="date"
              value={dateFilter}
              onChange={(event) => setDateFilter(event.target.value)}
              className="rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />
          </div>

          <div>
            <label className="mb-2 block text-sm font-semibold text-zinc-300">
              Szukaj
            </label>

            <input
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Imię, e-mail, telefon, oś, status, pozwolenie..."
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />
          </div>

          <button
            type="button"
            onClick={loadReservations}
            disabled={loading}
            className="rounded-xl bg-green-700 px-5 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {loading ? "Odświeżanie..." : "Odśwież"}
          </button>
        </div>
      )}

      {message && (
        <div className="mb-6 rounded-xl border border-zinc-700 bg-zinc-900 p-4 text-sm font-semibold text-zinc-200">
          {message}
        </div>
      )}

      {loading ? (
        <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-zinc-400">
          Ładowanie check-in...
        </div>
      ) : mainList.length === 0 ? (
        <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-zinc-400">
          Brak rezerwacji do obsługi dla wybranego dnia.
        </div>
      ) : (
        <div className="grid gap-4">
          {mainList.map((reservation) => {
            const isSaving = savingId === reservation.id;
            const profile = reservation.user_id
              ? profilesByUserId[reservation.user_id]
              : null;
            const isProfileVerified = isVerifiedProfile(profile);
            const shouldVerifyAtReception =
              Boolean(reservation.user_id) && !isProfileVerified;
            const missingFields = getMissingFields(profile);
            const completion = getCompletionPercent(profile);

            return (
              <article
                key={reservation.id}
                className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5"
              >
                <div className="grid gap-5 xl:grid-cols-[1.1fr_0.8fr_0.9fr_1fr_auto] xl:items-start">
                  <div>
                    <div className="mb-3 flex flex-wrap gap-2">
                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getStatusClass(
                          reservation.reservation_status
                        )}`}
                      >
                        {getReservationStatusLabel(
                          reservation.reservation_status
                        )}
                      </span>

                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getPaymentClass(
                          reservation.payment_status
                        )}`}
                      >
                        {getPaymentStatusLabel(reservation.payment_status)}
                      </span>

                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getVerificationClass(
                          profile
                        )}`}
                      >
                        Konto: {getVerificationStatusLabel(profile?.verification_status ?? null)}
                      </span>
                    </div>

                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Klient
                    </p>

                    <h2 className="mt-2 text-xl font-bold">
                      {reservation.customer_name || profile?.full_name || "Brak danych"}
                    </h2>

                    <p className="mt-1 text-sm text-zinc-400">
                      {reservation.customer_email || profile?.email || "Brak e-maila"}
                    </p>

                    <p className="mt-1 text-sm text-zinc-500">
                      Tel.: {reservation.customer_phone || profile?.phone || "brak"}
                    </p>
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Termin
                    </p>

                    <p className="mt-2 text-lg font-bold">
                      {reservation.reservation_date || "Brak daty"}
                    </p>

                    <p className="mt-1 text-sm text-zinc-400">
                      {normalizeTime(reservation.start_time)}–
                      {normalizeTime(reservation.end_time)}
                    </p>
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Oś
                    </p>

                    <p className="mt-2 text-lg font-bold">
                      {getLaneName(reservation)}
                    </p>

                    <p className="mt-1 text-sm text-green-400">
                      {Number(reservation.price ?? 0).toFixed(0)} zł
                    </p>

                    <p className="mt-4 text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Check-in
                    </p>

                    <p className="mt-1 text-sm text-zinc-300">
                      {reservation.checked_in_at
                        ? new Date(reservation.checked_in_at).toLocaleString(
                            "pl-PL"
                          )
                        : "brak"}
                    </p>
                  </div>

                  <div className="grid gap-3">
                    <div>
                      <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                        Płatność
                      </label>

                      <select
                        value={reservation.payment_status || "pay_on_site"}
                        disabled={isSaving}
                        onChange={(event) =>
                          updateReservation(
                            reservation,
                            {
                              payment_status: event.target.value,
                            },
                            "RESERVATION_PAYMENT_CHANGED"
                          )
                        }
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-sm text-white outline-none focus:border-green-600 disabled:opacity-60"
                      >
                        <option value="pay_on_site">Płatność na miejscu</option>
                        <option value="paid">Opłacona</option>
                        <option value="unpaid">Nieopłacona</option>
                        <option value="free">Darmowa</option>
                        <option value="voucher">Voucher</option>
                      </select>
                    </div>

                    <div>
                      <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                        Status wizyty
                      </label>

                      <select
                        value={reservation.reservation_status || "confirmed"}
                        disabled={isSaving}
                        onChange={(event) =>
                          updateReservation(
                            reservation,
                            {
                              reservation_status: event.target.value,
                            },
                            "RESERVATION_STATUS_CHANGED"
                          )
                        }
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-sm text-white outline-none focus:border-green-600 disabled:opacity-60"
                      >
                        <option value="confirmed">Potwierdzona</option>
                        <option value="completed">Zakończona</option>
                        <option value="no_show">No-show</option>
                        <option value="cancelled_by_admin">
                          Anulowana przez admina
                        </option>
                      </select>
                    </div>
                  </div>

                  <div className="grid gap-2">
                    {shouldVerifyAtReception ? (
                      <button
                        type="button"
                        disabled={isSaving}
                        onClick={() => verifyAccountAndStartVisit(reservation)}
                        className="rounded-xl border border-orange-700 px-4 py-3 text-sm font-bold text-orange-300 transition hover:bg-orange-950 disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Zweryfikuj konto i rozpocznij wizytę
                      </button>
                    ) : (
                      <button
                        type="button"
                        disabled={isSaving}
                        onClick={() => markCompleted(reservation)}
                        className="rounded-xl border border-green-700 px-4 py-3 text-sm font-bold text-green-300 transition hover:bg-green-950 disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Klient był / zakończ
                      </button>
                    )}

                    <button
                      type="button"
                      disabled={isSaving}
                      onClick={() => markNoShow(reservation)}
                      className="rounded-xl border border-yellow-700 px-4 py-3 text-sm font-bold text-yellow-300 transition hover:bg-yellow-950 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      No-show
                    </button>

                    <button
                      type="button"
                      disabled={isSaving}
                      onClick={() => cancelByAdmin(reservation)}
                      className="rounded-xl border border-red-700 px-4 py-3 text-sm font-bold text-red-300 transition hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      Anuluj
                    </button>

                    {isSaving && (
                      <p className="text-xs font-semibold text-yellow-400">
                        Zapisywanie...
                      </p>
                    )}
                  </div>
                </div>

                {shouldVerifyAtReception && (
                  <div className="mt-5 rounded-2xl border border-orange-800 bg-orange-950/40 p-5">
                    <div className="mb-4 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
                      <div>
                        <h3 className="text-xl font-bold text-orange-200">
                          Pierwsza wizyta / konto do weryfikacji
                        </h3>

                        <p className="mt-1 text-sm text-orange-100/80">
                          Przed wpuszczeniem klienta na oś zweryfikuj dane na
                          recepcji.
                        </p>
                      </div>

                      <span
                        className={
                          completion >= 80
                            ? "rounded-full border border-green-700 bg-green-950 px-4 py-2 text-sm font-bold text-green-300"
                            : "rounded-full border border-yellow-700 bg-yellow-950 px-4 py-2 text-sm font-bold text-yellow-300"
                        }
                      >
                        Dane: {completion}%
                      </span>
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
                          {valueOrMissing(profile?.full_name ?? reservation.customer_name ?? null)}
                        </p>

                        <p className="text-sm text-zinc-500">E-mail</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(profile?.email || reservation.customer_email)}
                        </p>

                        <p className="text-sm text-zinc-500">Telefon</p>
                        <p className="font-semibold">
                          {valueOrMissing(profile?.phone || reservation.customer_phone)}
                        </p>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Adres
                        </p>

                        <p className="text-sm text-zinc-500">Kod pocztowy</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(profile?.postal_code)}
                        </p>

                        <p className="text-sm text-zinc-500">Miasto</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(profile?.city)}
                        </p>

                        <p className="text-sm text-zinc-500">Ulica</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(profile?.street)}
                        </p>

                        <p className="text-sm text-zinc-500">Dom / lokal</p>
                        <p className="font-semibold">
                          {valueOrMissing(profile?.house_number)}
                          {profile?.apartment_number
                            ? ` / ${profile.apartment_number}`
                            : ""}
                        </p>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Pozwolenie na broń
                        </p>

                        <p className="text-sm text-zinc-500">Numer</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(profile?.weapon_permit_number)}
                        </p>

                        <p className="text-sm text-zinc-500">Typ</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(profile?.weapon_permit_type)}
                        </p>

                        <p className="text-sm text-zinc-500">Organ wydający</p>
                        <p className="font-semibold">
                          {valueOrMissing(profile?.weapon_permit_issuer)}
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
                          {yesNo(profile?.has_range_officer ?? null)}
                        </p>

                        <p className="text-sm text-zinc-500">Numer uprawnień</p>
                        <p className="font-semibold">
                          {valueOrMissing(profile?.range_officer_number)}
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
                          {yesNo(profile?.has_instructor ?? null)}
                        </p>

                        <p className="text-sm text-zinc-500">Numer uprawnień</p>
                        <p className="font-semibold">
                          {valueOrMissing(profile?.instructor_number)}
                        </p>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                          System
                        </p>

                        <p className="text-sm text-zinc-500">Status konta</p>
                        <p className="mb-3 font-semibold">
                          {getVerificationStatusLabel(profile?.verification_status ?? null)}
                        </p>

                        <p className="text-sm text-zinc-500">Rola</p>
                        <p className="font-semibold">
                          {valueOrMissing(profile?.role ?? null)}
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
  );
}

export default function CheckInPage() {
  return (
    <main className="min-h-screen bg-zinc-950 p-8 text-white">
      <Suspense
        fallback={
          <div className="mx-auto max-w-xl rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie check-in...
          </div>
        }
      >
        <CheckInContent />
      </Suspense>
    </main>
  );
}
