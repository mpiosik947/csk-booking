// Local-only disposable PostgreSQL helpers for the legal ownership acceptance gates.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";

export const container = "supabase_db_csk-booking";
export const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
export const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
export const children = new Set();
export function localDatabase(db) {
  assert.match(db, /^(?:sbr3|legal_window|legal_ownership)_[a-f0-9]{16}$/);
}
export function sql(db, query) {
  if (db !== "postgres") localDatabase(db);
  const result = spawnSync("docker", ["exec", "-i", container, "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "-U", "postgres", "-d", db], { input: query, encoding: "utf8", windowsHide: true, maxBuffer: 32e6 });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
export function session(db, label) {
  localDatabase(db);
  const name = label + "_" + randomBytes(4).toString("hex");
  const p = spawn("docker", ["exec", "-i", container, "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "-U", "postgres", "-d", db], { windowsHide: true });
  children.add(p);
  let out = "", err = "", pending;
  const state = { name, p, done: false, error: () => err };
  function complete() {
    if (!pending) return;
    const end = out.indexOf(pending.marker + "\n");
    if (end >= 0) {
      const result = out.slice(0, end); out = out.slice(end + pending.marker.length + 1);
      pending.resolve(result.trim()); pending = undefined;
    }
  }
  p.stdout.on("data", chunk => { out += chunk.toString().replaceAll("\r\n", "\n"); complete(); });
  p.stderr.on("data", chunk => err += chunk);
  state.exit = new Promise(resolve => p.on("exit", code => {
    state.done = true; children.delete(p);
    if (pending) { pending.reject(new Error(err || "psql exited " + code)); pending = undefined; }
    resolve(code);
  }));
  state.query = query => {
    assert.equal(state.done, false, err);
    assert.ok(!pending, "One query per session at a time");
    const marker = "END_" + randomBytes(10).toString("hex");
    return new Promise((resolve, reject) => {
      pending = { marker, resolve, reject };
      p.stdin.write(query + "\n\\echo " + marker + "\n");
    });
  };
  state.ready = state.query(`set application_name=${quote(name)}; set lock_timeout='1s'; set statement_timeout='5s';`);
  state.close = async () => { if (!state.done) p.stdin.end(); await state.exit; };
  return state;
}
export async function waitFor(check, label, milliseconds = 5000) {
  const deadline = Date.now() + milliseconds;
  while (!(await check())) { assert.ok(Date.now() < deadline, label); await pause(10); }
}
export function cleanup(db) {
  for (const p of children) p.kill();
  localDatabase(db);
  sql("postgres", `drop database if exists ${db} with (force);`);
  assert.equal(sql("postgres", `select count(*) from pg_database where datname=${quote(db)};`), "0");
}
