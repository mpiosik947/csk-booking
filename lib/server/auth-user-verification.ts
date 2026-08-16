import {
  isAuthApiError,
  isAuthError,
  isAuthRetryableFetchError,
  isAuthSessionMissingError,
  type AuthError,
  type User,
} from "@supabase/supabase-js";

type AuthUserResponse = {
  data: { user: User | null };
  error: AuthError | null;
};

export type AuthUserFailure =
  | { ok: false; code: "unauthorized"; status: 401 }
  | { ok: false; code: "auth_unavailable"; status: 503 }
  | { ok: false; code: "internal_error"; status: 500 };

export type AuthUserVerificationResult =
  | { ok: true; user: User }
  | AuthUserFailure;

export function getAuthUserFailureMessage(failure: AuthUserFailure) {
  if (failure.code === "auth_unavailable") {
    return "Usługa logowania jest chwilowo niedostępna. Spróbuj ponownie.";
  }

  if (failure.code === "internal_error") {
    return "Nie udało się zweryfikować sesji. Spróbuj ponownie.";
  }

  return "Musisz zalogować się ponownie.";
}

const UNAUTHORIZED_ERROR_NAMES = new Set([
  "AuthInvalidCredentialsError",
  "AuthInvalidJwtError",
  "AuthSessionMissingError",
]);

const UNAUTHORIZED_ERROR_CODES = new Set([
  "bad_jwt",
  "invalid_credentials",
  "invalid_jwt",
  "no_authorization",
  "session_expired",
  "session_not_found",
  "user_banned",
  "user_not_found",
]);

function isNetworkFailure(error: unknown) {
  if (isAuthRetryableFetchError(error) || error instanceof TypeError) {
    return true;
  }

  if (isAuthError(error) && error.name === "AuthUnknownError") {
    const originalError = (error as AuthError & { originalError?: unknown })
      .originalError;
    return originalError instanceof TypeError;
  }

  return false;
}

function classifyAuthError(error: unknown): AuthUserFailure {
  if (isNetworkFailure(error)) {
    return { ok: false, code: "auth_unavailable", status: 503 };
  }

  if (isAuthError(error)) {
    if (typeof error.status === "number" && error.status >= 500) {
      return { ok: false, code: "auth_unavailable", status: 503 };
    }

    if (
      isAuthSessionMissingError(error) ||
      UNAUTHORIZED_ERROR_NAMES.has(error.name) ||
      (typeof error.code === "string" &&
        UNAUTHORIZED_ERROR_CODES.has(error.code)) ||
      (isAuthApiError(error) && error.status === 401)
    ) {
      return { ok: false, code: "unauthorized", status: 401 };
    }

    return { ok: false, code: "internal_error", status: 500 };
  }

  return { ok: false, code: "internal_error", status: 500 };
}

export async function verifyAuthUser(
  getUser: () => Promise<AuthUserResponse>
): Promise<AuthUserVerificationResult> {
  try {
    const { data, error } = await getUser();

    if (error) {
      return classifyAuthError(error);
    }

    if (!data.user) {
      return { ok: false, code: "unauthorized", status: 401 };
    }

    return { ok: true, user: data.user };
  } catch (error) {
    return classifyAuthError(error);
  }
}
