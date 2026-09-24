import "server-only";

import { createClient } from "@supabase/supabase-js";
import { cache } from "react";
import { isCanonicalTenantSlug } from "./tenant-context-core";

const LOGO_PATH = /^\/[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const DIRECTORY_FIELDS = [
  "public_slug",
  "tenant_city",
  "tenant_logo_path",
  "tenant_name",
] as const;
const LANDING_FIELDS = [
  "public_slug",
  "show_about",
  "show_booking",
  "show_contact",
  "show_events",
  "show_instructor",
  "show_pricing",
  "show_regulations",
  "tenant_city",
  "tenant_description",
  "tenant_hero_image_path",
  "tenant_logo_path",
  "tenant_name",
  "tenant_opening_hours",
  "tenant_public_address",
  "tenant_public_email",
  "tenant_public_phone",
  "tenant_regulations_path",
  "tenant_slug",
  "tenant_social_links",
] as const;

export type PublicTenantDirectoryItem = Readonly<{
  publicSlug: string;
  name: string;
  city: string;
  logoPath: string | null;
}>;

export type PublicTenantLanding = Readonly<{
  tenantSlug: string;
  publicSlug: string;
  name: string;
  city: string;
  logoPath: string | null;
  heroImagePath: string | null;
  description: string | null;
  regulationsPath: string | null;
  publicAddress: string | null;
  publicPhone: string | null;
  publicEmail: string | null;
  openingHours: string | null;
  socialLinks: Readonly<Partial<Record<"facebook" | "instagram" | "youtube", string>>>;
  showBooking: boolean;
  showPricing: boolean;
  showInstructor: boolean;
  showEvents: boolean;
  showAbout: boolean;
  showContact: boolean;
  showRegulations: boolean;
}>;

export type PublicTenantDirectoryResult =
  | Readonly<{ ok: true; items: readonly PublicTenantDirectoryItem[]; search: string }>
  | Readonly<{ ok: false; items: readonly []; search: string }>;

function normalizeSearch(value: unknown) {
  if (typeof value !== "string") return "";
  const normalized = value.trim().replace(/\s+/g, " ");
  return normalized.length <= 80 ? normalized : normalized.slice(0, 80);
}

function readItem(value: unknown): PublicTenantDirectoryItem | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (Object.keys(row).sort().join(",") !== DIRECTORY_FIELDS.join(",")) return null;

  const publicSlug = row.public_slug;
  const name = row.tenant_name;
  const city = row.tenant_city;
  const logoPath = row.tenant_logo_path;
  if (!isCanonicalTenantSlug(publicSlug) || typeof name !== "string" || name !== name.trim() ||
      name.length < 1 || name.length > 120 || typeof city !== "string" ||
      city !== city.trim() || city.length < 1 || city.length > 120 ||
      (logoPath !== null && (typeof logoPath !== "string" ||
        logoPath.length > 255 || !LOGO_PATH.test(logoPath) ||
        logoPath.includes("..") || logoPath.includes("//")))) {
    return null;
  }

  return { publicSlug, name, city, logoPath: logoPath as string | null };
}

function isSafePublicPath(value: unknown): value is string | null {
  return value === null || (typeof value === "string" && value.length <= 255 &&
    LOGO_PATH.test(value) && !value.includes("..") && !value.includes("//"));
}

function readLanding(value: unknown): PublicTenantLanding | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (Object.keys(row).sort().join(",") !== LANDING_FIELDS.join(",")) return null;

  const tenantSlug = row.tenant_slug;
  const publicSlug = row.public_slug;
  const name = row.tenant_name;
  const city = row.tenant_city;
  const logoPath = row.tenant_logo_path;
  const heroImagePath = row.tenant_hero_image_path;
  const description = row.tenant_description;
  const regulationsPath = row.tenant_regulations_path;
  const publicAddress = row.tenant_public_address;
  const publicPhone = row.tenant_public_phone;
  const publicEmail = row.tenant_public_email;
  const openingHours = row.tenant_opening_hours;
  const socialLinks = row.tenant_social_links;
  const flags = [row.show_booking,row.show_pricing,row.show_instructor,row.show_events,row.show_about,row.show_contact,row.show_regulations];
  if (!isCanonicalTenantSlug(tenantSlug) || !isCanonicalTenantSlug(publicSlug) ||
      typeof name !== "string" || name !== name.trim() || name.length < 1 || name.length > 120 ||
      typeof city !== "string" || city !== city.trim() || city.length < 1 || city.length > 120 ||
      !isSafePublicPath(logoPath) || !isSafePublicPath(heroImagePath) ||
      !isSafePublicPath(regulationsPath) ||
      (description !== null && (typeof description !== "string" ||
        description !== description.trim() || description.length < 1 || description.length > 1200)) ||
      [publicAddress, publicPhone, publicEmail, openingHours].some((item) => item !== null && typeof item !== "string") ||
      !socialLinks || typeof socialLinks !== "object" || Array.isArray(socialLinks) ||
      Object.entries(socialLinks).some(([key, url]) => !["facebook","instagram","youtube"].includes(key) || typeof url !== "string" || url.length > 500 || !/^https:\/\/\S+$/u.test(url)) ||
      flags.some((flag) => typeof flag !== "boolean")) {
    return null;
  }

  return {
    tenantSlug,
    publicSlug,
    name,
    city,
    logoPath,
    heroImagePath,
    description: description as string | null,
    regulationsPath,
    publicAddress: publicAddress as string | null,
    publicPhone: publicPhone as string | null,
    publicEmail: publicEmail as string | null,
    openingHours: openingHours as string | null,
    socialLinks: socialLinks as PublicTenantLanding["socialLinks"],
    showBooking: row.show_booking as boolean,
    showPricing: row.show_pricing as boolean,
    showInstructor: row.show_instructor as boolean,
    showEvents: row.show_events as boolean,
    showAbout: row.show_about as boolean,
    showContact: row.show_contact as boolean,
    showRegulations: row.show_regulations as boolean,
  };
}

export async function getPublicTenantDirectory(
  requestedSearch: unknown,
): Promise<PublicTenantDirectoryResult> {
  const search = normalizeSearch(requestedSearch);
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!supabaseUrl || !anonKey) return { ok: false, items: [], search };

  try {
    const client = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await client.rpc("get_public_tenant_directory_v2", {
      p_search: search || null,
    });
    if (error || !Array.isArray(data) || data.length > 50) {
      return { ok: false, items: [], search };
    }

    const items = data.map(readItem);
    if (items.some((item) => item === null)) {
      return { ok: false, items: [], search };
    }
    return {
      ok: true,
      items: items as PublicTenantDirectoryItem[],
      search,
    };
  } catch {
    return { ok: false, items: [], search };
  }
}

export const getPublicTenantLanding = cache(async (
  slug: unknown,
): Promise<PublicTenantLanding | null> => {
  if (!isCanonicalTenantSlug(slug)) return null;
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!supabaseUrl || !anonKey) return null;

  try {
    const client = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await client.rpc("get_public_tenant_landing_v2", {
      p_slug: slug,
    });
    if (error || !Array.isArray(data) || data.length !== 1) return null;
    return readLanding(data[0]);
  } catch {
    return null;
  }
});
