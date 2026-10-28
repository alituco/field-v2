import { expect, type Page } from "@playwright/test";

export async function verifyAdminRequestInboxes(
  page: Page,
  markers: { supportDetails: string; reportDetails: string },
) {
  await page.goto("/admin");
  const navigation = page.locator(".admin-sidebar-nav");
  const overview = navigation.getByRole("button", { name: /^Overview/ });
  await expect(overview).toBeVisible();
  await expect(overview).toHaveClass(/\bactive\b/);
  await expect(
    page.locator(".admin-topbar").getByRole("heading", { level: 1 }),
  ).toBeVisible();
  await expect(
    page.getByRole("status", { name: "Loading admin overview", exact: true }),
  ).toBeHidden();

  await navigation.getByRole("button", { name: /^Support/ }).click();
  const supportSearch = page.getByPlaceholder("Search tickets");
  await expect(supportSearch).toBeVisible();
  await supportSearch.fill(markers.supportDetails);
  await expect(
    page.locator(".admin-support-detail .admin-report-description p"),
  ).toHaveText(markers.supportDetails);

  await navigation.getByRole("button", { name: /^Reports/ }).click();
  const reportSearch = page.getByPlaceholder("Search reports");
  await expect(reportSearch).toBeVisible();
  await reportSearch.fill(markers.reportDetails);
  await expect(
    page.locator(
      ".admin-report-detail:not(.admin-support-detail) .admin-report-description p",
    ),
  ).toHaveText(markers.reportDetails);
}
