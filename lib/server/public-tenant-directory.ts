import "server-only";

import { createClient } from "@supabase/supabase-js";
import { isCanonicalTenantSlug } from "./tenant-context-core";

const LOGO_PATH = /^\/[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const DIRECTORY_FIELDS = [
  "tenant_city",
  "tenant_logo_path",
  "tenant_name",
  "tenant_slug",
] as const;

export type PublicTenantDirectoryItem = Readonly<{
  slug: string;
  name: string;
  city: string;
  logoPath: string | null;
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

  const slug = row.tenant_slug;
  const name = row.tenant_name;
  const city = row.tenant_city;
  const logoPath = row.tenant_logo_path;
  if (!isCanonicalTenantSlug(slug) || typeof name !== "string" || name !== name.trim() ||
      name.length < 1 || name.length > 120 || typeof city !== "string" ||
      city !== city.trim() || city.length < 1 || city.length > 120 ||
      (logoPath !== null && (typeof logoPath !== "string" ||
        logoPath.length > 255 || !LOGO_PATH.test(logoPath) ||
        logoPath.includes("..") || logoPath.includes("//")))) {
    return null;
  }

  return { slug, name, city, logoPath: logoPath as string | null };
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
    const { data, error } = await client.rpc("get_public_tenant_directory_v1", {
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

export async function getPublishedTenantBySlug(slug: unknown) {
  if (!isCanonicalTenantSlug(slug)) return null;
  const result = await getPublicTenantDirectory(slug);
  if (!result.ok) return null;
  return result.items.find((tenant) => tenant.slug === slug) ?? null;
}
