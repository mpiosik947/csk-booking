"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { supabase } from "../../lib/supabase";
import {
  adaptPublicBookingConfiguration,
  parsePublicBookingConfiguration,
  type BookingDuration,
  type BookingLane,
  type BookingPricingRule,
} from "../../lib/public-booking-configuration";
import BookingForm from "./BookingForm";

export default function BookingPage() {
  const [lanes, setLanes] = useState<BookingLane[]>([]);
  const [durations, setDurations] = useState<BookingDuration[]>([]);
  const [pricingRules, setPricingRules] = useState<BookingPricingRule[]>([]);
  const [loading, setLoading] = useState(true);
  const [message, setMessage] = useState("");

  useEffect(() => {
    async function loadBookingConfiguration() {
      setLoading(true);
      setMessage("");

      const configurationResult = await supabase.rpc(
        "get_public_booking_configuration_v1"
      );

      if (configurationResult.error) {
        setMessage(
          "Nie udało się pobrać aktualnej konfiguracji rezerwacji. Spróbuj ponownie."
        );
        setLoading(false);
        return;
      }

      const resources = parsePublicBookingConfiguration(configurationResult.data);

      if (!resources) {
        setMessage(
          "Nie udało się pobrać aktualnej konfiguracji rezerwacji. Spróbuj ponownie."
        );
        setLoading(false);
        return;
      }

      const configuration = adaptPublicBookingConfiguration(resources);
      setLanes(configuration.lanes);
      setDurations(configuration.durations);
      setPricingRules(configuration.pricingRules);
      setLoading(false);
    }

    loadBookingConfiguration();
  }, []);

  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto max-w-5xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/20 sm:p-8">
        <header>
          <p className="mb-3 text-xs font-semibold uppercase tracking-[0.22em] text-[#d7c895]">
            CSK BOOKING
          </p>
          <h1 className="text-3xl font-bold sm:text-4xl">Zarezerwuj oś</h1>
          <p className="mt-3 max-w-3xl leading-7 text-[#a9ada4]">
            Wybierz datę, oś, liczbę strzelców, godzinę i czas rezerwacji.
            Ostateczna dostępność i cena są potwierdzane podczas zapisu.
          </p>
        </header>

        <div className="mt-6 rounded-2xl border border-[#30372c] bg-[#191e19] px-4 py-3 text-sm leading-6 text-[#a9ada4] sm:px-5">
          Wybierz oś → datę → liczbę strzelców → długość → godzinę
        </div>

        {loading && (
          <div
            role="status"
            className="mt-6 rounded-xl border border-[#30372c] bg-[#191e19] p-4 text-[#a9ada4]"
          >
            Ładowanie konfiguracji rezerwacji...
          </div>
        )}

        {message && (
          <div
            role="alert"
            className="mt-6 rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-[#e0a0a0]"
          >
            {message}
          </div>
        )}

        {!loading && lanes.length === 0 && !message && (
          <div
            role="status"
            className="mt-6 rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-[#e1c477]"
          >
            Brak aktywnych osi do rezerwacji.
          </div>
        )}

        {!loading && lanes.length > 0 && !message && (
          <section aria-label="Formularz rezerwacji" className="mt-8 w-full">
            <BookingForm
              lanes={lanes}
              durations={durations}
              pricingRules={pricingRules}
            />
          </section>
        )}

        <nav className="mt-8 border-t border-[#30372c] pt-6">
          <Link
            href="/"
            className="inline-flex min-h-11 items-center rounded-xl border border-[#30372c] px-5 py-3 text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#f2efe4]"
          >
            ← Wróć na stronę główną
          </Link>
        </nav>
      </section>
    </main>
  );
}
