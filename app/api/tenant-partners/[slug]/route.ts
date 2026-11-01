import { randomUUID, createHash } from "node:crypto";
import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import { normalizePartnerImage, partnerHeaders, partnerStorageClient, PARTNER_UPLOAD_LIMIT } from "@/lib/server/tenant-partner-media";
import { readPartnerList, validPartnerValues, UUID } from "@/lib/tenant-partners";

const json = (body: unknown, status = 200) => Response.json(body, { status, headers: partnerHeaders });
export async function POST(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  let uploaded: { path: string; tenant: string; id: string; registered: boolean } | null = null;
  let saved = false;
  try {
    if (request.headers.get("origin") !== new URL(request.url).origin) return json({ error: "forbidden" }, 403);
    const { slug } = await params;
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug) || slug.length > 63) return json({ error: "invalid_request" }, 400);
    const client = await getTenantRequestClient();
    const auth = await client.auth.getUser();
    if (auth.error || !auth.data?.user) return json({ error: "unauthorized" }, 401);
    const current = await client.rpc("admin_get_tenant_partners_v1", { p_tenant_slug: slug });
    const list = readPartnerList(current.data);
    if (current.error || !list) return json({ error: "forbidden" }, 403);
    const max = PARTNER_UPLOAD_LIMIT + 65536;
    if (Number(request.headers.get("content-length")) > max) return json({ error: "image_too_large" }, 413);
    const chunks: Uint8Array[] = []; let size = 0;
    const stream = request.body?.getReader();
    if (!stream) return json({ error: "invalid_request" }, 400);
    while (true) {
      const part = await stream.read(); if (part.done) break;
      size += part.value.byteLength;
      if (size > max) { await stream.cancel(); return json({ error: "image_too_large" }, 413); }
      chunks.push(part.value);
    }
    const form = await new Response(Buffer.concat(chunks), { headers: { "Content-Type": request.headers.get("content-type") ?? "" } }).formData();
    if ([...form.keys()].some(k => !["payload", "image"].includes(k)) || form.getAll("payload").length !== 1 || form.getAll("image").length > 1) return json({ error: "invalid_request" }, 400);
    const p = JSON.parse(String(form.get("payload")));
    if (!p || typeof p !== "object" || Object.keys(p).sort().join(",") !== "archive,id,media_id,revision,values" ||
      !UUID.test(p.id) || (p.revision !== null && !UUID.test(p.revision)) || (p.media_id !== null && !UUID.test(p.media_id)) ||
      typeof p.archive !== "boolean" || !validPartnerValues(p.values)) return json({ error: "invalid_request" }, 400);
    const image = form.get("image"); let media = p.media_id;
    if (image instanceof File && image.size > 0 && !p.archive) {
      let normalized;
      try { normalized = await normalizePartnerImage(Buffer.from(await image.arrayBuffer()), image.type); }
      catch { return json({ error: "invalid_image" }, 400); }
      const storage = partnerStorageClient(), id = randomUUID();
      const path = `${list.tenant_id}/partners/${id}.webp`;
      const result = await storage.storage.from("tenant-partners").upload(path, normalized.bytes, { contentType: "image/webp", upsert: false, cacheControl: "0" });
      if (result.error) return json({ error: "storage_unavailable" }, 503);
      uploaded = { path, tenant: list.tenant_id, id, registered: false };
      const register = await storage.rpc("register_tenant_partner_media_v1", { p_tenant_id: list.tenant_id, p_actor_id: auth.data.user.id,
        p_media_id: id, p_width: normalized.width, p_height: normalized.height, p_size: normalized.bytes.length, p_sha256: createHash("sha256").update(normalized.bytes).digest("hex") });
      if (register.error) return json({ error: "storage_unavailable" }, 503);
      uploaded.registered = true; media = id;
    }
    if (!media) return json({ error: "image_required" }, 400);
    // The request user's real JWT executes the writer. No service-role bypass.
    const result = await client.rpc("admin_save_tenant_partner_v1", { p_tenant_slug: slug, p_id: p.id, p_expected_revision: p.revision,
      p_values: p.values, p_media_id: media, p_archive: p.archive });
    if (result.error) {
      const code = (result.error as { code?: string }).code;
      return json({ error: code === "PT409" ? "conflict" : "save_failed" }, code === "PT409" ? 409 : code === "42501" ? 403 : 400);
    }
    saved = true;
    const next = readPartnerList(result.data);
    return next ? json(next) : json({ error: "reload_required" }, 503);
  } catch { return json({ error: "reload_required" }, 503); }
  finally {
    if (uploaded && !saved) {
      // Remove only this newly created, unreferenced object. An uncertain writer
      // response cannot cause deletion of an asset that was actually committed.
      try {
        const storage = partnerStorageClient();
        const discard = uploaded.registered ? await storage.rpc("discard_tenant_partner_media_v1", { p_tenant_id: uploaded.tenant, p_media_id: uploaded.id }) : { data: true, error: null };
        if (!discard.error && discard.data === true) await storage.storage.from("tenant-partners").remove([uploaded.path]);
      } catch { /* Private orphan is retained; never delete an uncertain reference. */ }
    }
  }
}
