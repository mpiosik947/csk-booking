import assert from "node:assert/strict";
import test from "node:test";
import {
  EVENT_REGISTRATION_STATUS,
  getEventRegistrationStatusPresentation,
} from "./event-registration-status.ts";
import { getPaymentStatusLabel } from "./payment-status.ts";

const expected = [
  [EVENT_REGISTRATION_STATUS.REGISTERED, "Zapisany", true, true, true],
  [EVENT_REGISTRATION_STATUS.APPROVED, "Zatwierdzony", true, true, false],
  [EVENT_REGISTRATION_STATUS.RESERVE, "Lista rezerwowa", false, true, false],
  [EVENT_REGISTRATION_STATUS.CANCELLED, "Anulowany", false, false, false],
];

for (const [
  status,
  label,
  occupiesPlace,
  userCanCancel,
  adminCanApprove,
] of expected) {
  test(`${status} has one canonical presentation and action contract`, () => {
    const presentation = getEventRegistrationStatusPresentation(status);

    assert.equal(presentation.label, label);
    assert.equal(presentation.occupiesPlace, occupiesPlace);
    assert.equal(presentation.userCanCancel, userCanCancel);
    assert.equal(presentation.adminCanApprove, adminCanApprove);
  });
}

test("legacy participant remains explicit without changing capacity semantics", () => {
  const presentation = getEventRegistrationStatusPresentation("participant");

  assert.equal(presentation.label, "Uczestnik");
  assert.equal(presentation.occupiesPlace, false);
  assert.equal(presentation.userCanCancel, true);
});

test("unknown values fail closed and are not rendered verbatim", () => {
  const presentation = getEventRegistrationStatusPresentation("<script>");

  assert.equal(presentation.status, null);
  assert.equal(presentation.label, "Nieznany status");
  assert.equal(presentation.userCanCancel, false);
  assert.equal(presentation.adminCanCancel, false);
});

test("event payment states retain their canonical Polish labels", () => {
  assert.equal(getPaymentStatusLabel("pay_on_site"), "Płatność na miejscu");
  assert.equal(getPaymentStatusLabel("paid"), "Opłacone");
  assert.equal(getPaymentStatusLabel("paid_on_site"), "Opłacone na miejscu");
  assert.equal(getPaymentStatusLabel("unpaid"), "Nieopłacone");
  assert.equal(getPaymentStatusLabel("free"), "Gratis");
  assert.equal(getPaymentStatusLabel("voucher"), "Voucher");
});
