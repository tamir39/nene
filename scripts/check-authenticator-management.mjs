import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { SecurityService } from "../backend/dist/security/security.service.js";
import { SecurityManagementService } from "../backend/dist/security/security-management.service.js";
import { DatabaseService } from "../backend/dist/database/database.service.js";
import { reserveSecurityProof } from "../backend/dist/security/security-proof.js";
const require = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
require("reflect-metadata");
const { Pool } = require("pg");
let stage = "fixture";
const checks = [];
try {
  await withIsolatedAuthFixture(
    async (f) => {
      const admin = new Pool({ connectionString: f.databaseUrl });
      let db;
      const originalFetch = globalThis.fetch;
      globalThis.fetch = (url, init) =>
        originalFetch(
          String(url).replace(`${f.authOrigin}/auth/v1/`, `${f.authOrigin}/`),
          init,
        );
      try {
        for (const role of ["anon", "authenticated", "service_role"])
          await admin.query(
            `DO $$ begin if not exists(select from pg_roles where rolname='${role}')then create role ${role};end if;end $$;`,
          );
        await admin.query(
          "create schema storage;create table storage.buckets(id text,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(bucket_id text)",
        );
        for (const file of [
          "20261015000100_identity_foundation.sql",
          "20261020000100_customer_accounts.sql",
          "20261103000100_authenticator_setup.sql",
          "20261103000500_authenticator_management.sql",
        ])
          await admin.query(
            readFileSync(
              new URL(
                "../infrastructure/supabase/migrations/" + file,
                import.meta.url,
              ),
              "utf8",
            ),
          );
        const dbPassword = randomBytes(24).toString("hex");
        await admin.query(`alter role nene_api login password '${dbPassword}'`);
        const url = new URL(f.databaseUrl);
        url.username = "nene_api";
        url.password = dbPassword;
        db = new DatabaseService({ database: { connectionString: url.href } });
        const security = new SecurityService(db, {
          supabaseUrl: f.authOrigin,
          supabasePublishableKey: f.anonKey,
        });
        const service = new SecurityManagementService(db, security);
        const call = async (path, body, token, method = "POST") => {
          const response = await fetch(`${f.authOrigin}${path}`, {
            method,
            headers: {
              "Content-Type": "application/json",
              ...(token ? { Authorization: `Bearer ${token}` } : {}),
            },
            ...(body ? { body: JSON.stringify(body) } : {}),
          });
          return {
            status: response.status,
            data: response.status === 204 ? {} : await response.json(),
          };
        };
        const request = (user, token) => {
          assert.equal(f.verifyAccessToken(token).sub, user.id);
          return {
            headers: { authorization: `Bearer ${token}` },
            user: { id: user.id, role: "customer" },
          };
        };
        async function login(user) {
          await delay(1100);
          const result = await call("/token?grant_type=password", {
            email: user.email,
            password: user.password,
          });
          assert.equal(result.status, 200);
          user.token = result.data.access_token;
          return request(user, user.token);
        }
        const used = new Map();
        function code(secret) {
          const set = used.get(secret) ?? new Set();
          used.set(secret, set);
          for (const delta of [0, -30, 30]) {
            const value = generateTotp(secret, {
              timestampSeconds: Math.floor(Date.now() / 1000) + delta,
            });
            if (!set.has(value)) {
              set.add(value);
              return value;
            }
          }
          throw new Error("No distinct fixture code available");
        }
        async function prepared() {
          const email = `management-${randomUUID()}@example.invalid`,
            password = randomBytes(24).toString("base64url");
          const created = await call(
            "/admin/users",
            { email, password, email_confirm: true },
            f.adminToken,
          );
          assert.equal(created.status, 200);
          const user = { id: created.data.id, email, password };
          await admin.query(
            "insert into bank.user_profiles(id,display_name,role,email) values($1,'Synthetic fixture','customer',$2)",
            [user.id, email],
          );
          let req = await login(user);
          const setup = await security.start(req);
          const usedCode = code(setup.secret);
          const pair = await security.verify(req, {
            requestId: setup.requestId,
            code: usedCode,
          });
          user.token = pair.accessToken;
          req = request(user, user.token);
          return { user, req, secret: setup.secret, setupCode: usedCode };
        }
        stage = "setup and recovery-code issuance";
        let { user, req, secret, setupCode } = await prepared();
        await assert.rejects(
          service.start(
            { ...req, user: { ...req.user, role: "officer" } },
            { purpose: "replace" },
          ),
          (e) => e.getStatus() === 403,
        );
        checks.push("officer denied");
        const pairStart = await Promise.allSettled([
          service.start(req, { purpose: "codes" }),
          service.start(req, { purpose: "codes" }),
        ]);
        assert.equal(
          pairStart.filter((x) => x.status === "fulfilled").length,
          1,
        );
        let flow = pairStart.find((x) => x.status === "fulfilled").value;
        assert.equal((await security.status(req)).state, "restricted");
        checks.push("single management reservation and restriction");
        await assert.rejects(
          service.issue(req, { requestId: flow.requestId, code: setupCode }),
          (e) => e.getStatus() === 400,
        );
        checks.push("setup proof cannot issue backup codes");
        let issued = await service.issue(req, {
          requestId: flow.requestId,
          code: code(secret),
        });
        assert.equal(issued.codes.length, 10);
        req = request(user, issued.accessToken);
        const originalCodes = issued.codes;
        await assert.rejects(
          service.issue(req, { requestId: flow.requestId, code: code(secret) }),
          (e) => e.getStatus() === 409,
        );
        checks.push("codes displayed once and duplicate command rejected");
        await assert.rejects(
          service.finish(req, { requestId: flow.requestId, saved: false }),
          (e) => e.getStatus() === 400,
        );
        const priorToken = issued.accessToken;
        await service.finish(req, { requestId: flow.requestId, saved: true });
        assert.equal(
          (await call("/user", null, priorToken, "GET")).status,
          403,
        );
        checks.push("save acknowledgement and global session revocation");
        req = await login(user);
        assert.equal((await security.status(req)).state, "ready");
        assert.equal((await service.status(req)).remaining, 10);
        stage = "normal authenticator replacement";
        // A fresh user avoids exhausting the deliberately small cross-purpose fixture budget.
        const normal = await prepared();
        await assert.rejects(
          service.finish(normal.req, {
            requestId: flow.requestId,
            saved: true,
          }),
          (e) => e.getStatus() === 409,
        );
        checks.push("another customer cannot read or finish the owned request");
        flow = await service.start(normal.req, { purpose: "replace" });
        const second = await login(normal.user);
        await assert.rejects(
          service.prove(second, { requestId: flow.requestId, code: "123456" }),
          (e) => e.getStatus() === 409,
        );
        checks.push("different session cannot inherit management");
        let proved = await service.prove(normal.req, {
          requestId: flow.requestId,
          code: code(normal.secret),
        });
        normal.req = request(normal.user, proved.accessToken);
        const replacement = await service.enroll(normal.req, {
          requestId: flow.requestId,
        });
        const factors = await security.provider("/user", proved.accessToken);
        assert.equal(
          factors.factors.filter(
            (x) => x.factor_type === "totp" && x.status === "verified",
          ).length,
          1,
        );
        checks.push("old factor retained before new verification");
        let verified = await service.verify(normal.req, {
          requestId: flow.requestId,
          code: code(replacement.secret),
        });
        normal.req = request(normal.user, verified.accessToken);
        issued = await service.issue(normal.req, {
          requestId: flow.requestId,
          code: code(replacement.secret),
        });
        normal.req = request(normal.user, issued.accessToken);
        assert.equal(
          (await security.provider("/user", issued.accessToken)).factors.filter(
            (x) => x.factor_type === "totp",
          ).length,
          1,
        );
        checks.push("old factor retired only after new proof");
        await service.finish(normal.req, {
          requestId: flow.requestId,
          saved: true,
        });
        normal.req = await login(normal.user);
        assert.equal((await security.status(normal.req)).state, "ready");
        stage = "lost-authenticator recovery";
        flow = await service.start(req, { purpose: "recover" });
        await assert.rejects(
          service.prove(req, {
            requestId: flow.requestId,
            code: "INVALIDCODE123456",
          }),
          (e) => e.getStatus() === 400,
        );
        assert.equal((await service.status(req)).management.step, "proof");
        checks.push(
          "wrong recovery code permits corrected proof without resetting security",
        );
        proved = await service.prove(req, {
          requestId: flow.requestId,
          code: originalCodes[0],
        });
        req = request(user, proved.accessToken);
        assert.equal(
          (
            await call(
              "/factors/recovery-codes/verify",
              { code: originalCodes[0] },
              proved.accessToken,
            )
          ).status,
          422,
        );
        checks.push("recovery code consumed once");
        const recovered = await service.enroll(req, {
          requestId: flow.requestId,
        });
        verified = await service.verify(req, {
          requestId: flow.requestId,
          code: code(recovered.secret),
        });
        req = request(user, verified.accessToken);
        issued = await service.issue(req, {
          requestId: flow.requestId,
          code: code(recovered.secret),
        });
        req = request(user, issued.accessToken);
        assert.equal(
          (
            await call(
              "/factors/recovery-codes/verify",
              { code: originalCodes[1] },
              issued.accessToken,
            )
          ).status,
          422,
        );
        checks.push("recovery rotates and invalidates old backup set");
        await service.finish(req, { requestId: flow.requestId, saved: true });
        req = await login(user);
        assert.equal((await security.status(req)).state, "ready");
        checks.push("recovered factor ready only after final sign-out");
        stage = "cancel unverified replacement";
        const cancelled = await prepared();
        flow = await service.start(cancelled.req, { purpose: "replace" });
        proved = await service.prove(cancelled.req, {
          requestId: flow.requestId,
          code: code(cancelled.secret),
        });
        cancelled.req = request(cancelled.user, proved.accessToken);
        await service.enroll(cancelled.req, { requestId: flow.requestId });
        await service.cancel(cancelled.req, { requestId: flow.requestId });
        assert.equal((await security.status(cancelled.req)).state, "ready");
        assert.equal(
          (await security.provider("/user", proved.accessToken)).factors.filter(
            (x) => x.factor_type === "totp",
          ).length,
          1,
        );
        checks.push("cancel removes only unverified replacement");
        stage = "expired request and explicit new-session resume";
        const resumed = await prepared();
        flow = await service.start(resumed.req, { purpose: "replace" });
        await admin.query(
          "update bank.security_management set expires_at=now()-interval '1 minute' where id=$1",
          [flow.requestId],
        );
        await assert.rejects(
          service.prove(resumed.req, {
            requestId: flow.requestId,
            code: "123456",
          }),
          (e) => e.getStatus() === 409,
        );
        resumed.req = await login(resumed.user);
        const revision = (await service.status(resumed.req)).management
          .revision;
        proved = await service.prove(
          resumed.req,
          { requestId: flow.requestId, code: code(resumed.secret) },
          true,
        );
        resumed.req = request(resumed.user, proved.accessToken);
        assert.equal(proved.revision, revision);
        assert.equal(
          (await service.status(resumed.req)).management.revision,
          revision + 1,
        );
        await service.cancel(resumed.req, { requestId: flow.requestId });
        checks.push(
          "expired flow requires fresh password and fresh proof; resume advances security revision",
        );
        stage = "lost verification reply reconciles only with new factor proof";
        const lost = await prepared();
        flow = await service.start(lost.req, { purpose: "replace" });
        proved = await service.prove(lost.req, {
          requestId: flow.requestId,
          code: code(lost.secret),
        });
        lost.req = request(lost.user, proved.accessToken);
        const lostSetup = await service.enroll(lost.req, {
          requestId: flow.requestId,
        });
        const providerBeforeLoss = security.provider.bind(security);
        security.provider = async (path, ...args) => {
          const result = await providerBeforeLoss(path, ...args);
          if (path.endsWith("/verify"))
            throw new Error("Discarded synthetic verification reply");
          return result;
        };
        await assert.rejects(
          service.verify(lost.req, {
            requestId: flow.requestId,
            code: code(lostSetup.secret),
          }),
        );
        security.provider = providerBeforeLoss;
        lost.req = await login(lost.user);
        assert.equal(
          (await service.status(lost.req)).management.proofKind,
          "new_authenticator",
        );
        assert.equal((await security.status(lost.req)).state, "restricted");
        proved = await service.prove(
          lost.req,
          { requestId: flow.requestId, code: code(lostSetup.secret) },
          true,
        );
        lost.req = request(lost.user, proved.accessToken);
        assert.equal(
          (await service.status(lost.req)).management.step,
          "verified",
        );
        checks.push(
          "lost new-factor verification reply requires new-factor reproof",
        );
        stage = "lost provider reply remains restricted";
        const unknown = await prepared();
        flow = await service.start(unknown.req, { purpose: "codes" });
        const originalProvider = security.provider.bind(security);
        security.provider = async (path, ...args) => {
          const response = await originalProvider(path, ...args);
          if (path === "/factors/recovery-codes" && args[1])
            throw new Error("Discarded synthetic reply");
          return response;
        };
        await assert.rejects(
          service.issue(unknown.req, {
            requestId: flow.requestId,
            code: code(unknown.secret),
          }),
        );
        security.provider = originalProvider;
        const status = await service.status(unknown.req);
        assert.equal(status.management.step, "issuing");
        assert.equal(status.management.canResume, false);
        assert.equal((await security.status(unknown.req)).state, "restricted");
        checks.push("uncertain provider issuance never restores readiness");
        stage = "concurrent shared proof budget";
        const budget = await prepared();
        const concurrent = await Promise.allSettled(
          Array.from({ length: 11 }, (_, i) =>
            reserveSecurityProof(
              db,
              budget.user.id,
              "synthetic-factor",
              String(100000 + i),
              "fixture",
            ),
          ),
        );
        assert.equal(
          concurrent.filter((x) => x.status === "fulfilled").length,
          9,
        );
        assert.equal(
          concurrent.filter(
            (x) => x.status === "rejected" && x.reason.getStatus() === 429,
          ).length,
          2,
        );
        checks.push(
          "concurrent proof reservations cannot exceed the customer rolling limit",
        );
        stage = "secret and grants audit";
        const records =
          JSON.stringify(
            (await admin.query("select * from bank.security_management")).rows,
          ) +
          JSON.stringify(
            (
              await admin.query(
                "select * from bank.security_proof_reservations",
              )
            ).rows,
          );
        for (const sensitive of [
          secret,
          replacement.secret,
          recovered.secret,
          ...originalCodes,
          ...issued.codes,
        ])
          assert.ok(!records.includes(sensitive));
        for (const role of ["anon", "authenticated", "service_role"])
          assert.equal(
            (
              await admin.query(
                "select has_table_privilege($1,'bank.security_management','select') allowed",
                [role],
              )
            ).rows[0].allowed,
            false,
          );
        checks.push(
          "no raw proof, setup key or recovery codes stored",
          "client roles denied",
        );
        console.log(JSON.stringify({ result: "passed", checks }));
      } finally {
        globalThis.fetch = originalFetch;
        await db?.onModuleDestroy();
        await admin.end();
      }
    },
    { recoveryCodes: true },
  );
  console.log("Owned management fixture cleaned.");
} catch (error) {
  console.error(
    JSON.stringify({
      result: "failed",
      stage,
      status:
        typeof error?.getStatus === "function" ? error.getStatus() : undefined,
      kind: error?.constructor?.name,
    }),
  );
  process.exitCode = 1;
}
