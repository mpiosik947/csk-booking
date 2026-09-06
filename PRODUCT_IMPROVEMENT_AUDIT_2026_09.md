# CSK Booking — Product Improvement Audit

**Roadmap horizon:** V1.1 / V1.2

**Audit date:** 2026-09-06

**Reviewed HEAD:** `c923feb1244202fe948d81243098b2cc6a61930d`

**Current product:** single-tenant V1, feature complete and production ready

## 1. Method and product baseline

This is a read-only product audit, not a security audit or implementation
review. Recommendations are based on the current pages, actions, RPC/API
contracts, production-smoke evidence and final V1 UAT. No code, database,
configuration or production state was changed.

The application already has a complete transactional core: hierarchy-aware
booking, atomic family conflicts, reservations, cancellation history, lane
blocks, Day/Week/Month Calendar, check-in, users, reports, events, waitlist
promotion, e-mail delivery and audited administrative operations. V1.1 should
therefore reduce friction and manual work before adding another broad module.

## 2. Current product review

| Area | What works well | Friction / unused opportunity |
|---|---|---|
| `/` | Five clear entries lead to Booking, Events, Login, Register and legal information. Mobile layout is already release-tested. | Returning customers receive the same generic entry as first-time visitors; there is no shortcut to their next booking or repeat action. |
| `/booking` | Progressive axis → mode → position selection, authoritative pricing/availability, clear whole-lane exclusivity and complete confirmation. | A repeat customer must rebuild the same choice from the beginning. No last-choice prefill or post-booking calendar action exists. |
| `/events` | Bounded search/pagination, authoritative availability, sold-out/reserve states and controlled registration. | No personal interest/favorite mechanism; no calendar export from an event or registration. |
| Login / Register | Shared 12–72 password policy, safe errors and clear account path. | No material V1.1 product gap. Avoid adding authentication complexity without a measured need. |
| Privacy / Terms | Current flows and processors are described; links are reachable. | Final controller/contact fields are a known legal dependency and excluded from this audit. |
| `/account` | Profile, declarations, qualifications, export and account deletion are complete. | It does not act as a preference center for reminders or booking defaults because those capabilities do not yet exist. |
| `/my-reservations` | Active/history/cancelled states, payment, details, cancellation and check-in link are present. | No “Book again”, exact cancellation-deadline presentation, calendar file or configurable pre-visit instructions. |
| `/my-events` | Upcoming/history/all, canonical statuses, payment, promotion confirmation and cancellation eligibility are present. | No calendar action or event reminder preference. History is usable but does not lead into a repeat/related event journey. |
| Admin dashboard | Strong “Today” view already exposes unverified, unpaid, waitlist, no-show, arrivals, check-in, collection and revenue indicators. | Tiles generally open broad target pages rather than an exact filtered work queue. Staff repeats filtering/context selection after clicking. |
| Admin Reservations | Search, filters, status/payment actions, cancellation, hierarchy labels and CSV are present. | No controlled staff-created phone/walk-in reservation and no direct “repeat/create similar” workflow. |
| Admin Calendar | Day/Week/Month, Today, type/lane filters, sticky resource/time headers, hierarchy correctness and entry preview/navigation exist. | Empty time cells are not actionable; schedule changes require leaving Calendar and rebuilding context. Drag-and-drop would be disproportionate risk. |
| Lane Blocks | Controlled creation, update/activation, family conflicts and Calendar visibility exist. | Repeating the same maintenance/closure pattern requires manual recreation; no safe recurrence or duplicate-draft action exists. |
| Check-in | Date view, customer/resource/status search, payment/attendance actions and token lookup support front desk work. | A dedicated “needs attention now” preset and communication context would reduce searching during peaks. Event attendance is not a first-class check-in workflow. |
| Users | Bounded search/filter/sort, details, role, verification, note, declarations and qualifications are complete. | Staff cannot see concise operational aggregates such as last visit, booking count or cancellation count. Avoid expanding raw PII. |
| Reports | KPI, 720-minute occupancy, hierarchy filters, pagination, safe CSV and mobile UX are complete. | Reports are pull-only; owners cannot subscribe to a bounded periodic summary. Historical snapshot residual is explicitly excluded. |
| Admin Events | Create/edit/activate, hierarchy assignment, search/scope/sort, participants, status/payment filters and pagination are complete. | Repeated training setup is manually re-entered. No participant export or event check-in mode exists. |

## 3. Quick wins

| Name | Current problem | Proposed improvement | User value | Business value | Effort | Risk | Recommended |
|---|---|---|---|---|---|---|---|
| Add to calendar | Confirmed dates remain only inside CSK pages/e-mail. | Generate a local `.ics` for a reservation or registered event using existing date/time/title/location snapshots. | High | Medium/High through fewer missed visits | Low | Low | YES |
| Book again | Returning users repeat the full selection path. | Add `Zarezerwuj ponownie`, prefilling only family/mode/resource/duration/people; always re-read current price and availability. | High | High | Low/Medium | Low/Medium | YES |
| Remember last booking choice | Booking always starts from an empty resource selection. | Store a non-sensitive local preference for last family/mode and offer it as a shortcut, with normal server revalidation. | Medium/High | Medium | Low | Low | YES |
| Exact cancellation deadline | The rule is communicated as 72 hours, requiring mental calculation. | Show the calculated Europe/Warsaw deadline beside eligible future reservations/events. | High | Medium | Low | Low | YES |
| Pre-visit checklist | Confirmation covers transaction facts but not a concise operational checklist. | Add configurable static “before your visit” content: arrival time, documents/equipment, payment and rules link. | High | Medium/High | Low | Low | YES |
| Actionable dashboard tiles | Staff lands on a broad list after selecting an attention KPI. | Pass safe filter/date query parameters so unpaid, check-in, no-show and waitlist tiles open the exact queue. | Low user / High staff | High | Low/Medium | Low | YES |
| Duplicate event draft | Recurring training data is manually retyped. | Add `Utwórz podobne` that copies safe event fields into an unsaved draft, excluding ID, date and participant data. | Low customer / High staff | High | Low/Medium | Low/Medium | YES |
| Participant CSV export | Staff can filter participants but cannot take the operational list offline. | Reuse the hardened semicolon/BOM/formula-safe CSV approach with the existing minimal participant DTO and active filters. | Low customer / High staff | Medium | Low/Medium | Low/Medium | YES |
| Post-cancellation replacement CTA | Cancellation ends without a direct recovery path. | Offer `Wybierz nowy termin`, returning to Booking with a safe preference-only prefill. | High | High | Low | Low | YES |
| Check-in attention preset | Search is flexible but front-desk priority is implicit. | Add local presets such as `Oczekiwani teraz`, `Nieopłaceni` and `Do zakończenia`, based on existing fields. | Medium | Medium/High | Low/Medium | Low | YES |

## 4. Customer experience decisions

| Candidate | Value | Complexity | Dependencies | Recommendation |
|---|---|---|---|---|
| `Zarezerwuj ponownie` | High: shortens the highest-intent return journey. | Low/Medium | Stable URL/prefill schema; current config/availability revalidation. | V1.1 |
| Favorite axis/position | Medium; useful only to frequent repeat users. | Medium | Preference storage and account UX. | Later; first validate last-choice/rebook usage. |
| Remember last choice | Medium/High. | Low | Privacy-safe browser preference; fail-closed if resource disappears. | V1.1 |
| Reservation reminder | High; likely reduces no-shows. | Medium/High | Scheduler, idempotent delivery jobs, preferences and delivery history. | V1.2 |
| Event reminder | High for attendance and event revenue. | Medium/High | Same notification foundation as reservation reminders. | V1.2 |
| Reschedule | High, but semantically more than cancel + create. | High | Atomic replacement or temporary slot hold; pricing/conflict/audit rules. | V1.2 after a dedicated design. |
| Booking waitlist / freed-slot alert | Potentially high only if slot scarcity is common. | High | Subscription model, expiry, notifications and fairness rules. | Later, based on demand evidence. |
| Event freed-place notification | Already delivered. | Existing | Cancellation invokes the reserve-promotion notification flow. | Close; do not rebuild. |
| Visit history | Already available through reservation history and attendance states. | Existing | None. | Close; improve presentation only if research shows need. |
| Easier future-reservation management | High. | Medium | Rebook/reschedule actions. | Start with rebook in V1.1. |
| Before-visit information | High. | Low/Medium | Initially static configuration/content; per-resource content only later. | V1.1 |
| Documents per reservation | Medium for special training, low for ordinary lane booking. | Medium/High | Document ownership/versioning/storage. | V1.2 only for a concrete document use case. |
| Add to personal calendar | High and broadly useful. | Low | Correct Warsaw timestamps and escaped ICS fields. | V1.1 |

## 5. Admin and operations audit

The current dashboard already answers the basic daily questions. The next
operational gain is not adding more counters but turning existing counters
into precise work queues and reducing duplicate data entry.

Highest time-saving improvements:

1. **Controlled admin-created reservation** for phone/front-desk bookings.
   It must use a dedicated audited writer with the same hierarchy lock,
   availability and pricing rules as public booking.
2. **Dashboard deep links and attention presets** for unpaid, expected,
   no-show, verification and event-waitlist work.
3. **Duplicate event into draft** for repeated trainings.
4. **Create reservation/block from Calendar context**, prefilling date, time
   and resource without silently writing.
5. **Filtered participant export** using the existing minimal DTO.
6. **Compact customer operational summary** in Users: last visit, completed
   visits, future bookings and cancellations, derived by a bounded aggregate
   contract rather than raw history fetch.

Bulk state changes are not a general V1.1 priority. They increase error impact
and audit complexity; use them only for a measured repetitive workflow.

## 6. Calendar improvements

Existing strengths include Today navigation, type/lane filters, type colors,
sticky headers, entry preview, source navigation and correct parent/child
capacity. Do not rebuild those features.

### Top 3

1. **Click empty slot → prepared action**: open a choice between a staff
   reservation and a lane block with date/resource/start prefilled. Final save
   remains explicit and uses the existing controlled writer.
2. **Explicit reschedule dialog**: prepare a new time, show conflicts and
   Before/After, then atomically save. Prefer this to drag-and-drop because it
   is clearer on mobile and safer under family locks.
3. **Operational state filter/badges**: add compact payment/attendance/attention
   cues without exposing extra PII or replacing existing type colors.

Drag-and-drop is not recommended now. It creates accidental mutation,
accessibility, touch and concurrency risks while the explicit workflow can
deliver most of the value.

## 7. Booking-flow improvements

The current progressive flow is understandable and should not be converted
into a multi-page wizard. Whole-axis versus position exclusivity, prices,
available hours and confirmation are already explicit.

Recommended refinements:

- Let known customers begin from `Book again` or a last-choice shortcut.
- Keep date/time/price authoritative and freshly loaded after every prefill.
- Show the exact cancellation deadline in confirmation and My Reservations.
- Add the pre-visit checklist and calendar download after success.
- On cancellation, offer a recovery CTA instead of ending the journey.

Do not auto-select a specific position merely because it was used previously;
present the remembered choice and let the customer confirm it.

## 8. Event / training improvements

| Feature | Assessment | Release |
|---|---|---|
| Duplicate event | High operational value; can reuse Event V2 create with a safe unsaved draft. | V1.1 |
| Recurring events | Valuable only after repeat patterns are quantified; requires series edit/cancel semantics. | V1.2/Later |
| Automatic reserve notification | Already triggered by cancellation and protected by claim/idempotency. | Existing — no rebuild |
| Participant management | Already strong; filtered export is the next practical gap. | V1.1/V1.2 |
| Event participant export | Useful for attendance desk and instructors once assignment exists. | V1.2; admin-only now |
| Event check-in | Real value for training days; reuse attendance concepts but needs event-specific status/audit design. | V1.2 |
| Documents | Useful for waivers/materials only with an approved content process. | Later |
| Reminders | High attendance value and shares the notification foundation. | V1.2 |
| Per-user registration limits | No current abuse/business evidence. | Later / do not build yet |
| Private/access-code events | New visibility and invitation semantics; no current requirement. | Later |
| More event fields | Avoid generic field growth; add only from a concrete workflow. | Later |

## 9. Check-in and front desk

- **Now:** the screen already supports date-based work, free search, token
  lookup, customer context, payment and attendance transitions.
- **V1.1:** add attention presets and preserve them in safe URL state.
- **V1.2:** add event check-in and a communication/delivery indicator if staff
  regularly resolves missing e-mails.
- **Later:** a reusable membership/user QR may reduce lookup time, but requires
  revocation, rotation and privacy UX.
- **Future integration:** NFC/PVC can map to a revocable opaque membership
  credential and the same lookup layer. Do not couple the current check-in
  token to a physical card.

## 10. Users / CRM-like features

Recommended scope is operational, not marketing surveillance.

| Candidate | Decision |
|---|---|
| Last completed visit | Recommend V1.2 through a bounded aggregate. |
| Completed/future/cancelled counts | Recommend V1.2; useful for support and retention. |
| Customer value | Later, only after revenue/payment semantics are formally defined. |
| Tags/segments | Do not add generic free-form segmentation now. |
| Operational notes | Existing admin note is sufficient; improve taxonomy only from a real workflow. |
| Account block | Requires explicit reasons, appeal/recovery and authorization; separate design. |
| Membership status | Only when CSK defines a membership product. |
| Documents/consents | Add only for specific legal/operational requirements with retention rules. |

No recommendation requires collecting new direct PII.

## 11. Automation audit

| Manual today | Automation | Value | Failure risk | Effort | Recommendation |
|---|---|---|---|---|---|
| Customer remembers reservation | Idempotent reminder 24h before start | High | Medium: duplicates, wrong timezone, cancelled bookings | 3/5 | V1.2 |
| Participant remembers training | Event reminder 24–48h before start | High | Medium | 3/5 | V1.2 on shared reminder foundation |
| Staff checks unpaid arrivals | Daily/near-term attention queue or digest | High operational | Low/Medium | 2/5 | V1.1 queue; V1.2 digest |
| Staff follows event reserve list | Cancellation-triggered notification | Already automated | Existing controlled residual | Existing | Close |
| Customer asks about payment | Reminder for explicitly unpaid future items | Medium | Medium: payment status can change | 3/5 | V1.2 after preferences |
| Staff compiles owner report | Scheduled weekly aggregate e-mail | Medium/High | Medium: stale/misdelivered report | 3/5 | V1.2, admin-only recipient allowlist |
| Staff repeats training setup | Duplicate draft now; true recurrence later | High | Low for draft, high for recurrence | 2/5 then 4/5 | V1.1 draft |
| Staff repeats closures/maintenance | Recurring lane blocks | Medium | High if an incorrect series blocks sales | 4/5 | Later with series preview/cancel |
| Historical date passes | Derive historical display from date/status | Already mostly derived | Low | Existing | Do not add needless status mutation jobs |

## 12. Communication UX

The product already sends transactional confirmation, cancellation,
registration and reserve-promotion e-mails with safe delivery controls.
Recommended evolution:

1. Add a concise pre-visit checklist and directions/rules link to confirmation
   surfaces.
2. Add opt-in reservation and event reminders on a shared idempotent job model.
3. Show staff a minimal delivery state/history when resolving a customer issue;
   do not expose provider bodies or tokens.
4. Keep cancellation confirmation and reserve notification transactional.
5. Defer SMS/push until e-mail reminder value and opt-in behavior are measured.

## 13. Mobile product experience

V1 mobile behavior is sound. A broad redesign is not justified.

- Put the next reservation/event and its check-in/calendar action above generic
  dashboard tiles when such an item exists.
- Keep `Book again` and `Choose another date` close to the completed/cancelled
  record rather than adding persistent bottom navigation.
- Add staff quick filters to the top of Check-in and Reservations.
- Prefer contextual sticky actions inside long forms/modals only where the
  primary action otherwise scrolls far off-screen.
- Reconsider bottom navigation only after analytics show frequent switching
  among three or more customer areas; today the dashboard cards are adequate.

## 14. Owner / business value — top opportunities

| Opportunity | Expected effect |
|---|---|
| Reservation reminders | Reduce no-show and unused capacity. |
| Book again | Increase repeat bookings with lower customer effort. |
| Admin-created phone/walk-in reservation | Capture offline demand without bypassing conflicts/audit. |
| Add to calendar | Reduce forgotten visits at very low cost. |
| Event duplication | Reduce setup time and make event sales more consistent. |
| Actionable attention queues | Reduce front-desk time spent searching. |
| Pre-visit instructions | Reduce support questions and arrival friction. |
| Calendar contextual creation | Shorten response to phone requests and maintenance needs. |
| Event participant export/check-in | Improve training-day operation. |
| Customer operational aggregates | Support retention decisions without collecting new PII. |

## 15. Do not build now

| Feature | Why not now | Cost / risk | When it may make sense |
|---|---|---|---|
| Full online payment/refund platform | Explicitly outside this audit; current model is operational payment status. | High financial, reconciliation and support risk. | After a separate monetization/payment architecture decision. |
| Drag-and-drop Calendar mutations | Explicit dialogs deliver most value with fewer accidental/concurrency/accessibility risks. | High regression and mobile complexity. | After contextual create/reschedule is proven insufficient. |
| NFC/PVC membership system | No membership credential/product model exists. | Hardware, privacy, lifecycle and support cost. | After membership requirements and revocation rules are approved. |
| Generic CRM/marketing automation suite | Would expand scope and data processing without demonstrated need. | High product and privacy cost. | When CSK has measured retention campaigns and consent requirements. |
| Booking-slot waitlist marketplace | Event waitlist exists, but resource-slot demand/fairness rules are different. | High notification, expiry and fairness complexity. | After analytics show material lost demand for specific slots. |

## 16. Technical enablers

| Feature | Required enabler |
|---|---|
| Add to calendar | Tested ICS serializer, Europe/Warsaw timestamps, escaping and snapshot values. No DB change. |
| Rebook / last choice | Versioned safe URL/prefill model; always resolve current resource config, price and availability. |
| Reminders | Notification preference model, idempotent job/outbox, scheduler, retry policy, cancellation invalidation and delivery observability. |
| Admin-created reservation | Dedicated role-gated RPC/API using current family locks, authoritative pricing, audit and customer lookup. |
| Duplicate event | Pure draft mapper initially; Event V2 create remains the only writer. |
| Participant export | Bounded admin export RPC or existing paginated contract orchestration, formula-safe CSV and a 5,000-row cap. |
| Calendar quick create/reschedule | Stable prefill contract and, for reschedule, an atomic audited writer with stale/conflict handling. |
| Customer operational aggregates | Minimal admin-only aggregate RPC; no browser fetch of full reservation history. |
| Scheduled reports | Admin recipient allowlist, aggregate snapshot, scheduler and delivery log. |

SaaS, tenant isolation, instructor assignment, retention, historical report
snapshots, final legal data and a full payment architecture are excluded. They
are mentioned only where they would become a hard dependency.

## 17. Priority scoring

Scores use 1–5, where effort/risk 1 is lowest.

| Recommendation | Business | User | Operations | Effort | Risk | Category |
|---|---:|---:|---:|---:|---:|---|
| Add reservation/event to calendar | 4 | 5 | 1 | 1 | 1 | QUICK WIN / V1.1 |
| Book again with safe prefill | 4 | 5 | 1 | 2 | 2 | QUICK WIN / V1.1 |
| Remember last booking choice | 3 | 4 | 1 | 1 | 1 | QUICK WIN / V1.1 |
| Exact cancellation deadline | 3 | 5 | 2 | 1 | 1 | QUICK WIN / V1.1 |
| Pre-visit checklist | 4 | 4 | 3 | 1 | 1 | QUICK WIN / V1.1 |
| Actionable dashboard deep links | 4 | 2 | 5 | 2 | 1 | QUICK WIN / V1.1 |
| Duplicate event draft | 4 | 1 | 5 | 2 | 2 | QUICK WIN / V1.1 |
| Participant CSV export | 3 | 1 | 4 | 2 | 2 | QUICK WIN / V1.2 |
| Check-in attention presets | 3 | 2 | 5 | 2 | 1 | QUICK WIN / V1.1 |
| Reservation reminders | 5 | 5 | 3 | 3 | 3 | V1.2 |
| Event reminders | 4 | 5 | 3 | 3 | 3 | V1.2 |
| Admin-created reservation | 5 | 3 | 5 | 4 | 4 | V1.2 |
| Calendar empty-slot actions | 4 | 2 | 5 | 3 | 3 | V1.2 |
| Controlled reschedule | 4 | 5 | 4 | 5 | 4 | V1.2 |
| Event check-in | 4 | 3 | 5 | 4 | 3 | V1.2 |
| Customer operational aggregates | 3 | 1 | 4 | 3 | 2 | V1.2 |
| Scheduled owner report | 3 | 1 | 4 | 3 | 3 | V1.2 |
| Recurring event series | 3 | 2 | 4 | 4 | 4 | LATER |
| Recurring lane blocks | 2 | 1 | 4 | 4 | 4 | LATER |
| Booking-slot waitlist | 4 | 4 | 2 | 5 | 4 | LATER |

## 18. Ranked recommendations

### Top 5 quick wins

1. Add reservation/event to calendar.
2. Book again with authoritative revalidation.
3. Show exact cancellation deadline.
4. Add a concise pre-visit checklist.
5. Open dashboard attention tiles with exact filters.

### Top 5 customer improvements

1. Book again.
2. Add to personal calendar.
3. Reservation/event reminders.
4. Exact deadline plus easier choose-another-date recovery.
5. Pre-visit checklist and directions/rules.

### Top 5 admin improvements

1. Controlled admin-created phone/walk-in reservation.
2. Actionable dashboard queues.
3. Duplicate event draft.
4. Calendar empty-slot create actions.
5. Filtered participant CSV export.

### Top 5 automations

1. Reservation reminder 24h before start.
2. Event reminder 24–48h before start.
3. Daily staff attention digest based on existing statuses.
4. Scheduled bounded owner report.
5. Payment reminder for explicitly unpaid future items.

### Top 10 product improvements overall

| # | Feature | Current problem | Proposed solution | User | Business | Ops | Effort | Risk | Dependencies | Release |
|---:|---|---|---|---:|---:|---:|---:|---:|---|---|
| 1 | Book again | Repeat customers rebuild the whole booking. | Preference-only prefill with fresh config/price/availability. | 5 | 4 | 1 | 2 | 2 | Prefill contract | V1.1 |
| 2 | Add to calendar | Confirmed visits remain easy to forget. | Download safe ICS for reservations and registered events. | 5 | 4 | 1 | 1 | 1 | ICS serializer | V1.1 |
| 3 | Reservation reminders | Customers must remember the visit themselves. | Opt-in idempotent 24h reminder. | 5 | 5 | 3 | 3 | 3 | Notification foundation | V1.2 |
| 4 | Actionable dashboard queues | Staff repeats filtering after opening a KPI. | Safe deep links and attention presets. | 2 | 4 | 5 | 2 | 1 | URL filter contract | V1.1 |
| 5 | Admin-created reservation | Phone/walk-in demand lacks a dedicated controlled path. | Audited admin writer reusing family locks/pricing. | 3 | 5 | 5 | 4 | 4 | New DB/API contract | V1.2 |
| 6 | Duplicate event draft | Repeat training details are retyped. | Copy safe fields into an unsaved Event V2 draft. | 1 | 4 | 5 | 2 | 2 | Draft mapper | V1.1 |
| 7 | Pre-visit checklist | Transaction data does not answer all arrival questions. | Concise checklist, rules and directions on confirmation surfaces. | 4 | 4 | 3 | 1 | 1 | Approved content | V1.1 |
| 8 | Calendar empty-slot action | Staff leaves Calendar and rebuilds date/resource context. | Prefilled reservation/block draft from an empty cell. | 2 | 4 | 5 | 3 | 3 | Prefill + controlled writers | V1.2 |
| 9 | Event participant export | Filtered participant work cannot be exported. | PII-minimal, formula-safe filtered CSV. | 1 | 3 | 4 | 2 | 2 | Bounded export contract | V1.2 |
| 10 | Event reminders / check-in | Training-day attendance is still communication/front-desk work. | Shared reminder foundation, then event attendance workflow. | 4 | 4 | 5 | 4 | 3 | Notifications + event status design | V1.2 |

## 19. Recommended CSK Booking V1.1

Keep V1.1 to five compatible improvements:

1. **Add to calendar** for future reservations and registered/approved events.
2. **Book again / choose another date** with a safe, non-authoritative prefill.
3. **Exact cancellation deadline plus pre-visit checklist** on confirmation and
   future-item details.
4. **Actionable admin dashboard queues and check-in presets** using safe URL
   filters.
5. **Duplicate event into an unsaved draft**, preserving Event V2 as the only
   writer.

This scope improves repeat conversion and daily operations without a new broad
module. Items 1–3 can be delivered without DB changes. Item 4 should first try
existing filters; item 5 can reuse the current create payload and should not
copy identifiers, status, date or participants.

## 20. Final recommendation

```text
PRODUCT IMPROVEMENT AUDIT:
COMPLETE

CURRENT V1:
FEATURE COMPLETE / PRODUCTION READY

TOP QUICK WINS:
1. Add reservation/event to calendar.
2. Book again with current-price and availability revalidation.
3. Show the exact cancellation deadline.
4. Add a concise pre-visit checklist.
5. Open admin attention tiles with exact filters.

TOP PRODUCT IMPROVEMENTS:
1. Book again.
2. Add to calendar.
3. Reservation reminders.
4. Actionable dashboard work queues.
5. Controlled admin-created reservation.
6. Duplicate event draft.
7. Pre-visit checklist and cancellation deadline.
8. Calendar empty-slot quick actions.
9. Safe participant CSV export.
10. Event reminders and event check-in.

RECOMMENDED V1.1 SCOPE:
1. Add to calendar.
2. Book again / choose another date.
3. Cancellation deadline and pre-visit checklist.
4. Actionable dashboard queues and check-in presets.
5. Duplicate event draft.

DO NOT BUILD YET:
1. Full online payment/refund platform.
2. Drag-and-drop Calendar mutations.
3. NFC/PVC membership system.

RECOMMENDED FIRST NEXT TASK:
Implement tested Add to calendar (.ics) actions for future reservations and
registered/approved events, using existing snapshot data and Europe/Warsaw
times.

DB CHANGE REQUIRED FOR FIRST TASK:
NO
```
