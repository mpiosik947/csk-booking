import "server-only";
import { notFound, redirect } from "next/navigation";
import { getTenantRequestClient } from "./tenant-route-context";

/** Platform authority never implies tenant operational authority. */
export async function requirePlatformAdmin() {
  const client = await getTenantRequestClient();
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) redirect("/login?redirectTo=%2Fplatform-admin");
  const result = await client.rpc("is_platform_admin_v1", {});
  if (result.error || result.data !== true) notFound();
  return client;
}
