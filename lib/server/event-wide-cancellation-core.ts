import { operationalEmailBrand, operationalEmailHistoryUrl, type OperationalEmailTenantContext } from "./operational-email-core.ts";
import { operationalEmailLayout } from "./operational-email-layout.ts";

export function eventWideCancellationContent(tenant: OperationalEmailTenantContext, event: {
  title: string; event_date: string; start_time: string; end_time: string; location: string | null;
}) {
  const title = "Wydarzenie zostało anulowane";
  const brand = operationalEmailBrand(tenant, title);
  const url = operationalEmailHistoryUrl(tenant, "events");
  const details = [
    { label: "Wydarzenie", value: event.title }, { label: "Data", value: event.event_date },
    { label: "Godzina", value: `${event.start_time.slice(0,5)}–${event.end_time.slice(0,5)}` },
    { label: "Miejsce", value: event.location ?? "-" }, { label: "Obiekt", value: tenant.displayName },
  ];
  return { subject: brand.subject,
    text: `${brand.headerText}\n\n${title}. Informacja dotyczy uczestników i listy rezerwowej.\n${details.map(d => `${d.label}: ${d.value}`).join("\n")}\n\nMoje szkolenia: ${url}`,
    html: operationalEmailLayout({ tenantDisplayName: tenant.displayName, title,
      intro: "Informacja dotyczy uczestników i listy rezerwowej.", details,
      actions: [{ label: "Moje szkolenia", url }] }),
  };
}
