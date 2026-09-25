import { notFound, redirect } from "next/navigation";
import { classifyTenantRoute } from "@/lib/tenant-routing";
import {
  getPublicRouteContext,
  getStaffRouteContext,
  getUserRouteContext,
  tenantRouteHasFeature,
} from "@/lib/server/tenant-route-context";
import { featureForTenantRoute } from "@/lib/tenant-features";
import BookingPage from "@/app/booking/page";
import EventsPage from "@/app/events/page";
import MyReservationsPage from "@/app/my-reservations/page";
import MyEventsPage from "@/app/my-events/page";
import AdminEventsPage from "@/app/admin/events/page";
import AdminLaneConfigurationPage from "@/app/admin/lane-configuration/page";
import AdminReportsPage from "@/app/admin/reports/page";
import AdminUsersPage from "@/app/admin/users/page";
import AdminLaneBlocksPage from "@/app/admin/lane-blocks/page";
import AdminReservationsPage from "@/app/admin/reservations/page";
import AdminHomePage from "@/app/admin/page";
import AdminCheckInPage from "@/app/admin/check-in/page";
import AdminCalendarPage from "@/app/admin/calendar/page";
import TenantAdminSettings from "@/app/admin/settings/TenantAdminSettings";

export default async function TenantModuleShell({
  params,
}: Readonly<{ params: Promise<{ slug: string; path: string[] }> }>) {
  const { slug, path } = await params;
  const route = classifyTenantRoute(path);
  if (route.kind === "not_found") notFound();

  // The layout checked the public slug. Recheck here before privileged work.
  const publicContext = await getPublicRouteContext(slug);
  if (!publicContext.ok) notFound();

  if (route.kind === "user" || route.kind === "staff") {
    const result = route.kind === "staff"
      ? await getStaffRouteContext(slug, route.roles)
      : await getUserRouteContext(slug);
    if (!result.ok) {
      if (result.code === "unauthorized") {
        const returnPath = `/t/${slug}/${route.path}`;
        redirect(`/login?redirectTo=${encodeURIComponent(returnPath)}`);
      }
      notFound();
    }
  }

  if (route.kind === "staff" && !route.known) notFound();

  const tenantId = publicContext.value.tenantId;
  const requiredFeature = featureForTenantRoute(route.path);
  if (requiredFeature) {
    const hasFeature = await tenantRouteHasFeature(
      tenantId,
      requiredFeature,
      route.kind === "public" ? "public" : "member",
    );
    if (!hasFeature) notFound();
  }
  if (route.path === "booking") return <BookingPage tenantId={tenantId} tenantSlug={slug} />;
  if (route.path === "events") return <EventsPage tenantId={tenantId} tenantSlug={slug} />;
  if (route.path === "my-reservations") return <MyReservationsPage tenantId={tenantId} tenantSlug={slug} />;
  if (route.path === "my-events") return <MyEventsPage tenantId={tenantId} tenantSlug={slug} />;
  if (route.kind === "staff" && route.path === "admin/events") {
    return <AdminEventsPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/lane-configuration") {
    return <AdminLaneConfigurationPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/reports") {
    return <AdminReportsPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/users") {
    return <AdminUsersPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/lane-blocks") {
    return <AdminLaneBlocksPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/reservations") {
    return <AdminReservationsPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin") {
    return <AdminHomePage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/check-in") {
    return <AdminCheckInPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/calendar") {
    return <AdminCalendarPage tenantId={tenantId} tenantSlug={slug} />;
  }
  if (route.kind === "staff" && route.path === "admin/settings") {
    return <TenantAdminSettings tenantSlug={slug} />;
  }

  notFound();
}
