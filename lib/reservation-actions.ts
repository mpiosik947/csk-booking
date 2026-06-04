import type { SupabaseClient } from "@supabase/supabase-js";

export type ReservationActionResult<T = unknown> = {
  data: T | null;
  error: string | null;
};

export type ReservationActionData = {
  id: string;
  reservation_status: string | null;
  attendance_status: string | null;
  payment_status: string | null;
  checked_in_at: string | null;
};

type ReservationActionOptions = {
  reservationId: string;
};

function getErrorMessage(error: unknown): string {
  if (!error) return "Nieznany błąd.";

  if (typeof error === "string") {
    return error;
  }

  if (typeof error === "object" && error !== null && "message" in error) {
    const message = (error as { message?: unknown }).message;

    if (typeof message === "string" && message.trim().length > 0) {
      return message;
    }
  }

  return "Nieznany błąd.";
}

async function updateReservation(
  supabase: SupabaseClient,
  reservationId: string,
  updates: Record<string, unknown>,
): Promise<ReservationActionResult<ReservationActionData>> {
  if (!reservationId) {
    return {
      data: null,
      error: "Brak ID rezerwacji.",
    };
  }

  const { data, error } = await supabase
    .from("reservations")
    .update(updates)
    .eq("id", reservationId)
    .select("id, reservation_status, attendance_status, payment_status, checked_in_at")
    .single();

  if (error) {
    return {
      data: null,
      error: getErrorMessage(error),
    };
  }

  return {
    data: data as ReservationActionData,
    error: null,
  };
}

export async function completeReservation(
  supabase: SupabaseClient,
  options: ReservationActionOptions,
): Promise<ReservationActionResult<ReservationActionData>> {
  return updateReservation(supabase, options.reservationId, {
    attendance_status: "present",
    reservation_status: "completed",
    checked_in_at: new Date().toISOString(),
  });
}

export async function markNoShow(
  supabase: SupabaseClient,
  options: ReservationActionOptions,
): Promise<ReservationActionResult<ReservationActionData>> {
  return updateReservation(supabase, options.reservationId, {
    attendance_status: "no_show",
    reservation_status: "no_show",
  });
}

export async function cancelReservation(
  supabase: SupabaseClient,
  options: ReservationActionOptions,
): Promise<ReservationActionResult<ReservationActionData>> {
  return updateReservation(supabase, options.reservationId, {
    reservation_status: "cancelled_by_admin",
  });
}

export async function markPaid(
  supabase: SupabaseClient,
  options: ReservationActionOptions,
): Promise<ReservationActionResult<ReservationActionData>> {
  return updateReservation(supabase, options.reservationId, {
    payment_status: "paid",
  });
}
export async function markPresent(
  supabase: any,
  { reservationId }: { reservationId: string }
) {
  const now = new Date().toISOString();

  const { data, error } = await supabase
    .from("reservations")
    .update({
      attendance_status: "present",
      reservation_status: "confirmed",
      checked_in_at: now,
      completed_at: null,
    })
    .eq("id", reservationId)
    .select()
    .single();

  if (error) {
    return { data: null, error: error.message };
  }

  return { data, error: null };
}

export async function markScheduled(
  supabase: any,
  { reservationId }: { reservationId: string }
) {
  const { data, error } = await supabase
    .from("reservations")
    .update({
      attendance_status: "planned",
      reservation_status: "confirmed",
      checked_in_at: null,
      completed_at: null,
    })
    .eq("id", reservationId)
    .select()
    .single();

  if (error) {
    return { data: null, error: error.message };
  }

  return { data, error: null };
}