"use client";

import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "../../../lib/supabase";
import { updateReservationPayment } from "../../../lib/reservation-actions";
import {
  getPaymentStatusBadgeClass,
  getPaymentStatusLabel,
  PAYMENT_STATUS,
} from "../../../lib/payment-status";
import {
  getReservationStatusBadgeClass,
  getReservationStatusLabel,
} from "../../../lib/reservation-status";
import { getLaneRelationDisplay } from "../../../lib/admin/lane-relation-display";
import { getReservationAttendanceActions } from "../../../lib/reservation-operational-state";
import AdminShell from "../_components/AdminShell";

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
  completed_at: string | null;
  price: number | null;
  shooting_lanes?: {
    id: string;
    name: string | null;
    resource_kind: string | null;
    parent_lane_id: string | null;
    display_order: number | null;
    is_active: boolean | null;
    parent_lane?: unknown;
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

type CancelReservationRpcResult = {
  changed: boolean;
  new_status?: string | null;
};

type AttendanceAction = "start" | "reset" | "complete" | "no_show";

type AttendanceRpcResult = {
  ok: boolean;
  reservation_id: string;
  changed: boolean;
  action: AttendanceAction;
  code: string;
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
  return (
    getLaneRelationDisplay(reservation.shooting_lanes)?.displayName ??
    "Nieznana oś"
  );
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

function parseCancelReservationRpcResult(
  data: unknown
): CancelReservationRpcResult | null {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return null;
  }

  const result = data as Record<string, unknown>;

  if (typeof result.changed !== "boolean") {
    return null;
  }

  return {
    changed: result.changed,
    new_status:
      typeof result.new_status === "string" || result.new_status === null
        ? result.new_status
        : undefined,
  };
}

function getCancellationErrorMessage(error: {
  code?: string | null;
  message?: string | null;
}) {
  const code = error.code?.trim().toUpperCase() ?? "";

  if (code === "42501") {
    return "Nie masz uprawnień do anulowania tej rezerwacji.";
  }

  if (code === "P0002") {
    return "Nie znaleziono rezerwacji.";
  }

  if (code === "55000") {
    return "Rezerwacji w tym statusie nie można anulować.";
  }

  return "Nie udało się anulować rezerwacji. Spróbuj ponownie.";
}

function parseAttendanceRpcResult(data: unknown): AttendanceRpcResult | null {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return null;
  }

  const result = data as Record<string, unknown>;

  if (
    typeof result.ok !== "boolean" ||
    typeof result.reservation_id !== "string" ||
    typeof result.changed !== "boolean" ||
    (result.action !== "start" &&
      result.action !== "reset" &&
      result.action !== "complete" &&
      result.action !== "no_show") ||
    typeof result.code !== "string"
  ) {
    return null;
  }

  return {
    ok: result.ok,
    reservation_id: result.reservation_id,
    changed: result.changed,
    action: result.action,
    code: result.code,
  };
}

function getAttendanceResultMessage(code: string) {
  switch (code) {
    case "not_allowed":
      return "Nie masz uprawnień do wykonania tej operacji.";
    case "reservation_not_found":
      return "Nie znaleziono rezerwacji.";
    case "invalid_input":
      return "Nieprawidłowa operacja rezerwacji.";
    case "invalid_state":
      return "Rezerwacja ma niespójny stan i wymaga kontroli administratora.";
    case "invalid_transition":
      return "Rezerwacji w tym statusie nie można zmienić.";
    default:
      return "Nie udało się zaktualizować rezerwacji. Spróbuj ponownie.";
  }
}

function getAttendanceErrorMessage(error: {
  code?: string | null;
  message?: string | null;
}) {
  const code = error.code?.trim().toUpperCase() ?? "";

  if (code === "42501") {
    return "Nie masz uprawnień do wykonania tej operacji.";
  }

  if (code === "22023") {
    return "Nieprawidłowa operacja rezerwacji.";
  }

  if (code === "P0002") {
    return "Nie znaleziono rezerwacji.";
  }

  if (code === "55000") {
    return "Rezerwacji w tym statusie nie można zmienić.";
  }

  return "Nie udało się zaktualizować rezerwacji. Spróbuj ponownie.";
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
  const router = useRouter();
  const params = useSearchParams();
  const token = params.get("token");

  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [selectedReservation, setSelectedReservation] =
    useState<Reservation | null>(null);
  const [profilesByUserId, setProfilesByUserId] = useState<
    Record<string, Profile>
  >({});

  const [currentUserId, setCurrentUserId] = useState("");
  const [currentUserRole, setCurrentUserRole] = useState<UserRole | "">("");

  const [dateFilter, setDateFilter] = useState(todayISODate());
  const [search, setSearch] = useState("");

  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const [savingId, setSavingId] = useState<string | null>(null);
  const attendanceInProgressIdsRef = useRef<Set<string>>(new Set());
  const cancellationInProgressIdsRef = useRef<Set<string>>(new Set());
  const [cancellingReservationIds, setCancellingReservationIds] = useState<
    Set<string>
  >(() => new Set());

  const isAdmin = currentUserRole === "admin";
  const isEmployee = currentUserRole === "pracownik";
  const isInstructor = currentUserRole === "instruktor";
  const canVerifyProfiles = isAdmin || isEmployee;
  const canCancelReservations = isAdmin || isEmployee;

  async function loadCurrentUser() {
    const {
      data: { user },
    } = await supabase.auth.getUser();

    setCurrentUserId(user?.id ?? "");

    if (!user) {
      router.replace("/login");
      return false;
    }

    const { data: profile, error } = await supabase
      .from("profiles")
      .select("role,full_name,email")
      .eq("user_id", user.id)
      .maybeSingle();

    const loadedRole = profile?.role
      ? (String(profile.role) as UserRole)
      : "";

    if (error || (loadedRole !== "admin" && loadedRole !== "pracownik")) {
      setCurrentUserRole(loadedRole);
      router.replace("/admin");
      return false;
    }

    setCurrentUserRole(loadedRole);
    return true;
  }

  async function loadProfilesForReservations(items: Reservation[]) {
    const reservationIds = Array.from(new Set(items.map((reservation) => reservation.id)));

    if (reservationIds.length === 0) {
      setProfilesByUserId({});
      return;
    }

    const loadedProfiles: Profile[] = [];
    for (let index = 0; index < reservationIds.length; index += 100) {
      const { data, error } = await supabase.rpc(
        "get_reservation_customer_profiles_v1",
        { p_reservation_ids: reservationIds.slice(index, index + 100) }
      );

      if (error) {
        console.error("Operational profile read failed:", error);
        setMessage("Nie udało się pobrać danych profili dla rezerwacji.");
        return;
      }

      loadedProfiles.push(...((data ?? []) as Profile[]));
    }

    const map: Record<string, Profile> = {};

    for (const profile of loadedProfiles) {
      map[profile.user_id] = profile;
    }

    setProfilesByUserId(map);
  }

  async function loadReservations() {
    setLoading(true);
    setMessage("");

    if (!(await loadCurrentUser())) {
      setLoading(false);
      return;
    }

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
        completed_at,
        price,
        shooting_lanes (
          id, name, resource_kind, parent_lane_id, display_order, is_active,
          parent_lane:shooting_lanes!parent_lane_id (
            id, name, resource_kind, parent_lane_id, display_order, is_active
          )
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

    if (!(await loadCurrentUser())) {
      setLoading(false);
      return;
    }

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
        completed_at,
        price,
        shooting_lanes (
          id, name, resource_kind, parent_lane_id, display_order, is_active,
          parent_lane:shooting_lanes!parent_lane_id (
            id, name, resource_kind, parent_lane_id, display_order, is_active
          )
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
    const timeoutId = window.setTimeout(() => {
      if (token) {
        void loadReservationByToken(token);
        return;
      }

      void loadReservations();
    }, 0);

    return () => window.clearTimeout(timeoutId);
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

  async function refreshReservationAfterAttendance(reservationId: string) {
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
        completed_at,
        price,
        shooting_lanes (
          id, name, resource_kind, parent_lane_id, display_order, is_active,
          parent_lane:shooting_lanes!parent_lane_id (
            id, name, resource_kind, parent_lane_id, display_order, is_active
          )
        )
      `
      )
      .eq("id", reservationId)
      .single();

    if (error) {
      console.error("Refreshing reservation after attendance RPC failed:", error);
      return false;
    }

    const refreshedReservation = data as unknown as Reservation;

    setReservations((current) =>
      current.map((item) =>
        item.id === reservationId ? refreshedReservation : item
      )
    );
    setSelectedReservation((current) =>
      current?.id === reservationId ? refreshedReservation : current
    );

    return true;
  }

  async function runAttendanceAction(
    reservationId: string,
    action: AttendanceAction,
    successMessage: string
  ) {
    if (attendanceInProgressIdsRef.current.has(reservationId)) {
      return false;
    }

    attendanceInProgressIdsRef.current.add(reservationId);
    setSavingId(reservationId);
    setMessage("");

    try {
      const { data, error } = await supabase.rpc(
        "update_reservation_attendance",
        {
          p_reservation_id: reservationId,
          p_action: action,
        }
      );

      if (error) {
        console.error("Reservation attendance RPC failed:", error);
        setMessage(getAttendanceErrorMessage(error));
        return false;
      }

      const result = parseAttendanceRpcResult(data);

      if (
        !result ||
        result.reservation_id !== reservationId ||
        result.action !== action
      ) {
        console.error("Reservation attendance RPC returned invalid data:", data);
        setMessage(
          "Nie udało się zaktualizować rezerwacji. Spróbuj ponownie."
        );
        return false;
      }

      if (!result.ok) {
        setMessage(getAttendanceResultMessage(result.code));
        return false;
      }

      const refreshed = await refreshReservationAfterAttendance(reservationId);

      if (!refreshed) {
        setMessage(
          "Zapisano zmianę, ale nie udało się odświeżyć danych. Odśwież widok."
        );
        return false;
      }

      setMessage(successMessage);
      return true;
    } catch (error) {
      console.error("Reservation attendance RPC failed:", error);
      setMessage(
        "Nie udało się zaktualizować rezerwacji. Spróbuj ponownie."
      );
      return false;
    } finally {
      attendanceInProgressIdsRef.current.delete(reservationId);
      setSavingId((current) => (current === reservationId ? null : current));
    }
  }

  async function updatePaymentStatus(
    reservation: Reservation,
    paymentStatus: string
  ) {
    setSavingId(reservation.id);
    setMessage("");

    const result = await updateReservationPayment(supabase, {
      reservationId: reservation.id,
      paymentStatus,
    });

    if (result.error) {
      setSavingId(null);
      setMessage(result.error);
      return;
    }

    const nextPaymentStatus = result.data?.payment_status ?? paymentStatus;
    setReservations((current) =>
      current.map((item) =>
        item.id === reservation.id
          ? { ...item, payment_status: nextPaymentStatus }
          : item
      )
    );

    if (selectedReservation?.id === reservation.id) {
      setSelectedReservation({
        ...selectedReservation,
        payment_status: nextPaymentStatus,
      });
    }

    setSavingId(null);
    setMessage("Zapisano zmianę.");
  }

  async function markStarted(reservation: Reservation) {
    await runAttendanceAction(
      reservation.id,
      "start",
      "Wizyta rozpoczęta."
    );
  }

  async function markCompleted(reservation: Reservation) {
    await runAttendanceAction(
      reservation.id,
      "complete",
      "Wizyta zakończona."
    );
  }

  async function resetStartedVisit(reservation: Reservation) {
    await runAttendanceAction(
      reservation.id,
      "reset",
      "Cofnięto rozpoczęcie wizyty."
    );
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

    await runAttendanceAction(
      reservation.id,
      "start",
      "Konto i uprawnienia zweryfikowane. Wizyta rozpoczęta."
    );
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
    await runAttendanceAction(
      reservation.id,
      "no_show",
      "Oznaczono no-show."
    );
  }

  async function handleCancelReservation(reservation: Reservation) {
    if (!canCancelReservations) {
      setMessage("Nie masz uprawnień do anulowania tej rezerwacji.");
      return;
    }

    if (cancellationInProgressIdsRef.current.has(reservation.id)) {
      return;
    }

    const confirmed = window.confirm(
      "Czy na pewno chcesz anulować tę rezerwację?"
    );

    if (!confirmed) {
      return;
    }

    cancellationInProgressIdsRef.current.add(reservation.id);
    setCancellingReservationIds((current) => {
      const next = new Set(current);
      next.add(reservation.id);
      return next;
    });
    setSavingId(reservation.id);
    setMessage("");

    try {
      const { data, error } = await supabase.rpc("cancel_reservation", {
        p_reservation_id: reservation.id,
      });

      if (error) {
        console.error("Check-in reservation cancellation RPC failed", error);
        setMessage(getCancellationErrorMessage(error));
        return;
      }

      const result = parseCancelReservationRpcResult(data);

      if (!result) {
        console.error("Invalid cancel_reservation RPC response", data);
        setMessage("Nie udało się anulować rezerwacji. Spróbuj ponownie.");
        return;
      }

      if (token) {
        await loadReservationByToken(token);
      } else {
        await loadReservations();
      }

      if (!result.changed) {
        setMessage("Rezerwacja była już anulowana.");
        return;
      }

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        setMessage(
          "Rezerwacja została anulowana, ale nie udało się wysłać wiadomości e-mail."
        );
        return;
      }

      try {
        const emailResponse = await fetch(
          "/api/send-reservation-cancellation",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${session.access_token}`,
            },
            body: JSON.stringify({ reservationId: reservation.id }),
          }
        );

        if (!emailResponse.ok) {
          setMessage(
            "Rezerwacja została anulowana, ale nie udało się wysłać wiadomości e-mail."
          );
          return;
        }
      } catch (emailError) {
        console.error("Reservation cancellation email failed", emailError);
        setMessage(
          "Rezerwacja została anulowana, ale nie udało się wysłać wiadomości e-mail."
        );
        return;
      }

      setMessage(
        "Rezerwacja została anulowana. Email anulowania został wysłany."
      );
    } catch (unexpectedError) {
      console.error(
        "Unexpected check-in reservation cancellation error",
        unexpectedError
      );
      setMessage("Nie udało się anulować rezerwacji. Spróbuj ponownie.");
    } finally {
      cancellationInProgressIdsRef.current.delete(reservation.id);
      setCancellingReservationIds((current) => {
        const next = new Set(current);
        next.delete(reservation.id);
        return next;
      });
      setSavingId(null);
    }
  }

  const mainList =
    token && selectedReservation ? [selectedReservation] : filteredReservations;

  return (
    <>
      {!token && (
        <section aria-labelledby="check-in-filters-heading" className="mb-8 rounded-[1.5rem] border border-[#30372c] bg-[#101310] p-4 sm:p-6">
          <div className="mb-5">
            <p className="text-xs font-bold uppercase tracking-[0.25em] text-[#d7c895]">Lista operacyjna</p>
            <h2 id="check-in-filters-heading" className="mt-2 text-xl font-bold">Wizyty do obsługi</h2>
          </div>
          <div className="grid gap-4 md:grid-cols-[auto_minmax(16rem,1fr)_auto] md:items-end">
          <div>
            <label htmlFor="check-in-date" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
              Data wizyt
            </label>

            <input
              id="check-in-date"
              type="date"
              value={dateFilter}
              onChange={(event) => setDateFilter(event.target.value)}
              className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-white outline-none focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
            />
          </div>

          <div>
            <label htmlFor="check-in-search" className="mb-2 block text-sm font-semibold text-[#d8dbd3]">
              Szukaj
            </label>

            <input
              id="check-in-search"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Imię, e-mail, telefon, oś, status, uprawnienia..."
              className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3 text-white outline-none placeholder:text-[#70766d] focus:border-[#8b986f] focus-visible:ring-2 focus-visible:ring-[#8b986f]/30"
            />
          </div>

          <button
            type="button"
            onClick={loadReservations}
            disabled={loading}
            className="min-h-11 w-full rounded-xl bg-[#66724f] px-5 py-3 font-semibold text-white transition hover:bg-[#78865d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60 md:w-auto"
          >
            {loading ? "Odświeżanie..." : "Odśwież"}
          </button>
          </div>
        </section>
      )}

      {message && (
        <div role="status" className="mb-6 rounded-xl border border-[#495044] bg-[#1b211b] p-4 text-sm font-semibold text-[#d8dbd3]">
          {message}
        </div>
      )}

      {loading ? (
        <div className="rounded-[1.5rem] border border-[#30372c] bg-[#101310] p-8 text-center text-[#a9ada4]">
          Ładowanie check-in...
        </div>
      ) : mainList.length === 0 ? (
        <div className="rounded-[1.5rem] border border-[#30372c] bg-[#101310] p-8 text-center">
          <p className="font-semibold text-[#d8dbd3]">Brak rezerwacji do obsługi dla wybranego dnia.</p>
          <p className="mt-2 text-sm text-[#858b82]">Zmień datę lub kryteria wyszukiwania.</p>
        </div>
      ) : (
        <section aria-label="Lista wizyt" className="grid gap-4">
          {mainList.map((reservation) => {
            const isSaving = savingId === reservation.id;
            const isCancelling = cancellingReservationIds.has(reservation.id);
            const attendanceActions = getReservationAttendanceActions(
              reservation
            ).filter(
              (action) =>
                !isInstructor || (action !== "start" && action !== "reset")
            );
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

            return (
              <article
                key={reservation.id}
                className="rounded-[1.5rem] border border-[#30372c] bg-[#101310] p-4 shadow-[0_18px_44px_rgba(0,0,0,0.16)] transition hover:border-[#485043] sm:p-5"
              >
                <div className="grid gap-6 lg:grid-cols-2 xl:grid-cols-[1.15fr_0.75fr_0.9fr_1fr] xl:items-start">
                  <div className="min-w-0 lg:col-span-2 xl:col-span-1">
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

                      {!isInstructor && (
                        <>
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
                            {permissionsVerified
                              ? "sprawdzone"
                              : "do sprawdzenia"}
                          </span>
                        </>
                      )}
                    </div>

                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Klient
                    </p>

                    <h3 className="mt-2 break-words text-xl font-bold">
                      {reservation.customer_name ||
                        profile?.full_name ||
                        "Brak danych"}
                    </h3>

                    <p className="mt-1 break-all text-sm text-[#b7bbb2]">
                      {reservation.customer_email ||
                        profile?.email ||
                        "Brak e-maila"}
                    </p>

                    <p className="mt-1 text-sm text-zinc-500">
                      Tel.:{" "}
                      {reservation.customer_phone || profile?.phone || "brak"}
                    </p>

                    {!isInstructor && (
                      <div className="mt-4 rounded-xl border border-[#30372c] bg-[#090b09] p-3 text-xs text-[#a9ada4]">
                        <p className="font-semibold text-zinc-300">
                          Deklarowane uprawnienia:
                        </p>

                        <p className="mt-1">
                          {declaredPermissions.length > 0
                            ? declaredPermissions.join(", ")
                            : "Brak zaznaczonych uprawnień"}
                        </p>
                      </div>
                    )}
                  </div>

                  <div className="min-w-0">
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

                  <div className="min-w-0">
                    <p className="text-xs uppercase tracking-[0.25em] text-zinc-500">
                      Oś
                    </p>

                    <p className="mt-2 break-words text-lg font-bold">
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

                  {!isInstructor && (
                    <div className="grid gap-3 rounded-xl border border-[#30372c] bg-[#090b09] p-4">
                    <div>
                      <label className="mb-2 block text-xs uppercase tracking-[0.25em] text-zinc-500">
                        Płatność
                      </label>

                      <select
                        value={reservation.payment_status || PAYMENT_STATUS.PAY_ON_SITE}
                        disabled={isSaving}
                        onChange={(event) =>
                          updatePaymentStatus(reservation, event.target.value)
                        }
                        className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-sm text-white outline-none focus:border-green-600 disabled:opacity-60"
                      >
                        <option value={PAYMENT_STATUS.PAY_ON_SITE}>Płatność na miejscu</option>
                        <option value={PAYMENT_STATUS.PAID}>Opłacona</option>
                        <option value={PAYMENT_STATUS.UNPAID}>Nieopłacona</option>
                        <option value={PAYMENT_STATUS.FREE}>Darmowa</option>
                        <option value={PAYMENT_STATUS.VOUCHER}>Voucher</option>
                      </select>
                    </div>

                    <div>
                      <p className="mb-2 text-xs uppercase tracking-[0.25em] text-zinc-500">
                        Dostępne akcje wizyty
                      </p>
                      <p className="rounded-xl border border-zinc-800 bg-zinc-950 px-4 py-3 text-sm text-zinc-300">
                        {attendanceActions.length === 0
                          ? "Brak dostępnych akcji"
                          : attendanceActions
                              .map((action) =>
                                action === "start"
                                  ? "Rozpocznij"
                                  : action === "complete"
                                    ? "Zakończ"
                                    : action === "no_show"
                                      ? "No-show"
                                      : "Cofnij rozpoczęcie"
                              )
                              .join(" · ")}
                      </p>
                    </div>
                    </div>
                  )}

                  <div className="grid gap-2 lg:col-span-2 xl:col-span-4 xl:grid-cols-[repeat(3,minmax(0,1fr))] xl:border-t xl:border-[#30372c] xl:pt-5">
                    {attendanceActions.includes("start") &&
                    shouldVerifyAtReception &&
                    canVerifyProfiles ? (
                      <>
                        <button
                          type="button"
                          disabled={isSaving || isVerificationRestricted}
                          title={verificationRestrictionReason}
                          onClick={() =>
                            verifyAccountAndStartVisit(reservation)
                          }
                        className="min-h-11 rounded-xl bg-[#66724f] px-4 py-3 text-sm font-bold text-white transition hover:bg-[#78865d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60"
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
                          className="min-h-11 rounded-xl border border-[#71663d] px-4 py-3 text-sm font-bold text-[#d7c895] transition hover:bg-[#211e12] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60"
                        >
                          Weryfikacja niepełna
                        </button>

                        {verificationRestrictionReason && (
                          <p className="text-xs text-zinc-400">
                            {verificationRestrictionReason}
                          </p>
                        )}
                      </>
                    ) : attendanceActions.includes("start") ? (
                      <button
                        type="button"
                        disabled={isSaving}
                        onClick={() => markStarted(reservation)}
                        className="min-h-11 rounded-xl bg-[#66724f] px-4 py-3 text-sm font-bold text-white transition hover:bg-[#78865d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Rozpocznij wizytę
                      </button>
                    ) : attendanceActions.includes("complete") ? (
                      <button
                        type="button"
                        disabled={isSaving}
                        onClick={() => markCompleted(reservation)}
                        className="min-h-11 rounded-xl bg-[#66724f] px-4 py-3 text-sm font-bold text-white transition hover:bg-[#78865d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Zakończ wizytę
                      </button>
                    ) : null}

                    {attendanceActions.includes("no_show") && (
                      <button
                        type="button"
                        disabled={isSaving}
                        onClick={() => markNoShow(reservation)}
                        className="min-h-11 rounded-xl border border-[#71663d] px-4 py-3 text-sm font-bold text-[#d7c895] transition hover:bg-[#211e12] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        No-show
                      </button>
                    )}

                    {attendanceActions.includes("reset") && !isInstructor && (
                      <button
                        type="button"
                        disabled={isSaving}
                        onClick={() => resetStartedVisit(reservation)}
                        className="min-h-11 rounded-xl border border-[#596155] px-4 py-3 text-sm font-bold text-[#c7d0c2] transition hover:bg-[#1b211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Cofnij rozpoczęcie
                      </button>
                    )}

                    {canCancelReservations &&
                      attendanceActions.includes("no_show") && (
                      <button
                        type="button"
                        disabled={isSaving || isCancelling}
                        onClick={() => handleCancelReservation(reservation)}
                        className="min-h-11 rounded-xl border border-[#744545] px-4 py-3 text-sm font-bold text-[#e0a0a0] transition hover:bg-[#2a1b1b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        {isCancelling ? "Anulowanie…" : "Anuluj"}
                      </button>
                    )}

                    {isSaving && (
                      <p className="text-xs font-semibold text-yellow-400">
                        Zapisywanie...
                      </p>
                    )}
                  </div>
                </div>

                {shouldVerifyAtReception && canVerifyProfiles && (
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
        </section>
      )}
    </>
  );
}

export default function CheckInPage() {
  return (
    <AdminShell
      eyebrow="CSK Booking"
      title="Check-in i obsługa wizyt"
      description="Obsługa dzisiejszych rezerwacji, obecności, no-show, płatności i weryfikacji klienta podczas pierwszej wizyty."
      actions={
        <Link href="/admin" className="inline-flex min-h-11 w-full items-center justify-center rounded-xl border border-[#495044] px-5 py-3 text-sm font-semibold text-[#d8dbd3] transition hover:border-[#8b986f] hover:bg-[#1b211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] sm:w-auto">
          ← Wróć do panelu
        </Link>
      }
    >
      <Suspense
        fallback={
          <div className="mx-auto max-w-xl rounded-xl border border-[#30372c] bg-[#101310] p-6 text-[#a9ada4]">
            Ładowanie check-in...
          </div>
        }
      >
        <CheckInContent />
      </Suspense>
    </AdminShell>
  );
}
