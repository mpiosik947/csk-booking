import "server-only";

type Reply = { data: unknown; error: unknown };
type Rpc = (name: string, args: Record<string, string>) => PromiseLike<Reply>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function deleteInput(value: unknown): value is { id: string; revision: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const p = value as Record<string, unknown>;
  return Object.keys(p).sort().join(",") === "id,revision" && typeof p.id === "string" && uuid.test(p.id) && typeof p.revision === "string" && uuid.test(p.revision);
}
// RPCs use the real request user's JWT. Storage receives only the key attested
// by prepare, never a browser-supplied tenant, media ID, token or object path.
export async function deleteArchivedPartner(rpc: Rpc, remove: (path: string) => Promise<boolean>, slug: string, input: { id: string; revision: string }) {
  const args = { p_tenant_slug: slug, p_id: input.id, p_expected_revision: input.revision };
  const prepared = await rpc("admin_prepare_partner_delete_v1", args);
  if (prepared.error) {
    const error = prepared.error as { code?: string; message?: string };
    return { status: error.code === "42501" ? 403 : error.code === "PT409" ? 409 : 400,
      error: error.message === "MEDIA_SHARED" ? "media_shared" : "delete_denied" };
  }
  const plan = prepared.data as Record<string, unknown> | null;
  if (!plan || ![plan.tenant_id, plan.media_id, plan.token].every(v => typeof v === "string" && uuid.test(v))) return { status: 502, error: "cleanup_unconfirmed" };
  const claimed = { ...args, p_token: plan.token as string };
  let finished = false;
  try {
    if (!await remove(`${plan.tenant_id}/partners/${plan.media_id}.webp`)) return { status: 502, error: "storage_cleanup_failed" };
    const final = await rpc("admin_finish_partner_delete_v1", claimed);
    if (final.error || final.data !== true) return { status: 409, error: "cleanup_unconfirmed" };
    finished = true;
    return { status: 200, deleted: true };
  } catch { return { status: 502, error: "cleanup_unconfirmed" }; }
  finally {
    if (!finished) {
      // Keep the durable attachment pin; release only this lease. If the
      // response is lost, a new request can recover after two minutes.
      try { await rpc("admin_release_partner_delete_v1", claimed); } catch { /* Retry after lease expiry. */ }
    }
  }
}
