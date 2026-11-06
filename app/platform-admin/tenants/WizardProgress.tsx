import { wizardSteps, stepStatus } from "@/lib/platform-onboarding-steps";
import type { Readiness } from "@/lib/platform-draft-readiness";

type Props = {
  step: number;
  readiness?: Readiness | null;
  laneCount?: number;
  onStep?: (step: number) => void;
  locked?: boolean;
};

export default function WizardProgress({ step, readiness = null, laneCount = 0, onStep, locked }: Props) {
  return <nav aria-label="Sekcje konfiguracji" className="mb-5 min-w-0">
    <p id="wizard-current-step" className="font-semibold" aria-live="polite">Krok {step + 1} z 7 · {wizardSteps[step]}</p>
    <label className="mt-2 block md:hidden">
      <span className="sr-only">Przejdź do kroku</span>
      <select aria-label="Przejdź do kroku" aria-describedby="wizard-current-step" className="min-h-11 w-full rounded border border-[#626b55] bg-[#161c14] p-2"
        disabled={!onStep || locked} value={step} onChange={event => onStep?.(Number(event.target.value))}>
        {wizardSteps.map((title, i) => <option key={title} value={i}>{i + 1}. {title}{onStep && ` · ${stepStatus(i, readiness, laneCount)}`}</option>)}
      </select>
    </label>
    <span className="sr-only md:hidden" aria-current="step">{wizardSteps[step]}</span>
    <ol className="mt-3 hidden gap-2 md:grid md:grid-cols-4 xl:grid-cols-7">
      {wizardSteps.map((title, i) => <li key={title}>
        <button type="button" aria-current={step === i ? "step" : undefined}
          disabled={locked || !onStep} onClick={() => onStep?.(i)}
          className={`h-full min-h-12 w-full rounded-lg border p-2 text-left text-sm focus-visible:outline-2 ${step === i ? "border-[#d7c895] bg-[#293025] font-semibold" : "border-[#48523c]"}`}>
          {i + 1}. {title}
          <span className="block text-xs">{step === i ? "Bieżący krok" : onStep ? stepStatus(i, readiness, laneCount) : "Po utworzeniu szkicu"}</span>
        </button>
      </li>)}
    </ol>
  </nav>;
}
