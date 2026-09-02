import Image from "next/image";
import Link from "next/link";
import ConfirmEventReserveForm from "./ConfirmEventReserveForm";

type ConfirmEventReservePageProps = {
  params: Promise<{
    token: string;
  }>;
};

export default async function ConfirmEventReservePage({
  params,
}: ConfirmEventReservePageProps) {
  const { token } = await params;

  return (
    <main className="flex min-h-screen items-center bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto w-full max-w-2xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl shadow-black/20 sm:p-9">
        <Image
          src="/login-brand.png"
          alt="Centrum Szkolenia Krutla"
          width={1536}
          height={1024}
          className="mx-auto h-auto w-full max-w-[260px] sm:max-w-[300px]"
          priority
        />

        <ConfirmEventReserveForm token={token} />

        <div className="mt-6 flex flex-col gap-3 sm:flex-row">
          <Link
            href="/my-events"
            className="inline-flex min-h-12 w-full items-center justify-center rounded-xl bg-[#536143] px-5 py-3 text-center text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:w-auto"
          >
            Moje szkolenia
          </Link>

          <Link
            href="/events"
            className="inline-flex min-h-12 w-full items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:w-auto"
          >
            Lista szkoleń
          </Link>
        </div>
      </section>
    </main>
  );
}
