import { test, expect } from "@playwright/test";

test("anonymous cancellation receipt is denied without a send", async ({ request }) => {
  const response = await request.post("/api/send-event-cancellation", { data: { registrationId: "10000000-0000-4000-8000-000000000001" } });
  expect(response.status()).toBe(401);
  expect(response.headers()["cache-control"]).toBe("private, no-store, max-age=0, must-revalidate");
});

test("forged authority fields rejected before auth or provider calls", async ({ request }) => {
  for (const extra of [{ tenantId: "forged" }, { email: "nobody@example.invalid" }, { userId: "forged" }]) {
    const response = await request.post("/api/send-event-cancellation", { headers: { Authorization: "Bearer synthetic-invalid" },
      data: { registrationId: "10000000-0000-4000-8000-000000000001", ...extra } });
    expect(response.status()).toBe(400);
  }
});

test("GET never starts a cancellation receipt", async ({ request }) => {
  expect((await request.get("/api/send-event-cancellation")).status()).toBe(405);
});
