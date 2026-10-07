import { readDetail, readPlans, type Detail, type Plan } from "./platform-wizard.ts";
import { candidateActions, expectedState, fallback, managementError, readAdmins, readCandidate, readEligibility, readLifecycle, readPlanPreview, type AdminAction, type Admins, type Candidate, type Eligibility, type Lifecycle, type PlanPreview } from "./platform-management.ts";

export type Rpc = (name: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;
export type Section<T> = { data: T | null; loading: boolean; error: string };
const section = <T>(data: T | null = null): Section<T> => ({ data, loading: true, error: "" });
export const adminRpc = { add: "platform_add_tenant_admin_v1", reactivate: "platform_reactivate_tenant_admin_v1", demote: "platform_demote_tenant_admin_v1", suspend: "platform_suspend_tenant_admin_v1" } as const;
export type Operation = "plan" | AdminAction | "archive" | "restore";
export const actionLabels: Record<Operation, string> = { plan: "Zmień plan", add: "Dodaj jako administratora", reactivate: "Reaktywuj administratora", demote: "Usuń uprawnienia administratora", suspend: "Zawieś administratora", archive: "Archiwizuj obiekt", restore: "Przywróć obiekt do konfiguracji" };
const success: Record<Operation, string> = { plan: "Plan obiektu został zmieniony.", add: "Administrator został dodany.", reactivate: "Administrator został reaktywowany.", demote: "Uprawnienia administratora zostały usunięte.", suspend: "Administrator został zawieszony.", archive: "Obiekt został zarchiwizowany.", restore: "Obiekt został przywrócony do stanu przygotowania." };
export type Attempt = { operation: Operation; rpc: string; payload: Record<string, unknown>; phase: "confirm" | "uncertain"; candidate?: Candidate; preview?: PlanPreview; lifecycle?: Lifecycle };
export type ManagementState = {
  detail: Section<Detail>; plans: Section<Plan[]>; admins: Section<Admins>; lifecycle: Section<Lifecycle>; eligibility: Section<Eligibility>;
  preview: Section<PlanPreview>; candidate: Section<Candidate>; target: string; email: string;
  busy: boolean; denied: boolean; message: string; attempt: Attempt | null;
};

/** Serializes user operations; readers within a canonical refresh run independently.
 * DB remains the authority. A denied response invalidates every section, including
 * other readers still in flight. A transport retry reuses the frozen attempt.
 */
export class ManagementSession {
  private listeners = new Set<() => void>();
  private generation = 0;
  private state: ManagementState;
  readonly id: string;
  private rpc: Rpc;
  private requestId: () => string;
  constructor(id: string, rpc: Rpc, initial: Detail | null, requestId: () => string = () => crypto.randomUUID()) {
    this.id = id; this.rpc = rpc; this.requestId = requestId;
    this.state = { detail: section(initial), plans: section(), admins: section(), lifecycle: section(), eligibility: section(), preview: { ...section<PlanPreview>(), loading: false }, candidate: { ...section<Candidate>(), loading: false }, target: "", email: "", busy: false, denied: false, message: "", attempt: null };
  }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  snapshot = () => this.state;
  private update(patch: Partial<ManagementState>) { this.state = { ...this.state, ...patch }; this.listeners.forEach(listener => listener()); }
  invalidate = () => { this.generation++; };
  deny = () => {
    this.generation++;
    this.update({ denied: true, busy: false, message: managementError({ code: "42501" }).message, attempt: null, detail: section(), plans: section(), admins: section(), lifecycle: section(), eligibility: section(), candidate: section(), preview: section(), email: "", target: "" });
  };
  private live(token: number) { return !this.state.denied && token === this.generation; }
  private async call(name: string, args: Record<string, unknown>) {
    try {
      const result = await this.rpc(name, args);
      if (result.error) throw result.error;
      return result.data;
    } catch (error) {
      if (managementError(error).kind === "denied") this.deny();
      throw error;
    }
  }
  private async read<T>(token: number, name: string, args: Record<string, unknown>, parse: (v: unknown) => T | null): Promise<Section<T>> {
    try {
      const data = parse(await this.call(name, args));
      return { data: this.live(token) ? data : null, loading: false, error: data ? "" : "Dane sekcji są niedostępne. Odśwież stan." };
    } catch { return { data: null, loading: false, error: "Dane sekcji są niedostępne. Odśwież stan." }; }
  }
  private async canonical(token: number) {
    const s = this.state;
    this.update({ detail: { ...s.detail, loading: true }, plans: section(), admins: section(), lifecycle: section(), eligibility: section(), preview: { ...section<PlanPreview>(), loading: false }, candidate: { ...section<Candidate>(), loading: false } });
    const args = { p_tenant_id: this.id };
    const [detail, plans, admins, lifecycle, eligibility] = await Promise.all([
      this.read(token, "platform_get_tenant_onboarding_detail_v1", args, v => readDetail(v, this.id)),
      this.read(token, "platform_list_active_plans_v1", {}, readPlans),
      this.read(token, "platform_get_tenant_admin_management_v1", args, v => readAdmins(v, this.id)),
      this.read(token, "platform_get_tenant_archive_preview_v1", args, v => readLifecycle(v, this.id)),
      this.read(token, "platform_get_tenant_delete_eligibility_v1", args, v => readEligibility(v, this.id)),
    ]);
    if (this.live(token)) this.update({ detail, plans, admins, lifecycle, eligibility });
  }
  async refresh() {
    if (this.state.busy || this.state.denied || this.state.attempt) return;
    const token = ++this.generation;
    this.update({ busy: true, message: "" });
    try { await this.canonical(token); } finally { if (this.live(token)) this.update({ busy: false }); }
  }
  private async preview(token: number, target: string) {
    this.update({ target, preview: section() });
    const preview = await this.read(token, "platform_get_tenant_plan_change_preview_v1", { p_tenant_id: this.id, p_target_plan_key: target }, v => readPlanPreview(v, this.id, target));
    if (this.live(token)) this.update({ preview });
  }
  async selectPlan(target: string) {
    if (this.locked || !this.state.plans.data?.some(p => p.plan_key === target)) return;
    const token = ++this.generation;
    this.update({ busy: true, message: "" });
    try { await this.preview(token, target); } finally { if (this.live(token)) this.update({ busy: false }); }
  }
  private async lookup(token: number, email: string, userId?: string) {
    this.update({ email, candidate: section() });
    const candidate = await this.read(token, "platform_lookup_tenant_admin_candidate_v1", { p_tenant_id: this.id, p_email: email }, v => {
      const c = readCandidate(v, email);
      return c && (!userId || c.user_id === userId) ? c : null;
    });
    if (this.live(token)) this.update({ candidate: { ...candidate, error: candidate.error ? "Nie znaleziono możliwego do wybrania konta lub odczyt się nie powiódł. Sprawdź dokładny e-mail i ponów wyszukiwanie." : "" } });
  }
  async findCandidate(email: string, userId?: string) {
    if (this.locked || !this.adminAvailable) return;
    const token = ++this.generation;
    this.update({ busy: true, message: "" });
    try { await this.lookup(token, email.trim(), userId); } finally { if (this.live(token)) this.update({ busy: false }); }
  }
  get locked() { return this.state.busy || this.state.denied || this.state.attempt !== null; }
  get adminAvailable() { return !!this.state.admins.data && this.state.admins.data.tenant.status !== "archived" && !this.state.admins.loading; }
  preparePlan() {
    const p = this.state.preview.data;
    if (this.locked || !this.state.plans.data || !p || !p.can_apply || p.blockers.length || p.tenant.status === "archived") return;
    this.update({ attempt: { operation: "plan", rpc: "platform_change_tenant_plan_v2", payload: { p_tenant_id: this.id, p_target_plan_key: p.target_plan.plan_key, p_expected_revision: p.revision }, phase: "confirm", preview: p }, message: "" });
  }
  prepareAdmin(operation: AdminAction) {
    const c = this.state.candidate.data;
    if (this.locked || !this.adminAvailable || !c || !candidateActions(c).includes(operation)) return;
    this.update({ attempt: { operation, rpc: adminRpc[operation], payload: { p_tenant_id: this.id, p_user_id: c.user_id, p_expected_state: expectedState(c) }, phase: "confirm", candidate: c }, message: "" });
  }
  prepareLifecycle(operation: "archive" | "restore") {
    const l = this.state.lifecycle.data;
    if (this.locked || !l || this.state.lifecycle.loading) return;
    if (operation === "archive" ? l.tenant.status === "archived" || !l.can_archive || l.blockers.length > 0 : l.tenant.status !== "archived") return;
    this.update({ attempt: { operation, rpc: operation === "archive" ? "platform_archive_tenant_v1" : "platform_restore_archived_tenant_v1", payload: { p_tenant_id: this.id, p_expected_revision: l.revision }, phase: "confirm", lifecycle: l }, message: "" });
  }
  cancel() { if (!this.state.busy && this.state.attempt?.phase === "confirm") this.update({ attempt: null }); }
  async confirm() {
    if (this.state.busy || this.state.denied || !this.state.attempt) return;
    const token = ++this.generation, original = this.state.attempt;
    const key = original.operation === "plan" ? "p_change_request_id" : "p_request_id";
    const attempt: Attempt = { ...original, payload: Object.freeze({ ...original.payload, [key]: original.payload[key] ?? this.requestId() }), phase: "uncertain" };
    this.update({ busy: true, attempt, message: "" });
    try {
      const result = await this.call(attempt.rpc, attempt.payload);
      if (!this.live(token)) return;
      // An unreadable acknowledgement is ambiguous, never an invitation to create a new request.
      if (!this.validReceipt(result, attempt)) throw new Error("Unconfirmed receipt");
      this.update({ attempt: null });
      await this.canonical(token);
      if (this.live(token)) this.update({ message: success[attempt.operation] });
    } catch (error) {
      if (!this.live(token)) return;
      const mapped = managementError(error);
      if (mapped.kind === "uncertain") {
        this.update({ message: "Nie udało się potwierdzić wyniku. Ponów tę samą próbę; identyfikator i dane pozostają zachowane." });
      } else {
        this.update({ attempt: null });
        await this.canonical(token);
        if (!this.live(token)) return;
        if (attempt.preview) await this.preview(token, attempt.preview.target_plan.plan_key);
        if (attempt.candidate) await this.lookup(token, attempt.candidate.email, attempt.candidate.user_id);
        if (this.live(token)) {
          const refreshed = mapped.kind === "plan-stale" ? this.state.preview.data : mapped.kind === "member-stale" ? this.state.candidate.data : mapped.kind === "lifecycle-stale" ? this.state.lifecycle.data : true;
          this.update({ message: refreshed ? mapped.message : fallback });
        }
      }
    } finally { if (this.live(token)) this.update({ busy: false }); }
  }
  private validReceipt(value: unknown, a: Attempt) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const r = value as Record<string, unknown>;
    if (a.operation === "plan") return ["changed", "no_change"].includes(String(r.code)) && r.plan_key === a.payload.p_target_plan_key && typeof r.revision === "string";
    if (a.operation === "archive" || a.operation === "restore") return r.tenant_id === this.id && r.status === (a.operation === "archive" ? "archived" : "dormant") && r.is_public === false && Number.isSafeInteger(r.revision);
    return ["changed", "no_change"].includes(String(r.code)) && r.user_id === a.payload.p_user_id && r.role === (a.operation === "demote" ? "user" : "admin") && r.status === (a.operation === "suspend" ? "suspended" : "active");
  }
}
