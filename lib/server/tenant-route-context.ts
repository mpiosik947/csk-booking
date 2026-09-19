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
