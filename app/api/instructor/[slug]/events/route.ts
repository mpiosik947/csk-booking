import { getStaffRouteContext, getTenantRequestClient } from "@/lib/server/tenant-route-context";
import { parseInstructorEvent, parseInstructorPage, parseInstructorParticipant } from "@/lib/instructor-contracts";

export const dynamic = "force-dynamic";
const headers = { "Cache-Control": "private, no-store, max-age=0, must-revalidate", "Vary": "Cookie" };
const deny = () => Response.json({ error: "Dostęp do szkolenia jest niedostępny." }, { status: 403, headers });
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const context = await getStaffRouteContext(slug, ["instructor"]);
  if (!context.ok) return deny();
  const query = new URL(request.url).searchParams;
  const eventId = query.get("eventId");
  const scope = query.get("scope") ?? "upcoming";
  const section = query.get("section") ?? "participants";
  const page = Number(query.get("page") ?? "0");
  if ((eventId !== null && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(eventId)) ||
    !["upcoming", "past", "cancelled"].includes(scope) || !["participants", "reserve"].includes(section) ||
    !Number.isSafeInteger(page) || page < 0 || page > 2000) return deny();
  try {
    const client = await getTenantRequestClient();
    const events = await client.rpc("get_my_instructor_events_v1", {
      p_tenant_id: context.value.tenant.tenantId, p_scope: scope, p_event_id: eventId,
      p_limit: 20, p_offset: eventId ? 0 : page * 20,
    });
    if (events.error) return deny();
    const data = parseInstructorPage(events.data, parseInstructorEvent);
    if (!eventId) return Response.json({ events: data }, { headers });
    if (data.items.length !== 1) return deny();
    const event = data.items[0];
    if (!event.participants_available) return Response.json({ event, participants: null }, { headers });
    const rows = await client.rpc("get_instructor_event_participants_v1", {
      p_event_id: eventId, p_section: section, p_limit: 50, p_offset: page * 50,
    });
    // Reauthorization in the participant RPC covers removal between these calls.
    if (rows.error) return deny();
    return Response.json({ event, participants: parseInstructorPage(rows.data, parseInstructorParticipant) }, { headers });
  } catch { return deny(); }
}
