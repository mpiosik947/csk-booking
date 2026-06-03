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

export function isPaidPaymentStatus(status: string | null | undefined) {
  return (
    status === PAYMENT_STATUS.PAID || status === PAYMENT_STATUS.PAID_ON_SITE
  );
}

export function getPaymentStatusLabel(status: string | null | undefined) {
  switch (status) {
    case PAYMENT_STATUS.PAY_ON_SITE:
      return "Płatność na miejscu";
    case PAYMENT_STATUS.PAID:
    case PAYMENT_STATUS.PAID_ON_SITE:
      return "Opłacona";
    case PAYMENT_STATUS.UNPAID:
      return "Nieopłacona";
    case PAYMENT_STATUS.FREE:
      return "Darmowa";
    case PAYMENT_STATUS.VOUCHER:
      return "Voucher";
    default:
      return status || "Brak statusu";
  }
}

export function getPaymentStatusBadgeClass(status: string | null | undefined) {
  switch (status) {
    case PAYMENT_STATUS.PAID:
    case PAYMENT_STATUS.PAID_ON_SITE:
      return "border-green-700 bg-green-950 text-green-300";
    case PAYMENT_STATUS.PAY_ON_SITE:
      return "border-yellow-700 bg-yellow-950 text-yellow-300";
    case PAYMENT_STATUS.UNPAID:
      return "border-red-700 bg-red-950 text-red-300";
    case PAYMENT_STATUS.FREE:
      return "border-blue-700 bg-blue-950 text-blue-300";
    case PAYMENT_STATUS.VOUCHER:
      return "border-purple-700 bg-purple-950 text-purple-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }
}