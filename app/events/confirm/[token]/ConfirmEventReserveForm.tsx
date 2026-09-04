"use client";

import Link from "next/link";
import { FormEvent, useState } from "react";
import { getEventConfirmationResponseMessage } from "@/lib/safe-client-error";
import { supabase } from "@/lib/supabase";

type ConfirmEventReserveFormProps = {
  token: string;
};

type ConfirmationState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "success"; message: string }
  | {
      status: "error";
      message: string;
      code?: string;
      requiresLogin?: boolean;
    };

export default function ConfirmEventReserveForm({
  token,
}: ConfirmEventReserveFormProps) {
  const [state, setState] = useState<ConfirmationState>({ status: "idle" });

  async function confirmPlace(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (state.status === "loading" || state.status === "success") {
      return;
    }

    setState({ status: "loading" });

    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        setState({
          status: "error",
          code: "unauthorized",
          message: "Zaloguj się, aby potwierdzić swoje miejsce.",
          requiresLogin: true,
        });
        return;
      }

      const response = await fetch("/api/confirm-event-reserve-promotion", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ token }),
      });
      const result: unknown = await response.json().catch(() => null);
      const code =
        result &&
        typeof result === "object" &&
        !Array.isArray(result) &&
        "code" in result &&
        typeof result.code === "string"
          ? result.code
          : undefined;
      const message = getEventConfirmationResponseMessage(code, response.ok);

      if (response.ok) {
        setState({ status: "success", message });
        return;
      }

      setState({
        status: "error",
        code,
        message,
        requiresLogin: response.status === 401,
      });
    } catch {
      setState({
        status: "error",
        code: "network_error",
        message:
          "Usługa potwierdzania jest chwilowo niedostępna. Spróbuj ponownie.",
      });
    }
  }

  const success = state.status === "success";
  const loading = state.status === "loading";
  const terminalError =
    state.status === "error" &&
    ["expired", "full", "not_found", "event_not_found", "not_reserve"].includes(
      state.code ?? ""
    );
  const title = success
    ? "Miejsce zostało potwierdzone"
    : "Potwierdź swoje miejsce";

  return (
    <form onSubmit={confirmPlace}>
      <h1 className="mt-6 text-center text-3xl font-bold sm:text-4xl">
        {title}
      </h1>

      {state.status === "idle" ? (
        <div className="mt-6 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 text-sm leading-6 text-[#a9ada4]">
          Potwierdzenie wymaga zalogowania i świadomego użycia przycisku. Samo
          otwarcie tego linku nie zmienia Twojego zapisu.
        </div>
      ) : null}

      {state.status === "success" || state.status === "error" ? (
        <div
          role={success ? "status" : "alert"}
          aria-live={success ? "polite" : undefined}
          className={`mt-6 rounded-2xl border p-5 text-sm leading-6 ${
            success
              ? "border-[#3f6848] bg-[#1b2a1d] text-[#a9d4ad]"
              : "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]"
          }`}
        >
          {state.message}
        </div>
      ) : null}

      {success ? (
        <div className="mt-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 text-sm leading-6 text-[#a9ada4]">
          Twój status został zmieniony z listy rezerwowej na uczestnika
          szkolenia. Szczegóły znajdziesz w panelu klienta.
        </div>
      ) : null}

      {state.status === "error" && state.requiresLogin ? (
        <Link
          href={`/login?redirectTo=${encodeURIComponent(
            `/events/confirm/${token}`
          )}`}
          className="mt-4 inline-flex min-h-12 w-full items-center justify-center rounded-xl border border-[#536143] px-5 py-3 text-center text-sm font-semibold text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
        >
          Przejdź do logowania
        </Link>
      ) : null}

      {!success &&
      !terminalError &&
      (state.status !== "error" || !state.requiresLogin) ? (
        <button
          type="submit"
          disabled={loading}
          className="mt-6 inline-flex min-h-12 w-full items-center justify-center rounded-xl bg-[#536143] px-5 py-3 text-center text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:opacity-60"
        >
          {loading ? "Potwierdzanie..." : "Potwierdź miejsce"}
        </button>
      ) : null}
    </form>
  );
}
