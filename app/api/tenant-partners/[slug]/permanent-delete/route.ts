import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import { partnerHeaders, partnerStorageClient } from "@/lib/server/tenant-partner-media";
import { deleteArchivedPartner, deleteInput } from "@/lib/server/tenant-partner-delete";

export async function POST(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  const json = (body: unknown, status: number) => Response.json(body, { status, headers: partnerHeaders });
  if (request.headers.get("origin") !== new URL(request.url).origin) return json({ error: "forbidden" }, 403);
  const { slug } = await params;
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug) || slug.length > 63) return json({ error: "invalid_request" }, 400);
  try {
    const client = await getTenantRequestClient(), auth = await client.auth.getUser();
    if (auth.error || !auth.data?.user) return json({ error: "unauthorized" }, 401);
    const reader = request.body?.getReader();
    if (!reader) return json({ error: "invalid_request" }, 400);
    const chunks: Uint8Array[] = []; let size = 0;
    while (true) { const part = await reader.read(); if (part.done) break;
      size += part.value.length; if (size > 1024) { await reader.cancel(); return json({ error: "invalid_request" }, 400); }
      chunks.push(part.value);
    }
    let input: unknown;
    try { input = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { return json({ error: "invalid_request" }, 400); }
    if (!deleteInput(input)) return json({ error: "invalid_request" }, 400);
    const result = await deleteArchivedPartner((name, args) => client.rpc(name, args), async path => {
      const { error } = await partnerStorageClient(15000).storage.from("tenant-partners").remove([path]);
      return !error;
    }, slug, input);
    return json(result.deleted ? { deleted: true } : { error: result.error }, result.status);
  } catch { return json({ error: "cleanup_unconfirmed" }, 502); }
}
