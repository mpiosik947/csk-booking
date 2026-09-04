export type AccountExportPayload = {
  export_version: 1;
  generated_at: string;
  account: Record<string, unknown>;
  profile: Record<string, unknown> | null;
  reservations: Array<Record<string, unknown>>;
  event_registrations: Array<Record<string, unknown>>;
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
