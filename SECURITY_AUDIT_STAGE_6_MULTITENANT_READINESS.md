# CSK Booking — etap 6: gotowość multi-tenant SaaS

## Ocena bieżąca

Obecny model jest bezpieczniejszym modelem **single-tenant z rolami globalnymi**, nie modelem tenant-aware. Nie istnieją `tenants`, `tenant_memberships` ani `tenant_id`. `profiles.role=admin` oznacza globalnego administratora wszystkich danych aplikacji.

**MULTI-TENANT READINESS: NOT READY**

To nie jest potwierdzona podatność cross-tenant w bieżącej usłudze, ponieważ tenant B obecnie nie istnieje. Jest to architektoniczny blocker przed dodaniem drugiej firmy.

## Docelowa granica zaufania

```text
auth.uid()
  → tenant_memberships(user_id, tenant_id, role)
  → zaufany tenant context w RLS/RPC
  → zasób.tenant_id albo bezpieczna, wymuszona FK relacja do tenant-owned parenta
```

Frontend może wskazać zasób, ale nie może ustalić autorytatywnego `tenant_id`. Każdy RPC musi wyprowadzić membership z `auth.uid()` i sprawdzić, że wszystkie parametry/lockowane rekordy należą do tego samego tenant. Platform admin powinien być odrębną, audytowaną koncepcją, a nie rolą tenant admin.

## Mapa tabel

| Tabela | `tenant_id` wymagany | Sposób izolacji docelowej | Ryzyko bez zmiany |
| --- | --- | --- | --- |
| `profiles` | pośrednio przez memberships; nie jedna globalna role | `tenant_memberships(user_id,tenant_id,role)`; profil globalny tylko dla tożsamości | globalny admin/pracownik |
| `shooting_lanes` | tak | bezpośredni tenant owner + composite FK w hierarchii | odczyt/konfiguracja innej firmy |
| `events` | tak | direct tenant, wszystkie lane assignments same tenant | globalne eventy i admin |
| `event_lanes` | relacyjnie, zalecany direct dla wymuszenia | composite FK `(tenant_id,event_id)` i `(tenant_id,lane_id)` | relacja cross-tenant |
| `reservations` | tak (mimo derivation z lane) | direct tenant + composite FK lane; owner user w tenant | BOLA przez ID/lane |
| `event_registrations` | tak | direct tenant + composite FK event; owner user | globalny staff read/write |
| `lane_blocks` | relacyjnie lub direct zalecany | tenant lane parent + composite FK | blokada zasobu B |
| `lane_booking_rules` | relacyjnie | tylko do lane w tenant, composite FK | sprzedaż/config B |
| `lane_booking_durations` | relacyjnie | tylko do lane w tenant | config B |
| `lane_pricing_rules` | relacyjnie | tylko do lane w tenant | ceny B |
| `lane_booking_family_configuration_versions` | tak lub silnie relacyjnie | tenant/root lane unique | optimistic lock koliduje globalnie |
| `audit_logs` | tak | direct tenant; platform audit oddzielnie | audit data leak/cross-tenant target |
| `email_deliveries` | tak lub bezpiecznie wyprowadzalny | tenant message context + scoped service operation | metadata cross-tenant |
| `confirmation_email_rate_limits` | decyzja | global per-user/IP albo tenant quota; jawny model | niejasne limity i korelacja |
| `auth.users` | nie | globalna tożsamość, membership wiele tenantów | nie wolno kopiować per tenant |

Direct `tenant_id` na tabelach transakcyjnych redukuje złożoność RLS i pozwala na indeksy `(tenant_id, ...)`; relacyjne tabele konfiguracyjne mogą dziedziczyć tenant, ale composite FK musi fizycznie uniemożliwiać cross-tenant linkage.

## Wymagane zmiany warstw

### Role i RLS

- przenieść role biznesowe do membership;
- każda polityka SELECT/I/U/D zaczyna się od aktywnego membership danego tenant;
- ownership to jednocześnie `user_id=auth.uid()` i właściwy tenant;
- publiczne konfiguracje muszą mieć jawny tenant resolver (host/subdomain/slug), nie dowolny tenant ID z requestu;
- admin A nie może widzieć ani mutować tenant B.

### SECURITY DEFINER RPC

- nie ufać `p_tenant_id`; jeśli parametr jest potrzebny do routingu, zawsze zweryfikować membership;
- wszystkie ID wejściowe pobrać i sprawdzić pod jednym tenant przed mutacją;
- family locks, event locks i conflict scopes muszą zawierać tenant;
- unikalności/idempotency i audit muszą mieć tenant scope;
- service-role background jobs muszą otrzymywać zaufany context rekordu i weryfikować powiązania, nie wykonywać globalnego wyszukiwania po słabym tokenie.

### Indeksy i constraints

- composite unique keys `(tenant_id,id)` umożliwiają composite FK;
- unikalności nazw, aktywnych rekordów, version roots i idempotency należy świadomie określić jako globalne lub tenant-scoped;
- zakazać cross-tenant parent/child, event/lane i reservation/lane;
- historyczne snapshoty powinny przechowywać tenant również po dezaktywacji parenta.

## Docelowy zestaw testów A/B

| Operacja | Admin A → A | Admin A → B | Employee A → A | Employee A → B | User A own | User A → User B / tenant B |
| --- | --- | --- | --- | --- | --- | --- |
| SELECT | ALLOW | DENY | wg roli | DENY | ALLOW | DENY |
| INSERT | ALLOW | DENY | wg roli | DENY | wg kontraktu | DENY |
| UPDATE | ALLOW | DENY | wg roli | DENY | own allowlist | DENY |
| DELETE | wg roli | DENY | wg roli | DENY | wg kontraktu | DENY |
| RPC | ALLOW | DENY | wg roli | DENY | own contract | DENY |

Dodatkowo trzeba testować:

- podmianę tenant_id, parent ID, lane ID, event ID i target user ID;
- cross-tenant arrays w family/event RPC;
- mieszany payload z jednym rekordem B — całość atomowo DENY;
- platform admin osobno od tenant admin;
- anon/public resolver nie ujawnia tenantów ani nie pozwala enumerować konfiguracji;
- background e-mail/cron nie miesza tenantów.

---

### SEC-004

Severity: **HIGH**
Status: **CONFIRMED**
Affected: cały model danych/RLS/RPC
Opis: brak modelu tenant i tenant-scoped membership. Obecne role i operacje administracyjne są globalne. Uruchomienie więcej niż jednej firmy na tym samym schemacie spowoduje zamierzony przez bieżące RLS dostęp admin/pracownik do wszystkich rekordów.
Attack scenario: po dodaniu tenant B bez pełnej przebudowy Admin A korzysta z istniejących globalnych policies/RPC i odczytuje/modyfikuje B.
Impact: pełny cross-tenant disclosure i integrity compromise.
Evidence: 0 kolumn `tenant_id`, brak tenants/memberships; globalne helpery roli oraz policies all staff/admin.
Remediation: wdrożyć model opisany powyżej przed onboardingiem drugiego tenant; migrację danych i policies traktować jako security boundary, z fail-closed preflight i testami A/B.
Regression test: pełna macierz SELECT/I/U/D/RPC dla tenant A/B, w tym mixed-ID payload i role.

## Warunek przejścia do READY

`READY` wymaga schematu tenant, membership roles, tenant-scoped RLS/RPC/FK/indexes, backfillu z walidacją, pełnej macierzy A/B oraz osobnego audytu po migracji. Samo dodanie `tenant_id` do kilku tabel nie wystarczy.
