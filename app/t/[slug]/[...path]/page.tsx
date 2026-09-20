import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { classifyTenantRoute, legacyCskPath } from "@/lib/tenant-routing";
import {
  getPublicRouteContext,
  getStaffRouteContext,
  getUserRouteContext,
} from "@/lib/server/tenant-route-context";
import BookingPage from "@/app/booking/page";
import EventsPage from "@/app/events/page";
import MyReservationsPage from "@/app/my-reservations/page";
import MyEventsPage from "@/app/my-events/page";
import AdminEventsPage from "@/app/admin/events/page";
import AdminLaneConfigurationPage from "@/app/admin/lane-configuration/page";
import AdminReportsPage from "@/app/admin/reports/page";
import AdminUsersPage from "@/app/admin/users/page";

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

  const oldPath = legacyCskPath(slug, route);
  return (
    <section className="rounded-2xl border border-[#8b986f] bg-[#192019] p-6 sm:p-8">
      <h1 className="text-xl font-semibold">Widok lokalizacji: {publicContext.value.name}</h1>
      <p className="mt-3 max-w-2xl text-[#d0d5c9]">
        Ten widok nie został jeszcze przełączony na tenantowy kontrakt danych. Nie pokazujemy tu danych z innej lokalizacji.
      </p>
      {oldPath && (
        <Link href={oldPath} className="mt-6 inline-flex rounded-lg border border-[#d7c895] px-4 py-3 text-[#d7c895]">
          Otwórz obecny widok CSK
        </Link>
      )}
    </section>
  );
}
