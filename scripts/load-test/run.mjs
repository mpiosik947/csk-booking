import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { spawnSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { getLocalLoadTestEnvironment } from "./local-safety.mjs";

const environment = getLocalLoadTestEnvironment();
const marker = "[LOADTEST]";
const runId = `${Date.now()}-${randomUUID().slice(0, 8)}`;
const password = `Local-Load-${randomUUID()}!Aa1`;
const activeStatuses = new Set(["confirmed"]);
const service = createClient(environment.supabaseUrl, environment.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function integerSetting(name, fallback, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}.`);
  }
  return value;
}

const config = {
  scenario: process.env.LOADTEST_SCENARIO ?? "all",
  users: integerSetting("LOADTEST_USERS", 500, 100, 500),
  concurrencyOverride: integerSetting("LOADTEST_CONCURRENCY", 0, 0, 500),
  operationsOverride: integerSetting("LOADTEST_OPERATIONS", 0, 0, 100000),
  durationSeconds: integerSetting("LOADTEST_DURATION_SECONDS", 0, 0, 86400),
  familyCount: integerSetting("LOADTEST_FAMILY_COUNT", 20, 1, 50),
  positionsPerFamily: integerSetting("LOADTEST_POSITIONS_PER_FAMILY", 5, 1, 20),
  requestTimeoutMs: integerSetting("LOADTEST_REQUEST_TIMEOUT_MS", 30000, 1000, 120000),
};

const allowedScenarios = new Set([
  "all",
  "baseline",
  "hundred",
  "race",
  "parallel",
  "ramp",
  "storm",
  "mixed",
]);
if (!allowedScenarios.has(config.scenario)) {
  throw new Error(`Unknown LOADTEST_SCENARIO: ${config.scenario}`);
}

const deadline = config.durationSeconds > 0
  ? performance.now() + config.durationSeconds * 1000
  : Number.POSITIVE_INFINITY;
const state = {
  users: [],
  resources: [],
  roots: [],
  metrics: [],
  integrity: [],
  rampStop: null,
};

function assertNoError(error, context) {
  if (error) throw new Error(`${context}: ${error.message}`);
}

async function mapConcurrent(values, concurrency, worker) {
  const results = new Array(values.length);
  let next = 0;
  async function runWorker() {
    while (true) {
      const index = next;
      next += 1;
      if (index >= values.length || performance.now() >= deadline) return;
      results[index] = await worker(values[index], index);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(concurrency, values.length) }, () => runWorker())
  );
  return results.filter((value) => value !== undefined);
}

async function fetchJson(url, options) {
  const started = performance.now();
  try {
    const response = await fetch(url, {
      ...options,
      signal: AbortSignal.timeout(config.requestTimeoutMs),
    });
    let body = null;
    try {
      body = await response.json();
    } catch {
      body = null;
    }
    return {
      durationMs: performance.now() - started,
      httpStatus: response.status,
      body,
      transportError: null,
    };
  } catch (error) {
    return {
      durationMs: performance.now() - started,
      httpStatus: 0,
      body: null,
      transportError: error instanceof Error ? error.name : "transport_error",
    };
  }
}

function percentile(sorted, ratio) {
  if (sorted.length === 0) return 0;
  const position = Math.min(sorted.length - 1, Math.ceil(sorted.length * ratio) - 1);
  return sorted[Math.max(0, position)];
}

function summarize(name, concurrency, results, wallMs) {
  const durations = results.map((result) => result.durationMs).sort((a, b) => a - b);
  const success = results.filter((result) => result.success).length;
  const expectedConflicts = results.filter((result) => result.expectedConflict).length;
  const unexpected = results.length - success - expectedConflicts;
  const serverErrors = results.filter((result) => result.httpStatus >= 500).length;
  const summary = {
    scenario: name,
    concurrency,
    operations: results.length,
    success,
    successRate: results.length ? success / results.length : 0,
    expectedConflicts,
    expectedConflictRate: results.length ? expectedConflicts / results.length : 0,
    unexpectedErrors: unexpected,
    unexpectedErrorRate: results.length ? unexpected / results.length : 0,
    serverErrors,
    avgMs: durations.length ? durations.reduce((sum, value) => sum + value, 0) / durations.length : 0,
    p50Ms: percentile(durations, 0.5),
    p95Ms: percentile(durations, 0.95),
    p99Ms: percentile(durations, 0.99),
    throughputRps: wallMs > 0 ? results.length / (wallMs / 1000) : 0,
    codes: Object.fromEntries(
      [...new Set(results.map((result) => result.code ?? result.transportError ?? "unknown"))]
        .sort()
        .map((code) => [code, results.filter((result) => (result.code ?? result.transportError ?? "unknown") === code).length])
    ),
  };
  state.metrics.push(summary);
  console.log(`METRIC ${JSON.stringify(summary)}`);
  return summary;
}

async function execute(name, tasks, concurrency, handler) {
  const started = performance.now();
  const results = await mapConcurrent(tasks, concurrency, handler);
  return summarize(name, concurrency, results, performance.now() - started);
}

function formatDate(dayOffset) {
  const date = new Date();
  date.setUTCHours(12, 0, 0, 0);
  date.setUTCDate(date.getUTCDate() + dayOffset);
  return date.toISOString().slice(0, 10);
}

function createTasks(count, dayOffset, note, users = state.users, resources = state.resources) {
  return Array.from({ length: count }, (_, index) => ({
    user: users[index % users.length],
    laneId: resources[index % resources.length].id,
    reservationDate: formatDate(dayOffset + Math.floor(index / 12)),
    startTime: `${String(8 + (index % 12)).padStart(2, "0")}:00`,
    durationMinutes: 60,
    shootersCount: 1,
    creationRequestId: randomUUID(),
    reservationNote: `${marker} ${note}`,
  }));
}

async function createReservation(task, expectedConflictCodes = new Set()) {
  const response = await fetchJson(`${environment.appUrl}/api/create-reservation`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${task.user.accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      laneId: task.laneId,
      reservationDate: task.reservationDate,
      startTime: task.startTime,
      durationMinutes: task.durationMinutes,
      shootersCount: task.shootersCount,
      creationRequestId: task.creationRequestId,
      reservationNote: task.reservationNote,
    }),
  });
  const code = response.body?.code;
  return {
    ...response,
    code,
    success: response.httpStatus === 200 && (code === "created" || code === "already_created"),
    expectedConflict: response.httpStatus === 409 && expectedConflictCodes.has(code),
    reservationId: response.body?.reservationId ?? null,
  };
}

async function createReservationRpc(task, expectedConflictCodes = new Set()) {
  const response = await fetchJson(`${environment.supabaseUrl}/rest/v1/rpc/create_reservation_v2`, {
    method: "POST",
    headers: {
      apikey: environment.anonKey,
      authorization: `Bearer ${task.user.accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      p_lane_id: task.laneId,
      p_reservation_date: task.reservationDate,
      p_start_time: task.startTime,
      p_duration_minutes: task.durationMinutes,
      p_shooters_count: task.shootersCount,
      p_creation_request_id: task.creationRequestId,
      p_reservation_note: task.reservationNote,
    }),
  });
  const code = response.body?.code;
  return {
    ...response,
    code,
    success: response.httpStatus === 200 && (code === "created" || code === "already_created"),
    expectedConflict: response.httpStatus === 200 && expectedConflictCodes.has(code),
    reservationId: response.body?.reservation_id ?? null,
  };
}

async function availability(task) {
  const response = await fetchJson(
    `${environment.supabaseUrl}/rest/v1/rpc/get_lane_booking_busy_ranges_v3`,
    {
      method: "POST",
      headers: {
        apikey: environment.anonKey,
        authorization: `Bearer ${task.user.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        p_lane_id: task.laneId,
        p_reservation_date: task.reservationDate,
      }),
    }
  );
  return {
    ...response,
    code: response.httpStatus === 200 && Array.isArray(response.body) ? "availability_ok" : "availability_error",
    success: response.httpStatus === 200 && Array.isArray(response.body),
    expectedConflict: false,
  };
}

async function cancelReservation(task) {
  const response = await fetchJson(`${environment.supabaseUrl}/rest/v1/rpc/cancel_reservation`, {
    method: "POST",
    headers: {
      apikey: environment.anonKey,
      authorization: `Bearer ${task.user.accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ p_reservation_id: task.reservationId }),
  });
  return {
    ...response,
    code: response.body?.changed === true ? "cancelled" : response.body?.code ?? "cancel_error",
    success: response.httpStatus === 200 && response.body?.changed === true,
    expectedConflict: false,
  };
}

async function createLocalAccount(index, role) {
  const email = `loadtest-${runId}-${role}-${String(index).padStart(4, "0")}@example.invalid`;
  const { data, error } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { test_marker: marker, loadtest_run: runId },
  });
  assertNoError(error, `create ${role} account ${index}`);
  if (!data.user) throw new Error(`Missing ${role} account ${index}.`);
  return { id: data.user.id, email, role, accessToken: "" };
}

async function signIn(account) {
  const response = await fetchJson(`${environment.supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: environment.anonKey, "content-type": "application/json" },
    body: JSON.stringify({ email: account.email, password }),
  });
  if (response.httpStatus !== 200 || typeof response.body?.access_token !== "string") {
    throw new Error(`Local sign-in failed for synthetic account ${account.id}.`);
  }
  account.accessToken = response.body.access_token;
  return account;
}

function resourcePayload(name, maxPeople, price, active, online) {
  return {
    name,
    is_active: active,
    online_bookable: online,
    max_shooters: maxPeople,
    max_people_online: maxPeople,
    booking_step_minutes: 60,
    durations_minutes: [60],
    pricing: [
      { day_group: "mon_thu", min_shooters: 1, max_shooters: maxPeople, label: `1–${maxPeople}`, hourly_price: price },
      { day_group: "fri_sun", min_shooters: 1, max_shooters: maxPeople, label: `1–${maxPeople}`, hourly_price: price + 2 },
    ],
  };
}

async function setupFixtures() {
  const [laneCheck, userCheck] = await Promise.all([
    service.from("shooting_lanes").select("id", { count: "exact", head: true }).like("name", `${marker}%`),
    service.auth.admin.listUsers({ page: 1, perPage: 1000 }),
  ]);
  assertNoError(laneCheck.error, "load-test lane preflight");
  assertNoError(userCheck.error, "load-test user preflight");
  if ((laneCheck.count ?? 0) !== 0 || userCheck.data.users.some((user) => user.user_metadata?.test_marker === marker)) {
    throw new Error("Prior [LOADTEST] fixtures exist. Run local db reset before retrying.");
  }

  console.log(`SETUP creating ${config.users} users and one local admin`);
  const admin = await createLocalAccount(0, "admin");
  const users = await mapConcurrent(
    Array.from({ length: config.users }, (_, index) => index + 1),
    20,
    (index) => createLocalAccount(index, "user")
  );
  const profiles = [admin, ...users].map((account) => ({
    user_id: account.id,
    role: account.role,
    first_name: marker,
    last_name: account.role === "admin" ? "Administrator" : "Użytkownik",
    full_name: `${marker} ${account.role === "admin" ? "Administrator" : "Użytkownik"}`,
    email: account.email,
    phone: "000000000",
    verification_status: "verified",
  }));
  for (let index = 0; index < profiles.length; index += 100) {
    const { error } = await service.from("profiles").upsert(profiles.slice(index, index + 100), { onConflict: "user_id" });
    assertNoError(error, "upsert load-test profiles");
  }
  await signIn(admin);
  state.users = await mapConcurrent(users, 25, signIn);

  const adminClient = createClient(environment.supabaseUrl, environment.anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${admin.accessToken}` } },
  });
  for (let familyIndex = 1; familyIndex <= config.familyCount; familyIndex += 1) {
    const familyLabel = String(familyIndex).padStart(2, "0");
    const positions = Array.from({ length: config.positionsPerFamily }, (_, positionIndex) =>
      resourcePayload(`${marker} F${familyLabel} stanowisko ${positionIndex + 1}`, 1, 10, true, true)
    );
    const payload = {
      root: {
        ...resourcePayload(`${marker} Rodzina ${familyLabel}`, config.positionsPerFamily, 10, true, false),
        whole_lane_bookable: false,
        positions_bookable: true,
      },
      positions,
    };
    const { data, error } = await adminClient.rpc("admin_create_lane_booking_family_v1", { p_family: payload });
    assertNoError(error, `create load-test family ${familyLabel}`);
    if (!data?.ok || data.code !== "created" || data.created_resource_count !== positions.length + 1) {
      throw new Error(`Family ${familyLabel} was not created atomically.`);
    }
  }

  const { data: resources, error: resourcesError } = await service
    .from("shooting_lanes")
    .select("id,name,resource_kind,parent_lane_id,is_active,whole_lane_bookable,positions_bookable")
    .like("name", `${marker}%`)
    .order("name");
  assertNoError(resourcesError, "read load-test resources");
  state.roots = (resources ?? []).filter((resource) => resource.resource_kind === "lane");
  state.resources = (resources ?? []).filter((resource) => resource.resource_kind === "position");
  if (state.roots.length !== config.familyCount || state.resources.length !== config.familyCount * config.positionsPerFamily) {
    throw new Error("Load-test hierarchy has an unexpected resource count.");
  }
  console.log(`SETUP complete users=${state.users.length} roots=${state.roots.length} positions=${state.resources.length}`);
}

async function fetchAll(table, select, filter) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    let query = service.from(table).select(select).range(from, from + 999);
    query = filter(query);
    const { data, error } = await query;
    assertNoError(error, `read ${table} integrity data`);
    rows.push(...(data ?? []));
    if ((data ?? []).length < 1000) return rows;
  }
}

function timesOverlap(a, b) {
  return a.start_time < b.end_time && b.start_time < a.end_time;
}

async function checkIntegrity(label) {
  const reservations = await fetchAll(
    "reservations",
    "id,user_id,lane_id,reservation_date,start_time,end_time,reservation_status,creation_request_id,reservation_note",
    (query) => query.like("reservation_note", `${marker}%`).order("id")
  );
  const resourceById = new Map([...state.roots, ...state.resources].map((resource) => [resource.id, resource]));
  const userIds = new Set(state.users.map((user) => user.id));
  const requestKeys = new Set();
  let duplicateRequestKeys = 0;
  let orphanReservations = 0;
  let invalidStatuses = 0;
  for (const reservation of reservations) {
    const requestKey = `${reservation.user_id}:${reservation.creation_request_id}`;
    if (requestKeys.has(requestKey)) duplicateRequestKeys += 1;
    requestKeys.add(requestKey);
    if (!resourceById.has(reservation.lane_id) || !userIds.has(reservation.user_id)) orphanReservations += 1;
    if (!["confirmed", "cancelled", "canceled", "cancelled_by_user", "cancelled_by_admin", "completed", "no_show"].includes(reservation.reservation_status)) invalidStatuses += 1;
  }

  const active = reservations.filter((reservation) => activeStatuses.has(reservation.reservation_status));
  let forbiddenOverlaps = 0;
  for (let left = 0; left < active.length; left += 1) {
    const a = active[left];
    const resourceA = resourceById.get(a.lane_id);
    const rootA = resourceA?.resource_kind === "lane" ? resourceA.id : resourceA?.parent_lane_id;
    for (let right = left + 1; right < active.length; right += 1) {
      const b = active[right];
      if (a.reservation_date !== b.reservation_date) continue;
      const resourceB = resourceById.get(b.lane_id);
      const rootB = resourceB?.resource_kind === "lane" ? resourceB.id : resourceB?.parent_lane_id;
      if (rootA !== rootB || !timesOverlap(a, b)) continue;
      if (a.lane_id === b.lane_id || resourceA?.resource_kind === "lane" || resourceB?.resource_kind === "lane") {
        forbiddenOverlaps += 1;
      }
    }
  }

  const brokenChildren = state.resources.filter((resource) => !state.roots.some((root) => root.id === resource.parent_lane_id)).length;
  const integrity = {
    label,
    reservations: reservations.length,
    duplicateRequestKeys,
    orphanReservations,
    invalidStatuses,
    forbiddenOverlaps,
    brokenChildren,
  };
  state.integrity.push(integrity);
  console.log(`INTEGRITY ${JSON.stringify(integrity)}`);
  if (duplicateRequestKeys || orphanReservations || invalidStatuses || forbiddenOverlaps || brokenChildren) {
    throw new Error(`CRITICAL integrity violation after ${label}.`);
  }
  return integrity;
}

async function countScenarioRows(note) {
  const { count, error } = await service
    .from("reservations")
    .select("id", { count: "exact", head: true })
    .eq("reservation_note", `${marker} ${note}`);
  assertNoError(error, `count ${note}`);
  return count ?? 0;
}

function concurrency(value) {
  return config.concurrencyOverride || value;
}

function operations(value) {
  return config.scenario === "all" || !config.operationsOverride ? value : config.operationsOverride;
}

async function runCreateScenario(
  name,
  count,
  defaultConcurrency,
  dayOffset,
  strict = true,
  handler = createReservation
) {
  const operationCount = operations(count);
  const summary = await execute(
    name,
    createTasks(operationCount, dayOffset, name),
    concurrency(defaultConcurrency),
    (task) => handler(task)
  );
  if (strict && (summary.success !== operationCount || summary.unexpectedErrors !== 0)) {
    throw new Error(`${name} expected ${operationCount} successful reservations.`);
  }
  if (await countScenarioRows(name) !== summary.success) {
    throw new Error(`${name} database row count does not match successful requests.`);
  }
  await checkIntegrity(name);
  return summary;
}

async function runRace() {
  const count = operations(100);
  const resource = state.resources[0];
  const tasks = Array.from({ length: count }, (_, index) => ({
    ...createTasks(1, 300, "race", [state.users[index % state.users.length]], [resource])[0],
    reservationDate: formatDate(300),
    startTime: "10:00",
  }));
  const summary = await execute(
    "race_same_slot",
    tasks,
    concurrency(100),
    (task) => createReservation(task, new Set(["slot_unavailable"]))
  );
  if (summary.success !== 1 || summary.expectedConflicts !== count - 1 || summary.unexpectedErrors !== 0) {
    throw new Error("Race scenario did not produce exactly one winner.");
  }
  if (await countScenarioRows("race") !== 1) throw new Error("Race created an unexpected row count.");
  await checkIntegrity("race_same_slot");
}

async function runRamp() {
  const levels = [10, 25, 50, 100, 200, 300, 500].filter((level) => level <= state.users.length);
  for (let index = 0; index < levels.length; index += 1) {
    const level = levels[index];
    const summary = await runCreateScenario(
      `ramp_${level}`,
      level,
      level,
      500 + index * 60,
      false
    );
    if (summary.serverErrors > 0 || summary.unexpectedErrorRate >= 0.02 || summary.p95Ms >= 10000) {
      state.rampStop = {
        level,
        serverErrors: summary.serverErrors,
        unexpectedErrorRate: summary.unexpectedErrorRate,
        p95Ms: summary.p95Ms,
        codes: summary.codes,
      };
      console.log(`RAMP_STOP level=${level}`);
      break;
    }
  }
}

async function runStorm() {
  const count = operations(500);
  const slots = state.resources.slice(0, 5).map((resource, index) => ({
    resource,
    date: formatDate(900),
    startTime: `${String(10 + index).padStart(2, "0")}:00`,
  }));
  const tasks = Array.from({ length: count }, (_, index) => ({
    user: state.users[index % state.users.length],
    laneId: slots[index % slots.length].resource.id,
    reservationDate: slots[index % slots.length].date,
    startTime: slots[index % slots.length].startTime,
    durationMinutes: 60,
    shootersCount: 1,
    creationRequestId: randomUUID(),
    reservationNote: `${marker} storm`,
  }));
  const summary = await execute(
    "conflict_storm",
    tasks,
    concurrency(500),
    (task) => createReservationRpc(task, new Set(["slot_unavailable"]))
  );
  if (summary.success !== slots.length || summary.expectedConflicts !== count - slots.length || summary.unexpectedErrors !== 0) {
    console.log("STORM_WARNING unexpected transport or business result count");
  }
  if (summary.success > slots.length || await countScenarioRows("storm") !== summary.success) {
    throw new Error("CRITICAL storm database count is invalid.");
  }
  await checkIntegrity("conflict_storm");
}

function deterministicShuffle(values) {
  const copy = [...values];
  let seed = 0x6c534b;
  for (let index = copy.length - 1; index > 0; index -= 1) {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    const swap = seed % (index + 1);
    [copy[index], copy[swap]] = [copy[swap], copy[index]];
  }
  return copy;
}

async function runMixed() {
  const prepTasks = createTasks(100, 940, "mixed-prep");
  const prepResults = await mapConcurrent(prepTasks, 50, (task) => createReservation(task));
  if (prepResults.some((result) => !result.success || !result.reservationId)) {
    throw new Error("Mixed-workload cancellation fixtures failed.");
  }
  const readTasks = createTasks(600, 950, "mixed-read").map((task) => ({ type: "read", ...task }));
  const createWork = createTasks(300, 1050, "mixed-create").map((task) => ({ type: "create", ...task }));
  const cancelTasks = prepResults.map((result, index) => ({
    type: "cancel",
    user: prepTasks[index].user,
    reservationId: result.reservationId,
  }));
  const tasks = deterministicShuffle([...readTasks, ...createWork, ...cancelTasks]);
  const summary = await execute("mixed_60_30_10", tasks, concurrency(100), (task) => {
    if (task.type === "read") return availability(task);
    if (task.type === "cancel") return cancelReservation(task);
    return createReservation(task);
  });
  if (summary.success !== tasks.length || summary.unexpectedErrors !== 0) {
    throw new Error("Mixed workload returned unexpected failures.");
  }
  await checkIntegrity("mixed_60_30_10");
}

function readDeadlocks() {
  const executable = process.env.LOADTEST_PSQL_PATH ?? "C:\\Program Files\\PostgreSQL\\18\\bin\\psql.exe";
  if (!fs.existsSync(executable)) return null;
  const result = spawnSync(
    executable,
    ["-h", "127.0.0.1", "-p", "54322", "-U", "postgres", "-d", "postgres", "-X", "-Atc", "select deadlocks from pg_catalog.pg_stat_database where datname=current_database();"],
    { encoding: "utf8", env: { ...process.env, PGPASSWORD: "postgres" } }
  );
  if (result.status !== 0) return null;
  const value = Number(result.stdout.trim());
  return Number.isInteger(value) ? value : null;
}

function writeReport(report) {
  const resultsDirectory = path.resolve("scripts/load-test/results");
  fs.mkdirSync(resultsDirectory, { recursive: true });
  fs.writeFileSync(path.join(resultsDirectory, "latest.json"), `${JSON.stringify(report, null, 2)}\n`, "utf8");
}

async function healthAndRecovery() {
  const checks = await Promise.all([
    fetch(`${environment.appUrl}/login`).then((response) => response.status),
    fetch(`${environment.supabaseUrl}/auth/v1/health`).then((response) => response.status),
    fetch("http://127.0.0.1:54323").then((response) => response.status),
  ]);
  const task = createTasks(1, 1200, "recovery")[0];
  const recovery = await createReservation(task);
  const result = {
    appStatus: checks[0],
    authStatus: checks[1],
    studioStatus: checks[2],
    ordinaryReservation: recovery.code,
    ordinaryReservationHttp: recovery.httpStatus,
  };
  console.log(`RECOVERY ${JSON.stringify(result)}`);
  if (checks.some((status) => status !== 200) || !recovery.success) {
    throw new Error("Services did not recover after the load test.");
  }
  await checkIntegrity("post_stress_recovery");
  return result;
}

async function main() {
  console.log(`SAFETY supabase=${environment.supabaseUrl} target=${environment.appUrl} remote_blocked=true`);
  const appHealth = await fetch(`${environment.appUrl}/login`);
  if (!appHealth.ok) throw new Error(`Local Next.js is not ready (${appHealth.status}).`);
  const deadlocksBefore = readDeadlocks();
  await setupFixtures();

  const selected = (name) => config.scenario === "all" || config.scenario === name;
  if (selected("baseline")) await runCreateScenario("baseline", 100, 10, 30);
  if (selected("hundred")) await runCreateScenario("users_100", 500, 100, 150);
  if (selected("race")) await runRace();
  if (selected("parallel")) {
    await runCreateScenario(
      "parallel_resources_rpc",
      1000,
      100,
      330,
      false,
      createReservationRpc
    );
  }
  if (selected("ramp")) await runRamp();
  if (selected("storm")) await runStorm();
  if (selected("mixed")) await runMixed();
  const recovery = await healthAndRecovery();
  const deadlocksAfter = readDeadlocks();

  const report = {
    runId,
    safety: { supabaseUrl: environment.supabaseUrl, appUrl: environment.appUrl, remoteBlocked: true },
    config,
    environment: { cpus: os.cpus().length, totalMemoryBytes: os.totalmem(), freeMemoryBytesAfter: os.freemem() },
    fixtures: { users: state.users.length, roots: state.roots.length, positions: state.resources.length },
    deadlocksBefore,
    deadlocksAfter,
    deadlocksDuringRun: deadlocksBefore === null || deadlocksAfter === null ? null : deadlocksAfter - deadlocksBefore,
    metrics: state.metrics,
    integrity: state.integrity,
    rampStop: state.rampStop,
    recovery,
  };
  writeReport(report);
  console.log(`LOADTEST_COMPLETE ${JSON.stringify({ runId, scenarios: state.metrics.length, deadlocksDuringRun: report.deadlocksDuringRun })}`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : "unknown error";
  writeReport({
    runId,
    status: "failed",
    error: message,
    safety: { supabaseUrl: environment.supabaseUrl, appUrl: environment.appUrl, remoteBlocked: true },
    config,
    metrics: state.metrics,
    integrity: state.integrity,
    rampStop: state.rampStop,
    deadlocksAfter: readDeadlocks(),
  });
  console.error(`LOADTEST_FAILED ${message}`);
  process.exitCode = 1;
});
