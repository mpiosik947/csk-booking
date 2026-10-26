import type { ReactNode } from "react";
import { cache } from "react";
import { getTenantRequestClient } from "@/lib/server/tenant-route-context";
import PublicAccessSessionClient from "./PublicAccessSessionClient";

const requestActor = cache(async () => {
  const { data, error } = await (await getTenantRequestClient()).auth.getUser();
  return error ? null : data?.user?.id ?? null;
});

/** Bind rendered navigation to the verified identity of this request, including hydration. */
export default async function PublicAccessSessionBoundary({ children }: { children: ReactNode }) {
  return <PublicAccessSessionClient serverActorId={await requestActor()}>{children}</PublicAccessSessionClient>;
}
