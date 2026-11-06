import type { Readiness, ReadinessCheck } from "./platform-draft-readiness.ts";

export const wizardSteps = [
  "Podstawowe dane", "Osie i stanowiska", "Rezerwacje i dostępność", "Godziny i zasady",
  "Strona i wygląd", "Funkcje obiektu", "Podsumowanie",
] as const;

export const summaryGroups = [
  { title: "Podstawowe dane", step: 0, keys: ["identity", "contact"] },
  { title: "Osie i stanowiska", step: 1, keys: ["resources", "references"] },
  { title: "Rezerwacje", step: 2, keys: ["booking", "prices", "durations"] },
  { title: "Godziny", step: 3, keys: ["hours"] },
  { title: "Strona publiczna", step: 4, keys: ["branding", "content", "partners"] },
  { title: "Funkcje obiektu", step: 5, keys: [] },
  { title: "Pakiet", step: 5, keys: ["plan"] },
  { title: "Administrator", step: 6, keys: ["membership"] },
];

export function checkStep(key: string) {
  return summaryGroups.find(group => group.keys.includes(key))?.step ?? 6;
}

export function checkStatus(checks: ReadinessCheck[]) {
  if (!checks.length) return "Brak wyniku";
  if (checks.some(c => c.result === "FAIL" && c.severity === "BLOCKER")) return "✕ Do poprawy";
  if (checks.some(c => c.result === "FAIL")) return "⚠ Wskazówka";
  return "✓ Spełnione";
}

export function stepStatus(step: number, readiness: Readiness | null, laneCount: number) {
  if (step === 6) return readiness?.current ? "✓ Sprawdzono" : "Do sprawdzenia";
  if (step === 1 && !laneCount) return "Brak osi";
  return checkStatus(readiness?.checks.filter(c => checkStep(c.key) === step) ?? []);
}

export function resumeStep(last: string | null, readiness: Readiness | null, laneCount: number) {
  if (last !== null && /^[0-6]$/.test(last) && (last === "6" || stepStatus(Number(last), readiness, laneCount) !== "✓ Spełnione")) return Number(last);
  if (!readiness) return 0;
  if (readiness.current || readiness.state === "READY") return 6;
  const first = readiness.checks.find(c => c.result === "FAIL" && c.severity === "BLOCKER");
  if (first?.key === "booking" && !laneCount) return 1;
  return first ? checkStep(first.key) : 0;
}

export function draftStatus(archived: boolean, readiness: Readiness | null) {
  if (archived) return "Zarchiwizowany";
  if (!readiness) return "Szkic";
  if (readiness.current) return "Gotowy do przekazania";
  return readiness.state === "READY" ? "Gotowy do sprawdzenia" : "Wymaga uzupełnienia";
}
