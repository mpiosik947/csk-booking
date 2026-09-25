import "server-only";
import { createClient } from "@supabase/supabase-js";
import { normalizeHostname, PLATFORM_BASE_URL } from "@/lib/platform-domain";

// Public RPCs only. Never forward browser credentials/cookies to this resolver.
function reader() {
  return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: (input, init) => fetch(input, { ...init, cache: "no-store" }) },
  });
}
export async function resolvePublicDomain(host: string) {
  if (normalizeHostname(host) !== host) return null;
  const { data, error } = await reader().rpc("resolve_public_tenant_domain_v1", { p_hostname: host });
  const slug = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
  if (error || !data || typeof data.tenant_slug !== "string" || typeof data.public_slug !== "string" ||
      !slug.test(data.tenant_slug) || !slug.test(data.public_slug)) return null;
  return { tenantSlug: data.tenant_slug as string, publicSlug: data.public_slug as string };
}
export async function tenantCanonical(publicSlug: string, section = "") {
  const { data, error } = await reader().rpc("get_public_tenant_primary_domain_v1", { p_public_slug: publicSlug });
  const host = !error && normalizeHostname(data);
  return host ? `https://${host}/${section}` : `${PLATFORM_BASE_URL}/${publicSlug}${section ? `/${section}` : ""}`;
}
