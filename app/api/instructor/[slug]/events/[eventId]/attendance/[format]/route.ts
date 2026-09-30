import { getStaffRouteContext, getTenantRequestClient } from "@/lib/server/tenant-route-context";
import { parseInstructorEvent, parseInstructorPage, parseInstructorParticipant } from "@/lib/instructor-contracts";
import { ATTENDANCE_EXPORT_LIMIT, attendanceCsv, attendanceFilename, attendancePrint } from "@/lib/attendance-export";

export const dynamic = "force-dynamic";
const headers = { "Cache-Control": "private, no-store, max-age=0, must-revalidate", "Vary": "Cookie", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex, nofollow", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'" };
const deny = () => new Response("Lista jest niedostępna.", { status: 403, headers });
export async function GET(_request: Request, { params }: { params: Promise<{ slug: string; eventId: string; format: string }> }) {
  try {
    const { slug, eventId, format } = await params;
    if (!["csv", "print"].includes(format) || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(eventId)) return deny();
    const context = await getStaffRouteContext(slug, ["instructor"]);
    if (!context.ok) return deny();
    const client = await getTenantRequestClient();
    const result = await client.rpc("get_my_instructor_events_v1", { p_tenant_id: context.value.tenant.tenantId, p_event_id: eventId, p_scope: "upcoming", p_limit: 1, p_offset: 0 });
    if (result.error) return deny();
    const events = parseInstructorPage(result.data, parseInstructorEvent);
    if (events.items.length !== 1 || events.items[0].id !== eventId || !events.items[0].participants_available) return deny();
    // Authoritative DB reader revalidates membership, assignment, lifecycle and retention on EVERY request, before count/data.
    const resultRows = await client.rpc("get_instructor_event_participants_v1", { p_event_id: eventId, p_section: "participants", p_limit: ATTENDANCE_EXPORT_LIMIT, p_offset: 0 });
    if (resultRows.error) return deny();
    const page = parseInstructorPage(resultRows.data, parseInstructorParticipant);
    if (page.total > ATTENDANCE_EXPORT_LIMIT) return new Response("Lista przekracza limit 100 uczestników. Nie wygenerowano częściowego eksportu.", { status: 422, headers });
    if (page.total !== page.items.length) return deny();
    const data = { tenant: context.value.tenant.name, event: events.items[0], rows: page.items };
    return format === "csv"
      ? new Response(attendanceCsv(data), { headers: { ...headers, "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": `attachment; filename="${attendanceFilename(data.event)}"` } })
      : new Response(attendancePrint(data), { headers: { ...headers, "Content-Type": "text/html; charset=utf-8" } });
  } catch { return deny(); }
}
