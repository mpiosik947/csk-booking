import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import {
  getLaneBlockErrorMessage,
  LANE_BLOCK_GENERIC_ERROR,
  validateLaneBlockRpcResult,
} from "./lane-block-management.ts";

const BLOCK_ID = "11111111-1111-4111-8111-111111111111";
const pagePath = path.resolve("app/admin/lane-blocks/page.tsx");

function functionSource(source, start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex + start.length);

  assert.notEqual(startIndex, -1, `Missing function start: ${start}`);
  assert.notEqual(endIndex, -1, `Missing function end: ${end}`);
  return source.slice(startIndex, endIndex);
}

async function runtimeSources(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const sources = [];

  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);

    if (entry.isDirectory()) {
      sources.push(...(await runtimeSources(entryPath)));
    } else if (/\.(?:js|jsx|ts|tsx)$/.test(entry.name)) {
      sources.push([entryPath, await readFile(entryPath, "utf8")]);
    }
  }

  return sources;
}

test("lane block RPC parser accepts only coherent known results", () => {
  for (const code of ["created", "activated", "deactivated"]) {
    assert.deepEqual(
      validateLaneBlockRpcResult({
        ok: true,
        changed: true,
        code,
        lane_block_id: BLOCK_ID,
      }),
      {
        ok: true,
        value: {
          ok: true,
          changed: true,
          code,
          lane_block_id: BLOCK_ID,
        },
      }
    );
  }

  assert.equal(
    validateLaneBlockRpcResult({
      ok: true,
      changed: false,
      code: "no_change",
      lane_block_id: BLOCK_ID,
    }).ok,
    true
  );

  for (const code of [
    "not_allowed",
    "invalid_input",
    "block_not_found",
    "invalid_lane",
    "inactive_lane",
    "conflict_reservation",
    "conflict_event",
    "invalid_hierarchy",
    "internal_error",
  ]) {
    assert.equal(
      validateLaneBlockRpcResult({
        ok: false,
        changed: false,
        code,
        lane_block_id: null,
      }).ok,
      true
    );
  }

  for (const value of [
    null,
    {},
    { ok: true, changed: true, code: "unknown", lane_block_id: BLOCK_ID },
    { ok: true, changed: false, code: "created", lane_block_id: BLOCK_ID },
    { ok: false, changed: false, code: "created", lane_block_id: BLOCK_ID },
    { ok: true, changed: false, code: "no_change", lane_block_id: null },
    { ok: true, changed: true, code: "internal_error", lane_block_id: null },
    { ok: true, changed: true, code: "created", lane_block_id: "invalid" },
  ]) {
    assert.deepEqual(validateLaneBlockRpcResult(value), { ok: false });
  }
});

test("controlled errors have safe Polish messages and unknown errors fail closed", () => {
  assert.equal(
    getLaneBlockErrorMessage("conflict_reservation"),
    "Nie można utworzyć blokady, ponieważ w tym czasie istnieje rezerwacja."
  );
  assert.equal(
    getLaneBlockErrorMessage("conflict_event"),
    "Nie można utworzyć blokady, ponieważ w tym czasie odbywa się szkolenie lub wydarzenie."
  );
  assert.equal(
    getLaneBlockErrorMessage("inactive_lane"),
    "Wybrana oś nie jest obecnie aktywna."
  );
  assert.equal(
    getLaneBlockErrorMessage("not_allowed"),
    "Nie masz uprawnień do wykonania tej operacji."
  );
  assert.equal(
    getLaneBlockErrorMessage("invalid_hierarchy"),
    "Nie można wykonać operacji z powodu nieprawidłowej konfiguracji osi."
  );
  assert.equal(getLaneBlockErrorMessage("internal_error"), LANE_BLOCK_GENERIC_ERROR);
  assert.equal(getLaneBlockErrorMessage("unknown"), LANE_BLOCK_GENERIC_ERROR);
});

test("lane block UI uses the create and toggle RPC contracts without a DML fallback", async () => {
  const source = await readFile(pagePath, "utf8");
  const createBlock = functionSource(
    source,
    "async function createBlock()",
    "async function toggleBlock("
  );
  const toggleBlock = functionSource(
    source,
    "async function toggleBlock(",
    "function getMessageClass("
  );

  assert.match(createBlock, /\.rpc\("admin_create_lane_block", \{/);
  assert.match(createBlock, /p_lane_id: laneId/);
  assert.match(createBlock, /p_block_date: blockDate/);
  assert.match(createBlock, /p_start_time: startTime/);
  assert.match(createBlock, /p_end_time: endTime/);
  assert.match(createBlock, /p_reason: reason/);
  assert.match(createBlock, /validateLaneBlockRpcResult\(data\)/);
  assert.match(createBlock, /result\.value\.code !== "created"/);
  assert.match(createBlock, /setLaneId\(""\)/);
  assert.match(createBlock, /setBlockDate\(""\)/);
  assert.match(createBlock, /setStartTime\(""\)/);
  assert.match(createBlock, /setEndTime\(""\)/);
  assert.match(createBlock, /setReason\(""\)/);
  assert.match(createBlock, /void loadData\(\)/);

  assert.match(toggleBlock, /\.rpc\(\s*"admin_set_lane_block_active"/);
  assert.match(toggleBlock, /p_block_id: blockId/);
  assert.match(toggleBlock, /p_is_active: targetStatus/);
  assert.match(toggleBlock, /validateLaneBlockRpcResult\(data\)/);
  assert.match(toggleBlock, /result\.value\.code !== "no_change"/);
  assert.match(toggleBlock, /void loadData\(\)/);

  assert.doesNotMatch(source, /admin_update_lane_block/);
  assert.doesNotMatch(source, /error\.message/);
  assert.doesNotMatch(source, /retry/i);
});

test("runtime contains no direct lane_blocks mutation", async () => {
  const sources = [
    ...(await runtimeSources(path.resolve("app"))),
    ...(await runtimeSources(path.resolve("lib"))),
  ];
  const directMutation = /\.from\(\s*["']lane_blocks["']\s*\)(?:(?!;)[\s\S])*?\.(?:insert|update|delete|upsert)\s*\(/g;
  const violations = sources.flatMap(([file, source]) => {
    directMutation.lastIndex = 0;
    return directMutation.test(source) ? [path.relative(process.cwd(), file)] : [];
  });

  assert.deepEqual(violations, []);
});
