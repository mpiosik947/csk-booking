import { expect, test } from "@playwright/test";

const APPROVED_FIELDS = [
  "booking_step_minutes",
  "currency_code",
  "display_name",
  "display_order",
  "durations_minutes",
  "effective_online_bookable",
  "lane_id",
  "max_people_online",
  "name",
  "parent_lane_id",
  "positions_bookable",
  "pricing",
  "resource_kind",
  "whole_lane_bookable",
].sort();

test("public booking uses the argument-free, PII-free configuration contract", async ({
  page,
}) => {
  const responsePromise = page.waitForResponse((response) =>
    response.url().includes("/rest/v1/rpc/get_public_booking_configuration_v1")
  );

  const navigation = await page.goto("/booking");
  expect(navigation?.status()).toBe(200);

  const response = await responsePromise;
  expect(response.status()).toBe(200);
  expect(response.request().postDataJSON()).toEqual({});

  const payload = await response.json();
  expect(Array.isArray(payload)).toBe(true);
  for (const row of payload as Record<string, unknown>[]) {
    expect(Object.keys(row).sort()).toEqual(APPROVED_FIELDS);
  }

  await expect(
    page.getByRole("heading", { name: "Zarezerwuj oś" })
  ).toBeVisible();
  await expect(page.getByText("Ładowanie konfiguracji rezerwacji...")).toBeHidden();
  const controlledError = page.getByText(
    "Nie udało się pobrać aktualnej konfiguracji rezerwacji. Spróbuj ponownie."
  );
  if (await controlledError.isVisible()) {
    await expect(controlledError).toBeVisible();
  } else {
    await expect(
      page
        .getByRole("region", { name: "Formularz rezerwacji" })
        .or(page.getByText("Brak aktywnych osi do rezerwacji."))
    ).toBeVisible();
  }
});
