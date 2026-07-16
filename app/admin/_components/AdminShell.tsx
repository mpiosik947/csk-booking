import type { ReactNode } from "react";

type AdminShellProps = {
  eyebrow: string;
  title: string;
  description?: string;
  badge?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
};

export default function AdminShell({
  eyebrow,
  title,
  description,
  badge,
  actions,
  children,
}: AdminShellProps) {
  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <div className="mx-auto w-full max-w-7xl">
        <section className="rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-[0_24px_70px_rgba(0,0,0,0.25)] sm:p-8">
          <header className="mb-8 flex flex-col gap-6 border-b border-[#30372c] pb-6 lg:flex-row lg:items-end lg:justify-between">
            <div className="min-w-0">
              <p className="mb-3 text-sm uppercase tracking-[0.35em] text-[#d7c895]">
                {eyebrow}
              </p>

              <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-center">
                <h1 className="text-3xl font-bold text-[#f2efe4] sm:text-4xl">
                  {title}
                </h1>
                {badge}
              </div>

              {description && (
                <p className="mt-4 max-w-3xl text-[#a9ada4]">
                  {description}
                </p>
              )}
            </div>

            {actions && (
              <div className="flex w-full flex-col gap-3 sm:w-auto sm:flex-row sm:flex-wrap lg:justify-end">
                {actions}
              </div>
            )}
          </header>

          {children}
        </section>
      </div>
    </main>
  );
}
