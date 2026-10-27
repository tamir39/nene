import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";

// Real-provider coordination experiment only. The normal Nene app, credentials,
// database and Auth flags are never read or changed. No financial API is called.
let stage = "preflight";
let lastStatus;
let childStage;

async function run(fixture) {
  const { authOrigin, signal, adminToken, verifyAccessToken } = fixture;
  console.log(JSON.stringify({ fixture: fixture.runtime }));

  async function request(route, { token, body, method = "GET" } = {}) {
    signal.throwIfAborted();
    const response = await fetch(`${authOrigin}${route}`, {
      method,
      redirect: "error",
      signal: AbortSignal.any([signal, AbortSignal.timeout(15_000)]),
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    lastStatus = response.status;
    const limit = route === "/factors" ? 2 * 1024 * 1024 : 128 * 1024;
    const reader = response.body.getReader();
    const chunks = [];
    let bytes = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        assert.ok(bytes <= limit);
        chunks.push(value);
      }
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw error;
    } finally {
      reader.releaseLock();
    }
    const raw = Buffer.concat(chunks).toString("utf8");
    const data = raw ? JSON.parse(raw) : null;
    assert.equal(response.status, 200);
    return data;
  }

  async function prepare(name) {
    stage = `prepare ${name}`;
    const email = `coordination-${randomUUID()}@example.invalid`;
    const password = randomBytes(24).toString("base64url");
    const user = await request("/admin/users", {
      token: adminToken,
      method: "POST",
      body: { email, password, email_confirm: true },
    });
    const login = () =>
      request("/token?grant_type=password", {
        method: "POST",
        body: { email, password },
      });
    let session = await login();
    assert.equal(verifyAccessToken(session.access_token).sub, user.id);
    const factor = await request("/factors", {
      token: session.access_token,
      method: "POST",
      body: {
        factor_type: "totp",
        friendly_name: "Synthetic coordination factor",
        issuer: "Nene isolated check",
      },
    });
    const remaining = 30_000 - (Date.now() % 30_000);
    if (remaining < 3000) await delay(remaining + 100, undefined, { signal });
    const challenge = await request(`/factors/${factor.id}/challenge`, {
      token: session.access_token,
      method: "POST",
      body: {},
    });
    session = await request(`/factors/${factor.id}/verify`, {
      token: session.access_token,
      method: "POST",
      body: {
        challenge_id: challenge.id,
        code: generateTotp(factor.totp.secret),
      },
    });
    assert.equal(verifyAccessToken(session.access_token).aal, "aal2");
    const backup = await request("/factors/recovery-codes", {
      token: session.access_token,
      method: "POST",
      body: {},
    });
    assert.equal(backup.codes.length, 10);
    session = await login();
    const claims = verifyAccessToken(session.access_token);
    assert.equal(claims.sub, user.id);
    assert.equal(claims.aal, "aal1");
    return {
      name,
      email,
      password,
      expectedUserId: user.id,
      recoveryCode: backup.codes[0],
    };
  }

  const names = [
    "verification_then_refresh",
    "refresh_then_verification",
    "logout_during_verification",
    "unknown_reply_requires_signin",
  ];
  const cases = [];
  for (const name of names) cases.push(await prepare(name));
  stage = "Dart session coordination against real provider";
  const absolute = (relative) =>
    fileURLToPath(new URL(relative, import.meta.url));
  const result = spawnSync(
    absolute("../.tools/flutter/bin/cache/dart-sdk/bin/dart.exe"),
    [
      `--packages=${absolute("../app/.dart_tool/package_config.json")}`,
      absolute("../experiments/session_coordination_provider/probe.dart"),
    ],
    {
      // Private pipe only. Never put synthetic credentials in arguments,
      // environment, files, assertions, or diagnostic output.
      input: JSON.stringify({ authOrigin, cases }),
      encoding: "utf8",
      windowsHide: true,
      timeout: 90_000,
      maxBuffer: 64 * 1024,
    },
  );
  if (result.status !== 0) {
    for (const line of (result.stderr ?? "").split(/\r?\n/)) {
      try {
        const detail = JSON.parse(line);
        if (
          detail.probe === "real_provider_session_coordination" &&
          detail.result === "failed" &&
          ["read_input", ...names].includes(detail.stage)
        )
          childStage = detail.stage;
      } catch {
        // Do not print compiler/provider stderr; it may contain private input.
      }
    }
  }
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0);
  const report = JSON.parse(result.stdout.trim());
  assert.equal(report.result, "passed");
  assert.equal(report.probe, "real_provider_session_coordination");
  assert.deepEqual(
    report.cases.map((item) => item.name),
    names,
  );
  for (const item of report.cases) assert.equal(item.passed, true);
  console.log(
    JSON.stringify({
      result: "passed",
      probe: "real_provider_session_coordination",
      cases: names.map((name) => ({ name, passed: true })),
      appIntegration: false,
      moneyMoved: false,
    }),
  );
}

try {
  await withIsolatedAuthFixture(run, { recoveryCodes: true });
  console.log(JSON.stringify({ ownedFixtureCleanup: "complete" }));
} catch (error) {
  // Failed assertions/child output may contain tokens. Emit safe stage only.
  console.error(
    JSON.stringify({
      result: "failed",
      stage,
      lastStatus,
      childStage,
      failureType:
        error instanceof assert.AssertionError ? "assertion" : "other",
      sourceLines: [
        ...String(error?.stack ?? "").matchAll(
          /check-session-coordination\.mjs:(\d+):\d+/g,
        ),
      ].map((match) => Number(match[1])),
    }),
  );
  process.exitCode = 1;
}
