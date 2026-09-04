import type { SupabaseClient } from "@supabase/supabase-js";
import { PAYMENT_STATUS } from "./payment-status";
import { reportClientError } from "./safe-client-error";

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
  completed_at: string | null;
  admin_note: string | null;
};

type ReservationActionOptions = {
  reservationId: string;
};

type UpdateReservationNoteOptions = ReservationActionOptions & {
  note: string;
};

type ReservationRpcResult = {
  ok: boolean;
  changed: boolean;
  code: string;
  reservation_id?: string;
  reservation_status?: string | null;
  attendance_status?: string | null;
  payment_status?: string | null;
  checked_in_at?: string | null;
  completed_at?: string | null;
};

const CONTROLLED_ERROR_MESSAGES: Record<string, string> = {
  not_allowed: "Brak uprawnień do wykonania tej operacji.",
  invalid_input: "Nieprawidłowe dane operacji.",
  reservation_not_found: "Nie znaleziono rezerwacji.",
  invalid_state: "Rezerwacja ma niespójny stan i wymaga kontroli administratora.",
  invalid_transition: "Ta zmiana nie jest dozwolona w bieżącym stanie rezerwacji.",
};

function isReservationRpcResult(value: unknown): value is ReservationRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const candidate = value as Partial<ReservationRpcResult>;
  return (
    typeof candidate.ok === "boolean" &&
    typeof candidate.changed === "boolean" &&
    typeof candidate.code === "string"
  );
}

function mapRpcData(
  result: ReservationRpcResult,
  fallback: Partial<ReservationActionData> = {}
): ReservationActionData | null {
  if (!result.reservation_id) return null;

  return {
    id: result.reservation_id,
    reservation_status:
      result.reservation_status ?? fallback.reservation_status ?? null,
    attendance_status:
      result.attendance_status ?? fallback.attendance_status ?? null,
    payment_status: result.payment_status ?? fallback.payment_status ?? null,
    checked_in_at: result.checked_in_at ?? fallback.checked_in_at ?? null,
    completed_at: result.completed_at ?? fallback.completed_at ?? null,
    admin_note: fallback.admin_note ?? null,
  };
}

async function callControlledRpc(
  supabase: SupabaseClient,
  functionName:
    | "update_reservation_attendance"
    | "update_reservation_payment"
    | "update_reservation_admin_note",
  parameters: Record<string, unknown>,
  fallback: Partial<ReservationActionData> = {}
): Promise<ReservationActionResult<ReservationActionData>> {
  const reservationId = parameters.p_reservation_id;
  if (typeof reservationId !== "string" || !reservationId) {
    return { data: null, error: "Brak ID rezerwacji." };
  }

  const { data, error } = await supabase.rpc(functionName, parameters);
  if (error) {
    reportClientError(`${functionName} RPC failed`, error);
    return { data: null, error: "Nie udało się zapisać zmiany. Spróbuj ponownie." };
  }

  if (!isReservationRpcResult(data)) {
    console.error(`${functionName} RPC returned an invalid contract`);
    return { data: null, error: "Nie udało się potwierdzić wyniku operacji." };
  }

  if (!data.ok) {
    return {
      data: null,
      error:
        CONTROLLED_ERROR_MESSAGES[data.code] ??
        "Operacja nie mogła zostać wykonana.",
    };
  }

  return { data: mapRpcData(data, fallback), error: null };
}

function runAttendanceAction(
  supabase: SupabaseClient,
  options: ReservationActionOptions,
  action: "start" | "reset" | "complete" | "no_show"
) {
  return callControlledRpc(supabase, "update_reservation_attendance", {
    p_reservation_id: options.reservationId,
    p_action: action,
  });
}

function updatePayment(
  supabase: SupabaseClient,
  options: ReservationActionOptions,
  paymentStatus: string
) {
  return callControlledRpc(
    supabase,
    "update_reservation_payment",
    {
      p_reservation_id: options.reservationId,
      p_payment_status: paymentStatus,
    },
    { payment_status: paymentStatus }
  );
}

export function completeReservation(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return runAttendanceAction(supabase, options, "complete");
}

export function markNoShow(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return runAttendanceAction(supabase, options, "no_show");
}

export async function cancelReservation(
  supabase: SupabaseClient,
  options: ReservationActionOptions
): Promise<ReservationActionResult<ReservationActionData>> {
  if (!options.reservationId) {
    return { data: null, error: "Brak ID rezerwacji." };
  }

  const { data, error } = await supabase.rpc("cancel_reservation", {
    p_reservation_id: options.reservationId,
  });
  if (error) {
    reportClientError("cancel_reservation RPC failed", error);
    return { data: null, error: "Nie udało się anulować rezerwacji." };
  }

  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return { data: null, error: "Nie udało się potwierdzić anulowania." };
  }

  const result = data as {
    reservation_id?: unknown;
    new_status?: unknown;
  };
  if (
    typeof result.reservation_id !== "string" ||
    typeof result.new_status !== "string"
  ) {
    return { data: null, error: "Nie udało się potwierdzić anulowania." };
  }

  return {
    data: {
      id: result.reservation_id,
      reservation_status: result.new_status,
      attendance_status: null,
      payment_status: null,
      checked_in_at: null,
      completed_at: null,
      admin_note: null,
    },
    error: null,
  };
}

export function markPaid(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return updatePayment(supabase, options, PAYMENT_STATUS.PAID);
}

export function markUnpaid(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return updatePayment(supabase, options, PAYMENT_STATUS.UNPAID);
}

export function markVoucher(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return updatePayment(supabase, options, PAYMENT_STATUS.VOUCHER);
}

export function markFree(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return updatePayment(supabase, options, PAYMENT_STATUS.FREE);
}

export function markPayOnSite(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return updatePayment(supabase, options, PAYMENT_STATUS.PAY_ON_SITE);
}

export function markPresent(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return runAttendanceAction(supabase, options, "start");
}

export function markScheduled(
  supabase: SupabaseClient,
  options: ReservationActionOptions
) {
  return runAttendanceAction(supabase, options, "reset");
}

export function updateReservationNote(
  supabase: SupabaseClient,
  options: UpdateReservationNoteOptions
) {
  return callControlledRpc(
    supabase,
    "update_reservation_admin_note",
    {
      p_reservation_id: options.reservationId,
      p_admin_note: options.note,
    },
    { admin_note: options.note.trim() || null }
  );
}

export function updateReservationPayment(
  supabase: SupabaseClient,
  options: ReservationActionOptions & { paymentStatus: string }
) {
  return updatePayment(supabase, options, options.paymentStatus);
}
