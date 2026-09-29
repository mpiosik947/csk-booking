import { notFound, redirect } from "next/navigation";
import { getStaffRouteContext, getTenantRequestClient, tenantRouteHasFeature } from "@/lib/server/tenant-route-context";
import InstructorEvents from "@/app/instructor/InstructorEvents";
export const dynamic = "force-dynamic";
export default async function Page({ params }: { params: Promise<{ slug: string; event?: string[] }> }) {
  const { slug, event = [] } = await params;
  if (event.length > 1 || (event[0] && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(event[0]))) notFound();
  const context = await getStaffRouteContext(slug, ["instructor"]);
  if (!context.ok) {
    if (context.code === "unauthorized") redirect(`/login?redirectTo=${encodeURIComponent(`/t/${slug}/instructor/events${event[0] ? `/${event[0]}` : ""}`)}`);
    notFound();
  }
  if (!await tenantRouteHasFeature(context.value.tenant.tenantId, "events", "member")) notFound();
  if (event[0]) {
    const access = await (await getTenantRequestClient()).rpc("get_my_instructor_events_v1", {
      p_tenant_id: context.value.tenant.tenantId, p_event_id: event[0],
    });
    if (access.error) notFound();
  }
  return <InstructorEvents slug={slug} eventId={event[0]} />;
}
