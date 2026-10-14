import { expect, type Locator, type Page, test } from "@playwright/test";

import { verifyAdminRequestInboxes } from "./support/admin-request-navigation";
import { finishSoloMatch } from "./support/finish-solo-match";
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
  await checkInPlayer(page, correctedPlayer, "Check in early");

  const refreshedCorrectedPlayer = page.locator(".attendance-player").filter({
    hasText: correctedPlayerName,
  }).first();
  await expect(refreshedCorrectedPlayer).toContainText(
    "Checked in early",
  );
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

  await checkInEveryPlayer(page, page.locator("details.attendance-roster"));
  await expect(playersTab).toContainText("14/14");
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
  await finishSoloMatch(
    page,
    manifest.games.match.id,
    endMatch.getByRole("button", {
      name: "Finish match",
      exact: true,
    }),
  );
  await expect(page.locator(".fixture-status")).toHaveText("Finished", {
    timeout: 30_000,
  });
  await expect(page.locator(".result-locked-note")).toContainText(
    "Final result saved. Admin corrections remain fully audited.",
  );

  await expectAdminApiMarkers(
    page,
    session.accessToken,
    manifest.markers.supportDetails,
    manifest.markers.reportDetails,
  );

  await verifyAdminRequestInboxes(page, manifest.markers);
});

async function openRoster(roster: Locator) {
  await expect(roster).toBeVisible();
  if (!(await roster.evaluate((element) => element.hasAttribute("open")))) {
    await roster.locator("summary").click();
  }
}

async function checkInPlayer(
  page: Page,
  player: Locator,
  timing: "Check in early" | "Check in late" | "Check in after kickoff",
) {
  await player.getByRole("button", {
    name: "Check in",
    exact: true,
  }).click();

  const timingDialog = page.getByRole("dialog", {
    name: /When did .* arrive\?/,
  });
  await expect(timingDialog).toBeVisible();
  await timingDialog.getByRole("button", {
    name: new RegExp(`^${timing}`),
  }).click();
  await expect(timingDialog).toBeHidden();
}

async function checkInEveryPlayer(page: Page, roster: Locator) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    await openRoster(roster);
    const buttons = roster.getByRole("button", {
      name: "Check in",
      exact: true,
    });
    const before = await buttons.count();
    if (before === 0) return;
    const player = buttons.first().locator(
      "xpath=ancestor::*[contains(concat(' ', normalize-space(@class), ' '), ' attendance-player ')][1]",
    );
    await checkInPlayer(page, player, "Check in early");
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
