import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { createServer } from "node:net";
import { setTimeout as delay } from "node:timers/promises";

const authImage = "public.ecr.aws/supabase/gotrue:v2.197.0";
const databaseImage = "postgres:16-alpine";
const labelKey = "dev.nene.authorization-prototype";

async function freePorts() {
  const held = [];
  try {
    for (let port = 3001; port <= 3005 && held.length < 2; port++) {
      const server = createServer();
      try {
        await new Promise((resolve, reject) => {
          server.once("error", reject);
          server.listen(port, "127.0.0.1", resolve);
        });
        held.push({ server, port });
      } catch {
        // Busy/reserved ports belong to someone else; never stop their listener.
      }
    }
    if (held.length !== 2)
      throw new Error("Two free Nene test ports in 3001–3005 are required.");
    return held.map(({ port }) => port);
  } finally {
    await Promise.all(
      held.map(({ server }) => new Promise((resolve) => server.close(resolve))),
    );
  }
}

function signedFixtureToken(secret, role) {
  const now = Math.floor(Date.now() / 1000);
  const encode = (value) =>
    Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({
    role,
    iss: "supabase",
    iat: now,
    exp: now + 3600,
  })}`;
  return `${unsigned}.${createHmac("sha256", secret).update(unsigned).digest("base64url")}`;
}

/**
 * Disposable provider/database fixture, never Nene's application database.
 * The callback must close its pg pools before returning. Treat returned URLs,
 * tokens and SQL results as private; only runtime metadata is safe to report.
 * The callback's errors are rethrown after cleanup, so callers must redact them.
 */
export async function withIsolatedAuthFixture(callback) {
  assert.equal(
    process.platform,
    "win32",
    "This fixture targets local Windows Docker Desktop.",
  );
  assert.equal(typeof callback, "function");
  const runId = randomUUID();
  const prefix = `nene-authz-${runId}`;
  const names = { network: prefix, db: `${prefix}-db`, auth: `${prefix}-auth` };
  const label = `${labelKey}=${runId}`;
  const created = [];
  const controller = new AbortController();
  const abort = () => controller.abort();
  for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, abort);
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
  const password = randomBytes(32).toString("base64url");
  const jwtSecret = randomBytes(48).toString("base64url");

  function docker(args, { env = {}, input, timeout = 20_000 } = {}) {
    const result = spawnSync("docker", args, {
      input,
      timeout,
      encoding: "utf8",
      windowsHide: true,
      env: { ...dockerEnv, ...env },
      maxBuffer: 2 * 1024 * 1024,
    });
    // CLI errors can contain credentials or SQL; never include their output.
    if (result.error || result.status !== 0)
      throw new Error("Isolated fixture Docker command failed.");
    return result.stdout.trim();
  }

  const inspect = (name, kind = "container") =>
    JSON.parse(docker([kind, "inspect", name]))[0];

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
      { input: statement, timeout: 15_000 },
    );
  }

  function assertBinding(name, containerPort, hostPort) {
    assert.deepEqual(
      inspect(name).NetworkSettings.Ports[`${containerPort}/tcp`],
      [{ HostIp: "127.0.0.1", HostPort: String(hostPort) }],
    );
  }

  async function waitReady(check) {
    for (let attempt = 0; attempt < 30; attempt++) {
      controller.signal.throwIfAborted();
      if (await check()) return;
      await delay(250, undefined, { signal: controller.signal });
    }
    throw new Error("Isolated fixture readiness timed out.");
  }

  try {
    controller.signal.throwIfAborted();
    // Inspect first: missing cached images fail without a pull or account access.
    const authInfo = inspect(authImage, "image");
    const databaseInfo = inspect(databaseImage, "image");
    const [authPort, databasePort] = await freePorts();
    const authOrigin = `http://127.0.0.1:${authPort}`;
    const databaseUrl = `postgresql://postgres:${password}@127.0.0.1:${databasePort}/postgres?sslmode=disable`;
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
      POSTGRES_PASSWORD: password,
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
        "--publish",
        `127.0.0.1:${databasePort}:5432`,
        "--tmpfs",
        "/var/lib/postgresql/data:rw",
        "--log-driver=none",
        ...Object.keys(dbEnv).flatMap((key) => ["--env", key]),
        databaseInfo.Id,
      ],
      { env: dbEnv },
    );
    docker(["start", names.db]);
    assertBinding(names.db, 5432, databasePort);
    await waitReady(async () => {
      if (!inspect(names.db).State.Running)
        throw new Error("Fixture database exited.");
      try {
        // The image's temporary initialization server accepts only Unix sockets.
        docker(
          ["exec", names.db, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"],
          { timeout: 2000 },
        );
        return true;
      } catch {
        return false;
      }
    });
    sql(
      "create schema if not exists auth; alter role postgres set search_path to auth, public;",
    );
    const authEnv = {
      GOTRUE_API_HOST: "0.0.0.0",
      GOTRUE_API_PORT: "9999",
      API_EXTERNAL_URL: authOrigin,
      GOTRUE_SITE_URL: authOrigin,
      GOTRUE_DB_DRIVER: "postgres",
      GOTRUE_DB_DATABASE_URL: `postgres://postgres:${password}@${names.db}:5432/postgres?sslmode=disable`,
      GOTRUE_DB_NAMESPACE: "auth",
      GOTRUE_JWT_SECRET: jwtSecret,
      GOTRUE_JWT_EXP: "3600",
      GOTRUE_JWT_AUD: "authenticated",
      GOTRUE_JWT_DEFAULT_GROUP_NAME: "authenticated",
      GOTRUE_JWT_ADMIN_ROLES: "service_role",
      GOTRUE_DISABLE_SIGNUP: "true",
      GOTRUE_EXTERNAL_EMAIL_ENABLED: "true",
      GOTRUE_MAILER_AUTOCONFIRM: "true",
      GOTRUE_LOG_LEVEL: "error",
      GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED: "true",
      GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL: "10",
      GOTRUE_MFA_TOTP_ENROLL_ENABLED: "true",
      GOTRUE_MFA_TOTP_VERIFY_ENABLED: "true",
      GOTRUE_MFA_PHONE_ENROLL_ENABLED: "false",
      GOTRUE_MFA_PHONE_VERIFY_ENABLED: "false",
      // Test traffic only; this does not validate a production provider limit.
      GOTRUE_MFA_RATE_LIMIT_CHALLENGE_AND_VERIFY: "200",
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
        `127.0.0.1:${authPort}:9999`,
        "--log-driver=none",
        ...Object.keys(authEnv).flatMap((key) => ["--env", key]),
        authInfo.Id,
      ],
      { env: authEnv },
    );
    docker(["start", names.auth]);
    assertBinding(names.auth, 9999, authPort);
    await waitReady(async () => {
      if (!inspect(names.auth).State.Running)
        throw new Error("Fixture Auth exited.");
      try {
        return (
          await fetch(`${authOrigin}/health`, {
            redirect: "error",
            signal: AbortSignal.any([
              controller.signal,
              AbortSignal.timeout(1000),
            ]),
          })
        ).ok;
      } catch {
        return false;
      }
    });
    return await callback({
      authOrigin,
      databaseUrl,
      adminToken: signedFixtureToken(jwtSecret, "service_role"),
      anonKey: signedFixtureToken(jwtSecret, "anon"),
      sql,
      signal: controller.signal,
      runtime: Object.freeze({
        runId,
        labelKey,
        authImage,
        authImageId: authInfo.Id,
        databaseImage,
        databaseImageId: databaseInfo.Id,
        authPort,
        databasePort,
      }),
    });
  } finally {
    const failedCleanup = [];
    for (const [kind, name] of created.reverse()) {
      try {
        // Register names before create: a lost creation reply must not leak a resource.
        // A successful listing is required before absence can count as clean.
        const resources = docker([
          kind,
          "ls",
          ...(kind === "container" ? ["--all"] : []),
          "--filter",
          `name=${name}`,
          "--format",
          "{{json .}}",
        ])
          .split(/\r?\n/)
          .filter(Boolean)
          .map((line) => JSON.parse(line));
        if (
          !resources.some(
            (resource) =>
              (kind === "container" ? resource.Names : resource.Name) === name,
          )
        )
          continue;
        const resource = inspect(name, kind);
        const labels =
          kind === "network" ? resource.Labels : resource.Config.Labels;
        assert.equal(labels[labelKey], runId);
        if (kind === "container")
          docker(["rm", "--force", "--volumes", resource.Id]);
        else docker(["network", "rm", resource.Id]);
      } catch {
        failedCleanup.push(name);
      }
    }
    for (const signal of ["SIGINT", "SIGTERM"])
      process.removeListener(signal, abort);
    if (failedCleanup.length)
      throw new Error(
        `Owned fixture cleanup needs attention: ${failedCleanup.join(", ")}`,
      );
  }
}
