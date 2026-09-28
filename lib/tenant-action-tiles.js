import { getAdminRouteRoles } from './admin/route-protection.js';

/** Navigation visibility only. Destination routes retain their server/DB guards. */
export async function loadTenantActionTiles(client, slug) {
  if (typeof slug !== 'string' || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug) || slug.length > 63) return null;
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) return null;
  const customer = { clientHref: '/dashboard', staffHref: null };
  try {
    const resolved = await client.rpc('resolve_active_tenant_by_slug_v1', { p_slug: slug });
    const rows = resolved.data;
    if (resolved.error || !Array.isArray(rows) || rows.length !== 1) return customer;
    const tenant = rows[0];
    if (tenant.tenant_slug !== slug || tenant.tenant_status !== 'active' ||
      typeof tenant.tenant_id !== 'string' || !/^[0-9a-f-]{36}$/i.test(tenant.tenant_id)) return customer;
    const role = await client.rpc('get_my_tenant_role_v1', { p_tenant_id: tenant.tenant_id });
    const legacyRole = { admin: 'admin', employee: 'pracownik', instructor: 'instruktor' }[role.data];
    return !role.error && legacyRole && getAdminRouteRoles('/admin').includes(legacyRole)
      ? { ...customer, staffHref: `/t/${slug}/admin` } : customer;
  } catch { return customer; }
}
