import { createHash } from "node:crypto";
/** Claim IDs rotate; the invitation token identifies the SAME logical invitation.
 * Hash the token so it is not disclosed in provider idempotency metadata.
 */
export function eventInvitationKey(tenantId: string, registrationId: string, invitationToken: string) {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (![tenantId, registrationId, invitationToken].every(v => typeof v === "string" && uuid.test(v))) throw new Error("Invalid invitation");
  return `reserve-promotion/${tenantId}/${registrationId}/${createHash("sha256").update(invitationToken).digest("hex")}`;
}
