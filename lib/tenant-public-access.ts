export type TenantPublicAccess = Readonly<{
  state: "live" | "coming_soon";
  allowed: boolean;
}>;

export const PUBLIC_UNAVAILABLE_MESSAGE = "Dostępna wkrótce";

export function readTenantPublicAccess(value: unknown): TenantPublicAccess | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (Object.keys(row).sort().join(",") !== "allowed,state" ||
      (row.state !== "live" && row.state !== "coming_soon") ||
      typeof row.allowed !== "boolean") return null;
  return { state: row.state, allowed: row.allowed };
}

export function publicAccessError(error: unknown) {
  if (!error || typeof error !== "object" || !("code" in error)) return null;
  if (error.code === "PT423") return {
    code: "TENANT_PUBLIC_ACCESS_UNAVAILABLE", error: PUBLIC_UNAVAILABLE_MESSAGE, status: 423,
  };
  if (error.code === "PT409") return {
    code: "TENANT_PUBLIC_ACCESS_RETRY", error: "Dostępność obiektu jest aktualizowana. Spróbuj ponownie.", status: 409,
  };
  return null;
}

export async function fetchTenantPublicAccess(
  client: { rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> },
  slug: string,
): Promise<TenantPublicAccess | null> {
  try {
    const { data, error } = await client.rpc("get_public_tenant_access_v1", { p_slug: slug });
    return error ? null : readTenantPublicAccess(data);
  } catch { return null; }
}
