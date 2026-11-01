import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import { partnerHeaders, partnerStorageClient } from "@/lib/server/tenant-partner-media";
import { UUID, readPublicPartners } from "@/lib/tenant-partners";
import { createClient } from "@supabase/supabase-js";
import { hostFromRequest, PLATFORM_HOST } from "@/lib/platform-domain";
import { resolvePublicDomain } from "@/lib/server/tenant-domain";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const missing = () => new Response(null, { status: 404, headers: partnerHeaders });
  try {
    const { id } = await params;
    if (!UUID.test(id)) return missing();
    const local = process.env.NEXT_PUBLIC_SUPABASE_URL?.startsWith("http://127.0.0.1:") === true;
    const host = hostFromRequest(request.headers.get("host"), local);
    if (!host) return missing();
    const custom = host !== PLATFORM_HOST && host !== "localhost";
    const client = custom ? createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
      auth: { persistSession: false, autoRefreshToken: false },
    }) : await getTenantRequestClient();
    const domainAllowed = async () => {
      if (!custom) return true;
      const domain = await resolvePublicDomain(host);
      if (!domain) return false;
      const result = await client.rpc("get_public_tenant_partners_v1", { p_public_slug: domain.publicSlug });
      return !result.error && !!readPublicPartners(result.data)?.some(p => p.media_id === id.toLowerCase());
    };
    if (!await domainAllowed()) return missing();
    const read = () => client.rpc("get_tenant_partner_media_v1", { p_media_id: id });
    const { data: path, error } = await read();
    if (error || typeof path !== "string" || !new RegExp(`^[0-9a-f-]{36}/partners/${id}\\.webp$`, "i").test(path)) return missing();
    const { data, error: downloadError } = await partnerStorageClient().storage.from("tenant-partners").download(path);
    if (downloadError || !data) return missing();
    // Recheck after storage I/O, including logout, expiry and state changes.
    const again = await read();
    if (again.error || again.data !== path || !await domainAllowed()) return missing();
    return new Response(data, { headers: { ...partnerHeaders, "Content-Type": "image/webp", "Content-Disposition": 'inline; filename="partner.webp"', "Cross-Origin-Resource-Policy": "same-origin" } });
  } catch { return missing(); }
}
