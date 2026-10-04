export type FieldErrors = Record<string, string>;
export type Hours = { openingTime: string; closingTime: string; legacy: string | null };
export const EMAIL_ERROR = "Podaj poprawny adres e-mail albo pozostaw pole puste.";
const PATH_ERROR = "Podaj lokalną ścieżkę, np. /brand/logo.png, bez .. i //, albo pozostaw pole puste.";
const URL_ERROR = "Podaj pełny adres URL albo pozostaw pole puste.";
const time = /^(?:[01]\d|2[0-3]):[0-5]\d$/;
export function parseHours(value: string | null): Hours {
  if (!value) return { openingTime: "", closingTime: "", legacy: null };
  const pair = /^(\d{2}:\d{2})[–-](\d{2}:\d{2})$/.exec(value);
  if (pair && time.test(pair[1]) && time.test(pair[2]) && pair[2] > pair[1])
    return { openingTime: pair[1], closingTime: pair[2], legacy: null };
  return { openingTime: "", closingTime: "", legacy: value };
}
export function serializeHours(hours: Hours): string | null {
  return hours.legacy ?? (hours.openingTime && hours.closingTime ? `${hours.openingTime}–${hours.closingTime}` : null);
}
export function validateSettings(settings: Record<string, unknown>, hours: Hours): FieldErrors {
  const errors: FieldErrors = {};
  const text = (key: string) => String(settings[key] ?? "").trim();
  const length = (value: string) => Array.from(value).length;
  for (const key of ["display_name", "city"]) if (!text(key) || length(text(key)) > 120) errors[key] = "Podaj od 1 do 120 znaków.";
  for (const key of ["logo_path", "hero_image_path", "regulations_path"]) {
    const value = text(key);
    if (value && (length(value) > 255 || !/^\/[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(value) || value.includes("..") || value.includes("//"))) errors[key] = PATH_ERROR;
  }
  if (length(text("description")) > 1200) errors.description = "Opis może mieć maksymalnie 1200 znaków.";
  if (text("public_address") && (length(text("public_address")) > 300 || /[\u0000-\u001f\u007f]/.test(text("public_address")))) errors.public_address = "Adres może mieć maksymalnie 300 znaków i nie może zawierać znaków sterujących.";
  const phone = text("public_phone");
  if (phone && (length(phone) < 5 || length(phone) > 32 || !/^[0-9+(). -]+$/.test(phone))) errors.public_phone = "Podaj od 5 do 32 znaków: cyfry, spacje, +, nawiasy, kropkę lub myślnik, albo pozostaw pole puste.";
  const email = text("public_email");
  if (email && (length(email) > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) errors.public_email = EMAIL_ERROR;
  const social = (settings.social_links ?? {}) as Record<string, string>;
  for (const key of ["facebook", "instagram", "youtube"]) {
    const value = (social[key] ?? "").trim();
    if (!value) continue;
    try { const url = new URL(value); if (length(value) > 500 || !/^https:\/\/[^\s]+$/.test(value) || url.protocol !== "https:" || !url.hostname) errors[key] = URL_ERROR; }
    catch { errors[key] = URL_ERROR; }
  }
  if (!hours.legacy) {
    if (hours.openingTime && !hours.closingTime) errors.closingTime = "Podaj również godzinę zamknięcia.";
    if (hours.closingTime && !hours.openingTime) errors.openingTime = "Podaj również godzinę otwarcia.";
    for (const key of ["openingTime", "closingTime"] as const) if (hours[key] && !time.test(hours[key])) errors[key] = "Podaj godzinę w formacie HH:MM.";
    if (time.test(hours.openingTime) && time.test(hours.closingTime) && hours.closingTime <= hours.openingTime) errors.closingTime = "Godzina zamknięcia musi być późniejsza niż godzina otwarcia.";
  }
  return errors;
}
export function mapSettingsError(error: { code?: string; message?: string }, settings: Record<string, unknown>, hours: Hours): { fields: FieldErrors; summary: string; conflict: boolean } {
  if (error.code === "PT409" || error.code === "40001" || error.message?.includes("settings_conflict")) return { fields: {}, summary: "Ustawienia zostały zmienione w innym miejscu. Odśwież dane i spróbuj ponownie.", conflict: true };
  const fields: FieldErrors = {};
  if (error.code === "23514") {
    for (const key of ["display_name", "city", "logo_path", "hero_image_path", "regulations_path", "description", "public_address", "public_phone", "public_email", "opening_hours"]) {
      if (error.message?.includes(`tenant_public_profiles_${key}_check`)) {
        fields[key === "opening_hours" ? (hours.legacy ? "legacyHours" : "openingTime") : key] = key === "public_email" ? EMAIL_ERROR : ["logo_path", "hero_image_path", "regulations_path"].includes(key) ? PATH_ERROR : "Sprawdź format i długość tego pola.";
      }
    }
  }
  if (error.code === "22023") Object.assign(fields, validateSettings(settings, hours));
  return { fields, summary: Object.keys(fields).length ? "Popraw zaznaczone pola." : "Nie udało się zapisać ustawień. Spróbuj ponownie.", conflict: false };
}
