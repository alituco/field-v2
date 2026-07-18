import { expect, type Locator, type Page, test } from "@playwright/test";

import {
  installAdminSession,
  loadStagingManifest,
} from "./support/staging-session";

test("referee runs the match and admin sees player-created requests", async ({
  context,
  page,
}) => {
  const manifest = await loadStagingManifest();
  const session = await installAdminSession(context, manifest);

  await page.goto("/");
  await expect(page.getByText(/Signed in as/)).toBeVisible();

  const matchSelector = page.getByLabel("Choose assigned match");
  if (await matchSelector.count() > 0) {
    await matchSelector.selectOption(manifest.games.match.id);
  }
  await expect(page.locator(".referee-kickoff-details")).toContainText(
    manifest.games.match.venue,
  );

  const playersTab = page.getByRole("button", { name: /Players/ }).first();
  await playersTab.click();
  await openRoster(page.locator("details.attendance-roster"));

  const correctedPlayerName = manifest.accounts.main.displayName;
  const correctedPlayer = page.locator(".attendance-player").filter({
    hasText: correctedPlayerName,
  }).first();
  await expect(correctedPlayer).toBeVisible();
  await correctedPlayer.getByRole("button", {
    name: "Check in",
    exact: true,
  }).click();

  const refreshedCorrectedPlayer = page.locator(".attendance-player").filter({
    hasText: correctedPlayerName,
  }).first();
  await expect(refreshedCorrectedPlayer.getByRole("button", {
    name: "Remove",
    exact: true,
  })).toBeVisible();
  await refreshedCorrectedPlayer.getByRole("button", {
    name: "Remove",
    exact: true,
  }).click();

  const removalDialog = page.getByRole("dialog", {
    name: "Remove check-in?",
  });
  await expect(removalDialog).toBeVisible();
  await removalDialog.getByRole("button", {
    name: "Remove check-in",
    exact: true,
  }).click();
  await expect(removalDialog).toBeHidden();
  await openRoster(page.locator("details.attendance-roster"));
  await expect(
    page.locator(".attendance-player").filter({
      hasText: correctedPlayerName,
    }).first().getByRole("button", { name: "Check in", exact: true }),
  ).toBeVisible();

  await checkInEveryPlayer(page.locator("details.attendance-roster"));
  await expect(playersTab).toContainText("12/12");
  await expect(page.getByRole("button", {
    name: "Start game",
    exact: true,
  })).toBeEnabled();
  await page.getByRole("button", {
    name: "Start game",
    exact: true,
  }).click();
  await expect(page.locator(".fixture-status")).toHaveText("Live now");
  await page.getByRole("button", { name: /^Match/ }).first().click();

  const goalButton = page.getByRole("button", {
    name: /Goal/,
  }).first();
  await expect(goalButton).toBeEnabled();
  await goalButton.click();

  const goalDialog = page.getByRole("dialog", { name: "Record a goal" });
  await expect(goalDialog).toBeVisible();
  await goalDialog.getByRole("button", {
    name: "Confirm goal",
    exact: true,
  }).click();
  await expect(goalDialog).toBeHidden();

  const endMatch = page.locator("details.timer-end-disclosure");
  await endMatch.locator("summary").click();
  await endMatch.getByRole("button", {
    name: "Finish match",
    exact: true,
  }).click();
  await expect(page.getByText(
    "Final result saved. Admin corrections remain fully audited.",
    { exact: true },
  )).toBeVisible();

  await expectAdminApiMarkers(
    page,
    session.accessToken,
    manifest.markers.supportDetails,
    manifest.markers.reportDetails,
  );

  await page.goto("/admin");
  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();

  await page.locator(".admin-sidebar-nav").getByRole("button", {
    name: /Support/,
  }).click();
  const supportSearch = page.getByPlaceholder("Search tickets");
  await expect(supportSearch).toBeVisible();
  await supportSearch.fill(manifest.markers.supportDetails);
  await expect(
    page.locator(
      ".admin-support-detail .admin-report-description p",
    ),
  ).toHaveText(manifest.markers.supportDetails);

  await page.locator(".admin-sidebar-nav").getByRole("button", {
    name: /Reports/,
  }).click();
  const reportSearch = page.getByPlaceholder("Search reports");
  await expect(reportSearch).toBeVisible();
  await reportSearch.fill(manifest.markers.reportDetails);
  await expect(
    page.locator(
      ".admin-report-detail:not(.admin-support-detail) .admin-report-description p",
    ),
  ).toHaveText(manifest.markers.reportDetails);
});

async function openRoster(roster: Locator) {
  await expect(roster).toBeVisible();
  if (!(await roster.evaluate((element) => element.hasAttribute("open")))) {
    await roster.locator("summary").click();
  }
}

async function checkInEveryPlayer(roster: Locator) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    await openRoster(roster);
    const buttons = roster.getByRole("button", {
      name: "Check in",
      exact: true,
    });
    const before = await buttons.count();
    if (before === 0) return;
    await buttons.first().click();
    await expect.poll(() =>
      roster.getByRole("button", {
        name: "Check in",
        exact: true,
      }).count()
    ).toBe(before - 1);
  }
  throw new Error("The referee roster still had unchecked players.");
}

async function expectAdminApiMarkers(
  page: Page,
  accessToken: string,
  supportDetails: string,
  reportDetails: string,
) {
  const headers = { authorization: `Bearer ${accessToken}` };
  const supportResponse = await page.request.get(
    "/api/referee/admin/support?status=ACTIVE",
    { headers },
  );
  expect(
    supportResponse.ok(),
    `Support API returned ${supportResponse.status()}.`,
  ).toBe(true);
  const supportPayload = await supportResponse.json() as {
    tickets?: Array<{ description?: string }>;
  };
  expect(supportPayload.tickets?.some(
    (ticket) => ticket.description === supportDetails,
  )).toBe(true);

  const reportResponse = await page.request.get(
    "/api/referee/admin/reports?status=OPEN",
    { headers },
  );
  expect(
    reportResponse.ok(),
    `Reports API returned ${reportResponse.status()}.`,
  ).toBe(true);
  const reportPayload = await reportResponse.json() as {
    reports?: Array<{ description?: string }>;
  };
  expect(reportPayload.reports?.some(
    (report) => report.description === reportDetails,
  )).toBe(true);
}
