import PlatformBrand from "@/app/_components/PlatformBrand";
import { requirePlatformAdmin } from "@/lib/server/platform-admin";
import PlatformTenants from "./PlatformTenants";

export default async function PlatformAdminPage() {
  const client = await requirePlatformAdmin();
  const { data } = await client.auth.getUser();
  return <div className="platform-ui min-h-screen"><header className="mx-auto max-w-7xl px-4 pt-6"><PlatformBrand compact /></header><PlatformTenants key={data?.user?.id ?? ""} actorId={data?.user?.id ?? ""} /></div>;
}
