type AccountExportBase = {
  generated_at: string;
  account: Record<string, unknown>;
  profile: Record<string, unknown> | null;
  reservations: Array<Record<string, unknown>>;
  event_registrations: Array<Record<string, unknown>>;
};

export type AccountExportV1Payload = AccountExportBase & {
  export_version: 1;
};

export type AccountExportTenantRelationship = {
  tenant: {
    id: string;
    name: string;
    slug: string;
  };
  membership: {
    role: "admin" | "employee" | "user" | "instructor";
    status: "active" | "pending" | "suspended";
    created_at: string;
    updated_at: string;
  };
  verification: null | {
    status: "pending" | "verified" | "rejected";
    permissions_verified: boolean;
    permissions_verified_at: string | null;
    updated_at: string;
  };
};

export type AccountExportV2Payload = AccountExportBase & {
  export_version: 2;
  tenant_relationships: AccountExportTenantRelationship[];
};

export type AccountExportPayload =
  | AccountExportV1Payload
  | AccountExportV2Payload
  | AccountExportV3Payload;

export type AccountExportV3Payload = AccountExportBase & {
  export_version: 3;
  tenant_relationships: AccountExportTenantRelationship[];
  event_instructors: Array<Record<string, unknown>>;
  email_deliveries: Array<Record<string, unknown>>;
  reminder_schedules: Array<Record<string, unknown>>;
  reminder_occurrences: Array<Record<string, unknown>>;
  platform_admin: { status: "active" | "suspended"; created_at: string } | null;
  platform_audit_history: Array<Record<string, unknown>>;
  audit_history: Array<Record<string, unknown>>;
  external_settlements: Array<Record<string, unknown>>;
  tenant_domain_requests: Array<Record<string, unknown>>;
};

export function isAccountExportPayload(
  value: unknown
): value is AccountExportPayload;

type SupabaseOperation<T> = PromiseLike<{ data: T; error: unknown }>;

export type AccountDeletionResult =
  | {
      ok: true;
      code: "deleted";
      status: 200;
      alreadyAnonymized: boolean;
    }
  | {
      ok: false;
      code: "internal_error";
      status: 500;
    }
  | {
      ok: false;
      code: "auth_deletion_pending";
      status: 503;
    };

export function executeAccountDeletion(options: {
  anonymizeBusinessData: () => SupabaseOperation<unknown>;
  deleteAuthUser: () => Promise<{ data?: unknown; error: unknown }>;
}): Promise<AccountDeletionResult>;
