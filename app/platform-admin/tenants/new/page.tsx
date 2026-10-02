import { requirePlatformAdmin } from "@/lib/server/platform-admin";
import TenantWizard from "./TenantWizard";
import { redirect } from "next/navigation";

export default async function NewTenantPage() {
  const client = await requirePlatformAdmin();
  const { data } = await client.auth.getUser();
  if (!data?.user) redirect("/login?redirectTo=%2Fplatform-admin");
  return <TenantWizard actorId={data.user.id} />;
}
