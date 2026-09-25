import { requirePlatformAdmin } from "@/lib/server/platform-admin";
import PlatformTenants from "./PlatformTenants";

export default async function PlatformAdminPage() {
  await requirePlatformAdmin();
  return <PlatformTenants />;
}
