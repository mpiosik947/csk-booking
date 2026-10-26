import "server-only";
import { getTenantRequestClient } from "./tenant-route-context";
import { getPublicTenantLanding } from "./public-tenant-directory";
import { parsePublicContent } from "../public-tenant-content";

export type PublicSection = "cennik" | "o-obiekcie" | "kontakt";
const sectionFlags = { cennik: "showPricing", "o-obiekcie": "showAbout", kontakt: "showContact" } as const;

export async function getPublicSubpageTenant(slug: string, section: PublicSection) {
  const tenant = await getPublicTenantLanding(slug);
  // Flags are already intersected with entitlements by the public DB reader.
  return tenant && tenant[sectionFlags[section]] === true ? tenant : null;
}

export async function getPublicTenantContent(publicSlug: string) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return null;
  try {
    const client = await getTenantRequestClient();
    const { data, error } = await client.rpc("get_public_tenant_content_v1", { p_public_slug: publicSlug });
    return error ? null : parsePublicContent(data);
  } catch { return null; }
}
