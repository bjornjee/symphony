import {expect, test} from "@playwright/test";
import fs from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

const browserDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(browserDirectory, "../../..");
const artifactRoot = path.join(repositoryRoot, ".uiux-loop");
const fixturePort = Number(process.env.DASHBOARD_FIXTURE_PORT || "43127");
const controlBase = `http://127.0.0.1:${fixturePort + 1}`;
const iterationDirectory = process.env.UIUX_ITERATION || "iter-1";

const viewports = [
  {name: "1440x900", width: 1440, height: 900},
  {name: "390x844", width: 390, height: 844}
];

const screenshotStates = [
  "running",
  "live-log",
  "retrying",
  "blocked",
  "stale",
  "unavailable",
  "offline",
  "empty",
  "loading",
  "error"
];

async function setFixtureState(request, state) {
  const response = await request.post(`${controlBase}/state/${state}`);
  expect(response.status(), `fixture state ${state}`).toBe(204);
}

async function publishFixtureUpdate(request) {
  const response = await request.post(`${controlBase}/update`);
  expect(response.status(), "fixture PubSub update").toBe(204);
}

async function expectNoHorizontalOverflow(page) {
  const dimensions = await page.evaluate(() => {
    const viewport = window.innerWidth;
    const overflowers = [...document.body.querySelectorAll("*")]
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          element: element.id ? `#${element.id}` : element.className || element.tagName,
          left: Math.round(rect.left),
          right: Math.round(rect.right),
          width: Math.round(rect.width)
        };
      })
      .filter(({left, right}) => left < 0 || right > viewport);

    return {
      viewport,
      document: document.documentElement.scrollWidth,
      body: document.body.scrollWidth,
      overflowers
    };
  });

  expect(
    dimensions.document,
    `document horizontal overflow: ${JSON.stringify(dimensions.overflowers)}`
  ).toBeLessThanOrEqual(
    dimensions.viewport
  );
  expect(dimensions.body, "body horizontal overflow").toBeLessThanOrEqual(
    dimensions.viewport
  );
}

async function captureState(page, state, viewport) {
  for (const directory of [iterationDirectory, "final"]) {
    const outputDirectory = path.join(artifactRoot, directory);
    await fs.mkdir(outputDirectory, {recursive: true});
    await page.screenshot({
      path: path.join(outputDirectory, `${state}-${viewport.name}.png`),
      type: "png",
      fullPage: false,
      scale: "css"
    });
  }
}

async function gotoReady(page, request) {
  await setFixtureState(request, "mixed");
  await page.goto("/", {waitUntil: "domcontentloaded"});
  await expect(page.locator("#dashboard-root")).toHaveAttribute("data-dashboard-state", "ready");
  await expect(page.locator("#agent-detail")).toHaveAttribute("data-agent-status", "running");
}

async function tabTo(page, targetId) {
  for (let index = 0; index < 12; index += 1) {
    await page.keyboard.press("Tab");
    const activeId = await page.evaluate(() => document.activeElement?.id || "");
    if (activeId === targetId) return;
  }

  expect(await page.evaluate(() => document.activeElement?.id || "")).toBe(targetId);
}

test("dashboard states and live interactions remain observable", async ({page, request}) => {
  const consoleErrors = [];
  const pageErrors = [];
  const resourceErrors = [];

  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("requestfailed", (requestFailure) => {
    resourceErrors.push(
      `${requestFailure.method()} ${requestFailure.url()} ${requestFailure.failure()?.errorText || ""}`
    );
  });
  page.on("response", (response) => {
    if (response.status() >= 400) {
      resourceErrors.push(`${response.status()} ${response.url()}`);
    }
  });

  await fs.mkdir(path.join(artifactRoot, iterationDirectory), {recursive: true});
  await fs.mkdir(path.join(artifactRoot, "final"), {recursive: true});

  for (const viewport of viewports) {
    await page.setViewportSize({width: viewport.width, height: viewport.height});

    await gotoReady(page, request);
    await expect(page.locator("#agent-issue-running")).toBeVisible();
    await expect(page.locator("#agent-detail-log .log-line")).toHaveCount(50);
    await expect(
      page.locator("#agent-detail-log").getByText("Streaming implementation output 60")
    ).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "running", viewport);
    await page.locator("#agent-detail-log").scrollIntoViewIfNeeded();
    await captureState(page, "live-log", viewport);

    await page.locator("#agent-issue-retrying").click();
    await expect(page.locator("#agent-detail")).toHaveAttribute("data-agent-status", "retrying");
    await expect(page.getByText("Retry attempt 3")).toBeVisible();
    await expect(
      page.locator("#agent-detail-log").getByText("Previous attempt output 60")
    ).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "retrying", viewport);

    await page.locator("#agent-issue-blocked").click();
    await expect(page.locator("#agent-detail")).toHaveAttribute("data-agent-status", "blocked");
    await expect(page.getByText("Approval or input needed").last()).toBeVisible();
    await expect(
      page.locator("#agent-detail-log").getByText("Operator input context 60")
    ).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "blocked", viewport);

    await setFixtureState(request, "stale");
    const staleAgent = page.getByRole("button", {name: /PIN-STALE/});
    await expect(staleAgent).toBeVisible();
    await staleAgent.click();
    await expect(page.locator("#agent-detail")).toHaveAttribute("data-agent-status", "stale");
    await expectNoHorizontalOverflow(page);
    await captureState(page, "stale", viewport);

    await gotoReady(page, request);
    await page.locator("#agent-issue-blocked").click();
    await setFixtureState(request, "empty");
    await expect(page.locator("#agent-detail")).toHaveAttribute("data-agent-status", "unavailable");
    await expect(
      page.getByText("This agent is no longer present in the current runtime snapshot")
    ).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "unavailable", viewport);

    await gotoReady(page, request);
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator(".status-badge-offline")).toBeVisible();
    await expect(page.locator(".status-badge-live")).toBeHidden();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "offline", viewport);
    await page.evaluate(() => window.liveSocket.connect());
    await expect(page.locator(".status-badge-live")).toBeVisible();

    await setFixtureState(request, "empty");
    await page.goto("/", {waitUntil: "domcontentloaded"});
    await expect(page.locator("#dashboard-root")).toHaveAttribute("data-dashboard-state", "empty");
    await expect(page.getByText("No agents need monitoring")).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "empty", viewport);

    await setFixtureState(request, "error");
    await page.goto("/", {waitUntil: "domcontentloaded"});
    await expect(page.locator("#dashboard-root")).toHaveAttribute("data-dashboard-state", "error");
    await expect(
      page.getByRole("heading", { name: "Snapshot unavailable" }),
    ).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "error", viewport);

    await setFixtureState(request, "loading");
    await page.goto("/", {waitUntil: "domcontentloaded"});
    await expect(page.locator("#dashboard-root")).toHaveAttribute("data-dashboard-state", "loading");
    await expect(page.getByText("Loading agent status")).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await captureState(page, "loading", viewport);
    await expect(page.locator("#dashboard-root")).toHaveAttribute("data-dashboard-state", "ready");
  }

  await page.setViewportSize({width: 1440, height: 900});
  await gotoReady(page, request);
  await tabTo(page, "agent-issue-retrying");

  const focusStyle = await page.locator("#agent-issue-retrying").evaluate((element) => {
    const style = getComputedStyle(element);
    return {style: style.outlineStyle, width: style.outlineWidth, color: style.outlineColor};
  });

  expect(focusStyle.style).not.toBe("none");
  expect(Number.parseFloat(focusStyle.width)).toBeGreaterThanOrEqual(2);
  await page.keyboard.press("Enter");
  await expect(page.locator("#agent-detail")).toHaveAttribute("data-agent-status", "retrying");

  await page.goto("/", {waitUntil: "domcontentloaded"});
  await expect(page.locator("#dashboard-root")).toHaveAttribute("data-dashboard-state", "ready");
  await tabTo(page, "agent-detail-log");

  const logKeyboardStart = await page
    .locator("#agent-detail-log")
    .evaluate((element) => element.scrollTop);

  await page.keyboard.press("PageUp");

  await expect
    .poll(() => page.locator("#agent-detail-log").evaluate((element) => element.scrollTop))
    .toBeLessThan(logKeyboardStart);

  await page.goto("/", {waitUntil: "domcontentloaded"});
  await expect(page.locator("#dashboard-root")).toHaveAttribute("data-dashboard-state", "ready");
  await tabTo(page, "agent-issue-running");
  await page.keyboard.press("Enter");

  const timeline = page.locator("#agent-detail-timeline");
  const logTail = page.locator("#agent-detail-log");
  const logFollowState = page.locator("[data-log-follow-state]");
  await expect(timeline.locator("li")).toHaveCount(8);
  await expect(logTail.locator("li")).toHaveCount(50);
  await timeline.evaluate((element) => {
    element.scrollTop = 140;
  });
  await logTail.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(logFollowState).toHaveText("Following");

  const beforeUpdate = await page.evaluate(() => ({
    activeElementId: document.activeElement?.id,
    scrollTop: document.querySelector("#agent-detail-timeline")?.scrollTop,
    logDistanceFromBottom: (() => {
      const log = document.querySelector("#agent-detail-log");
      return log ? log.scrollHeight - log.clientHeight - log.scrollTop : null;
    })()
  }));

  await publishFixtureUpdate(request);
  await expect(page.locator("#current-activity-title")).toContainText("revision 1");
  await expect(logTail.locator(".log-line").last()).toContainText(
    "Live output revision 1: completed bounded dashboard update"
  );

  const afterUpdate = await page.evaluate(() => ({
    activeElementId: document.activeElement?.id,
    scrollTop: document.querySelector("#agent-detail-timeline")?.scrollTop,
    logDistanceFromBottom: (() => {
      const log = document.querySelector("#agent-detail-log");
      return log ? log.scrollHeight - log.clientHeight - log.scrollTop : null;
    })()
  }));

  expect(afterUpdate.activeElementId).toBe(beforeUpdate.activeElementId);
  expect(afterUpdate.scrollTop).toBe(beforeUpdate.scrollTop);
  expect(afterUpdate.logDistanceFromBottom).toBeLessThanOrEqual(24);

  await logTail.evaluate((element) => {
    element.scrollTop = 60;
  });
  const pausedLogScrollTop = await logTail.evaluate((element) => element.scrollTop);
  await expect(logFollowState).toHaveText("Paused");

  await publishFixtureUpdate(request);
  await expect(page.locator("#current-activity-title")).toContainText("revision 2");
  await expect(logTail.locator(".log-line").last()).toContainText(
    "Live output revision 2: completed bounded dashboard update"
  );
  expect(await logTail.evaluate((element) => element.scrollTop)).toBe(pausedLogScrollTop);
  await expect(logFollowState).toHaveText("Paused");

  await page.locator("#agent-issue-retrying").click();
  await expect(logTail.locator(".log-line").last()).toBeInViewport();
  await expect(logFollowState).toHaveText("Following");
  await page.locator("#agent-issue-running").click();

  await setFixtureState(request, "transitioned");
  await expect(page.locator("#agent-detail")).toHaveAttribute("data-agent-status", "retrying");
  await expect(page.locator("#agent-issue-running")).toHaveAttribute("aria-pressed", "true");

  const afterStatusTransition = await page.evaluate(() => document.activeElement?.id);
  expect(afterStatusTransition).toBe(beforeUpdate.activeElementId);

  await gotoReady(page, request);
  await page.getByText("Session and workspace", {exact: true}).click();
  await page.evaluate(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {writeText: () => Promise.reject(new Error("clipboard denied"))}
    });
  });

  const copyId = page.getByRole("button", {name: "Copy ID"});
  await copyId.click();
  await expect(page.locator("[data-copy-status]")).toHaveText(
    "Copy failed. Select and copy the value manually."
  );
  await expect(copyId).toBeFocused();

  await page.evaluate(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {writeText: () => Promise.resolve()}
    });
  });
  await copyId.click();
  await expect(page.locator("[data-copy-status]")).toHaveText("Copied Session ID.");
  await expect(copyId).toBeFocused();

  expect(consoleErrors, "browser console errors").toEqual([]);
  expect(pageErrors, "uncaught page errors").toEqual([]);
  expect(resourceErrors, "failed or error resources").toEqual([]);

  const behaviorEvidence = `# Dashboard browser behavior check

Preservation gate state: PASS

| Check | Result | Evidence |
| --- | --- | --- |
| Desktop render 1440x900 | PASS | All nine named states rendered without horizontal overflow. |
| Narrow render 390x844 | PASS | All nine named states rendered within the viewport. |
| Keyboard-only selection | PASS | Tab reached retrying agent and Enter selected it. |
| Visible focus | PASS | Computed focus outline was ${focusStyle.width} ${focusStyle.style} ${focusStyle.color}. |
| Keyboard log reading | PASS | Tab focused the named log region and Page Up scrolled older output. |
| PubSub selection preservation | PASS | Selected ID remained agent-issue-running. |
| Focus identity preservation | PASS | activeElement remained ${afterUpdate.activeElementId}. |
| Status transition preservation | PASS | Selected issue and focus survived running → retrying. |
| Clipboard outcomes | PASS | Successful and rejected writes produced visible guidance without moving focus. |
| Reading position preservation | PASS | timeline scrollTop remained ${afterUpdate.scrollTop}. |
| Live log selection | PASS | Running, retrying, and blocked agents exposed their own bounded audit tail. |
| Live log following | PASS | A newly appended line appeared without navigation and the tail followed while at the bottom. |
| Paused log reading | PASS | scrollTop remained ${pausedLogScrollTop} after the operator scrolled up and another line arrived. |
| Live/offline indicator | PASS | Disconnect showed Offline; reconnect restored Live. |
| Console and page errors | PASS | No console, page, request, or HTTP resource errors. |
| Named states | PASS | ${screenshotStates.join(", ")} captured at both viewports. |
`;

  await fs.writeFile(path.join(artifactRoot, "behavior-check.md"), behaviorEvidence);
  await fs.writeFile(
    path.join(artifactRoot, iterationDirectory, "change.md"),
    `# ${iterationDirectory.replace("-", " ")} changes\n\nAddressed the current critique brief and captured fresh behavior evidence.\n`
  );
});
