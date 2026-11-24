import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";

// Provider compatibility only. Synthetic users, ephemeral labelled resources,
// no Nene app/database credentials and no production recovery implementation.
const requireBackend = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
const { createClient } = requireBackend("@supabase/supabase-js");
let stage = "preflight";
let lastHttp;
let observations = 0;
const rejectedGates = [];

function record(check, detail = {}) {
  observations += 1;
  console.log(JSON.stringify({ check, ...detail }));
}

function safeHttp(status, data) {
  const error = data?.error_code ?? data?.code;
  return {
    status,
    ...(typeof error === "string" && /^[a-z_]+$/.test(error) ? { error } : {}),
  };
}

function toolsFor(fixture) {
  const { authOrigin, signal, adminToken, anonKey, verifyAccessToken } =
    fixture;
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
    lastHttp = { status: response.status };
    // Generated QR SVGs are verbose. Bound the actual streamed bytes instead
    // of buffering an unlimited body or mistaking SVG size for Auth failure.
    const limit =
      route === "/factors" && method === "POST" ? 2 * 1024 * 1024 : 128 * 1024;
    const reader = response.body?.getReader();
    const chunks = [];
    let responseBytes = 0;
    if (reader) {
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          responseBytes += value.byteLength;
          assert.ok(responseBytes <= limit);
          chunks.push(value);
        }
      } catch (error) {
        await reader.cancel().catch(() => {});
        throw error;
      } finally {
        reader.releaseLock();
      }
    }
    const raw = Buffer.concat(chunks).toString("utf8");
    const data = raw ? JSON.parse(raw) : null;
    lastHttp = safeHttp(response.status, data);
    return { status: response.status, data, responseBytes };
  }

  async function login(user) {
    const result = await request("/token?grant_type=password", {
      method: "POST",
      body: { email: user.email, password: user.password },
    });
    assert.equal(result.status, 200);
    const claims = verifyAccessToken(result.data.access_token);
    assert.equal(claims.sub, user.id);
    assert.equal(claims.aal, "aal1");
    return result.data;
  }

  async function user() {
    const email = `recovery-${randomUUID()}@example.invalid`;
    const password = randomBytes(24).toString("base64url");
    const created = await request("/admin/users", {
      token: adminToken,
      method: "POST",
      body: { email, password, email_confirm: true },
    });
    assert.equal(created.status, 200);
    const result = { id: created.data.id, email, password };
    return { ...result, session: await login(result) };
  }

  async function enroll(session, name) {
    const parentStage = stage;
    stage = `${parentStage}: enroll request`;
    const result = await request("/factors", {
      token: session.access_token,
      method: "POST",
      body: {
        factor_type: "totp",
        friendly_name: name,
        issuer: "Nene isolated check",
      },
    });
    assert.equal(result.status, 200);
    assert.equal(typeof result.data.totp.secret, "string");
    record("totp_enrollment_response_size", {
      bytes: result.responseBytes,
      limit: 2 * 1024 * 1024,
    });
    stage = parentStage;
    return result.data;
  }

  async function verifyTotp(session, factor) {
    const parentStage = stage;
    stage = `${parentStage}: challenge request`;
    const remaining = 30_000 - (Date.now() % 30_000);
    if (remaining < 3000) await delay(remaining + 100, undefined, { signal });
    const challenge = await request(`/factors/${factor.id}/challenge`, {
      token: session.access_token,
      method: "POST",
      body: {},
    });
    assert.equal(challenge.status, 200);
    stage = `${parentStage}: verify request`;
    const result = await request(`/factors/${factor.id}/verify`, {
      token: session.access_token,
      method: "POST",
      body: {
        challenge_id: challenge.data.id,
        code: generateTotp(factor.totp.secret),
      },
    });
    assert.equal(result.status, 200);
    assert.equal(verifyAccessToken(result.data.access_token).aal, "aal2");
    stage = parentStage;
    return result.data;
  }

  async function prepared(name) {
    const result = await user();
    result.factor = await enroll(result.session, name);
    result.session = await verifyTotp(result.session, result.factor);
    return result;
  }

  const recovery = (session, code) =>
    request("/factors/recovery-codes/verify", {
      token: session.access_token,
      method: "POST",
      body: { code },
    });
  async function status(session) {
    const result = await request("/factors/recovery-codes", {
      token: session.access_token,
    });
    assert.equal(result.status, 200);
    assert.deepEqual(Object.keys(result.data).sort(), [
      "id",
      "remaining",
      "total",
      "type",
    ]);
    assert.equal(result.data.type, "recovery_code");
    return result.data;
  }
  async function generate(session) {
    const result = await request("/factors/recovery-codes", {
      token: session.access_token,
      method: "POST",
      body: {},
    });
    assert.equal(result.status, 200);
    assert.equal(result.data.codes.length, result.data.total);
    assert.equal(new Set(result.data.codes).size, result.data.total);
    return result.data;
  }

  function sdk(enabled) {
    return createClient(authOrigin, anonKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
        storageKey: randomUUID(),
        experimental: { recoveryCodes: enabled },
      },
      global: {
        fetch: (input, init) => {
          const target = new URL(typeof input === "string" ? input : input.url);
          assert.equal(target.origin, authOrigin);
          target.pathname = target.pathname.replace(/^\/auth\/v1(?=\/)/, "");
          return fetch(target, {
            ...init,
            redirect: "error",
            signal: AbortSignal.any([signal, AbortSignal.timeout(15_000)]),
          });
        },
      },
    });
  }
  return {
    request,
    login,
    user,
    enroll,
    verifyTotp,
    prepared,
    recovery,
    status,
    generate,
    sdk,
  };
}

async function disabledProbe(fixture) {
  const { user, request, sdk } = toolsFor(fixture);
  stage = "disabled provider and SDK gates";
  record("disabled_runtime", {
    ...fixture.runtime,
    sdk: requireBackend("@supabase/supabase-js/package.json").version,
  });
  const a = await user();
  for (const [route, error] of [
    ["/factors/recovery-codes", "mfa_recovery_codes_enroll_not_enabled"],
    ["/factors/recovery-codes/verify", "mfa_recovery_codes_verify_not_enabled"],
  ]) {
    const result = await request(route, {
      token: a.session.access_token,
      method: "POST",
      body: { code: "invalid-synthetic-code" },
    });
    assert.equal(result.status, 422);
    assert.equal(result.data.error_code, error);
    record(error, safeHttp(result.status, result.data));
  }
  const client = sdk(false);
  try {
    await assert.rejects(client.auth.mfa.recoveryCodes.generate());
    record("sdk_experimental_gate_rejects_disabled_call");
  } finally {
    await client.auth.stopAutoRefresh();
  }
}

async function enabledProbe(fixture) {
  const { verifyAccessToken, signal } = fixture;
  const {
    request,
    login,
    user,
    enroll,
    verifyTotp,
    prepared,
    recovery,
    status,
    generate,
    sdk,
  } = toolsFor(fixture);
  record("enabled_runtime", fixture.runtime);

  stage = "fresh password evidence and signature verification";
  const a = await user();
  const initial = verifyAccessToken(a.session.access_token);
  const passwordTime = (claims) =>
    claims.amr.find((method) => method.method === "password")?.timestamp;
  assert.ok(Number.isInteger(passwordTime(initial)));
  const pieces = a.session.access_token.split(".");
  const altered = JSON.parse(Buffer.from(pieces[1], "base64url").toString());
  altered.amr = [
    { method: "password", timestamp: Math.floor(Date.now() / 1000) + 600 },
  ];
  pieces[1] = Buffer.from(JSON.stringify(altered)).toString("base64url");
  assert.throws(() => verifyAccessToken(pieces.join(".")));
  await delay(1200, undefined, { signal });
  const refreshed = await request("/token?grant_type=refresh_token", {
    method: "POST",
    body: { refresh_token: a.session.refresh_token },
  });
  assert.equal(refreshed.status, 200);
  const refreshedClaims = verifyAccessToken(refreshed.data.access_token);
  assert.equal(passwordTime(refreshedClaims), passwordTime(initial));
  assert.equal(refreshedClaims.session_id, initial.session_id);
  assert.ok(refreshedClaims.iat > initial.iat);
  a.session = await login(a);
  const freshClaims = verifyAccessToken(a.session.access_token);
  assert.ok(passwordTime(freshClaims) > passwordTime(initial));
  assert.notEqual(freshClaims.session_id, initial.session_id);
  record("signed_password_evidence_refresh_vs_fresh_login", {
    tamperedClaimsRejected: true,
    refreshPreservesPasswordTime: true,
    refreshAdvancesIssuedAt: true,
    passwordLoginChangesSession: true,
  });

  stage = "AAL1 and anonymous generation restrictions";
  const factorsBefore = await request("/user", {
    token: a.session.access_token,
  });
  assert.equal(factorsBefore.status, 200);
  const anon = await request("/factors/recovery-codes", {
    method: "POST",
    body: {},
  });
  assert.equal(anon.status, 401);
  const low = await request("/factors/recovery-codes", {
    token: a.session.access_token,
    method: "POST",
    body: {},
  });
  assert.equal(low.status, 403);
  assert.equal(low.data.error_code, "insufficient_aal");
  record("generation_requires_authenticated_aal2", {
    anonymous: safeHttp(anon.status, anon.data),
    aal1: safeHttp(low.status, low.data),
  });
  const factorsAfter = await request("/user", {
    token: a.session.access_token,
  });
  assert.equal(factorsAfter.status, 200);
  const inventory = (value) =>
    (value.factors ?? []).map((factor) => ({
      type: ["totp", "phone", "recovery_code", "webauthn"].includes(
        factor.factor_type,
      )
        ? factor.factor_type
        : "unknown",
      status: ["verified", "unverified"].includes(factor.status)
        ? factor.status
        : "unknown",
    }));
  record("factor_inventory_around_denied_generation", {
    before: inventory(factorsBefore.data),
    after: inventory(factorsAfter.data),
  });

  stage = "TOTP enrollment before recovery generation";
  a.factor = await enroll(a.session, "Original synthetic authenticator");
  a.session = await verifyTotp(a.session, a.factor);
  const afterTotp = verifyAccessToken(a.session.access_token);
  const storedAal = fixture.sql(
    `select aal from auth.sessions where id = '${afterTotp.session_id}';`,
  );
  assert.ok(["aal1", "aal2"].includes(storedAal));
  record("totp_session_before_sdk_adoption", {
    tokenAal: afterTotp.aal,
    storedAal,
  });
  const client = sdk(true);
  let set;
  try {
    stage = "SDK session adoption before recovery generation";
    const adopted = await client.auth.setSession(a.session);
    lastHttp = safeHttp(adopted.error?.status ?? 200, adopted.error);
    assert.equal(adopted.error, null);
    a.session = adopted.data.session;
    const adoptedClaims = verifyAccessToken(a.session.access_token);
    const sdkSession = await client.auth.getSession();
    assert.equal(sdkSession.error, null);
    assert.equal(sdkSession.data.session.access_token, a.session.access_token);
    record("sdk_session_after_adoption", {
      aal: adoptedClaims.aal,
      sameSession: adoptedClaims.session_id === afterTotp.session_id,
      sameAccessToken:
        sdkSession.data.session.access_token === a.session.access_token,
    });
    stage = "SDK recovery-code generation";
    const generated = await client.auth.mfa.recoveryCodes.generate({
      friendlyName: "Synthetic backup set",
    });
    lastHttp = safeHttp(generated.error?.status ?? 200, generated.error);
    assert.equal(generated.error, null);
    set = generated.data;
    assert.equal(set.codes.length, set.total);
    assert.equal(new Set(set.codes).size, set.total);
    stage = "SDK recovery-code status and duplicate";
    const read = await client.auth.mfa.recoveryCodes.getStatus();
    assert.equal(read.error, null);
    assert.equal(read.data.remaining, set.total);
    assert.ok(!Object.hasOwn(read.data, "codes"));
    const duplicate = await client.auth.mfa.recoveryCodes.generate();
    assert.equal(duplicate.error?.code, "mfa_verified_factor_exists");
    record("sdk_generate_status_and_duplicate", {
      total: set.total,
      noPlaintextInStatus: true,
      duplicate: safeHttp(duplicate.error.status, duplicate.error),
    });
  } finally {
    await client.auth.stopAutoRefresh();
  }
  const other = await user();
  const otherAttempt = await recovery(other.session, set.codes[0]);
  assert.equal(otherAttempt.status, 422);
  assert.equal(otherAttempt.data.error_code, "mfa_verification_failed");
  record(
    "another_customer_cannot_use_code",
    safeHttp(otherAttempt.status, otherAttempt.data),
  );

  stage = "valid recovery and sequential replay";
  a.session = await login(a);
  const preRecovery = verifyAccessToken(a.session.access_token);
  const wrong = await recovery(a.session, "invalid-synthetic-code");
  assert.equal(wrong.status, 422);
  const oldRefresh = a.session.refresh_token;
  const valid = await recovery(a.session, set.codes[0]);
  assert.equal(valid.status, 200);
  const upgraded = verifyAccessToken(valid.data.access_token);
  assert.equal(upgraded.sub, a.id);
  assert.equal(upgraded.session_id, preRecovery.session_id);
  assert.equal(upgraded.aal, "aal2");
  assert.ok(
    upgraded.amr.some((method) => method.method === "mfa/recovery_code"),
  );
  assert.notEqual(valid.data.refresh_token, oldRefresh);
  a.session = valid.data;
  const used = await recovery(a.session, set.codes[0]);
  assert.equal(used.status, 422);
  assert.equal(used.data.error_code, "mfa_verification_failed");
  assert.equal((await status(a.session)).remaining, set.total - 1);
  record("valid_recovery_rotates_pair_same_session_and_rejects_reuse", {
    aal: "aal2",
    sameSession: true,
    recoveryAmr: true,
    refreshRotated: true,
    replay: safeHttp(used.status, used.data),
  });

  stage = "concurrent recovery-code consumption";
  const concurrent = await Promise.all([
    recovery(a.session, set.codes[1]),
    recovery(a.session, set.codes[1]),
  ]);
  const accepted = concurrent.filter((r) => r.status === 200);
  const concurrentSafe =
    accepted.length === 1 && concurrent.some((r) => r.status === 422);
  if (!concurrentSafe)
    rejectedGates.push("concurrent_recovery_code_consumption");
  record("concurrent_same_code_observation", {
    results: concurrent.map((r) => safeHttp(r.status, r.data)),
    accepted: accepted.length,
    gatePassed: concurrentSafe,
  });
  assert.ok(accepted.length >= 1);
  a.session = accepted[0].data;
  assert.equal((await status(a.session)).remaining, set.total - 2);

  stage = "recovery AAL2 can replace TOTP without admin";
  const replacement = await enroll(
    a.session,
    "Replacement synthetic authenticator",
  );
  const before = await request("/user", { token: a.session.access_token });
  assert.equal(before.status, 200);
  assert.equal(
    before.data.factors.find((f) => f.id === a.factor.id)?.status,
    "verified",
  );
  assert.equal(
    before.data.factors.find((f) => f.id === replacement.id)?.status,
    "unverified",
  );
  a.session = await verifyTotp(a.session, replacement);
  const removed = await request(`/factors/${a.factor.id}`, {
    token: a.session.access_token,
    method: "DELETE",
  });
  assert.equal(removed.status, 200);
  const after = await request("/user", { token: a.session.access_token });
  assert.equal(after.status, 200);
  assert.ok(!after.data.factors.some((f) => f.id === a.factor.id));
  assert.equal(
    after.data.factors.find((f) => f.id === replacement.id)?.status,
    "verified",
  );
  record("replacement_verified_before_old_factor_self_removal", {
    oldRetainedUntilVerified: true,
    adminResetUsed: false,
  });

  stage = "backup regeneration invalidates old unused codes";
  const rotated = await request("/factors/recovery-codes/regenerate", {
    token: a.session.access_token,
    method: "POST",
  });
  assert.equal(rotated.status, 200);
  assert.equal(rotated.data.codes.length, set.total);
  const stale = await recovery(a.session, set.codes[2]);
  assert.equal(stale.status, 422);
  const next = await recovery(a.session, rotated.data.codes[0]);
  assert.equal(next.status, 200);
  a.session = next.data;
  record("regeneration_invalidates_prior_set", {
    oldUnusedCode: safeHttp(stale.status, stale.data),
    newCode: safeHttp(next.status, next.data),
    noPlaintextInStatus: !Object.hasOwn(await status(a.session), "codes"),
  });

  stage = "lost verification response and final-code exhaustion";
  const lost = await prepared("Lost reply synthetic authenticator");
  const lostSet = await generate(lost.session);
  lost.session = await login(lost);
  // Deliberately discard successful replies; this models lost application
  // handoff, not a claim that a transport fault was injected.
  const beforeLost = lost.session;
  const discarded = await recovery(beforeLost, lostSet.codes[0]);
  assert.equal(discarded.status, 200);
  const retryLost = await recovery(beforeLost, lostSet.codes[0]);
  assert.equal(retryLost.status, 422);
  lost.session = await login(lost);
  assert.equal((await status(lost.session)).remaining, lostSet.total - 1);
  record("discarded_verification_reply_cannot_replay_code", {
    remaining: lostSet.total - 1,
    retry: safeHttp(retryLost.status, retryLost.data),
    freshLoginAal: verifyAccessToken(lost.session.access_token).aal,
  });
  for (const code of lostSet.codes.slice(1, -1)) {
    const result = await recovery(lost.session, code);
    assert.equal(result.status, 200);
    lost.session = result.data;
  }
  assert.equal((await status(lost.session)).remaining, 1);
  const finalCode = lostSet.codes.at(-1);
  assert.equal((await recovery(lost.session, finalCode)).status, 200);
  lost.session = await login(lost);
  assert.equal((await status(lost.session)).remaining, 0);
  const finalRetry = await recovery(lost.session, finalCode);
  assert.equal(finalRetry.status, 422);
  const noAuthority = await request("/factors/recovery-codes/regenerate", {
    token: lost.session.access_token,
    method: "POST",
  });
  assert.equal(noAuthority.status, 403);
  assert.equal(noAuthority.data.error_code, "insufficient_aal");
  record("last_code_lost_reply_leaves_fresh_login_without_recovery_authority", {
    remaining: 0,
    replay: safeHttp(finalRetry.status, finalRetry.data),
    regenerate: safeHttp(noAuthority.status, noAuthority.data),
  });

  stage = "lost generation response and provider AAL2 breadth";
  const generateLost = await prepared(
    "Lost generation synthetic authenticator",
  );
  const hidden = await generate(generateLost.session);
  const visibleStatus = await status(generateLost.session);
  assert.equal(visibleStatus.remaining, hidden.total);
  const cannotRetrieve = await request("/factors/recovery-codes", {
    token: generateLost.session.access_token,
    method: "POST",
    body: {},
  });
  assert.equal(cannotRetrieve.status, 422);
  const recoverySession = await login(generateLost);
  const recoveryOnly = await recovery(recoverySession, hidden.codes[0]);
  assert.equal(recoveryOnly.status, 200);
  const broadAal2 = await request("/factors/recovery-codes/regenerate", {
    token: recoveryOnly.data.access_token,
    method: "POST",
  });
  assert.equal(broadAal2.status, 200);
  record(
    "lost_generation_status_has_no_secrets_and_recovery_aal2_is_not_purpose_restricted",
    {
      duplicate: safeHttp(cannotRetrieve.status, cannotRetrieve.data),
      recoverySessionCanRegenerate: true,
      nenePurposeRestrictionStillRequired: true,
    },
  );

  stage = "global signout and old access signature";
  const accessBeforeLogout = a.session.access_token;
  const refreshBeforeLogout = a.session.refresh_token;
  const logout = await request("/logout?scope=global", {
    token: accessBeforeLogout,
    method: "POST",
  });
  assert.equal(logout.status, 204);
  const staleRefresh = await request("/token?grant_type=refresh_token", {
    method: "POST",
    body: { refresh_token: refreshBeforeLogout },
  });
  assert.ok([400, 401].includes(staleRefresh.status));
  // Cryptographic validity is deliberately distinguished from provider/session
  // liveness and from Nene's future server-side security revision checks.
  assert.equal(verifyAccessToken(accessBeforeLogout).sub, a.id);
  const staleAccess = await request("/user", { token: accessBeforeLogout });
  assert.ok([200, 401, 403].includes(staleAccess.status));
  record("global_logout_revokes_refresh_but_not_access_signature", {
    refresh: safeHttp(staleRefresh.status, staleRefresh.data),
    userEndpoint: safeHttp(staleAccess.status, staleAccess.data),
    signatureStillValid: true,
  });

  stage = "real provider recovery pair through pinned Dart client";
  const dartUser = await prepared("Dart handoff synthetic authenticator");
  const dartCodes = await generate(dartUser.session);
  dartUser.session = await login(dartUser);
  const dartRecovery = await recovery(dartUser.session, dartCodes.codes[0]);
  assert.equal(dartRecovery.status, 200);
  const dartClaims = verifyAccessToken(dartRecovery.data.access_token);
  assert.equal(dartClaims.sub, dartUser.id);
  assert.equal(dartClaims.aal, "aal2");
  assert.ok(
    dartClaims.amr.some((method) => method.method === "mfa/recovery_code"),
  );
  const absolute = (relative) =>
    fileURLToPath(new URL(relative, import.meta.url));
  const dartResult = spawnSync(
    absolute("../.tools/flutter/bin/cache/dart-sdk/bin/dart.exe"),
    [
      `--packages=${absolute("../app/.dart_tool/package_config.json")}`,
      absolute("../experiments/session_handoff_provider/probe.dart"),
    ],
    {
      // Test credentials cross a private pipe only, never arguments, files or
      // environment. Treat even a failed child process's output as sensitive.
      input: JSON.stringify({
        authOrigin: fixture.authOrigin,
        accessToken: dartRecovery.data.access_token,
        refreshToken: dartRecovery.data.refresh_token,
        expectedUserId: dartUser.id,
        expectedSessionId: dartClaims.session_id,
      }),
      encoding: "utf8",
      windowsHide: true,
      timeout: 45_000,
      maxBuffer: 64 * 1024,
    },
  );
  assert.equal(dartResult.error, undefined);
  assert.equal(dartResult.status, 0);
  const proof = JSON.parse(dartResult.stdout.trim());
  assert.equal(proof.result, "passed");
  assert.equal(proof.probe, "real_provider_dart_session_handoff");
  const trueFields = [
    "freshAdoptionWithoutRefresh",
    "adoptedSubjectAndSessionMatch",
    "explicitRefreshSucceeded",
    "refreshTokenRotated",
    "refreshedSubjectAndSessionMatch",
  ];
  for (const field of trueFields) assert.equal(proof[field], true);
  assert.equal(proof.aal, "aal2");
  assert.equal(proof.refreshExchanges, 1);
  assert.ok(
    Number.isSafeInteger(proof.userEndpointReads) &&
      proof.userEndpointReads >= 1,
  );
  assert.equal(proof.persistentSessionStorage, false);
  assert.equal(proof.appIntegration, false);
  record("real_provider_dart_session_handoff", {
    ...Object.fromEntries(trueFields.map((field) => [field, true])),
    aal: "aal2",
    userEndpointReads: proof.userEndpointReads,
    refreshExchanges: 1,
    persistentSessionStorage: false,
    appIntegration: false,
  });
}

try {
  await withIsolatedAuthFixture(disabledProbe);
  record("disabled_fixture_cleanup_complete");
  await withIsolatedAuthFixture(enabledProbe, { recoveryCodes: true });
  record("enabled_fixture_cleanup_complete");
  console.log(
    JSON.stringify({
      result: rejectedGates.length ? "capability_rejected" : "passed",
      observations,
      rejectedGates,
      appIntegration: false,
      moneyMoved: false,
    }),
  );
  if (rejectedGates.length) process.exitCode = 1;
} catch (error) {
  // Assertion errors can embed raw provider sessions/codes. Never print them.
  console.error(
    JSON.stringify({
      result: "failed",
      stage,
      lastHttp,
      failureType:
        error instanceof assert.AssertionError
          ? "assertion"
          : error instanceof TypeError
            ? "type"
            : "other",
      sourceLines: [
        ...String(error?.stack ?? "").matchAll(
          /check-recovery-compatibility\.mjs:(\d+):\d+/g,
        ),
      ].map((match) => Number(match[1])),
      detail:
        "Failure details suppressed to protect fixture secrets; inspect the named stage.",
    }),
  );
  process.exitCode = 1;
}
