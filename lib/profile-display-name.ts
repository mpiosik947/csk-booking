export type ProfileDisplayNameSource = {
  first_name?: string | null;
  last_name?: string | null;
  full_name?: string | null;
  email?: string | null;
};

export function getProfileDisplayName(
  profile: ProfileDisplayNameSource,
  fallback = "Użytkownik"
) {
  const structuredName = [profile.first_name, profile.last_name]
    .map((value) => value?.trim() ?? "")
    .filter(Boolean)
    .join(" ");

  return (
    structuredName ||
    profile.full_name?.trim() ||
    profile.email?.trim() ||
    fallback
  );
}

export function hasStructuredProfileName(
  profile: ProfileDisplayNameSource
) {
  return Boolean(profile.first_name?.trim() && profile.last_name?.trim());
}
