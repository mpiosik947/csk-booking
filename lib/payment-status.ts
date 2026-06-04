export const PAYMENT_STATUS = {
  PAY_ON_SITE: "pay_on_site",
  PAID: "paid",
  PAID_ON_SITE: "paid_on_site",
  UNPAID: "unpaid",
  FREE: "free",
  VOUCHER: "voucher",
} as const;

export type PaymentStatus =
  (typeof PAYMENT_STATUS)[keyof typeof PAYMENT_STATUS];

export const PAYMENT_STATUSES = Object.values(PAYMENT_STATUS);

export const PAYMENT_STATUS_LABELS: Record<PaymentStatus, string> = {
  [PAYMENT_STATUS.PAY_ON_SITE]: "Płatność na miejscu",
  [PAYMENT_STATUS.PAID]: "Opłacona",
  [PAYMENT_STATUS.PAID_ON_SITE]: "Opłacona",
  [PAYMENT_STATUS.UNPAID]: "Nieopłacona",
  [PAYMENT_STATUS.FREE]: "Darmowa",
  [PAYMENT_STATUS.VOUCHER]: "Voucher",
};

export const PAYMENT_STATUS_BADGE_CLASSES: Record<PaymentStatus, string> = {
  [PAYMENT_STATUS.PAY_ON_SITE]:
    "border-yellow-700 bg-yellow-950 text-yellow-300",
  [PAYMENT_STATUS.PAID]: "border-green-700 bg-green-950 text-green-300",
  [PAYMENT_STATUS.PAID_ON_SITE]:
    "border-green-700 bg-green-950 text-green-300",
  [PAYMENT_STATUS.UNPAID]: "border-red-700 bg-red-950 text-red-300",
  [PAYMENT_STATUS.FREE]: "border-blue-700 bg-blue-950 text-blue-300",
  [PAYMENT_STATUS.VOUCHER]: "border-purple-700 bg-purple-950 text-purple-300",
};

export function isPaymentStatus(
  status: string | null | undefined,
): status is PaymentStatus {
  if (!status) return false;

  return PAYMENT_STATUSES.includes(status as PaymentStatus);
}

export function isPaidPaymentStatus(status: string | null | undefined) {
  return (
    status === PAYMENT_STATUS.PAID || status === PAYMENT_STATUS.PAID_ON_SITE
  );
}

export function getPaymentStatusLabel(status: string | null | undefined) {
  if (!status) return "Brak statusu";

  if (isPaymentStatus(status)) {
    return PAYMENT_STATUS_LABELS[status];
  }

  return status;
}

export function getPaymentStatusBadgeClass(
  status: string | null | undefined,
) {
  if (!status) {
    return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }

  if (isPaymentStatus(status)) {
    return PAYMENT_STATUS_BADGE_CLASSES[status];
  }

  return "border-zinc-700 bg-zinc-900 text-zinc-300";
}