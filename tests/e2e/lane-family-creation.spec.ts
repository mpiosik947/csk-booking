import { randomUUID } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Locator, type Page } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const environment = getLocalSupabaseTestEnvironment();
const service = createClient(environment.supabaseUrl, environment.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const standaloneName = "[TEST] Oś samodzielna 25m";
const hierarchyName = "[TEST] Oś 50m hierarchia";
const positionNames = [
  "[TEST] Stanowisko 1",
  "[TEST] Stanowisko 2",
  "[TEST] Stanowisko 3",
];
const invalidNames = [
  "[TEST] Walidacja brak nazwy",
  "[TEST] Walidacja pojemność",
  "[TEST] Walidacja limit",
  "[TEST] Walidacja cena",
  "[TEST] Walidacja luka",
  "[TEST] Walidacja overlap",
  "[TEST] Walidacja czas",
  "[TEST] Walidacja stanowisko",
  "[TEST] Atomowość rodziny osi",
  "[TEST] Security rodziny osi",
];
const runMarker = `${Date.now()}-${randomUUID().slice(0, 8)}`;
const adminEmail = `test-lane-family-admin-${runMarker}@example.invalid`;
const userEmail = `test-lane-family-user-${runMarker}@example.invalid`;
const password = `Local-E2E-${randomUUID()}!Aa1`;

let adminUserId = "";
let regularUserId = "";
let adminClient: SupabaseClient;
let regularUserClient: SupabaseClient;

function assertNoError(error: { message: string } | null, context: string) {
  if (error) throw new Error(`${context}: ${error.message}`);
}

async function cleanupStaleTestUsers() {
  const { data, error } = await service.auth.admin.listUsers({
    page: 1,
    perPage: 1000,
  });
  assertNoError(error, "list local test users");
  const staleUsers = data.users.filter(
    (user) => user.user_metadata?.test_marker === "[TEST][LANE-FAMILY-E2E]"
  );
  for (const user of staleUsers) {
    const { error: deleteError } = await service.auth.admin.deleteUser(user.id);
    assertNoError(deleteError, "delete stale local test user");
  }
}

async function createLocalTestUser(email: string, role: "admin" | "user") {
  const { data, error } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { test_marker: "[TEST][LANE-FAMILY-E2E]" },
  });
  assertNoError(error, `create local ${role}`);
  if (!data.user) throw new Error(`Local ${role} was not created.`);

  const { error: profileError } = await service.from("profiles").upsert(
    {
      user_id: data.user.id,
      first_name: "[TEST]",
      last_name: role === "admin" ? "Administrator E2E" : "Użytkownik E2E",
      full_name:
        role === "admin"
          ? "[TEST] Administrator E2E"
          : "[TEST] Użytkownik E2E",
      email,
      role,
    },
    { onConflict: "user_id" }
  );
  assertNoError(profileError, `create local ${role} profile`);
  return data.user.id;
}

async function authenticatedClient(email: string) {
  const client = createClient(environment.supabaseUrl, environment.anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error } = await client.auth.signInWithPassword({ email, password });
  assertNoError(error, `sign in ${email}`);
  return client;
}

async function attachLocalOnlyNetworkGuard(page: Page) {
  const forbidden: string[] = [];
  await page.route("**/*", async (route) => {
    const hostname = new URL(route.request().url()).hostname.toLowerCase();
    if (hostname.endsWith(".supabase.co")) {
      forbidden.push(hostname);
      await route.abort("blockedbyclient");
      return;
    }
    await route.continue();
  });
  return forbidden;
}

async function loginAsAdmin(page: Page) {
  const forbidden = await attachLocalOnlyNetworkGuard(page);
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(adminEmail);
  await page.getByLabel("Hasło").fill(password);
  await page.getByRole("button", { name: "Zaloguj się" }).click();
  await expect(page).toHaveURL(/\/dashboard$/u);
  await page.goto("/admin/lane-configuration");
  await expect(page.getByRole("heading", { name: "Konfiguracja osi" })).toBeVisible();
  await expect(page.getByRole("button", { name: "+ Dodaj nową oś" })).toBeEnabled();
  expect(forbidden, "No browser request may reach *.supabase.co").toEqual([]);
  return forbidden;
}

async function openCreateDialog(page: Page) {
  await page.getByRole("button", { name: "+ Dodaj nową oś" }).click();
  const dialog = page.getByRole("dialog", { name: "Dodaj nową oś" });
  await expect(dialog).toBeVisible();
  return dialog;
}

function sectionForHeading(scope: Locator, heading: string) {
  return scope
    .getByRole("heading", { name: heading, exact: true })
    .locator("xpath=ancestor::section[1]");
}

async function setCheckbox(scope: Locator, label: string, checked: boolean) {
  const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const checkbox = scope.getByRole("checkbox", {
    name: new RegExp(`^${escapedLabel}`, "u"),
  });
  if ((await checkbox.isChecked()) !== checked) await checkbox.click();
}

async function fillPricingGroup(
  resource: Locator,
  dayGroup: "Pon–Czw" | "Pt–Nd",
  maxPeople: number,
  price: number
) {
  const group = sectionForHeading(resource, dayGroup);
  await group.getByLabel("Od osób", { exact: true }).fill("1");
  await group.getByLabel("Do osób", { exact: true }).fill(String(maxPeople));
  await group
    .getByLabel("Opis progu", { exact: true })
    .fill(maxPeople === 1 ? "1 osoba" : `1–${maxPeople} osób`);
  await group.getByLabel("Cena PLN/h", { exact: true }).fill(String(price));
}

async function fillResource(
  resource: Locator,
  options: {
    kind: "lane" | "position";
    name: string;
    capacity: number;
    maxPeople: number;
    durations: number[];
    weekdayPrice: number;
    weekendPrice: number;
    active: boolean;
    online: boolean;
  }
) {
  await resource
    .getByLabel(options.kind === "lane" ? "Nazwa osi" : "Nazwa stanowiska", {
      exact: true,
    })
    .fill(options.name);
  await resource
    .getByLabel(
      options.kind === "lane" ? "Pojemność osi" : "Pojemność stanowiska",
      { exact: true }
    )
    .fill(String(options.capacity));
  await resource
    .getByLabel("Maks. osób w jednej rezerwacji", { exact: true })
    .fill(String(options.maxPeople));
  await resource.getByLabel("Krok rezerwacji (min)", { exact: true }).fill("60");
  await setCheckbox(resource, "Aktywny zasób", options.active);
  await setCheckbox(resource, "Rezerwacje online", options.online);

  let durationInputs = resource.getByLabel("Czas rezerwacji w minutach", {
    exact: true,
  });
  while ((await durationInputs.count()) < options.durations.length) {
    await resource.getByRole("button", { name: "+ Dodaj czas", exact: true }).click();
    durationInputs = resource.getByLabel("Czas rezerwacji w minutach", {
      exact: true,
    });
  }
  for (let index = 0; index < options.durations.length; index += 1) {
    await durationInputs.nth(index).fill(String(options.durations[index]));
  }

  await fillPricingGroup(resource, "Pon–Czw", options.maxPeople, options.weekdayPrice);
  await fillPricingGroup(resource, "Pt–Nd", options.maxPeople, options.weekendPrice);
}

async function fillValidStandalone(dialog: Locator, name: string) {
  const root = sectionForHeading(dialog, "Oś główna");
  await fillResource(root, {
    kind: "lane",
    name,
    capacity: 4,
    maxPeople: 4,
    durations: [60, 120],
    weekdayPrice: 60,
    weekendPrice: 70,
    active: false,
    online: false,
  });
  await setCheckbox(root, "Rezerwacja całej osi", true);
  await setCheckbox(root, "Rezerwacja stanowisk", false);
  return root;
}

async function familyRows(rootName: string) {
  const { data: roots, error } = await service
    .from("shooting_lanes")
    .select("*")
    .eq("name", rootName)
    .eq("resource_kind", "lane");
  assertNoError(error, `read ${rootName}`);
  expect(roots).toHaveLength(1);
  const root = roots![0];
  const { data: children, error: childrenError } = await service
    .from("shooting_lanes")
    .select("*")
    .eq("parent_lane_id", root.id)
    .order("display_order");
  assertNoError(childrenError, `read children ${rootName}`);
  return { root, children: children ?? [] };
}

async function relatedConfiguration(laneIds: string[]) {
  const [rules, durations, pricing] = await Promise.all([
    service.from("lane_booking_rules").select("*").in("lane_id", laneIds),
    service
      .from("lane_booking_durations")
      .select("*")
      .in("lane_id", laneIds)
      .order("duration_minutes"),
    service
      .from("lane_pricing_rules")
      .select("*")
      .in("lane_id", laneIds)
      .order("day_group")
      .order("min_shooters"),
  ]);
  assertNoError(rules.error, "read booking rules");
  assertNoError(durations.error, "read durations");
  assertNoError(pricing.error, "read pricing");
  return {
    rules: rules.data ?? [],
    durations: durations.data ?? [],
    pricing: pricing.data ?? [],
  };
}

function validWriteResource(name: string, maxPeople = 4) {
  return {
    name,
    is_active: false,
    online_bookable: false,
    max_shooters: maxPeople,
    max_people_online: maxPeople,
    booking_step_minutes: 60,
    durations_minutes: [60, 120],
    pricing: [
      {
        day_group: "mon_thu",
        min_shooters: 1,
        max_shooters: maxPeople,
        label: `1–${maxPeople} osób`,
        hourly_price: 60,
      },
      {
        day_group: "fri_sun",
        min_shooters: 1,
        max_shooters: maxPeople,
        label: `1–${maxPeople} osób`,
        hourly_price: 70,
      },
    ],
  };
}

async function tableCounts() {
  const tables = [
    "shooting_lanes",
    "lane_booking_rules",
    "lane_booking_durations",
    "lane_pricing_rules",
  ];
  const result: Record<string, number> = {};
  for (const table of tables) {
    const { count, error } = await service
      .from(table)
      .select("*", { count: "exact", head: true });
    assertNoError(error, `count ${table}`);
    result[table] = count ?? -1;
  }
  return result;
}

async function expectNoResource(name: string) {
  const { count, error } = await service
    .from("shooting_lanes")
    .select("id", { count: "exact", head: true })
    .eq("name", name);
  assertNoError(error, `check absence ${name}`);
  expect(count).toBe(0);
}

test.describe.serial("local admin lane-family creation", () => {
  test.beforeAll(async () => {
    await cleanupStaleTestUsers();
    adminUserId = await createLocalTestUser(adminEmail, "admin");
    regularUserId = await createLocalTestUser(userEmail, "user");
    adminClient = await authenticatedClient(adminEmail);
    regularUserClient = await authenticatedClient(userEmail);
  });

  test.afterAll(async () => {
    if (adminUserId) await service.auth.admin.deleteUser(adminUserId);
    if (regularUserId) await service.auth.admin.deleteUser(regularUserId);
  });

  test("scenario 1: standalone lane survives details, edit and refresh", async ({
    page,
  }) => {
    const forbidden = await loginAsAdmin(page);
    const dialog = await openCreateDialog(page);
    await expect(
      dialog.getByRole("radio", { name: /^Samodzielna/u })
    ).toBeChecked();
    await fillValidStandalone(dialog, standaloneName);
    await expect(
      dialog.getByRole("button", { name: "Przejdź do podsumowania" })
    ).toBeEnabled();
    await dialog.getByRole("button", { name: "Przejdź do podsumowania" }).click();
    const review = page.getByRole("dialog", { name: "Sprawdź pełną konfigurację" });
    await expect(review).toBeVisible();
    await expect(review).toContainText(standaloneName);
    await expect(review).toContainText("oś główna i 0 stanowisk");
    await expect(review).toContainText("Nieaktywny");
    await expect(review).toContainText("Wyłączone");
    await expect(review).toContainText("Rezerwacja całej osi: Włączona");
    await expect(review).toContainText("Rezerwacja stanowisk: Wyłączona");
    await review.getByRole("button", { name: "Utwórz rodzinę osi" }).click();

    await expect(page.getByRole("status")).toContainText(
      "Nowa rodzina osi została utworzona."
    );
    const card = page
      .getByRole("heading", { name: standaloneName, exact: true })
      .locator("xpath=ancestor::article[1]");
    await expect(card).toContainText("Nieaktywna");
    await expect(card).toContainText("Offline");
    await card.getByRole("button", { name: "Szczegóły" }).click();
    const details = page.getByRole("dialog", { name: standaloneName });
    await expect(details).toContainText("60 min");
    await expect(details).toContainText("120 min");
    await expect(details).toContainText("60");
    await expect(details).toContainText("70");
    await details.getByRole("button", { name: "Zamknij szczegóły konfiguracji" }).click();
    await card.getByRole("button", { name: "Edytuj konfigurację" }).click();
    const editor = page.getByRole("dialog", { name: standaloneName });
    await expect(editor.getByRole("textbox", { name: /^Nazwa osi/u })).toHaveValue(
      standaloneName
    );
    await expect(editor.getByRole("spinbutton", { name: /^Pojemność osi/u })).toHaveValue(
      "4"
    );
    await expect(
      editor.getByRole("spinbutton", {
        name: /^Maks\. osób w jednej rezerwacji/u,
      })
    ).toHaveValue("4");
    await editor.getByRole("button", { name: "Zamknij edycję konfiguracji" }).click();
    await page.reload();
    await expect(page.getByRole("heading", { name: standaloneName })).toBeVisible();

    const family = await familyRows(standaloneName);
    expect(family.children).toHaveLength(0);
    expect(family.root.resource_kind).toBe("lane");
    expect(family.root.parent_lane_id).toBeNull();
    expect(family.root.is_active).toBe(false);
    expect(family.root.whole_lane_bookable).toBe(true);
    expect(family.root.positions_bookable).toBe(false);
    expect(family.root.max_shooters).toBe(4);
    const configuration = await relatedConfiguration([family.root.id]);
    expect(configuration.rules).toMatchObject([
      { online_bookable: false, max_people_online: 4 },
    ]);
    expect(configuration.durations.map((row) => row.duration_minutes)).toEqual([
      60,
      120,
    ]);
    expect(configuration.pricing).toHaveLength(2);
    expect(configuration.pricing.map((row) => Number(row.hourly_price)).sort()).toEqual([
      60,
      70,
    ]);
    expect(forbidden).toEqual([]);
  });

  test("scenario 2: one parent and three valid positions persist", async ({ page }) => {
    const forbidden = await loginAsAdmin(page);
    const dialog = await openCreateDialog(page);
    await dialog.getByRole("radio", { name: /^Ze stanowiskami/u }).click();
    await dialog.getByRole("button", { name: "+ Dodaj stanowisko" }).click();
    await dialog.getByRole("button", { name: "+ Dodaj stanowisko" }).click();

    const root = sectionForHeading(dialog, "Oś główna");
    await fillResource(root, {
      kind: "lane",
      name: hierarchyName,
      capacity: 6,
      maxPeople: 6,
      durations: [60, 120],
      weekdayPrice: 100,
      weekendPrice: 120,
      active: true,
      online: true,
    });
    await setCheckbox(root, "Rezerwacja całej osi", true);
    await setCheckbox(root, "Rezerwacja stanowisk", true);

    for (let index = 0; index < positionNames.length; index += 1) {
      const position = sectionForHeading(dialog, `Stanowisko ${index + 1}`);
      await fillResource(position, {
        kind: "position",
        name: positionNames[index],
        capacity: 1,
        maxPeople: 1,
        durations: [60, 120],
        weekdayPrice: 100,
        weekendPrice: 120,
        active: true,
        online: true,
      });
    }

    await expect(
      dialog.getByRole("button", { name: "Przejdź do podsumowania" })
    ).toBeEnabled();
    await dialog.getByRole("button", { name: "Przejdź do podsumowania" }).click();
    const review = page.getByRole("dialog", { name: "Sprawdź pełną konfigurację" });
    await expect(review).toContainText("oś główna i 3 stanowisk");
    for (const name of [hierarchyName, ...positionNames]) {
      await expect(review).toContainText(name);
    }
    await review.getByRole("button", { name: "Utwórz rodzinę osi" }).click();
    await expect(page.getByRole("status")).toContainText(
      "Nowa rodzina osi została utworzona."
    );
    await page.reload();
    const card = page
      .getByRole("heading", { name: hierarchyName, exact: true })
      .locator("xpath=ancestor::article[1]");
    await expect(card).toContainText("3 stanowisk");
    for (const name of positionNames) await expect(card).toContainText(name);

    const family = await familyRows(hierarchyName);
    expect(family.root.resource_kind).toBe("lane");
    expect(family.root.parent_lane_id).toBeNull();
    expect(family.root.whole_lane_bookable).toBe(true);
    expect(family.root.positions_bookable).toBe(true);
    expect(family.root.max_shooters).toBe(6);
    expect(family.children).toHaveLength(3);
    expect(family.children.map((row) => row.name)).toEqual(positionNames);
    expect(
      family.children.every(
        (row) =>
          row.resource_kind === "position" && row.parent_lane_id === family.root.id
      )
    ).toBe(true);
    const ids = [family.root.id, ...family.children.map((row) => row.id)];
    const configuration = await relatedConfiguration(ids);
    expect(configuration.rules).toHaveLength(4);
    expect(configuration.rules.every((row) => row.online_bookable)).toBe(true);
    expect(configuration.durations).toHaveLength(8);
    expect(configuration.pricing).toHaveLength(8);
    expect(forbidden).toEqual([]);
  });

  test("scenario 3: client validation blocks every invalid family", async ({ page }) => {
    const forbidden = await loginAsAdmin(page);

    const cases: Array<{
      name: string;
      mutate: (dialog: Locator, root: Locator) => Promise<void>;
      expected: RegExp;
    }> = [
      {
        name: invalidNames[0],
        mutate: async (_dialog, root) => root.getByLabel("Nazwa osi").fill(""),
        expected: /nazwa musi mieć/u,
      },
      {
        name: invalidNames[1],
        mutate: async (_dialog, root) => root.getByLabel("Pojemność osi").fill("0"),
        expected: /limity muszą być/u,
      },
      {
        name: invalidNames[2],
        mutate: async (_dialog, root) => {
          await root.getByLabel("Pojemność osi").fill("4");
          await root.getByLabel("Maks. osób w jednej rezerwacji").fill("5");
        },
        expected: /nie może przekraczać pojemności/u,
      },
      {
        name: invalidNames[3],
        mutate: async (_dialog, root) =>
          sectionForHeading(root, "Pon–Czw").getByLabel("Cena PLN/h").fill(""),
        expected: /cena musi być/u,
      },
      {
        name: invalidNames[4],
        mutate: async (_dialog, root) =>
          sectionForHeading(root, "Pon–Czw").getByLabel("Od osób").fill("2"),
        expected: /zawiera lukę/u,
      },
      {
        name: invalidNames[5],
        mutate: async (_dialog, root) => {
          const group = sectionForHeading(root, "Pon–Czw");
          await group.getByRole("button", { name: "+ Dodaj próg" }).click();
          await group.getByLabel("Od osób").nth(1).fill("3");
          await group.getByLabel("Do osób").nth(1).fill("4");
          await group.getByLabel("Opis progu").nth(1).fill("3–4 osoby");
          await group.getByLabel("Cena PLN/h").nth(1).fill("55");
        },
        expected: /nakładają się/u,
      },
      {
        name: invalidNames[6],
        mutate: async (_dialog, root) => {
          while ((await root.getByLabel("Czas rezerwacji w minutach").count()) > 0) {
            await root.getByRole("button", { name: /^Usuń czas/u }).first().click();
          }
        },
        expected: /dodaj co najmniej jeden czas/u,
      },
      {
        name: invalidNames[7],
        mutate: async (dialog) => {
          await dialog.getByRole("radio", { name: /^Ze stanowiskami/u }).click();
          const position = sectionForHeading(dialog, "Stanowisko 1");
          await position.getByLabel("Nazwa stanowiska").fill("");
          await position.getByLabel("Pojemność stanowiska").fill("0");
        },
        expected: /Stanowisko 1/u,
      },
    ];

    for (const invalidCase of cases) {
      await page.goto("/admin/lane-configuration");
      const dialog = await openCreateDialog(page);
      const root = await fillValidStandalone(dialog, invalidCase.name);
      await invalidCase.mutate(dialog, root);
      await expect(dialog.getByRole("alert")).toContainText(invalidCase.expected);
      await expect(
        dialog.getByRole("button", { name: "Przejdź do podsumowania" })
      ).toBeDisabled();
      await expectNoResource(invalidCase.name);
    }
    expect(forbidden).toEqual([]);
  });

  test("scenario 4: rejected RPC payload leaves every table unchanged", async () => {
    const before = await tableCounts();
    const invalidPosition = validWriteResource("[TEST] Atomowość stanowisko", 4);
    invalidPosition.pricing = invalidPosition.pricing.map((rule) =>
      rule.day_group === "mon_thu"
        ? { ...rule, min_shooters: 2, max_shooters: 4 }
        : rule
    );
    const { data, error } = await adminClient.rpc(
      "admin_create_lane_booking_family_v1",
      {
        p_family: {
          root: {
            ...validWriteResource(invalidNames[8], 4),
            whole_lane_bookable: true,
            positions_bookable: false,
          },
          positions: [invalidPosition],
        },
      }
    );
    assertNoError(error, "atomic rejection RPC");
    expect(data).toMatchObject({ ok: false, changed: false, created_resource_count: 0 });
    expect(["invalid_configuration", "invalid_payload"]).toContain(data.code);
    await expectNoResource(invalidNames[8]);
    await expectNoResource("[TEST] Atomowość stanowisko");
    expect(await tableCounts()).toEqual(before);
  });

  test("scenario 5: only admin RPC works and direct DML stays blocked", async ({
    page,
  }) => {
    const forbidden = await attachLocalOnlyNetworkGuard(page);
    const payload = {
      root: {
        ...validWriteResource(invalidNames[9], 4),
        whole_lane_bookable: true,
        positions_bookable: false,
      },
      positions: [],
    };
    const { data: userResult, error: userError } = await regularUserClient.rpc(
      "admin_create_lane_booking_family_v1",
      { p_family: payload }
    );
    assertNoError(userError, "regular user creator RPC");
    expect(userResult).toMatchObject({ ok: false, changed: false, code: "not_allowed" });

    const anonClient = createClient(environment.supabaseUrl, environment.anonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { error: anonRpcError } = await anonClient.rpc(
      "admin_create_lane_booking_family_v1",
      { p_family: payload }
    );
    expect(anonRpcError).not.toBeNull();
    await expectNoResource(invalidNames[9]);

    const standalone = await familyRows(standaloneName);
    const configuration = await relatedConfiguration([standalone.root.id]);
    const targets: Array<{
      table: string;
      matchColumn: string;
      matchValue: string;
      update: Record<string, unknown>;
      insert: Record<string, unknown>;
    }> = [
      {
        table: "shooting_lanes",
        matchColumn: "id",
        matchValue: standalone.root.id,
        update: { name: "[TEST] direct update denied" },
        insert: {
          id: randomUUID(),
          name: "[TEST] direct insert denied",
          type: "konfigurowalna",
          price_per_hour: 0,
          is_active: false,
          max_shooters: 1,
          booking_step_minutes: 60,
          display_order: 99999,
          currency_code: "PLN",
          resource_kind: "lane",
          whole_lane_bookable: false,
          positions_bookable: false,
        },
      },
      {
        table: "lane_booking_rules",
        matchColumn: "lane_id",
        matchValue: standalone.root.id,
        update: { max_people_online: 999 },
        insert: { lane_id: randomUUID(), online_bookable: false, max_people_online: 1 },
      },
      {
        table: "lane_booking_durations",
        matchColumn: "id",
        matchValue: configuration.durations[0].id,
        update: { duration_minutes: 180 },
        insert: {
          lane_id: randomUUID(),
          duration_minutes: 60,
          display_order: 99999,
          is_active: true,
        },
      },
      {
        table: "lane_pricing_rules",
        matchColumn: "id",
        matchValue: configuration.pricing[0].id,
        update: { label: "[TEST] direct update denied" },
        insert: {
          lane_id: randomUUID(),
          day_group: "mon_thu",
          min_shooters: 1,
          max_shooters: 1,
          label: "[TEST] direct insert denied",
          hourly_price: 1,
          display_order: 99999,
          is_active: true,
        },
      },
    ];

    for (const client of [adminClient, regularUserClient, anonClient]) {
      for (const target of targets) {
        const insert = await client.from(target.table).insert(target.insert);
        expect(insert.error, `${target.table} INSERT must be denied`).not.toBeNull();
        const update = await client
          .from(target.table)
          .update(target.update)
          .eq(target.matchColumn, target.matchValue);
        expect(update.error, `${target.table} UPDATE must be denied`).not.toBeNull();
        const deletion = await client
          .from(target.table)
          .delete()
          .eq(target.matchColumn, target.matchValue);
        expect(deletion.error, `${target.table} DELETE must be denied`).not.toBeNull();
      }
    }

    await page.goto("/login");
    await page.getByLabel("E-mail").fill(userEmail);
    await page.getByLabel("Hasło").fill(password);
    await page.getByRole("button", { name: "Zaloguj się" }).click();
    await expect(page).toHaveURL(/\/dashboard$/u);
    await page.goto("/admin/lane-configuration");
    await expect(page).not.toHaveURL(/\/admin\/lane-configuration$/u);

    const unchanged = await familyRows(standaloneName);
    expect(unchanged.root.name).toBe(standaloneName);
    expect(unchanged.root.max_shooters).toBe(4);
    expect(forbidden).toEqual([]);
  });
});
