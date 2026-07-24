import {defineConfig} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const browserDirectory = path.dirname(fileURLToPath(import.meta.url));
const fixturePort = Number(process.env.DASHBOARD_FIXTURE_PORT || "43127");

export default defineConfig({
  testDir: browserDirectory,
  testMatch: "dashboard_live.spec.mjs",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 120_000,
  expect: {timeout: 10_000},
  reporter: [["line"]],
  use: {
    baseURL: `http://127.0.0.1:${fixturePort}`,
    headless: true,
    locale: "en-US",
    reducedMotion: "reduce",
    screenshot: "off",
    trace: "off"
  },
  webServer: {
    command: "MIX_ENV=test mise exec -- mix run --no-start test/support/dashboard_visual_fixture.exs",
    cwd: path.resolve(browserDirectory, "../.."),
    url: `http://127.0.0.1:${fixturePort + 1}/health`,
    timeout: 120_000,
    reuseExistingServer: false,
    stdout: "pipe",
    stderr: "pipe"
  }
});
