import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

// Optional module path allows the desktop's already-installed Playwright bundle.
// Never installs/downloads a browser or reuses a personal Edge profile.
const [originArg, modulePath] = process.argv.slice(2);
const origin = new URL(originArg ?? "http://127.0.0.1:4179");
assert.equal(origin.protocol, "http:");
assert.equal(origin.hostname, "127.0.0.1");
assert.ok(Number(origin.port) >= 4179 && Number(origin.port) <= 4199);
assert.equal(origin.pathname, "/");
assert.equal(
  origin.search + origin.hash + origin.username + origin.password,
  "",
);
if (modulePath) assert.ok(path.isAbsolute(modulePath));
const { chromium } = await import(
  modulePath ? pathToFileURL(modulePath).href : "playwright"
);
const run = `nene-${randomUUID()}`;
let browser;
let stage = "launch Edge";
try {
  browser = await chromium.launch({ channel: "msedge", headless: true });
  stage = "create isolated pages";
  const context = await browser.newContext();
  // The fixture supplies every Auth response in memory. Only fixed local assets
  // can leave the pages; unexpected real Auth/network use aborts the probe.
  const denied = [];
  await context.route("**/*", async (route) => {
    const target = new URL(route.request().url());
    if (
      target.origin === origin.origin &&
      ["/index.html", "/probe.js", "/favicon.ico"].includes(target.pathname)
    ) {
      await route.continue();
    } else {
      denied.push("unexpected-network-request");
      await route.abort();
    }
  });
  const leader = await context.newPage();
  const observer = await context.newPage();
  const errors = [];
  for (const page of [leader, observer])
    page.on("pageerror", () => errors.push("browser-script-error"));
  stage = "load loopback fixture";
  await leader.goto(`${origin.origin}/index.html?run=${run}&role=leader`);
  await observer.goto(`${origin.origin}/index.html?run=${run}&role=observer`);
  stage = "wait for browser scenarios";
  await leader.waitForSelector(
    'body[data-probe-state="complete"], body[data-probe-state="failed"]',
    { timeout: 110_000 },
  );
  const result = JSON.parse(await leader.locator("#results").innerText());
  console.log(JSON.stringify(result));
  stage = "validate browser results";
  assert.equal(result.state, "complete");
  assert.equal(result.results.length, 9);
  assert.ok(result.results.every((item) => item.result === "passed"));
  assert.deepEqual(denied, []);
  assert.deepEqual(errors, []);
  for (const page of [leader, observer]) {
    assert.deepEqual(
      await page.evaluate(() => ({
        local: localStorage.length,
        session: sessionStorage.length,
      })),
      { local: 0, session: 0 },
    );
  }
  stage = "verify reload clears only the observer's memory session";
  assert.equal(
    await observer.locator("body").getAttribute("data-owner-user"),
    "customer-b",
  );
  await observer.reload();
  await observer.waitForSelector('body[data-probe-state="ready"]');
  assert.equal(
    await observer.locator("body").getAttribute("data-owner-user"),
    "signed-out",
  );
  assert.deepEqual(
    await observer.evaluate(() => ({
      local: localStorage.length,
      session: sessionStorage.length,
    })),
    { local: 0, session: 0 },
  );
  assert.deepEqual(denied, []);
  assert.deepEqual(errors, []);
  const report = {
    browser: `Microsoft Edge ${browser.version()} (headless, isolated context)`,
    ...result,
    unexpectedNetworkRequests: denied.length,
    browserScriptErrors: errors.length,
    localAndSessionStorageEmpty: true,
    independentTabReloadStartsSignedOut: true,
    browserOwnershipGate:
      "passed for isolated coordinator; app integration remains separate",
  };
  await writeFile(
    new URL("../.tmp/session-coordination-web-result.json", import.meta.url),
    `${JSON.stringify(report, null, 2)}\n`,
  );
  console.log(JSON.stringify(report));
} catch (error) {
  // Do not dump page contents, tokens or browser internals on failure.
  console.error(
    JSON.stringify({ result: "failed", stage, errorType: error.name }),
  );
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
}
