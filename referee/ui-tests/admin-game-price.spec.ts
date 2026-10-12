import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import type { AdminGamePricing } from "../src/lib/admin-game-pricing";

const publicConfig = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? publicConfig.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname.split(".")[0];
const gameId = "d1000000-0000-4000-8000-000000000001";
const profileId = "b1000000-0000-4000-8000-000000000001";
const reason = "A discount for the remaining game places.";

function initialPricing(): AdminGamePricing {
  return {
    priceFils: 13000, currency: "USD", canEdit: true, lockedReason: null,
    bookings: [{
      bookingId: "a1000000-0000-4000-8000-000000000001", profileId, displayName: "Sam P.",
      status: "CONFIRMED", bookedAt: "2026-10-11T12:00:00Z", matchFeeFils: 13000,
      depositFils: 2600, paidTotalFils: 15600, refundedFils: 0, currency: "USD", paymentStatus: "SUCCEEDED",
    }],
  };
}

async function mockGame(page: Page, options: {
  pricing?: AdminGamePricing | null;
  status?: string;
  failure?: { status: number; message: string };
  conflictOnce?: boolean;
} = {}) {
  const writes: { method: string; body: Record<string, unknown> }[] = [];
  let pricing = options.pricing === undefined ? initialPricing() : options.pricing;
  const fixture = {
    matchKind: pricing === null ? "CLAN" : "SOLO", id: gameId, status: options.status ?? "OPEN",
    operationalState: null, operationalStateUpdatedAt: null, venue: "Encanto Park · Pitch 1",
    day: "Saturday", timeSlot: "8:30 PM – 9:30 PM", matchDate: "2099-07-25", cancellationReason: null,
    cancellationCode: null, homeScore: null, awayScore: null, clock: null, events: [],
    homeClan: { id: "white", name: "White team", tag: "WHT", emblem: "W" },
    awayClan: { id: "black", name: "Black team", tag: "BLK", emblem: "B" },
  };
  await page.addInitScript(({ key }) => {
    localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated" } }));
  }, { key: `sb-${project}-auth-token` });
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ status: 200, contentType: "application/json", body: "{}" }));
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (request.method() === "PATCH") {
      expect(path).toBe(`/api/referee/admin/games/solo/${gameId}/price`);
      const body = request.postDataJSON();
      writes.push({ method: request.method(), body });
      if (options.conflictOnce && writes.length === 1 && pricing) {
        pricing = { ...pricing, priceFils: 14000 };
        await route.fulfill({ status: 409, json: { error: "Another admin changed this game’s price. Refresh and try again." } });
        return;
      }
      if (options.failure) {
        await route.fulfill({ status: options.failure.status, json: { error: options.failure.message } });
        return;
      }
      if (pricing) pricing = { ...pricing, priceFils: Math.round(Number(body.priceUsd) * 1000) };
      await route.fulfill({ json: { priceFils: pricing?.priceFils, currency: pricing?.currency } });
      return;
    }
    await route.fulfill({ json: { detail: {
      fixture, currency: pricing?.currency ?? "USD", pricing,
      participants: { matchKind: "SOLO", matchId: gameId, status: fixture.status, capacity: 14, capacityPerSide: 7, registeredPlayers: [], actualPlayers: [], withdrawnPlayers: [], counts: { registered: 0, actual: 0, withdrawn: 0 } },
      reserves: { active: [], history: [] }, assignedReferee: null,
      ratingSummary: { kind: "SOLO", whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null, teamSrSpread: null, ratedPlayers: 0 },
      audit: [], reports: [], stoppages: [], resolutionCase: null,
    } } });
  });
  await page.goto(`/admin/games/${fixture.matchKind.toLowerCase()}/${gameId}`);
  return writes;
}

async function editPrice(page: Page, price: string) {
  await page.getByRole("button", { name: "Edit price", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Edit game price" });
  await dialog.getByLabel("New price per player (USD)").fill(price);
  await dialog.getByLabel("Reason for the price change").fill(reason);
  return dialog;
}

for (const price of ["15.25", "9.50", "0", "0.50", "100.00"]) {
  test(`price ${price} changes the new-booking quote without rewriting an existing payment`, async ({ page }) => {
    const writes = await mockGame(page);
    const panel = page.getByRole("region", { name: "Game price", exact: true });
    await expect(panel.getByText("$13.00 USD", { exact: true }).first()).toBeVisible();
    const dialog = await editPrice(page, price);
    await expect(dialog.getByText("Existing payments stay exactly as they are")).toBeVisible();
    await expect(dialog.getByText(/not its recurring schedule/)).toBeVisible();
    await dialog.getByRole("button", { name: "Save new price" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.getByRole("status").filter({ hasText: "Game price updated" })).toBeVisible();
    expect(writes).toEqual([{ method: "PATCH", body: { priceUsd: price, expectedPriceFils: 13000, reason } }]);
    await expect(panel.getByText(`$${Number(price).toFixed(2)} USD`, { exact: true }).first()).toBeVisible();
    const row = panel.getByRole("row", { name: /Sam P\./ });
    await expect(row.getByRole("cell", { name: "$13.00 USD", exact: true })).toBeVisible();
    await expect(row.getByRole("cell", { name: "$2.60 USD", exact: true })).toBeVisible();
    await expect(row.getByRole("cell", { name: "$15.60 USD", exact: true })).toBeVisible();
    await expect(row.getByRole("cell", { name: "$0.00 USD", exact: true })).toBeVisible();
    await expect(row.getByRole("link", { name: "Sam P." })).toHaveAttribute("href", `/admin/people/player/${profileId}`);
  });
}

test("price and reason validation block unsafe or unchanged submissions", async ({ page }) => {
  const writes = await mockGame(page);
  const dialog = await editPrice(page, "13.00");
  const save = dialog.getByRole("button", { name: "Save new price" });
  await expect(save).toBeDisabled();
  const input = dialog.getByLabel("New price per player (USD)");
  for (const invalid of ["", "-1", "0.01", "0.49", "100.01", "1.001", "abc", "1e2", "0x10", "Infinity"]) {
    await input.fill(invalid);
    await expect(input).toHaveAttribute("aria-invalid", "true");
    await expect(save).toBeDisabled();
  }
  await input.fill("12.00");
  await dialog.getByLabel("Reason for the price change").fill("short");
  await expect(save).toBeDisabled();
  await dialog.getByLabel("Reason for the price change").fill(reason);
  await expect(save).toBeEnabled();
  expect(writes).toHaveLength(0);
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Edit price", exact: true })).toBeFocused();
});

test("failed save preserves the price and reason and shows the server error", async ({ page }) => {
  const writes = await mockGame(page, { failure: { status: 500, message: "Could not save the game price." } });
  const dialog = await editPrice(page, "12.25");
  await dialog.getByRole("button", { name: "Save new price" }).click();
  await expect(dialog.getByRole("alert")).toHaveText("Could not save the game price.");
  await expect(dialog.getByLabel("New price per player (USD)")).toHaveValue("12.25");
  await expect(dialog.getByLabel("Reason for the price change")).toHaveValue(reason);
  await expect(dialog.getByRole("button", { name: "Save new price" })).toBeEnabled();
  expect(writes).toHaveLength(1);
});

test("a concurrent edit requires a deliberate refresh and keeps the admin draft", async ({ page }) => {
  const writes = await mockGame(page, { conflictOnce: true });
  const dialog = await editPrice(page, "12.25");
  await dialog.getByRole("button", { name: "Save new price" }).click();
  await expect(dialog.getByRole("alert")).toHaveText("Another admin changed this game’s price. Refresh and try again.");
  await expect(dialog.getByRole("button", { name: "Save new price" })).toBeDisabled();
  await dialog.getByRole("button", { name: "Refresh current price" }).click();
  await expect(dialog.getByRole("status")).toContainText("$14.00 USD");
  await expect(dialog.getByLabel("New price per player (USD)")).toHaveValue("12.25");
  await expect(dialog.getByLabel("Reason for the price change")).toHaveValue(reason);
  await dialog.getByRole("button", { name: "Save new price" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(writes.map((write) => write.body.expectedPriceFils)).toEqual([13000, 14000]);
});

for (const status of ["LIVE", "FINAL", "CANCELLED"]) {
  test(`${status} game retains payment visibility without an edit control`, async ({ page }) => {
    await mockGame(page, { status, pricing: { ...initialPricing(), canEdit: false, lockedReason: "Only upcoming open or full games can have their price changed." } });
    await expect(page.getByRole("heading", { name: "Game price", exact: true })).toBeVisible();
    await expect(page.getByText("Only upcoming open or full games can have their price changed.")).toBeVisible();
    await expect(page.getByRole("button", { name: "Edit price", exact: true })).toHaveCount(0);
    await expect(page.getByRole("cell", { name: "$15.60 USD", exact: true })).toBeVisible();
  });
}

test("legacy BHD prices stay labelled BHD and read-only", async ({ page }) => {
  const pricing = initialPricing();
  await mockGame(page, { pricing: { ...pricing, currency: "BHD", canEdit: false, lockedReason: "Historical BHD games are read-only.", bookings: pricing.bookings.map((booking) => ({ ...booking, currency: "BHD" })) } });
  await expect(page.getByText("Historical BHD games are read-only.")).toBeVisible();
  await expect(page.getByRole("cell", { name: "15.600 BHD", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Edit price", exact: true })).toHaveCount(0);
  await expect(page.getByText(/USD/)).toHaveCount(0);
});

test("cancelled and repeated bookings retain distinct amounts; unknown is not zero", async ({ page }, info) => {
  const pricing = initialPricing();
  await mockGame(page, { pricing: { ...pricing, bookings: [
    { ...pricing.bookings[0], status: "CANCELLED", refundedFils: 7800 },
    { ...pricing.bookings[0], bookingId: "a2000000-0000-4000-8000-000000000002", matchFeeFils: 9500, depositFils: 0, paidTotalFils: 9500 },
    { ...pricing.bookings[0], bookingId: "a3000000-0000-4000-8000-000000000003", displayName: "Historical player", matchFeeFils: null, depositFils: null, paidTotalFils: null, refundedFils: null, paymentStatus: "NOT_RECORDED" },
  ] } });
  await expect(page.getByRole("row", { name: /Sam P\./ })).toHaveCount(2);
  await expect(page.getByRole("cell", { name: "$7.80 USD", exact: true })).toBeVisible();
  await expect(page.getByRole("row", { name: /Historical player/ }).getByRole("cell", { name: "Not recorded", exact: true })).toHaveCount(4);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("heading", { name: "Game price", exact: true }).scrollIntoViewIfNeeded();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: info.outputPath("game-price-mobile.png"), fullPage: true });
});

test("an empty payment history stays clear and clan games expose no solo-price editor", async ({ page }) => {
  await mockGame(page, { pricing: { ...initialPricing(), bookings: [] } });
  await expect(page.getByText("No bookings have been recorded for this game.")).toBeVisible();
  await mockGame(page, { pricing: null });
  await expect(page.getByRole("heading", { name: "Game price", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Edit price", exact: true })).toHaveCount(0);
});
