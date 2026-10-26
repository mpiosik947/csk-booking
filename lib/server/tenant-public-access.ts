import "server-only";
import { getTenantRequestClient } from "./tenant-route-context";
import { fetchTenantPublicAccess } from "../tenant-public-access";

/** Request cookies only. Never persist an actor's decision in a shared cache. */
export async function getTenantPublicAccess(slug: string) {
  return fetchTenantPublicAccess(await getTenantRequestClient(), slug);
}
