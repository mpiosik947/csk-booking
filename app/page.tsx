"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";

type AppIconName =
  | "calendar"
  | "training"
  | "user"
  | "target"
  | "document"
  | "dashboard"
  | "reservations"
  | "events"
  | "admin"
  | "logout"
  | "warning"
  | "arrow";

function AppIcon({
  name,
  className = "h-5 w-5",
}: {
  name: AppIconName;
  className?: string;
}) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
    >
      {name === "calendar" && (
        <>
          <rect x="3" y="5" width="18" height="16" rx="2" />
          <path d="M16 3v4M8 3v4M3 10h18M8 14h.01M12 14h.01M16 14h.01M8 17h.01M12 17h.01" />
        </>
      )}
      {name === "training" && (
        <>
          <path d="m3 7 9-4 9 4-9 4-9-4Z" />
          <path d="M6 9v5c0 1.7 2.7 3 6 3s6-1.3 6-3V9M21 7v6" />
        </>
      )}
      {name === "user" && (
        <>
          <circle cx="12" cy="8" r="4" />
          <path d="M4 21a8 8 0 0 1 16 0" />
        </>
      )}
      {name === "target" && (
        <>
          <circle cx="12" cy="12" r="8" />
          <circle cx="12" cy="12" r="3" />
          <path d="M15 9 21 3M17 3h4v4" />
        </>
      )}
      {name === "document" && (
        <>
          <path d="M6 3h8l4 4v14H6z" />
          <path d="M14 3v5h5M9 13h6M9 17h6" />
        </>
      )}
      {name === "dashboard" && (
        <>
          <rect x="3" y="3" width="7" height="7" rx="1" />
          <rect x="14" y="3" width="7" height="7" rx="1" />
          <rect x="3" y="14" width="7" height="7" rx="1" />
          <rect x="14" y="14" width="7" height="7" rx="1" />
        </>
      )}
      {name === "reservations" && (
        <>
          <rect x="5" y="4" width="14" height="17" rx="2" />
          <path d="M9 4V2h6v2M8 9h8M8 13h8M8 17h5" />
        </>
      )}
      {name === "events" && (
        <>
          <rect x="3" y="5" width="18" height="16" rx="2" />
          <path d="M16 3v4M8 3v4M3 10h18M8 14h3M8 17h7" />
        </>
      )}
      {name === "admin" && (
        <>
          <path d="M12 3 20 6v5c0 5-3.4 8.5-8 10-4.6-1.5-8-5-8-10V6l8-3Z" />
          <path d="m9 12 2 2 4-4" />
        </>
      )}
      {name === "logout" && (
        <>
          <path d="M10 4H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h5M14 8l4 4-4 4M18 12H8" />
        </>
      )}
      {name === "warning" && (
        <>
          <path d="M10.3 4.2 2.7 18a2 2 0 0 0 1.8 3h15a2 2 0 0 0 1.8-3L13.7 4.2a2 2 0 0 0-3.4 0Z" />
          <path d="M12 9v4M12 17h.01" />
        </>
      )}
      {name === "arrow" && <path d="m9 18 6-6-6-6" />}
    </svg>
  );
}

export default function Home() {
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<UserRole | null>(null);

  useEffect(() => {
    async function loadUser() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      setEmail(user?.email ?? "");

      if (!user) {
        setRole(null);
        return;
      }

      const { data: roleData, error: roleError } = await supabase.rpc(
        "get_my_role"
      );

      if (roleError) {
        setRole(null);
        return;
      }

      setRole((roleData as UserRole) ?? null);
    }

    loadUser();
  }, []);

  async function handleLogout() {
    await supabase.auth.signOut();
    setEmail("");
    setRole(null);
    window.location.href = "/";
  }

  const canSeeAdminPanel =
    role === "admin" || role === "pracownik" || role === "instruktor";

  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto w-full max-w-4xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/30 sm:p-8">
        <header className="text-center">
          <Image
            src="/login-brand.png"
            alt="CSK - Centrum Szkolenia Krutla"
            width={1536}
            height={1024}
            priority
            className="mx-auto h-auto w-full max-w-[300px] rounded-xl sm:max-w-[340px] lg:max-w-[380px]"
          />

          <h1 className="sr-only">Centrum Szkolenia Krutla</h1>
          <p className="mx-auto mt-4 max-w-xl text-base text-[#a9ada4] sm:text-lg">
            System rezerwacji osi strzeleckich, szkoleń i eventów.
          </p>
        </header>

        <div className="mt-7 grid gap-4 md:grid-cols-2">
          <a
            href="/booking"
            className="group flex min-h-32 items-center rounded-2xl border border-[#536143] bg-[#26301f] p-4 text-left transition hover:border-[#78865f] hover:bg-[#303b27] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:p-5"
          >
            <span className="flex shrink-0 items-center self-stretch border-r border-[#536143] pr-4 text-[#d7c895]">
              <AppIcon name="calendar" className="h-7 w-7" />
            </span>
            <span className="min-w-0 flex-1 px-4">
              <span className="block text-lg font-bold text-[#f2efe4]">
                Zarezerwuj termin
              </span>
              <span className="mt-1 block text-sm leading-5 text-[#c3c8bb]">
                Sprawdź dostępność osi i wybierz termin.
              </span>
            </span>
            <AppIcon
              name="arrow"
              className="h-5 w-5 shrink-0 text-[#9da88b] transition group-hover:translate-x-1"
            />
          </a>

          <a
            href="/events"
            className="group flex min-h-32 items-center rounded-2xl border border-[#6f5a2e] bg-[#332b1d] p-4 text-left transition hover:border-[#9a7c3e] hover:bg-[#403522] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:p-5"
          >
            <span className="flex shrink-0 items-center self-stretch border-r border-[#6f5a2e] pr-4 text-[#d7c895]">
              <AppIcon name="training" className="h-7 w-7" />
            </span>
            <span className="min-w-0 flex-1 px-4">
              <span className="block text-lg font-bold text-[#f2efe4]">
                Szkolenia i eventy
              </span>
              <span className="mt-1 block text-sm leading-5 text-[#c9c1ae]">
                Sprawdź dostępne szkolenia i zapisz się online.
              </span>
            </span>
            <AppIcon
              name="arrow"
              className="h-5 w-5 shrink-0 text-[#bca266] transition group-hover:translate-x-1"
            />
          </a>
        </div>

        <div className="my-6 flex flex-col items-center justify-center gap-3 border-y border-[#30372c] py-4 text-sm text-[#b7bbb1] sm:flex-row">
          <AppIcon name="user" className="h-5 w-5 text-[#aab58f]" />
          {email ? (
            <p className="min-w-0 text-center sm:text-left">
              Zalogowany jako:{" "}
              <span className="break-all font-semibold text-[#d7c895]">
                {email}
              </span>
            </p>
          ) : (
            <div className="flex flex-wrap items-center justify-center gap-x-4 gap-y-2">
              <span>Masz konto?</span>
              <a
                href="/login"
                className="font-semibold text-[#d7c895] underline-offset-4 transition hover:text-[#eadba6] hover:underline focus-visible:rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861]"
              >
                Zaloguj się
              </a>
              <a
                href="/register"
                className="font-semibold text-[#d7c895] underline-offset-4 transition hover:text-[#eadba6] hover:underline focus-visible:rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861]"
              >
                Rejestracja
              </a>
            </div>
          )}
        </div>

        <div>
          <h2 className="mb-3 text-xs font-bold tracking-[0.2em] text-[#858c7f]">
            INFORMACJE
          </h2>

          <div className="space-y-3">
            <div className="flex items-center rounded-2xl border border-[#343a31] bg-[#1a1e1a] p-4 text-left opacity-80">
              <AppIcon
                name="target"
                className="mr-4 h-6 w-6 shrink-0 text-[#b9a66c]"
              />
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-semibold text-[#e4e1d7]">
                    Strzelanie z instruktorem
                  </h3>
                  <span className="rounded-full border border-[#75643b] bg-[#2b261b] px-2 py-0.5 text-[0.65rem] font-bold tracking-wide text-[#d7c895]">
                    WKRÓTCE
                  </span>
                </div>
                <p className="mt-1 text-sm leading-5 text-[#92988e]">
                  Dla osób nieposiadających pozwolenia. Broń, amunicja i
                  instruktor na miejscu.
                </p>
              </div>
            </div>

            {email && (
              <>
                <a
                  href="/dashboard"
                  className="group flex items-center rounded-2xl border border-[#343a31] bg-[#1a1e1a] p-4 text-left transition hover:border-[#56614d] hover:bg-[#202520] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                >
                  <AppIcon
                    name="dashboard"
                    className="mr-4 h-6 w-6 shrink-0 text-[#aab58f]"
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block font-semibold">Panel klienta</span>
                    <span className="mt-1 block text-sm text-[#92988e]">
                      Przejdź do głównego panelu swojego konta.
                    </span>
                  </span>
                  <AppIcon
                    name="arrow"
                    className="ml-3 h-5 w-5 shrink-0 text-[#7f8877] transition group-hover:translate-x-1"
                  />
                </a>

                <a
                  href="/my-reservations"
                  className="group flex items-center rounded-2xl border border-[#343a31] bg-[#1a1e1a] p-4 text-left transition hover:border-[#56614d] hover:bg-[#202520] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                >
                  <AppIcon
                    name="reservations"
                    className="mr-4 h-6 w-6 shrink-0 text-[#aab58f]"
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block font-semibold">Moje rezerwacje</span>
                    <span className="mt-1 block text-sm text-[#92988e]">
                      Sprawdź aktywne rezerwacje osi i ich historię.
                    </span>
                  </span>
                  <AppIcon
                    name="arrow"
                    className="ml-3 h-5 w-5 shrink-0 text-[#7f8877] transition group-hover:translate-x-1"
                  />
                </a>

                <a
                  href="/my-events"
                  className="group flex items-center rounded-2xl border border-[#343a31] bg-[#1a1e1a] p-4 text-left transition hover:border-[#56614d] hover:bg-[#202520] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                >
                  <AppIcon
                    name="events"
                    className="mr-4 h-6 w-6 shrink-0 text-[#aab58f]"
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block font-semibold">Moje szkolenia</span>
                    <span className="mt-1 block text-sm text-[#92988e]">
                      Zobacz swoje zapisy na szkolenia i eventy.
                    </span>
                  </span>
                  <AppIcon
                    name="arrow"
                    className="ml-3 h-5 w-5 shrink-0 text-[#7f8877] transition group-hover:translate-x-1"
                  />
                </a>
              </>
            )}

            <a
              href="/terms"
              className="group flex items-center rounded-2xl border border-[#343a31] bg-[#1a1e1a] p-4 text-left transition hover:border-[#56614d] hover:bg-[#202520] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
            >
              <AppIcon
                name="document"
                className="mr-4 h-6 w-6 shrink-0 text-[#aab58f]"
              />
              <span className="min-w-0 flex-1">
                <span className="block font-semibold">Regulamin i RODO</span>
                <span className="mt-1 block text-sm leading-5 text-[#92988e]">
                  Zapoznaj się z zasadami korzystania z obiektu i ochroną
                  danych.
                </span>
              </span>
              <AppIcon
                name="arrow"
                className="ml-3 h-5 w-5 shrink-0 text-[#7f8877] transition group-hover:translate-x-1"
              />
            </a>

            {canSeeAdminPanel && (
              <a
                href="/admin"
                className="group flex items-center rounded-2xl border border-[#4a513e] bg-[#1d211b] p-4 text-left transition hover:border-[#657052] hover:bg-[#252a22] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#a8b58a] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              >
                <AppIcon
                  name="admin"
                  className="mr-4 h-6 w-6 shrink-0 text-[#b9c39f]"
                />
                <span className="min-w-0 flex-1 font-semibold">
                  Panel administratora
                </span>
                <AppIcon
                  name="arrow"
                  className="ml-3 h-5 w-5 shrink-0 text-[#7f8877] transition group-hover:translate-x-1"
                />
              </a>
            )}

            {email && (
              <button
                type="button"
                onClick={handleLogout}
                className="flex w-full items-center rounded-2xl border border-[#493333] bg-[#211919] p-4 text-left text-[#c98d8d] transition hover:border-[#694444] hover:bg-[#2a1d1d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#b96f6f] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              >
                <AppIcon
                  name="logout"
                  className="mr-4 h-5 w-5 shrink-0"
                />
                <span className="font-semibold">Wyloguj</span>
              </button>
            )}
          </div>
        </div>

        <div className="mt-6 flex gap-4 rounded-2xl border border-[#6f5a2e] bg-[#242015] p-4 text-left">
          <AppIcon
            name="warning"
            className="mt-0.5 h-6 w-6 shrink-0 text-[#d2b66f]"
          />
          <div>
            <h2 className="text-xs font-bold tracking-[0.16em] text-[#d7c895]">
              WERSJA TESTOWA
            </h2>
            <p className="mt-1 text-sm text-[#c8c0ab]">
              System w fazie sprawdzania.
            </p>
            <p className="mt-1 text-sm text-[#9f9b8f]">
              Rezerwacje mogą wymagać potwierdzenia telefonicznego.
            </p>
          </div>
        </div>
      </section>
    </main>
  );
}


