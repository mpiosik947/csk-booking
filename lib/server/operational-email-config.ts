import "server-only";

// Only the display name is platform branding; the configured mailbox is preserved.
export function getOperationalEmailSenderConfiguration(environment: NodeJS.ProcessEnv = process.env) {
  const configuredFrom = environment.RESERVATION_EMAIL_FROM?.trim();
  const mailbox = configuredFrom?.match(/^[^<>\r\n]*<([^<>\s]+@[^<>\s]+)>$/)?.[1]
    ?? (configuredFrom && /^[^<>\s]+@[^<>\s]+$/.test(configuredFrom) ? configuredFrom : undefined);
  return {
    resendApiKey: environment.RESEND_API_KEY?.trim(),
    from: mailbox ? `StrzelajTu.pl <${mailbox}>` : undefined,
  };
}
