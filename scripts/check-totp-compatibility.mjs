import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import { generateTotp } from "./lib/totp-fixture.mjs";

// Provider compatibility experiment only. No Nene DB, credentials or banking API.
// Docker resources are unique, labelled, disposable and never reused for the app.
const authImage = "public.ecr.aws/supabase/gotrue:v2.197.0";
const databaseImage = "postgres:16-alpine";
const requireBackend = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
const { createClient } = requireBackend("@supabase/supabase-js");
const runId = randomUUID();
const prefix = `nene-totp-check-${runId}`;
const label = `dev.nene.totp-check=${runId}`;
const names = { network: prefix, db: `${prefix}-db`, auth: `${prefix}-auth` };
const jwtSecret = randomBytes(48).toString("base64url");
const databasePassword = randomBytes(32).toString("base64url");
const created = [];
const observations = [];
const signals = new AbortController();
let stage = "preflight",
  origin,
  cleanupFailed = false,
  lastHttp;
let failed = false;
for (const signal of ["SIGINT", "SIGTERM"])
  process.once(signal, () => signals.abort());

// Refuse remote engines; never inherit user Docker overrides into this experiment.
const dockerEnv = { ...process.env };
for (const key of Object.keys(dockerEnv)) {
  if (
    [
      "DOCKER_HOST",
      "DOCKER_CONTEXT",
      "DOCKER_TLS_VERIFY",
      "DOCKER_CERT_PATH",
    ].includes(key.toUpperCase())
  )
    delete dockerEnv[key];
}
dockerEnv.DOCKER_HOST = "npipe:////./pipe/dockerDesktopLinuxEngine";

function docker(args, { env = {}, input, timeout = 30_000 } = {}) {
  const result = spawnSync("docker", args, {
    input,
    encoding: "utf8",
    timeout,
    windowsHide: true,
    env: { ...dockerEnv, ...env },
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0)
    throw new Error("Local Docker command failed.");
  return result.stdout.trim();
}

function inspect(name, kind = "container") {
  return JSON.parse(docker([kind, "inspect", name]))[0];
}

function findCreatedResource(kind, name) {
  // A create command can lose its reply after succeeding. Listing must succeed
  // before absence counts as clean; never swallow a Docker connection failure.
  const output = docker([
    kind,
    "ls",
    ...(kind === "container" ? ["--all"] : []),
    "--filter",
    `name=${name}`,
    "--format",
    "{{json .}}",
  ]);
  return output
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .find(
      (resource) =>
        (kind === "container" ? resource.Names : resource.Name) === name,
    );
}

function record(name, detail) {
  observations.push({ name, ...detail });
  console.log(JSON.stringify({ check: name, ...detail }));
}

function jwt(role) {
  const now = Math.floor(Date.now() / 1000);
  const header = Buffer.from(
    JSON.stringify({ alg: "HS256", typ: "JWT" }),
  ).toString("base64url");
  const body = Buffer.from(
    JSON.stringify({ role, iss: "supabase", iat: now, exp: now + 3600 }),
  ).toString("base64url");
  const signature = createHmac("sha256", jwtSecret)
    .update(`${header}.${body}`)
    .digest("base64url");
  return `${header}.${body}.${signature}`;
}

function claims(token) {
  // Diagnostic comparisons only; authorization is verified by the Auth server.
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
}

async function request(route, { token, body, method = "GET", ip } = {}) {
  signals.signal.throwIfAborted();
  const response = await fetch(`${origin}${route}`, {
    method,
    redirect: "error",
    signal: AbortSignal.any([signals.signal, AbortSignal.timeout(10_000)]),
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(ip ? { "X-Forwarded-For": ip } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const data = await response.json();
  const result = { status: response.status, data };
  lastHttp = safeResult(result);
  return result;
}

function safeResult(result) {
  const error = result.data?.error_code;
  return {
    status: result.status,
    ...(typeof error === "string" && /^[a-z_]+$/.test(error) ? { error } : {}),
  };
}

function sql(statement) {
  return docker(
    [
      "exec",
      "--interactive",
      names.db,
      "psql",
      "-X",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-Atq",
      "-v",
      "ON_ERROR_STOP=1",
    ],
    { input: statement },
  );
}

async function availablePort() {
  for (let port = 3001; port <= 3005; port++) {
    const server = createServer();
    try {
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, "127.0.0.1", resolve);
      });
      await new Promise((resolve) => server.close(resolve));
      return port;
    } catch {
      server.close();
    }
  }
  throw new Error("No free Nene API port; nothing stopped.");
}

async function startFixture() {
  assert.equal(
    process.platform,
    "win32",
    "This local Docker Desktop runner targets Windows.",
  );
  const authInfo = inspect(authImage, "image");
  const dbInfo = inspect(databaseImage, "image");
  record("runtime", {
    authImage,
    authImageId: authInfo.Id,
    databaseImage,
    databaseImageId: dbInfo.Id,
    sdk: requireBackend("@supabase/supabase-js/package.json").version,
  });
  const port = await availablePort();
  origin = `http://127.0.0.1:${port}`;
  created.push(["network", names.network]);
  docker([
    "network",
    "create",
    "--opt",
    "com.docker.network.bridge.host_binding_ipv4=127.0.0.1",
    "--label",
    label,
    names.network,
  ]);
  const dbEnv = {
    POSTGRES_PASSWORD: databasePassword,
    POSTGRES_INITDB_ARGS: "--auth-host=scram-sha-256",
  };
  created.push(["container", names.db]);
  docker(
    [
      "create",
      "--pull=never",
      "--name",
      names.db,
      "--label",
      label,
      "--network",
      names.network,
      "--tmpfs",
      "/var/lib/postgresql/data:rw",
      "--log-driver=none",
      ...Object.keys(dbEnv).flatMap((key) => ["--env", key]),
      dbInfo.Id,
    ],
    { env: dbEnv },
  );
  docker(["start", names.db]);
  stage = "isolated database readiness";
  let ready = false;
  for (let i = 0; i < 80; i++) {
    signals.signal.throwIfAborted();
    try {
      docker([
        "exec",
        names.db,
        "pg_isready",
        "-h",
        "127.0.0.1",
        "-U",
        "postgres",
      ]);
      ready = true;
      break;
    } catch {
      await delay(250, undefined, { signal: signals.signal });
    }
  }
  assert.ok(ready);
  sql(
    "create schema if not exists auth; alter role postgres set search_path to auth, public;",
  );
  const authEnv = {
    GOTRUE_API_HOST: "0.0.0.0",
    GOTRUE_API_PORT: "9999",
    API_EXTERNAL_URL: origin,
    GOTRUE_SITE_URL: origin,
    GOTRUE_DB_DRIVER: "postgres",
    GOTRUE_DB_DATABASE_URL: `postgres://postgres:${databasePassword}@${names.db}:5432/postgres?sslmode=disable`,
    GOTRUE_DB_NAMESPACE: "auth",
    GOTRUE_JWT_SECRET: jwtSecret,
    GOTRUE_JWT_EXP: "3600",
    GOTRUE_JWT_AUD: "authenticated",
    GOTRUE_JWT_DEFAULT_GROUP_NAME: "authenticated",
    GOTRUE_JWT_ADMIN_ROLES: "service_role",
    GOTRUE_DISABLE_SIGNUP: "true",
    GOTRUE_EXTERNAL_EMAIL_ENABLED: "true",
    GOTRUE_MAILER_AUTOCONFIRM: "true",
    GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED: "true",
    GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL: "10",
    GOTRUE_MFA_TOTP_ENROLL_ENABLED: "true",
    GOTRUE_MFA_TOTP_VERIFY_ENABLED: "true",
    GOTRUE_MFA_PHONE_ENROLL_ENABLED: "false",
    GOTRUE_MFA_PHONE_VERIFY_ENABLED: "false",
    // Elevated only in this disposable fixture; production rate limits are not tested.
    GOTRUE_MFA_RATE_LIMIT_CHALLENGE_AND_VERIFY: "200",
    GOTRUE_LOG_LEVEL: "error",
  };
  created.push(["container", names.auth]);
  docker(
    [
      "create",
      "--pull=never",
      "--name",
      names.auth,
      "--label",
      label,
      "--network",
      names.network,
      "--publish",
      `127.0.0.1:${port}:9999`,
      "--log-driver=none",
      ...Object.keys(authEnv).flatMap((key) => ["--env", key]),
      authInfo.Id,
    ],
    { env: authEnv },
  );
  docker(["start", names.auth]);
  const bindings = inspect(names.auth).NetworkSettings.Ports;
  assert.deepEqual(bindings["9999/tcp"], [
    { HostIp: "127.0.0.1", HostPort: String(port) },
  ]);
  stage = "isolated Auth readiness";
  ready = false;
  for (let i = 0; i < 20; i++) {
    signals.signal.throwIfAborted();
    if (!inspect(names.auth).State.Running)
      throw new Error("Fixture Auth exited.");
    try {
      if (
        (
          await fetch(`${origin}/health`, {
            signal: AbortSignal.any([
              signals.signal,
              AbortSignal.timeout(1000),
            ]),
            redirect: "error",
          })
        ).ok
      ) {
        ready = true;
        break;
      }
    } catch {
      /* readiness only */
    }
    await delay(250, undefined, { signal: signals.signal });
  }
  assert.ok(ready);
  assert.deepEqual(inspect(names.db).HostConfig.PortBindings, {});
  record("isolation", {
    runId,
    loopbackOnly: true,
    port,
    dedicatedNetwork: true,
    disposableDatabase: true,
    persistentNeneChanged: false,
  });
}

async function user() {
  const email = `totp-${randomUUID()}@example.invalid`;
  const password = randomBytes(24).toString("base64url");
  const createdUser = await request("/admin/users", {
    token: jwt("service_role"),
    method: "POST",
    body: { email, password, email_confirm: true },
  });
  assert.equal(createdUser.status, 200);
  const session = await request("/token?grant_type=password", {
    method: "POST",
    body: { email, password },
  });
  assert.equal(session.status, 200);
  assert.equal(claims(session.data.access_token).aal, "aal1");
  return { id: createdUser.data.id, session: session.data, email, password };
}

async function challenge(factor, token, ip) {
  const result = await request(`/factors/${factor}/challenge`, {
    token,
    method: "POST",
    body: {},
    ip,
  });
  assert.equal(result.status, 200);
  assert.match(result.data.id, /^[0-9a-f-]{36}$/i);
  return result.data.id;
}

function verify(factor, challengeId, token, code, ip) {
  return request(`/factors/${factor}/verify`, {
    token,
    method: "POST",
    body: { challenge_id: challengeId, code },
    ip,
  });
}

async function stableCode(secret) {
  // Leave enough of the same time step for concurrent calls; never log the code.
  const remaining = 30_000 - (Date.now() % 30_000);
  if (remaining < 5000)
    await delay(remaining + 100, undefined, { signal: signals.signal });
  return generateTotp(secret);
}

function sdk() {
  return createClient(origin, jwt("anon"), {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
      storageKey: randomUUID(),
    },
    global: {
      fetch: (input, init) => {
        const target = new URL(typeof input === "string" ? input : input.url);
        assert.equal(target.origin, origin);
        target.pathname = target.pathname.replace(/^\/auth\/v1(?=\/)/, "");
        return fetch(target, {
          ...init,
          redirect: "error",
          signal: AbortSignal.any([
            signals.signal,
            AbortSignal.timeout(10_000),
          ]),
        });
      },
    },
  });
}

async function evaluate() {
  stage = "provisioned synthetic users and disabled signup";
  const a = await user();
  const b = await user();
  const deniedSignup = await request("/signup", {
    method: "POST",
    body: {
      email: `signup-${randomUUID()}@example.invalid`,
      password: randomBytes(24).toString("base64url"),
    },
  });
  assert.equal(deniedSignup.status, 422);
  record("public_signup_disabled", safeResult(deniedSignup));
  const anonEnroll = await request("/factors", {
    method: "POST",
    body: { factor_type: "totp" },
  });
  assert.equal(anonEnroll.status, 401);
  record("anonymous_enrollment_denied", safeResult(anonEnroll));
  const oldToken = a.session.access_token;
  stage = "factor enrollment and invalid codes";
  const enrolled = await request("/factors", {
    token: oldToken,
    method: "POST",
    body: {
      factor_type: "totp",
      friendly_name: "Synthetic compatibility check",
      issuer: "Nene local experiment",
    },
  });
  assert.equal(enrolled.status, 200);
  const { id: factor, totp } = enrolled.data;
  assert.equal(typeof totp.secret, "string");
  assert.equal(typeof totp.qr_code, "string");
  const now = Math.floor(Date.now() / 1000);
  const validCodes = new Set(
    [-60, -30, 0, 30, 60].map((offset) =>
      generateTotp(totp.secret, { timestampSeconds: now + offset }),
    ),
  );
  let wrongCode = "000000";
  while (validCodes.has(wrongCode))
    wrongCode = String(Number(wrongCode) + 1).padStart(6, "0");
  const wrong = await verify(
    factor,
    await challenge(factor, oldToken),
    oldToken,
    wrongCode,
  );
  assert.equal(wrong.status, 422);
  record("wrong_code_denied", safeResult(wrong));
  let oldTime = now - 300;
  while (
    validCodes.has(generateTotp(totp.secret, { timestampSeconds: oldTime }))
  )
    oldTime -= 30;
  const expired = await verify(
    factor,
    await challenge(factor, oldToken),
    oldToken,
    generateTotp(totp.secret, { timestampSeconds: oldTime }),
  );
  assert.equal(expired.status, 422);
  record("old_code_denied", safeResult(expired));
  const otherUser = await verify(
    factor,
    await challenge(factor, oldToken),
    b.session.access_token,
    await stableCode(totp.secret),
  );
  assert.ok([403, 404].includes(otherUser.status));
  record("other_user_denied", safeResult(otherUser));
  const otherChallenge = await request(`/factors/${factor}/challenge`, {
    token: b.session.access_token,
    method: "POST",
    body: {},
  });
  assert.equal(otherChallenge.status, 404);
  record("other_user_challenge_denied", safeResult(otherChallenge));

  stage = "valid enrollment and session rotation";
  const firstChallenge = await challenge(factor, oldToken);
  const firstCode = await stableCode(totp.secret);
  const first = await verify(factor, firstChallenge, oldToken, firstCode);
  assert.equal(first.status, 200);
  assert.equal(claims(first.data.access_token).aal, "aal2");
  assert.equal(
    (await request("/user", { token: first.data.access_token })).status,
    200,
  );
  const sameSession =
    claims(oldToken).session_id === claims(first.data.access_token).session_id;
  record("valid_verification", {
    status: first.status,
    aal: "aal2",
    sameSessionId: sameSession,
    refreshTokenRotated: a.session.refresh_token !== first.data.refresh_token,
  });
  record(
    "old_access_token_after_verification",
    safeResult(await request("/user", { token: oldToken })),
  );
  a.session = first.data;
  const token = a.session.access_token;

  stage = "successful challenge and code replay";
  const replay = await verify(factor, firstChallenge, token, firstCode);
  assert.equal(replay.status, 422);
  assert.equal(replay.data.error_code, "mfa_ip_address_mismatch");
  record("same_challenge_replay", safeResult(replay));
  const second = await verify(
    factor,
    await challenge(factor, token),
    token,
    firstCode,
  );
  assert.ok([200, 422].includes(second.status));
  record("same_successful_code_new_challenge", safeResult(second));
  const concurrentCreation = await Promise.all(
    [0, 1].map(() =>
      request(`/factors/${factor}/challenge`, {
        token,
        method: "POST",
        body: {},
      }),
    ),
  );
  assert.ok(
    concurrentCreation.every((result) => [200, 500].includes(result.status)),
  );
  record("concurrent_challenge_creation", {
    results: concurrentCreation.map(safeResult),
  });
  // Separate creation conflicts from the verification concurrency observation.
  const parallelChallenges = [
    await challenge(factor, token),
    await challenge(factor, token),
  ];
  const parallelCode = await stableCode(totp.secret);
  const parallel = await Promise.all(
    parallelChallenges.map((id) => verify(factor, id, token, parallelCode)),
  );
  assert.ok(
    parallel.every((result) => [200, 422, 500].includes(result.status)),
  );
  record("same_code_concurrent_distinct_challenges", {
    results: parallel.map(safeResult),
    accepted: parallel.filter((r) => r.status === 200).length,
  });
  const duplicateChallenge = await challenge(factor, token);
  const duplicateCode = await stableCode(totp.secret);
  const duplicate = await Promise.all([
    verify(factor, duplicateChallenge, token, duplicateCode),
    verify(factor, duplicateChallenge, token, duplicateCode),
  ]);
  assert.ok(
    duplicate.every((result) => [200, 422, 500].includes(result.status)),
  );
  record("same_challenge_concurrent_verification", {
    results: duplicate.map(safeResult),
    accepted: duplicate.filter((r) => r.status === 200).length,
  });

  stage = "IP binding and challenge expiry";
  const ipChallenge = await challenge(factor, token, "192.0.2.10");
  const changedIp = await verify(
    factor,
    ipChallenge,
    token,
    await stableCode(totp.secret),
    "192.0.2.11",
  );
  assert.equal(changedIp.status, 422);
  assert.equal(changedIp.data.error_code, "mfa_ip_address_mismatch");
  record("changed_forwarded_ip_denied", safeResult(changedIp));
  const sameIp = await verify(
    factor,
    ipChallenge,
    token,
    await stableCode(totp.secret),
    "192.0.2.10",
  );
  assert.equal(sameIp.status, 200);
  record("same_forwarded_ip_accepted", safeResult(sameIp));
  const agedChallenge = await challenge(factor, token);
  sql(
    `update auth.mfa_challenges set created_at = now() - interval '10 minutes' where id = '${agedChallenge}';`,
  );
  const aged = await verify(
    factor,
    agedChallenge,
    token,
    await stableCode(totp.secret),
  );
  assert.equal(aged.status, 422);
  assert.equal(aged.data.error_code, "mfa_challenge_expired");
  record("aged_fixture_challenge_denied", safeResult(aged));

  stage = "lost successful reply recovery";
  const lostChallenge = await challenge(factor, token);
  const lostCode = await stableCode(totp.secret);
  // Intentionally discard the successful response; no local operation receipt exists.
  assert.equal(
    (await verify(factor, lostChallenge, token, lostCode)).status,
    200,
  );
  const retry = await verify(factor, lostChallenge, token, lostCode);
  assert.equal(retry.status, 422);
  assert.equal(retry.data.error_code, "mfa_ip_address_mismatch");
  record("discarded_success_reply_then_retry", {
    ...safeResult(retry),
    recoverableTransactionReceipt: false,
  });

  stage = "request-scoped installed SDK integration";
  const clientA = sdk();
  const clientB = sdk();
  assert.equal(
    (
      await clientA.auth.setSession({
        access_token: token,
        refresh_token: a.session.refresh_token,
      })
    ).error,
    null,
  );
  assert.equal(
    (
      await clientB.auth.setSession({
        access_token: b.session.access_token,
        refresh_token: b.session.refresh_token,
      })
    ).error,
    null,
  );
  const sdkChallenge = await clientA.auth.mfa.challenge({ factorId: factor });
  assert.equal(sdkChallenge.error, null);
  const sdkVerified = await clientA.auth.mfa.verify({
    factorId: factor,
    challengeId: sdkChallenge.data.id,
    code: await stableCode(totp.secret),
  });
  assert.equal(sdkVerified.error, null);
  assert.equal((await clientA.auth.getUser()).data.user.id, a.id);
  assert.equal((await clientB.auth.getUser()).data.user.id, b.id);
  const refreshed = await clientA.auth.refreshSession();
  assert.equal(refreshed.error, null);
  assert.equal(claims(refreshed.data.session.access_token).aal, "aal2");
  record("installed_sdk_request_scoping_and_refresh", {
    verified: true,
    usersIsolated: true,
    refreshSucceeded: true,
    sameSessionId:
      claims(refreshed.data.session.access_token).session_id ===
      claims(token).session_id,
  });
  const removed = await clientA.auth.mfa.unenroll({ factorId: factor });
  assert.equal(removed.error, null);
  const removedChallenge = await request(`/factors/${factor}/challenge`, {
    token: refreshed.data.session.access_token,
    method: "POST",
    body: {},
  });
  assert.equal(removedChallenge.status, 404);
  record("removed_factor_denied", safeResult(removedChallenge));

  stage = "pre-MFA refresh token recovery in separate fixture";
  const recoveryUser = await user();
  const recoveryFactor = await request("/factors", {
    token: recoveryUser.session.access_token,
    method: "POST",
    body: { factor_type: "totp" },
  });
  assert.equal(recoveryFactor.status, 200);
  const recoverySuccess = await verify(
    recoveryFactor.data.id,
    await challenge(recoveryFactor.data.id, recoveryUser.session.access_token),
    recoveryUser.session.access_token,
    await stableCode(recoveryFactor.data.totp.secret),
  );
  assert.equal(recoverySuccess.status, 200);
  const oldRefresh = await request("/token?grant_type=refresh_token", {
    method: "POST",
    body: { refresh_token: recoveryUser.session.refresh_token },
  });
  assert.ok([200, 400, 401, 422].includes(oldRefresh.status));
  record("pre_MFA_refresh_token_after_verification", {
    ...safeResult(oldRefresh),
    ...(oldRefresh.status === 200
      ? { aal: claims(oldRefresh.data.access_token).aal }
      : {}),
  });
  const returnedRefresh = await request("/token?grant_type=refresh_token", {
    method: "POST",
    body: { refresh_token: recoverySuccess.data.refresh_token },
  });
  assert.ok([200, 400, 401, 422].includes(returnedRefresh.status));
  record("returned_refresh_after_old_token_retry", {
    ...safeResult(returnedRefresh),
    ...(returnedRefresh.status === 200
      ? { aal: claims(returnedRefresh.data.access_token).aal }
      : {}),
  });

  const replayAccepted =
    second.status === 200 ||
    parallel.filter((r) => r.status === 200).length > 1 ||
    duplicate.filter((r) => r.status === 200).length > 1;
  record("compatibility_verdict", {
    providerEnrollmentAndVerificationWork: true,
    providerAloneMeetsTransactionRules: false,
    successfulCodeReplayObserved: replayAccepted,
    concurrentProviderErrorObserved: [
      ...concurrentCreation,
      ...parallel,
      ...duplicate,
    ].some((result) => result.status === 500),
    neneFinancialFlowImplementedOrTested: false,
  });
}

try {
  await startFixture();
  await evaluate();
} catch {
  failed = true;
  console.error(
    `TOTP experiment failed during: ${stage}. Provider bodies, codes and credentials were suppressed.`,
  );
  if (lastHttp) console.error(JSON.stringify({ lastHttp }));
} finally {
  for (const [kind, name] of created.reverse()) {
    try {
      if (!findCreatedResource(kind, name)) continue;
      const resource = inspect(name, kind);
      const resourceLabels =
        kind === "network" ? resource.Labels : resource.Config.Labels;
      assert.equal(resourceLabels["dev.nene.totp-check"], runId);
      if (kind === "container")
        docker(["rm", "--force", "--volumes", resource.Id]);
      else docker(["network", "rm", resource.Id]);
    } catch {
      cleanupFailed = true;
      console.error(
        `Cleanup requires attention for this experiment resource: ${name}`,
      );
    }
  }
  record("cleanup", {
    complete: !cleanupFailed,
    observations: observations.length,
  });
  process.exitCode = failed || cleanupFailed ? 1 : 0;
}
