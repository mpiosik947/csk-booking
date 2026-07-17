"use client";

import { Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { supabase } from "../../../lib/supabase";
import {
  cancelReservation as cancelReservationAction,
  completeReservation as completeReservationAction,
  markNoShow as markNoShowAction,
  markPaid as markPaidAction,
} from "../../../lib/reservation-actions";
import {
  RESERVATION_STATUS,
  getReservationStatusBadgeClass,
  getReservationStatusLabel,
} from "../../../lib/reservation-status";
import {
  PAYMENT_STATUSES,
  getPaymentStatusBadgeClass,
  getPaymentStatusLabel,
} from "../../../lib/payment-status";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";

type VerificationAction = "verify" | "mark_pending" | "reject";

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

type VerificationRpcResult = {
  user_id: string;
  verification_status: string | null;
  permissions_verified: boolean | null;
  permissions_verified_at: string | null;
  permissions_verified_by: string | null;
  permissions_verification_note: string | null;
  verified_at: string | null;
  verified_by: string | null;
  unverified_at: string | null;
  unverified_by: string | null;
  updated_at: string | null;
};

const VERIFIED_NOTE =
  "Sprawdzono uprawnienia klienta podczas pierwszej wizyty. Dokumenty okazane do wglądu, bez kopiowania i zapisywania numerów. Klient zapoznany z regulaminem i zasadami bezpieczeństwa. Konto zweryfikowane.";

const INCOMPLETE_NOTE =
  "Nie zakończono pełnej weryfikacji uprawnień. Klient poinformowany o konieczności okazania wymaganych dokumentów przy kolejnej wizycie. Konto pozostaje niezweryfikowane.";

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

function arePermissionsVerified(profile: Profile | null | undefined) {
  return Boolean(profile?.permissions_verified);
}

function valueOrMissing(value: string | null | undefined) {
  return value && value.trim() ? value : "Brak danych";
}

function yesNo(value: boolean | null | undefined) {
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
  ];

  const filled = fields.filter((field) => field && field.trim()).length;

  return Math.round((filled / fields.length) * 100);
}

function getDeclaredPermissions(profile: Profile | null | undefined) {
  if (!profile) return [];

  const permissions: string[] = [];

  if (profile.permission_sport) permissions.push("sportowe");
  if (profile.permission_collector) permissions.push("kolekcjonerskie");
  if (profile.permission_hunting) permissions.push("myśliwskie / łowieckie");
  if (profile.permission_training) permissions.push("szkoleniowe / dopuszczenie");
  if (profile.permission_personal_protection) permissions.push("ochrona osobista");
  if (profile.permission_other) permissions.push("inne");

  return permissions;
}

function getDeclaredQualifications(profile: Profile | null | undefined) {
  if (!profile) return [];

  const qualifications: string[] = [];

  if (profile.qualification_instructor) qualifications.push("instruktor");
  if (profile.qualification_range_officer)
    qualifications.push("prowadzący strzelanie / range officer");
  if (profile.qualification_pzss_license) qualifications.push("licencja PZSS");
  if (profile.qualification_hunter) qualifications.push("myśliwy");

  return qualifications;
}

function getVerificationClass(profile: Profile | null | undefined) {
  if (isVerifiedProfile(profile)) {
    return "border-green-700 bg-green-950 text-green-300";
  }

  if (profile?.verification_status === "rejected") {
    return "border-red-700 bg-red-950 text-red-300";
  }

  return "border-orange-700 bg-orange-950 text-orange-300";
}

function getPermissionsClass(profile: Profile | null | undefined) {
  if (arePermissionsVerified(profile)) {
    return "border-green-700 bg-green-950 text-green-300";
  }

  return "border-yellow-700 bg-yellow-950 text-yellow-300";
}

function isNullableString(value: unknown): value is string | null {
  return typeof value === "string" || value === null;
}

function isVerificationRpcResult(value: unknown): value is VerificationRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Record<string, unknown>;

  return (
    typeof result.user_id === "string" &&
    isNullableString(result.verification_status) &&
    (typeof result.permissions_verified === "boolean" ||
      result.permissions_verified === null) &&
    isNullableString(result.permissions_verified_at) &&
    isNullableString(result.permissions_verified_by) &&
    isNullableString(result.permissions_verification_note) &&
    isNullableString(result.verified_at) &&
    isNullableString(result.verified_by) &&
    isNullableString(result.unverified_at) &&
    isNullableString(result.unverified_by) &&
    isNullableString(result.updated_at)
  );
}

function BooleanLine({
  label,
  value,
}: {
  label: string;
  value: boolean | null | undefined;
}) {
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

  const isAdmin = currentUserRole === "admin";
  const isEmployee = currentUserRole === "pracownik";
  const canVerifyProfiles = isAdmin || isEmployee;

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
      const permissions = getDeclaredPermissions(profile).join(" ").toLowerCase();
      const qualifications = getDeclaredQualifications(profile)
        .join(" ")
        .toLowerCase();

      return (
        name.includes(phrase) ||
        email.includes(phrase) ||
        phone.includes(phrase) ||
        lane.includes(phrase) ||
        status.includes(phrase) ||
        payment.includes(phrase) ||
        verification.includes(phrase) ||
        permissions.includes(phrase) ||
        qualifications.includes(phrase)
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
    setSavingId(reservation.id);
    setMessage("");

    const result = await completeReservationAction(supabase, {
      reservationId: reservation.id,
    });

    if (result.error) {
      setSavingId(null);
      setMessage(`Błąd zapisu: ${result.error}`);
      return;
    }

    const updatedReservation: Reservation = {
      ...reservation,
      attendance_status: result.data?.attendance_status ?? "present",
      reservation_status: result.data?.reservation_status ?? "completed",
      checked_in_at: result.data?.checked_in_at ?? new Date().toISOString(),
    };

    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id ? updatedReservation : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation(updatedReservation);
    }

    const profile = reservation.user_id
      ? profilesByUserId[reservation.user_id]
      : null;

    const auditError = await createAuditLog({
      action: "CHECK_IN_COMPLETED",
      reservation,
      profile,
      details: {
        before: {
          reservation_status: reservation.reservation_status,
          attendance_status: reservation.attendance_status,
          checked_in_at: reservation.checked_in_at,
        },
        after: {
          reservation_status: updatedReservation.reservation_status,
          attendance_status: updatedReservation.attendance_status,
          checked_in_at: updatedReservation.checked_in_at,
        },
      },
    });

    setSavingId(null);

    if (auditError) {
      setMessage(
        `Wizyta zakończona, ale nie udało się dodać wpisu audit log: ${auditError}`
      );
      return;
    }

    setMessage("Wizyta zakończona.");
  }

  async function runVerificationAction(
    reservation: Reservation,
    profile: Profile,
    action: VerificationAction,
    note: string | null
  ): Promise<VerificationRpcResult | null> {
    if (!canVerifyProfiles) {
      setMessage("Brak uprawnień do weryfikacji profili.");
      return null;
    }

    if (
      isEmployee &&
      (profile.user_id === currentUserId || profile.role === "admin")
    ) {
      setMessage("Ta operacja weryfikacyjna nie jest dostępna dla pracownika.");
      return null;
    }

    setSavingId(reservation.id);
    setMessage("");

    try {
      const trimmedNote = note?.trim() ?? "";
      const { data, error } = await supabase.rpc(
        "update_profile_verification",
        {
          p_target_user_id: profile.user_id,
          p_action: action,
          p_note: trimmedNote || null,
        }
      );

      if (error) {
        console.error("Profile verification RPC failed:", error);
        setMessage(
          "Nie udało się zaktualizować weryfikacji profilu. Spróbuj ponownie."
        );
        return null;
      }

      if (!isVerificationRpcResult(data) || data.user_id !== profile.user_id) {
        console.error("Profile verification RPC returned invalid data:", data);
        setMessage(
          "Nie udało się zaktualizować weryfikacji profilu. Spróbuj ponownie."
        );
        return null;
      }

      setProfilesByUserId((current) => ({
        ...current,
        [data.user_id]: {
          ...profile,
          verification_status: data.verification_status,
          permissions_verified: data.permissions_verified,
          permissions_verified_at: data.permissions_verified_at,
          permissions_verified_by: data.permissions_verified_by,
          permissions_verification_note: data.permissions_verification_note,
          updated_at: data.updated_at,
        },
      }));

      return data;
    } catch (error) {
      console.error("Profile verification RPC failed:", error);
      setMessage(
        "Nie udało się zaktualizować weryfikacji profilu. Spróbuj ponownie."
      );
      return null;
    } finally {
      setSavingId(null);
    }
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

    if (!canVerifyProfiles) {
      setMessage("Brak uprawnień do weryfikacji profili.");
      return;
    }

    if (
      isEmployee &&
      (profile.user_id === currentUserId || profile.role === "admin")
    ) {
      setMessage("Ta operacja weryfikacyjna nie jest dostępna dla pracownika.");
      return;
    }

    const missingFields = getMissingFields(profile);

    if (missingFields.length > 0) {
      const confirmed = window.confirm(
        `Konto posiada braki:\n\n• ${missingFields.join(
          "\n• "
        )}\n\nCzy mimo to zweryfikować konto, uprawnienia i rozpocząć wizytę?`
      );

      if (!confirmed) return;
    }

    const verificationResult = await runVerificationAction(
      reservation,
      profile,
      "verify",
      null
    );

    if (!verificationResult) return;

    setSavingId(reservation.id);
    setMessage("");

    try {
      const reservationResult = await completeReservationAction(supabase, {
        reservationId: reservation.id,
      });

      if (reservationResult.error) {
        console.error(
          "Completing reservation after profile verification failed:",
          reservationResult.error
        );
        setMessage(
          "Konto zostało zweryfikowane, ale nie udało się zakończyć wizyty. Spróbuj ponownie wykonać check-in."
        );
        return;
      }

      const now = new Date().toISOString();
      const updatedReservation: Reservation = {
        ...reservation,
        attendance_status:
          reservationResult.data?.attendance_status ?? "present",
        reservation_status:
          reservationResult.data?.reservation_status ??
          RESERVATION_STATUS.COMPLETED,
        checked_in_at: reservationResult.data?.checked_in_at ?? now,
      };

      setReservations((current) =>
        current.map((item) =>
          item.id === reservation.id ? updatedReservation : item
        )
      );

      if (selectedReservation?.id === reservation.id) {
        setSelectedReservation(updatedReservation);
      }

      const auditError = await createAuditLog({
        action: "CHECK_IN_COMPLETED",
        reservation,
        profile,
        details: {
          before: {
            reservation_status: reservation.reservation_status,
            attendance_status: reservation.attendance_status,
            checked_in_at: reservation.checked_in_at,
          },
          after: {
            reservation_status: updatedReservation.reservation_status,
            attendance_status: updatedReservation.attendance_status,
            checked_in_at: updatedReservation.checked_in_at,
          },
        },
      });

      if (auditError) {
        setMessage(
          `Konto i uprawnienia zweryfikowane, wizyta rozpoczęta, ale nie udało się dodać wpisu audit log: ${auditError}`
        );
        return;
      }

      setMessage("Konto i uprawnienia zweryfikowane. Wizyta rozpoczęta.");
    } catch (error) {
      console.error(
        "Completing reservation after profile verification failed:",
        error
      );
      setMessage(
        "Konto zostało zweryfikowane, ale nie udało się zakończyć wizyty. Spróbuj ponownie wykonać check-in."
      );
    } finally {
      setSavingId(null);
    }
  }

  async function markVerificationIncomplete(reservation: Reservation) {
    if (!reservation.user_id) {
      setMessage("Ta rezerwacja nie jest powiązana z kontem użytkownika.");
      return;
    }

    const profile = profilesByUserId[reservation.user_id];

    if (!profile) {
      setMessage("Nie znaleziono profilu użytkownika do aktualizacji.");
      return;
    }

    const verificationResult = await runVerificationAction(
      reservation,
      profile,
      "mark_pending",
      null
    );

    if (!verificationResult) return;

    setMessage("Weryfikacja profilu została zaktualizowana.");
  }

  async function markNoShow(reservation: Reservation) {
    setSavingId(reservation.id);
    setMessage("");

    const result = await markNoShowAction(supabase, {
      reservationId: reservation.id,
    });

    if (result.error) {
      setSavingId(null);
      setMessage(`Błąd zapisu: ${result.error}`);
      return;
    }

    const updatedReservation: Reservation = {
      ...reservation,
      attendance_status: result.data?.attendance_status ?? "no_show",
      reservation_status: result.data?.reservation_status ?? "no_show",
    };

    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id ? updatedReservation : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation(updatedReservation);
    }

    const profile = reservation.user_id
      ? profilesByUserId[reservation.user_id]
      : null;

    const auditError = await createAuditLog({
      action: "RESERVATION_NO_SHOW",
      reservation,
      profile,
      details: {
        before: {
          reservation_status: reservation.reservation_status,
          attendance_status: reservation.attendance_status,
        },
        after: {
          reservation_status: updatedReservation.reservation_status,
          attendance_status: updatedReservation.attendance_status,
        },
      },
    });

    setSavingId(null);

    if (auditError) {
      setMessage(
        `Oznaczono no-show, ale nie udało się dodać wpisu audit log: ${auditError}`
      );
      return;
    }

    setMessage("Oznaczono no-show.");
  }

  async function cancelByAdmin(reservation: Reservation) {
    setSavingId(reservation.id);
    setMessage("");

    const result = await cancelReservationAction(supabase, {
      reservationId: reservation.id,
    });

    if (result.error) {
      setSavingId(null);
      setMessage(`Błąd zapisu: ${result.error}`);
      return;
    }

    const updatedReservation: Reservation = {
      ...reservation,
      reservation_status:
        result.data?.reservation_status ?? "cancelled_by_admin",
    };

    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id ? updatedReservation : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation(updatedReservation);
    }

    const profile = reservation.user_id
      ? profilesByUserId[reservation.user_id]
      : null;

    const auditError = await createAuditLog({
      action: "RESERVATION_CANCELLED_BY_ADMIN",
      reservation,
      profile,
      details: {
        before: {
          reservation_status: reservation.reservation_status,
        },
        after: {
          reservation_status: updatedReservation.reservation_status,
        },
      },
    });

    setSavingId(null);

    if (auditError) {
      setMessage(
        `Anulowano rezerwację, ale nie udało się dodać wpisu audit log: ${auditError}`
      );
      return;
    }

    setMessage("Rezerwacja anulowana.");
  }

  async function markPaymentAsPaid(reservation: Reservation) {
    setSavingId(reservation.id);
    setMessage("");

    const result = await markPaidAction(supabase, {
      reservationId: reservation.id,
    });

    if (result.error) {
      setSavingId(null);
      setMessage(`Błąd zapisu: ${result.error}`);
      return;
    }

    const updatedReservation: Reservation = {
      ...reservation,
      payment_status: result.data?.payment_status ?? "paid",
    };

    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id ? updatedReservation : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation(updatedReservation);
    }

    const profile = reservation.user_id
      ? profilesByUserId[reservation.user_id]
      : null;

    const auditError = await createAuditLog({
      action: "RESERVATION_PAYMENT_PAID",
      reservation,
      profile,
      details: {
        before: {
          payment_status: reservation.payment_status,
        },
        after: {
          payment_status: updatedReservation.payment_status,
        },
      },
    });

    setSavingId(null);

    if (auditError) {
      setMessage(
        `Oznaczono płatność, ale nie udało się dodać wpisu audit log: ${auditError}`
      );
      return;
    }

    setMessage("Płatność oznaczona jako opłacona.");
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
            weryfikacji klienta podczas pierwszej wizyty.
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
              placeholder="Imię, e-mail, telefon, oś, status, uprawnienia..."
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
            const permissionsVerified = arePermissionsVerified(profile);

            const shouldVerifyAtReception =
              Boolean(reservation.user_id) &&
              (!isProfileVerified || !permissionsVerified);

            const isVerificationRestricted =
              !profile ||
              !canVerifyProfiles ||
              (isEmployee &&
                (profile.user_id === currentUserId ||
                  profile.role === "admin"));
            const verificationRestrictionReason = !profile
              ? "Brak profilu użytkownika do weryfikacji."
              : !canVerifyProfiles
                ? "Weryfikacja profilu jest dostępna tylko dla administratora i pracownika."
                : isEmployee && profile.user_id === currentUserId
                  ? "Pracownik nie może weryfikować własnego konta."
                  : isEmployee && profile.role === "admin"
                    ? "Pracownik nie może zmieniać weryfikacji administratora."
                    : undefined;

            const missingFields = getMissingFields(profile);
            const completion = getCompletionPercent(profile);
            const declaredPermissions = getDeclaredPermissions(profile);
            const declaredQualifications = getDeclaredQualifications(profile);

            return (
              <article
                key={reservation.id}
                className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5"
              >
                <div className="grid gap-5 xl:grid-cols-[1.1fr_0.8fr_0.9fr_1fr_auto] xl:items-start">
                  <div>
                    <div className="mb-3 flex flex-wrap gap-2">
                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getReservationStatusBadgeClass(
                          reservation.reservation_status
                        )}`}
                      >
                        {getReservationStatusLabel(
                          reservation.reservation_status
                        )}
                      </span>

                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getPaymentStatusBadgeClass(
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
                        Konto:{" "}
                        {getVerificationStatusLabel(
                          profile?.verification_status ?? null
                        )}
                      </span>

                      <span
                        className={`rounded-full border px-3 py-1 text-xs font-bold ${getPermissionsClass(
                          profile
                        )}`}
                      >
                        Uprawnienia:{" "}
                        {permissionsVerified ? "sprawdzone" : "do sprawdzenia"}
                      </span>
                    </div>

                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Klient
                    </p>

                    <h2 className="mt-2 text-xl font-bold">
                      {reservation.customer_name ||
                        profile?.full_name ||
                        "Brak danych"}
                    </h2>

                    <p className="mt-1 text-sm text-zinc-400">
                      {reservation.customer_email ||
                        profile?.email ||
                        "Brak e-maila"}
                    </p>

                    <p className="mt-1 text-sm text-zinc-500">
                      Tel.:{" "}
                      {reservation.customer_phone || profile?.phone || "brak"}
                    </p>

                    <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950 p-3 text-xs text-zinc-400">
                      <p className="font-semibold text-zinc-300">
                        Deklarowane uprawnienia:
                      </p>

                      <p className="mt-1">
                        {declaredPermissions.length > 0
                          ? declaredPermissions.join(", ")
                          : "Brak zaznaczonych uprawnień"}
                      </p>
                    </div>
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
                        onChange={(event) => {
                          if (event.target.value === "paid") {
                            markPaymentAsPaid(reservation);
                            return;
                          }

                          updateReservation(
                            reservation,
                            {
                              payment_status: event.target.value,
                            },
                            "RESERVATION_PAYMENT_CHANGED"
                          );
                        }}
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-sm text-white outline-none focus:border-green-600 disabled:opacity-60"
                      >
                        {PAYMENT_STATUSES.map((status) => (
                          <option key={status} value={status}>
                            {getPaymentStatusLabel(status)}
                          </option>
                        ))}
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
                        {[
                          RESERVATION_STATUS.CONFIRMED,
                          RESERVATION_STATUS.COMPLETED,
                          RESERVATION_STATUS.NO_SHOW,
                          RESERVATION_STATUS.CANCELLED_BY_ADMIN,
                        ].map((status) => (
                          <option key={status} value={status}>
                            {getReservationStatusLabel(status)}
                          </option>
                        ))}
                      </select>
                    </div>
                  </div>

                  <div className="grid gap-2">
                    {shouldVerifyAtReception ? (
                      <>
                        <button
                          type="button"
                          disabled={isSaving || isVerificationRestricted}
                          title={verificationRestrictionReason}
                          onClick={() =>
                            verifyAccountAndStartVisit(reservation)
                          }
                          className="rounded-xl border border-orange-700 px-4 py-3 text-sm font-bold text-orange-300 transition hover:bg-orange-950 disabled:cursor-not-allowed disabled:opacity-60"
                        >
                          Zweryfikuj konto i uprawnienia
                        </button>

                        <button
                          type="button"
                          disabled={isSaving || isVerificationRestricted}
                          title={verificationRestrictionReason}
                          onClick={() =>
                            markVerificationIncomplete(reservation)
                          }
                          className="rounded-xl border border-yellow-700 px-4 py-3 text-sm font-bold text-yellow-300 transition hover:bg-yellow-950 disabled:cursor-not-allowed disabled:opacity-60"
                        >
                          Weryfikacja niepełna
                        </button>

                        {verificationRestrictionReason && (
                          <p className="text-xs text-zinc-400">
                            {verificationRestrictionReason}
                          </p>
                        )}
                      </>
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
                          Pierwsza wizyta / uprawnienia do sprawdzenia
                        </h3>

                        <p className="mt-1 text-sm text-orange-100/80">
                          Sprawdź dokumenty tylko do wglądu. Nie zapisuj numerów
                          dokumentów, pozwoleń ani legitymacji.
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

                    <div className="mb-5 rounded-xl border border-green-900 bg-green-950/40 p-4 text-sm text-green-200">
                      <p className="font-semibold">
                        Zasada minimalizacji danych
                      </p>

                      <p className="mt-1 text-green-300">
                        Weryfikujesz uprawnienia na miejscu, ale w systemie
                        zapisujesz tylko wynik weryfikacji i krótką notatkę. Bez
                        numerów dokumentów.
                      </p>
                    </div>

                    <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Dane podstawowe
                        </p>

                        <p className="text-sm text-zinc-500">Imię i nazwisko</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(
                            profile?.full_name ??
                              reservation.customer_name ??
                              null
                          )}
                        </p>

                        <p className="text-sm text-zinc-500">E-mail</p>
                        <p className="mb-3 font-semibold">
                          {valueOrMissing(
                            profile?.email || reservation.customer_email
                          )}
                        </p>

                        <p className="text-sm text-zinc-500">Telefon</p>
                        <p className="font-semibold">
                          {valueOrMissing(
                            profile?.phone || reservation.customer_phone
                          )}
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
                          Deklarowane pozwolenia / uprawnienia
                        </p>

                        <BooleanLine
                          label="Pozwolenie sportowe"
                          value={profile?.permission_sport}
                        />

                        <BooleanLine
                          label="Pozwolenie kolekcjonerskie"
                          value={profile?.permission_collector}
                        />

                        <BooleanLine
                          label="Pozwolenie myśliwskie / łowieckie"
                          value={profile?.permission_hunting}
                        />

                        <BooleanLine
                          label="Szkoleniowe / dopuszczenie"
                          value={profile?.permission_training}
                        />

                        <BooleanLine
                          label="Ochrona osobista"
                          value={profile?.permission_personal_protection}
                        />

                        <BooleanLine
                          label="Inne"
                          value={profile?.permission_other}
                        />
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Dodatkowe kwalifikacje
                        </p>

                        <BooleanLine
                          label="Instruktor"
                          value={profile?.qualification_instructor}
                        />

                        <BooleanLine
                          label="Prowadzący strzelanie / RO"
                          value={profile?.qualification_range_officer}
                        />

                        <BooleanLine
                          label="Licencja PZSS"
                          value={profile?.qualification_pzss_license}
                        />

                        <BooleanLine
                          label="Myśliwy"
                          value={profile?.qualification_hunter}
                        />
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Weryfikacja uprawnień
                        </p>

                        <p className="text-sm text-zinc-500">Status konta</p>
                        <p className="mb-3 font-semibold">
                          {getVerificationStatusLabel(
                            profile?.verification_status ?? null
                          )}
                        </p>

                        <p className="text-sm text-zinc-500">
                          Status uprawnień
                        </p>
                        <p className="mb-3 font-semibold">
                          {permissionsVerified
                            ? "Sprawdzone przez obsługę"
                            : "Do sprawdzenia podczas wizyty"}
                        </p>

                        <p className="text-sm text-zinc-500">
                          Data sprawdzenia
                        </p>
                        <p className="mb-3 font-semibold">
                          {profile?.permissions_verified_at
                            ? new Date(
                                profile.permissions_verified_at
                              ).toLocaleString("pl-PL")
                            : "Brak danych"}
                        </p>

                        <p className="text-sm text-zinc-500">Notatka</p>
                        <p className="whitespace-pre-line text-sm font-semibold leading-6">
                          {valueOrMissing(
                            profile?.permissions_verification_note
                          )}
                        </p>
                      </div>

                      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                        <p className="mb-3 text-xs uppercase tracking-[0.25em] text-zinc-500">
                          Notatki systemowe
                        </p>

                        <p className="text-sm text-zinc-500">
                          Gotowa notatka po weryfikacji
                        </p>

                        <p className="mb-4 rounded-lg border border-green-900 bg-green-950/40 p-3 text-xs leading-5 text-green-200">
                          {VERIFIED_NOTE}
                        </p>

                        <p className="text-sm text-zinc-500">
                          Gotowa notatka przy brakach
                        </p>

                        <p className="rounded-lg border border-yellow-900 bg-yellow-950/40 p-3 text-xs leading-5 text-yellow-200">
                          {INCOMPLETE_NOTE}
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


