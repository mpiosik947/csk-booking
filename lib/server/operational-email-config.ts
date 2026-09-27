import "server-only";

// Current sender is preserved; no provider/display-name configuration cutover.
export function getOperationalEmailSenderConfiguration(environment: NodeJS.ProcessEnv = process.env) {
  return { resendApiKey: environment.RESEND_API_KEY?.trim(), from: environment.RESERVATION_EMAIL_FROM?.trim() };
}
