import "server-only";

/** Canonical server-only entry point. Browser code must never import this module. */
export {
  isCanonicalTenantSlug,
  tenantSlugFromPath,
  resolvePublicTenantContext,
  resolveAuthenticatedTenantContext,
  resolveStaffTenantContext,
  resourceBelongsToTenant,
} from "./tenant-context-core.ts";

export type {
  TenantContext,
  AuthenticatedTenantContext,
  StaffTenantContext,
  TenantContextClient,
  ContextResult,
} from "./tenant-context-core.ts";
