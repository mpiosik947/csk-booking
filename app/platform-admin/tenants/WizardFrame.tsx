import type { ReactNode } from "react";

/** The viewport is split so even a wrapped action bar never overlaps a field. */
export default function WizardFrame({ children, actions }: { children: ReactNode; actions: ReactNode }) {
  return <div className="flex h-dvh min-w-0 flex-col bg-[#090b09] text-[#f2efe4]">
    <div data-wizard-scroll className="min-h-0 flex-1 overflow-y-auto overscroll-contain [&>main]:min-h-full">{children}</div>
    {actions && <div className="shrink-0 border-t border-[#626b55] bg-[#141814] px-4 pt-2 pb-[max(.5rem,env(safe-area-inset-bottom))]">
      <div className="mx-auto w-full max-w-7xl">{actions}</div>
    </div>}
  </div>;
}
