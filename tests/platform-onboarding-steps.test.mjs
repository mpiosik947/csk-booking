import test from "node:test";
import assert from "node:assert/strict";
import { checkStatus, checkStep, draftStatus, resumeStep, stepStatus, wizardSteps } from "../lib/platform-onboarding-steps.ts";

const check = (key, result = "PASS", severity = "BLOCKER") => ({ key, result, severity });
const state = (checks, extra = {}) => ({ state: "NOT_READY", current: false, checks, ...extra });

test("seven positions use server checks; unknown and optional warnings cannot authorize handover", () => {
  assert.equal(wizardSteps.length, 7);
  assert.equal(checkStatus([]), "Brak wyniku");
  assert.equal(checkStatus([check("hours", "FAIL", "WARNING")]), "⚠ Wskazówka");
  assert.equal(checkStatus([check("booking","FAIL"),check("hours","FAIL","WARNING")]), "✕ Do poprawy");
  assert.equal(checkStep("unexpected_check"), 6);
  assert.equal(stepStatus(1, state([check("resources")]), 0), "Brak osi");
  assert.equal(draftStatus(false,state([], {state:"READY"})), "Gotowy do sprawdzenia");
  assert.equal(draftStatus(true,state([], {current:true})), "Zarchiwizowany");
});

test("resume prefers an unfinished remembered section, then a server blocker or the validated summary", () => {
  const r = state([check("identity"),check("plan","FAIL"),check("hours","FAIL","WARNING")]);
  assert.equal(resumeStep("3",r,1),3);
  assert.equal(resumeStep("0",r,1),5);
  assert.equal(resumeStep("99",r,1),5);
  assert.equal(resumeStep(null,state([check("booking","FAIL")]),0),1);
  assert.equal(resumeStep(null,state([], {current:true}),0),6);
  assert.equal(resumeStep(null,null,0),0);
});
