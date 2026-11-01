import { uuid } from "./platform-wizard.ts";

export type ReadinessCheck = { key: string; label: string; severity: "BLOCKER" | "WARNING"; result: "PASS" | "FAIL"; explanation: string };
export type Readiness = { tenantId: string; revision: string | null; validatedRevision: string | null; validatedAt: string | null; validatedBy: string | null; current: boolean; stale: boolean; state: "NOT_READY" | "READY" | "VALIDATED"; overall: "PASS" | "FAIL"; checks: ReadinessCheck[] };
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const revision = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);

export function readReadiness(value: unknown, tenantId: string): Readiness | null {
  if (!object(value) || !uuid(tenantId) || value.tenant_id !== tenantId || value.validation_version !== 1 || !["NOT_READY", "READY", "VALIDATED"].includes(String(value.state)) || !["PASS", "FAIL"].includes(String(value.overall)) || typeof value.validation_current !== "boolean" || typeof value.stale !== "boolean") return null;
  if (value.current_revision !== null && !revision(value.current_revision)) return null;
  if (value.last_validated_revision !== null && !revision(value.last_validated_revision)) return null;
  if (value.validated_by !== null && !uuid(value.validated_by)) return null;
  if (value.validated_at !== null && (typeof value.validated_at !== "string" || !Number.isFinite(Date.parse(value.validated_at)))) return null;
  if ((value.last_validated_revision === null) !== (value.validated_at === null)) return null;
  if (!Array.isArray(value.checks) || !value.checks.length) return null;
  const checks: ReadinessCheck[] = [];
  for (const c of value.checks) {
    if (!object(c) || typeof c.key !== "string" || !/^[a-z_]+$/.test(c.key) || typeof c.label !== "string" || typeof c.explanation !== "string" || !["BLOCKER", "WARNING"].includes(String(c.severity)) || !["PASS", "FAIL"].includes(String(c.result)) || checks.some(row => row.key === c.key)) return null;
    checks.push({ key: c.key, label: c.label, explanation: c.explanation, severity: c.severity as ReadinessCheck["severity"], result: c.result as ReadinessCheck["result"] });
  }
  const passed = value.current_revision !== null && !checks.some(c => c.severity === "BLOCKER" && c.result === "FAIL");
  const current = passed && value.current_revision === value.last_validated_revision && value.validated_at !== null;
  if (value.overall !== (passed ? "PASS" : "FAIL") || value.validation_current !== current || value.state !== (current ? "VALIDATED" : passed ? "READY" : "NOT_READY") || value.stale !== (value.last_validated_revision !== null && !current)) return null;
  return { tenantId, revision: value.current_revision as string | null, validatedRevision: value.last_validated_revision as string | null, validatedAt: value.validated_at as string | null, validatedBy: value.validated_by as string | null, current, stale: value.stale, state: value.state as Readiness["state"], overall: value.overall as Readiness["overall"], checks };
}

export function readinessNotice(r: Readiness): string {
  return r.current ? "Konfiguracja zweryfikowana" : r.stale ? "Konfiguracja zmieniła się od ostatniej weryfikacji" : r.state === "READY" ? "Konfiguracja spełnia wymagania — uruchom weryfikację" : "Konfiguracja wymaga uzupełnienia";
}
