import "server-only";

// Only the display name is platform branding; the configured mailbox is preserved.
export function getOperationalEmailSenderConfiguration(environment: NodeJS.ProcessEnv = process.env) {
  // Optional for backwards compatibility. If configured, accept one bare mailbox only.
  const configuredReplyTo = environment.RESERVATION_EMAIL_REPLY_TO;
  const replyTo = configuredReplyTo?.trim();
  const invalidReplyTo = configuredReplyTo !== undefined && (
    /[\r\n]/.test(configuredReplyTo) ||
    !replyTo || !/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/.test(replyTo)
  );
  const configuredFrom = environment.RESERVATION_EMAIL_FROM?.trim();
  const mailbox = configuredFrom?.match(/^[^<>\r\n]*<([^<>\s]+@[^<>\s]+)>$/)?.[1]
    ?? (configuredFrom && /^[^<>\s]+@[^<>\s]+$/.test(configuredFrom) ? configuredFrom : undefined);
  return {
    resendApiKey: environment.RESEND_API_KEY?.trim(),
    from: mailbox && !invalidReplyTo && environment.VERCEL_ENV !== "preview"
      ? `StrzelajTu.pl <${mailbox}>` : undefined,
    ...(replyTo && !invalidReplyTo ? { replyTo } : {}),
  };
}
