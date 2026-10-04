export type DormantTenant = {
  tenant_id: string; tenant_slug: string; display_name: string;
  city: string | null; tenant_status: "dormant";
};

export function isDormantTenant(value: unknown): value is DormantTenant {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Partial<DormantTenant>;
  return typeof row.tenant_id === "string" && /^[0-9a-f-]{36}$/i.test(row.tenant_id) &&
    typeof row.tenant_slug === "string" && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(row.tenant_slug) &&
    typeof row.display_name === "string" && (row.city === null || typeof row.city === "string") &&
    row.tenant_status === "dormant";
}
