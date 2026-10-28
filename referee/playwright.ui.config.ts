import { defineConfig, devices } from "@playwright/test";

// Isolated UI contracts: all account/API traffic is mocked, never shared staging data.
export default defineConfig({
  testDir: "./ui-tests",
  timeout: 30_000,
  retries: 0,
  workers: 1,
  outputDir: "test-results/ui",
  use: { baseURL: "http://127.0.0.1:3000", ...devices["Desktop Chrome"], viewport: { width: 1440, height: 1000 }, screenshot: "only-on-failure", serviceWorkers: "block" },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    ...(process.env.FIELD_UI_WEBKIT === "1" ? [{ name: "webkit", use: { ...devices["Desktop Safari"] } }] : []),
  ],
  webServer: {
    command: "npm run dev -- --hostname 127.0.0.1", url: "http://127.0.0.1:3000", reuseExistingServer: true,
    env: {
      NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "ui-tests-mocked-only",
    },
  },
});
