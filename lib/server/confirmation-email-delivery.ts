import { createClient } from "@supabase/supabase-js";

export type ConfirmationDeliveryCode =
  | "sent"
  | "already_sent"
  | "in_progress"
  | "attempt_limit_reached"
  | "unauthorized"
  | "not_found"
  | "invalid_status"
  | "delivery_failed"
  | "internal_error";

type SafeProviderErrorCode =
  | "email_send_failed"
  | "email_provider_error"
  | "invalid_recipient"
  | "unexpected_error";

type RpcCallResult = {
  data: unknown;
  error: unknown;
};

type ProviderSendResult = {
  data: { id?: string } | null;
  error: unknown;
};

type CompletionInput = {
  p_claim_id: string;
  p_success: boolean;
  p_provider_message_id: string | null;
  p_error_code: SafeProviderErrorCode | null;
};

type DeliveryDependencies = {
  prepare: () => Promise<RpcCallResult>;
  send: (idempotencyKey: string) => Promise<ProviderSendResult>;
  complete: (input: CompletionInput) => Promise<RpcCallResult>;
};

export type ConfirmationDeliveryOutcome = {
  ok: boolean;
  code: ConfirmationDeliveryCode;
  status: number;
};

type ReadyPreparation = {
  claimId: string;
  idempotencyKey: string;
};

export type ConfirmationEmailConfiguration = {
  resendApiKey: string;
  from: string;
  supabaseUrl: string;
  serviceRoleKey: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function readCode(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const code = (value as Record<string, unknown>).code;
  return typeof code === "string" ? code : null;
}

function readReadyPreparation(value: unknown): ReadyPreparation | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const result = value as Record<string, unknown>;
  const claimId = typeof result.claim_id === "string" ? result.claim_id : "";
  const deliveryId =
    typeof result.delivery_id === "string" ? result.delivery_id : "";
  const idempotencyKey =
    typeof result.idempotency_key === "string" ? result.idempotency_key : "";

  if (
    result.ok !== true ||
    result.changed !== true ||
    result.code !== "ready" ||
    !UUID_PATTERN.test(claimId) ||
    !UUID_PATTERN.test(deliveryId) ||
    !idempotencyKey ||
    idempotencyKey.length > 256
  ) {
    return null;
  }

  return { claimId, idempotencyKey };
}

function mapPrepareOutcome(code: string | null): ConfirmationDeliveryOutcome {
  switch (code) {
    case "already_sent":
      return { ok: true, code, status: 200 };
    case "in_progress":
      return { ok: false, code, status: 409 };
    case "attempt_limit_reached":
      return { ok: false, code, status: 429 };
    case "unauthorized":
      return { ok: false, code, status: 401 };
    case "not_found":
      return { ok: false, code, status: 404 };
    case "invalid_status":
      return { ok: false, code, status: 409 };
    default:
      return { ok: false, code: "internal_error", status: 500 };
  }
}

function normalizeProviderError(error: unknown): SafeProviderErrorCode {
  if (!error || typeof error !== "object") {
    return "unexpected_error";
  }

  const errorRecord = error as Record<string, unknown>;
  const code =
    typeof errorRecord.code === "string"
      ? errorRecord.code.toLowerCase()
      : typeof errorRecord.name === "string"
        ? errorRecord.name.toLowerCase()
        : "";
  const message =
    typeof errorRecord.message === "string"
      ? errorRecord.message.toLowerCase()
      : "";
  const status =
    typeof errorRecord.statusCode === "number"
      ? errorRecord.statusCode
      : typeof errorRecord.status === "number"
        ? errorRecord.status
        : undefined;

  if (code.includes("unexpected")) {
    return "unexpected_error";
  }

  if (
    status === 401 ||
    status === 403 ||
    status === 429 ||
    (typeof status === "number" && status >= 500) ||
    code.includes("api_key") ||
    code.includes("authentication") ||
    code.includes("authorization") ||
    code.includes("domain") ||
    code.includes("sender") ||
    code.includes("configuration") ||
    code.includes("rate_limit") ||
    code.includes("provider")
  ) {
    return "email_provider_error";
  }

  const explicitlyInvalidRecipient =
    code.includes("invalid_recipient") ||
    code.includes("invalid_email") ||
    code.includes("email_validation");
  const mentionsRecipient =
    explicitlyInvalidRecipient ||
    message.includes("recipient") ||
    message.includes("email address");
  const mentionsValidation =
    code.includes("validation") ||
    message.includes("invalid") ||
    message.includes("validation");

  if (explicitlyInvalidRecipient || (mentionsRecipient && mentionsValidation)) {
    return "invalid_recipient";
  }

  if (status === 400 || status === 422) {
    return "unexpected_error";
  }

  return "email_send_failed";
}

function completionSucceeded(value: unknown, expectedCode: "sent" | "failed") {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    (value as Record<string, unknown>).ok === true &&
    (value as Record<string, unknown>).code === expectedCode
  );
}

export function getConfirmationEmailConfiguration(
  environment: NodeJS.ProcessEnv = process.env
): ConfirmationEmailConfiguration | null {
  const resendApiKey = environment.RESEND_API_KEY?.trim();
  const from = environment.RESERVATION_EMAIL_FROM?.trim();
  const supabaseUrl = environment.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const serviceRoleKey = environment.SUPABASE_SERVICE_ROLE_KEY?.trim();

  if (!resendApiKey || !from || !supabaseUrl || !serviceRoleKey) {
    return null;
  }

  return { resendApiKey, from, supabaseUrl, serviceRoleKey };
}

export function getConfirmationServiceRoleClient(
  configuration: ConfirmationEmailConfiguration
) {
  return createClient(configuration.supabaseUrl, configuration.serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}

export async function deliverConfirmationEmail({
  prepare,
  send,
  complete,
}: DeliveryDependencies): Promise<ConfirmationDeliveryOutcome> {
  const preparation = await prepare();

  if (preparation.error) {
    return { ok: false, code: "internal_error", status: 500 };
  }

  const prepareCode = readCode(preparation.data);

  if (prepareCode !== "ready") {
    return mapPrepareOutcome(prepareCode);
  }

  const ready = readReadyPreparation(preparation.data);

  if (!ready) {
    return { ok: false, code: "internal_error", status: 500 };
  }

  let providerResult: ProviderSendResult;

  try {
    providerResult = await send(ready.idempotencyKey);
  } catch (error) {
    providerResult = { data: null, error };
  }

  if (providerResult.error) {
    const failure = await complete({
      p_claim_id: ready.claimId,
      p_success: false,
      p_provider_message_id: null,
      p_error_code: normalizeProviderError(providerResult.error),
    });

    if (
      failure.error ||
      !completionSucceeded(failure.data, "failed")
    ) {
      return { ok: false, code: "internal_error", status: 500 };
    }

    return { ok: false, code: "delivery_failed", status: 502 };
  }

  const providerMessageId =
    typeof providerResult.data?.id === "string"
      ? providerResult.data.id.trim()
      : null;

  if (!providerMessageId) {
    const failure = await complete({
      p_claim_id: ready.claimId,
      p_success: false,
      p_provider_message_id: null,
      p_error_code: "unexpected_error",
    });

    if (
      failure.error ||
      !completionSucceeded(failure.data, "failed")
    ) {
      return { ok: false, code: "internal_error", status: 500 };
    }

    return { ok: false, code: "delivery_failed", status: 502 };
  }

  const completion = await complete({
    p_claim_id: ready.claimId,
    p_success: true,
    p_provider_message_id: providerMessageId,
    p_error_code: null,
  });

  if (
    completion.error ||
    !completionSucceeded(completion.data, "sent")
  ) {
    return { ok: false, code: "internal_error", status: 500 };
  }

  return { ok: true, code: "sent", status: 200 };
}
