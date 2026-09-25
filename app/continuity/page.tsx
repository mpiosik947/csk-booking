import { redirect } from "next/navigation";
import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import ContinuityPanel from "./ContinuityPanel";

export default async function ContinuityPage() {
  const client = await getTenantRequestClient();
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) redirect("/login?redirectTo=%2Fcontinuity");
  return <ContinuityPanel />;
}
