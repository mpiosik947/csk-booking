import { test, expect } from "@playwright/test";

test("event-wide cancellation requires authentication and GET has no side effect", async ({ request }) => {
  const response = await request.post("/api/cancel-event", { data: { eventId: "10000000-0000-4000-8000-000000000001", retry: false } });
  expect(response.status()).toBe(401);
  expect(response.headers()["cache-control"]).toBe("private, no-store, max-age=0, must-revalidate");
  expect((await request.get("/api/cancel-event")).status()).toBe(405);
});

test("event-wide cancellation rejects caller-selected authority before any RPC", async ({ request }) => {
  for (const extra of [{ tenantId: "forged" }, { userId: "forged" }, { email: "nobody@example.invalid" }]) {
    const response = await request.post("/api/cancel-event", {
      headers: { Authorization: "Bearer synthetic-invalid" },
      data: { eventId: "10000000-0000-4000-8000-000000000001", retry: false, ...extra },
    });
    expect(response.status()).toBe(400);
  }
});
