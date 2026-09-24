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
  "tenant_city",
  "tenant_description",
  "tenant_hero_image_path",
  "tenant_logo_path",
  "tenant_name",
  "tenant_regulations_path",
  "tenant_slug",
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
  if (!isCanonicalTenantSlug(tenantSlug) || !isCanonicalTenantSlug(publicSlug) ||
      typeof name !== "string" || name !== name.trim() || name.length < 1 || name.length > 120 ||
      typeof city !== "string" || city !== city.trim() || city.length < 1 || city.length > 120 ||
      !isSafePublicPath(logoPath) || !isSafePublicPath(heroImagePath) ||
      !isSafePublicPath(regulationsPath) ||
      (description !== null && (typeof description !== "string" ||
        description !== description.trim() || description.length < 1 || description.length > 1200))) {
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
    const { data, error } = await client.rpc("get_public_tenant_landing_v1", {
      p_slug: slug,
    });
    if (error || !Array.isArray(data) || data.length !== 1) return null;
    return readLanding(data[0]);
  } catch {
    return null;
  }
});
