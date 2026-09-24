import "server-only";

import { cache } from "react";
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
import {
  resolvePublicTenantContext,
  resolveAuthenticatedTenantContext,
  resolveStaffTenantContext,
  type TenantContextClient,
} from "./tenant-context";
import type { TenantFeatureKey } from "../tenant-features";

/** A fresh anon-key client for the current request; never a service-role client. */
export const getTenantRequestClient = cache(async (): Promise<TenantContextClient> => {
  const cookieStore = await cookies();
  const client = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) => {
              cookieStore.set(name, value, options);
            });
          } catch {
            // Server Components cannot always set cookies. Never grant on refresh failure.
          }
        },
      },
    },
  );
  return client as unknown as TenantContextClient;
});

export const getPublicRouteContext = cache(async (slug: string) =>
  resolvePublicTenantContext(await getTenantRequestClient(), slug));

export async function getUserRouteContext(slug: string) {
  return resolveAuthenticatedTenantContext(await getTenantRequestClient(), slug);
}

export async function getStaffRouteContext(
  slug: string,
  roles: readonly ("admin" | "employee" | "instructor")[],
) {
  return resolveStaffTenantContext(await getTenantRequestClient(), slug, roles);
}

/** Fail-closed feature checks. Public checks disclose only effective availability. */
export async function tenantRouteHasFeature(
  tenantId: string,
  feature: TenantFeatureKey,
  access: "public" | "member",
) {
  const client = await getTenantRequestClient();
  const rpc = access === "public"
    ? "get_public_tenant_feature_access_v1"
    : "get_my_tenant_feature_access_v1";
  try {
    const { data, error } = await client.rpc(rpc, {
      p_tenant_id: tenantId,
      p_feature_key: feature,
    });
    return !error && data === true;
  } catch {
    return false;
  }
}
