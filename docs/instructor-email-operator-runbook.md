# Instructor email exceptional retry

This runbook uses the existing protected delivery path for already-created instructor email obligations. It does not authorize production execution by itself. Obtain explicit approval for the event and real email send before executing a batch. No scheduler or suspended-tenant panel is introduced.

## Resource and authority

`eventId` is a resource selector, not authority. The database resolves the event, derives its tenant, and verifies the caller. The request must contain only `eventId`; never supply tenant IDs, user IDs, recipients, instructor IDs or delivery IDs as authority or delivery scope.

Use an existing authenticated account with an active admin or employee membership in the event's tenant. An operator title, Platform Admin status or possession of a service-role key does not substitute for that membership. If no suitable approved account exists, STOP; do not grant a membership, impersonate a user or call worker RPCs directly to bypass authorization.

The normal tenant panel remains blocked during suspension. This exceptional server action grants no event management, participant, instructor-panel or assignment access.

## When retry is appropriate

Use this procedure after an interrupted or failed immediate dispatch, or to process another bounded batch. The obligations must already exist from canonical business transitions.

- Active tenant: the existing claim contract selects eligible assignment, removal and cancellation obligations for the event. Approve that entire eligible event batch; this endpoint cannot select a single delivery type.
- Suspended tenant: only existing removal and event-cancellation obligations can be admitted. Assignment remains denied.
- Canonical `disabled` (inactive) or `dormant`: authorization and new claims are denied. Do not reactivate the tenant as a workaround.

## Read only inspection

An authorized DB operator may run the following SELECT in a read-only transaction. Replace the placeholder with the approved event UUID. Do not select recipient addresses, participant data, tokens or message bodies.

```sql
begin read only;
select e.id as event_id, e.tenant_id, t.status as tenant_status,
       d.id as delivery_id, d.record_id as assignment_generation,
       d.message_type, d.delivery_state, d.attempt_count,
       d.attempt_window_started_at, d.claim_expires_at,
       d.sent_at, d.last_error_code,
       d.message_type || '/' || d.record_id::text as provider_identity
from public.events e
join public.tenants t on t.id = e.tenant_id
join public.event_instructors i on i.event_id = e.id and i.tenant_id = e.tenant_id
join public.email_deliveries d on d.record_id = i.id and d.tenant_id = i.tenant_id
  and d.recipient_user_id = i.instructor_user_id
where e.id = '<approved-event-uuid>'::uuid
  and d.message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation')
order by d.id;
rollback;
```

Retain only the technical snapshot in restricted operational evidence. Compare the complete set of `(delivery_id, message_type, assignment_generation, provider_identity)` before and after. No new logical row or identity may appear because of retry. Coordinate against concurrent legitimate business transitions; if they occur, stop and reconcile before another batch.

## Protected action

Execute exactly one HTTPS request through an approved operator HTTP client:

```http
POST https://strzelajtu.pl/api/send-instructor-emails
Authorization: Bearer <approved-account-current-access-token>
Content-Type: application/json

{"eventId":"<approved-event-uuid>"}
```

Inject the short-lived account token through the client's protected secret input. Never paste it into this runbook, logs, shell history, screenshots or tickets. Do not use service_role as the request bearer. Do not obtain someone else's browser token. Discard the token from the operator client afterward.

The route verifies Auth and DB authorization before the existing server-only mechanism calls claim/read/complete. The DB selects existing obligations, derives recipients and enforces tenant/generation/lifecycle binding. Nothing in this procedure creates assignments or obligations or modifies event state.

## Response and follow up

Successful processing returns HTTP 200 with `{"delivery":{"sent":0,"attempted":0,"pending":false}}` (counts vary). At most five attempts are claimed per call. `sent` counts confirmed provider success plus successful completion, not inbox delivery. `pending` is a batch hint, not an authoritative queue count. Zero attempts may mean ineligible, leased, exhausted or no remaining obligations; inspect rather than blindly repeat.

HTTP 400 means invalid request, 401 invalid/missing authentication, 403 unavailable or unauthorized resource, and 503 processing unavailable. A timeout or 503 can occur after admission or provider activity: do not assume zero sends.

Re-run the read-only inspection. Confirm unchanged logical identities and inspect states. Active leases last five minutes; do not clear or steal them. Retry is bounded to three attempts and a 23-hour window from first admission. The provider key stays `message_type/assignment_id`. Provider uncertainty is not `sent` and is not exactly-once; reconcile provider metadata through authorized tooling before another attempt. Never invent a new key, manually reset attempts, insert delivery rows or replay business transitions.

An admitted assignment attempt may finish after a later cancellation/removal/suspension. There is no recall guarantee. Every new admission rechecks eligibility. Existing removal/cancellation continuity never restores protected UI access.

## Stop conditions

STOP on missing approval/account authority, unexpected event or tenant, disabled/dormant lifecycle, missing obligations, unexpected new identities, exhausted attempts/window, uncertain provider outcome not reconciled, privacy cleanup or concurrent business changes affecting the snapshot. Missing rows after retention must not be recreated. Sent history must not be rewritten. Escalate the result; do not add a scheduler, bypass or second delivery implementation.
