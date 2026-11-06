import type { Profile, profileFlagKeys } from "./platform-draft-configuration.ts";
import type { TenantFeatureKey } from "./tenant-features.ts";

type Capability = { group: string; name: string; help: string; entitlement: TenantFeatureKey; lane?: boolean };

export const capabilities: readonly Capability[] = [
  { group: "Rezerwacje", name: "Rezerwacje online", help: "Pozwala klientom rezerwować dostępne osie i stanowiska po otwarciu zapisów.", entitlement: "booking" },
  { group: "Rezerwacje", name: "Rezerwacja pojedynczych stanowisk", help: "Dla każdej osi wybierasz, które stanowiska można zarezerwować osobno.", entitlement: "booking", lane: true },
  { group: "Rezerwacje", name: "Rezerwacja całej osi", help: "Osobno dla każdej osi określasz, czy klient może zarezerwować ją w całości.", entitlement: "booking", lane: true },
  { group: "Obsługa obiektu", name: "Kalendarz administracyjny", help: "Pokazuje obsłudze rezerwacje, wydarzenia i dostępność obiektu.", entitlement: "advanced_calendar" },
  { group: "Obsługa obiektu", name: "Blokady osi", help: "Pozwala czasowo wyłączyć oś lub stanowisko z rezerwacji, np. na serwis lub zawody.", entitlement: "lane_blocks" },
  { group: "Obsługa obiektu", name: "Check-in / QR", help: "Obsługa może potwierdzić przybycie klienta z rezerwacją.", entitlement: "checkin" },
  { group: "Wydarzenia", name: "Wydarzenia i szkolenia", help: "Pozwala tworzyć wydarzenia i prowadzić na nie zapisy.", entitlement: "events" },
  { group: "Wydarzenia", name: "Lista rezerwowa", help: "Jest częścią zapisów na wydarzenie. Gdy zabraknie miejsc, uczestnik może trafić na listę rezerwową.", entitlement: "events" },
  { group: "Zespół", name: "Pracownicy", help: "Uprawniona obsługa zarządza użytkownikami obiektu.", entitlement: "staff" },
  { group: "Zespół", name: "Informacja o instruktorach", help: "Pakiet pozwala pokazać na stronie zapowiedź. Przypisania instruktorów do wydarzeń są zarządzane osobno.", entitlement: "instructors" },
  { group: "Zarządzanie", name: "Raporty", help: "Administrator może przeglądać i eksportować raporty o rezerwacjach.", entitlement: "reports" },
  { group: "Strona publiczna", name: "Domena własna", help: "Domenę można skonfigurować osobno po jej zweryfikowaniu.", entitlement: "custom_domain" },
];

export type VisibilityKey = typeof profileFlagKeys[number];
type Visibility = { key: VisibilityKey; name: string; help: string; entitlement?: "booking" | "events" | "instructors" };
export const pageSections: readonly Visibility[] = [
  { key: "show_booking", name: "Pokaż odnośnik do rezerwacji", help: "Dodaje na stronie obiektu przycisk rezerwacji.", entitlement: "booking" },
  { key: "show_pricing", name: "Pokaż cennik informacyjny", help: "Pokazuje aktywne pozycje cennika. Ceny rezerwacji ustawiasz przy osiach.", entitlement: "booking" },
  { key: "show_events", name: "Pokaż wydarzenia", help: "Dodaje na stronie odnośnik do wydarzeń. Zapisy i lista rezerwowa należą do modułu wydarzeń.", entitlement: "events" },
  { key: "show_instructor", name: "Pokaż zapowiedź sekcji instruktorskiej", help: "Pokazuje informację o planowanej usłudze. Nie uruchamia rezerwacji z instruktorem.", entitlement: "instructors" },
  { key: "show_about", name: "Pokaż sekcję „O obiekcie”", help: "Udostępnia opis oferty i informację, do kogo jest skierowana." },
  { key: "show_contact", name: "Pokaż kontakt i dojazd", help: "Udostępnia sekcję z danymi kontaktowymi obiektu." },
  { key: "show_regulations", name: "Pokaż regulamin obiektu", help: "Pokazuje odnośnik do regulaminu po wskazaniu pliku." },
];

export function sectionAvailable(section: Visibility, access: Record<"booking" | "events" | "instructors", boolean>) {
  return !section.entitlement || access[section.entitlement];
}

export function visibleSections(profile: Profile, access: Record<"booking" | "events" | "instructors", boolean>) {
  return pageSections.filter(section => sectionAvailable(section, access) && profile[section.key]);
}
