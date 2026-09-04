type ErrorWithCode = {
  code?: unknown;
};

const SAFE_ERROR_CODE = /^[a-z0-9_]{1,64}$/i;

export function getSafeErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object") {
    return null;
  }

  const code = (error as ErrorWithCode).code;
  return typeof code === "string" && SAFE_ERROR_CODE.test(code)
    ? code.toLowerCase()
    : null;
}

export function reportClientError(operation: string, error?: unknown) {
  const code = getSafeErrorCode(error);

  if (code) {
    console.error(operation, { code });
    return;
  }

  console.error(operation);
}

export function getLoginErrorMessage(error: unknown) {
  switch (getSafeErrorCode(error)) {
    case "email_not_confirmed":
      return "Wymagana jest weryfikacja adresu e-mail. Sprawdź skrzynkę pocztową i kliknij link aktywacyjny wysłany podczas rejestracji.";
    case "invalid_credentials":
      return "Nieprawidłowy adres e-mail lub hasło.";
    default:
      return "Nie udało się zalogować. Spróbuj ponownie.";
  }
}

export function getRegistrationErrorMessage(error: unknown) {
  const code = getSafeErrorCode(error);

  if (code === "user_already_exists" || code === "email_exists") {
    return "Konto z tym adresem e-mail już istnieje. Zaloguj się lub skorzystaj z odzyskiwania hasła.";
  }

  return "Nie udało się utworzyć konta. Spróbuj ponownie.";
}

const EVENT_CONFIRMATION_MESSAGES: Readonly<Record<string, string>> = {
  confirmed: "Miejsce zostało potwierdzone.",
  full: "Brak wolnych miejsc na tym szkoleniu.",
  expired: "Link potwierdzający wygasł.",
  not_found: "Nie znaleziono aktywnego zaproszenia.",
  event_not_found: "Nie znaleziono aktywnego zaproszenia.",
  not_reserve: "Ten zapis nie oczekuje już na potwierdzenie miejsca.",
  invalid_token: "Nieprawidłowy link potwierdzający.",
  unauthorized: "Zaloguj się, aby potwierdzić swoje miejsce.",
  auth_unavailable:
    "Usługa uwierzytelniania jest chwilowo niedostępna. Spróbuj ponownie.",
};

export function getEventConfirmationResponseMessage(
  code: unknown,
  success: boolean
) {
  if (typeof code === "string" && EVENT_CONFIRMATION_MESSAGES[code]) {
    return EVENT_CONFIRMATION_MESSAGES[code];
  }

  return success
    ? "Miejsce zostało potwierdzone."
    : "Nie udało się potwierdzić miejsca. Spróbuj ponownie.";
}

const SESSION_ERROR_CODES = new Set([
  "bad_jwt",
  "no_authorization",
  "session_expired",
  "session_not_found",
]);

export function getPasswordUpdateErrorMessage(
  error: unknown,
  context: "account" | "reset"
) {
  const code = getSafeErrorCode(error);

  if (code === "same_password") {
    return "Nowe hasło musi być inne niż poprzednie.";
  }

  if (code === "weak_password") {
    return "Hasło nie spełnia wymagań bezpieczeństwa.";
  }

  if (context === "reset" && code && SESSION_ERROR_CODES.has(code)) {
    return "Link resetujący jest nieprawidłowy albo wygasł. Wygeneruj nowy link.";
  }

  return context === "reset"
    ? "Nie udało się zmienić hasła. Spróbuj ponownie."
    : "Nie udało się zmienić hasła. Spróbuj ponownie.";
}
