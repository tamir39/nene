import assert from "node:assert/strict";
import { randomUUID, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { SecurityService } from "../backend/dist/security/security.service.js";
const require = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
require("reflect-metadata");
const { Pool } = require("pg");
let stage = "fixture";
try {
  await withIsolatedAuthFixture(async (f) => {
    const pool = new Pool({ connectionString: f.databaseUrl });
    const originalFetch = globalThis.fetch;
    // Isolated GoTrue has no gateway; strip only the exact gateway prefix.
    globalThis.fetch = (url, init) =>
      originalFetch(
        String(url).replace(`${f.authOrigin}/auth/v1/`, `${f.authOrigin}/`),
        init,
      );
    try {
      // Create only fixture roles if absent; no normal database is used.
      for (const role of ["nene_api", "anon", "authenticated", "service_role"])
        await pool.query(
          `DO $$ begin if not exists(select from pg_roles where rolname='${role}') then create role ${role}; end if; end $$;`,
        );
      await pool.query(
        "create schema if not exists bank; create table if not exists bank.user_profiles(id uuid primary key)",
      );
      await pool.query(
        readFileSync(
          new URL(
            "../infrastructure/supabase/migrations/20261103000100_authenticator_setup.sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      await pool.query(
        readFileSync(
          new URL(
            "../infrastructure/supabase/migrations/20261103000500_authenticator_management.sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      const service = new SecurityService(
        {
          query: async (sql, args) => (await pool.query(sql, args)).rows,
          transaction: async (work) => {
            const client = await pool.connect();
            try {
              await client.query("BEGIN");
              const result = await work(client);
              await client.query("COMMIT");
              return result;
            } catch (error) {
              await client.query("ROLLBACK");
              throw error;
            } finally {
              client.release();
            }
          },
        },
        { supabaseUrl: f.authOrigin, supabasePublishableKey: f.anonKey },
      );
      const call = async (path, body, token) => {
        const response = await fetch(`${f.authOrigin}${path}`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...(token ? { Authorization: `Bearer ${token}` } : {}),
          },
          body: JSON.stringify(body),
        });
        assert.equal(response.status, 200);
        return response.json();
      };
      const email = `setup-${randomUUID()}@example.invalid`,
        password = randomBytes(24).toString("base64url");
      const user = await call(
        "/admin/users",
        { email, password, email_confirm: true },
        f.adminToken,
      );
      await pool.query("insert into bank.user_profiles values($1)", [user.id]);
      const login = await call("/token?grant_type=password", {
        email,
        password,
      });
      f.verifyAccessToken(login.access_token);
      const req = {
        headers: { authorization: `Bearer ${login.access_token}` },
        user: { id: user.id, role: "customer" },
      };
      stage = "role and initial status";
      await assert.rejects(
        service.start({ ...req, user: { ...req.user, role: "officer" } }),
      );
      assert.equal((await service.status(req)).state, "not_set_up");
      stage = "enrollment and duplicate prevention";
      const setup = await service.start(req);
      assert.ok(setup.secret);
      await assert.rejects(service.start(req));
      assert.equal((await service.status(req)).state, "pending");
      const second = await call("/token?grant_type=password", {
        email,
        password,
      });
      const otherSession = {
        ...req,
        headers: { authorization: `Bearer ${second.access_token}` },
      };
      await assert.rejects(
        service.verify(otherSession, {
          requestId: setup.requestId,
          code: "123456",
        }),
      );
      stage = "wrong code safely retried";
      const valid = generateTotp(setup.secret);
      const wrong = valid === "000000" ? "111111" : "000000";
      await assert.rejects(
        service.verify(req, { requestId: setup.requestId, code: wrong }),
        (e) => e.getStatus?.() === 400,
      );
      assert.equal((await service.status(req)).state, "pending");
      stage = "verified pair and durable status";
      const pair = await service.verify(req, {
        requestId: setup.requestId,
        code: generateTotp(setup.secret),
      });
      assert.equal(f.verifyAccessToken(pair.accessToken).aal, "aal2");
      const current = {
        ...req,
        headers: { authorization: `Bearer ${pair.accessToken}` },
      };
      assert.equal((await service.status(current)).state, "ready");
      await assert.rejects(
        service.verify(current, { requestId: setup.requestId, code: valid }),
      );
      await pool.query(
        "update bank.authenticator_setup set state='verifying' where customer_id=$1",
        [user.id],
      );
      assert.equal((await service.status(current)).state, "ready");
      const row = (await pool.query("select * from bank.authenticator_setup"))
        .rows[0];
      assert.ok(!JSON.stringify(row).includes(setup.secret));

      // Abandoned initial setup on a second synthetic customer. Each sign-in
      // is a new Auth session with fresh password evidence at AAL1.
      stage = "abandoned setup fixture";
      const restartEmail = `restart-${randomUUID()}@example.invalid`;
      const restartUser = await call(
        "/admin/users",
        { email: restartEmail, password, email_confirm: true },
        f.adminToken,
      );
      await pool.query("insert into bank.user_profiles values($1)", [
        restartUser.id,
      ]);
      const signIn = async () => {
        const session = await call("/token?grant_type=password", {
          email: restartEmail,
          password,
        });
        assert.equal(f.verifyAccessToken(session.access_token).aal, "aal1");
        return {
          headers: { authorization: `Bearer ${session.access_token}` },
          user: { id: restartUser.id, role: "customer" },
        };
      };
      const factorsOf = async (r) => {
        const response = await fetch(`${f.authOrigin}/user`, {
          headers: { Authorization: r.headers.authorization },
        });
        assert.equal(response.status, 200);
        return ((await response.json()).factors ?? []).map((x) => ({
          id: x.id,
          status: x.status,
          type: x.factor_type,
        }));
      };
      const setupRow = async () =>
        (
          await pool.query(
            "select request_id,state,factor_id,revision,attempts from bank.authenticator_setup where customer_id=$1",
            [restartUser.id],
          )
        ).rows[0];
      const first = await signIn();
      const abandonedSetup = await service.start(first);
      const abandonedFactor = (await setupRow()).factor_id;
      assert.equal((await service.status(first)).state, "pending");

      stage = "restart after a new session";
      const secondSession = await signIn();
      assert.equal((await service.status(secondSession)).state, "not_set_up");
      const restarted = await service.start(secondSession);
      assert.notEqual(restarted.secret, abandonedSetup.secret);
      assert.notEqual(restarted.requestId, abandonedSetup.requestId);
      assert.equal(restarted.revision, 2);
      const afterRestart = await factorsOf(secondSession);
      // The AAL1 session removed the old unverified factor and enrolled a new one.
      assert.equal(afterRestart.length, 1);
      assert.notEqual(afterRestart[0].id, abandonedFactor);
      assert.equal(afterRestart[0].status, "unverified");
      assert.equal((await setupRow()).factor_id, afterRestart[0].id);
      await assert.rejects(
        service.verify(first, {
          requestId: abandonedSetup.requestId,
          code: generateTotp(abandonedSetup.secret),
        }),
        (e) => e.getStatus?.() === 409,
      );
      await assert.rejects(
        service.start(secondSession),
        (e) => e.getStatus?.() === 409,
      );

      stage = "attempt limit waits for expiry";
      const nearby = new Set(
        [-60, -30, 0, 30, 60].map((offset) =>
          generateTotp(restarted.secret, {
            timestampSeconds: Math.floor(Date.now() / 1000) + offset,
          }),
        ),
      );
      const wrongCodes = ["000001", "000002", "000003", "000004", "000005"]
        .concat(["000006", "000007", "000008", "000009", "000010"])
        .filter((c) => !nearby.has(c))
        .slice(0, 5);
      for (const code of wrongCodes)
        await assert.rejects(
          service.verify(secondSession, {
            requestId: restarted.requestId,
            code,
          }),
          (e) => e.getStatus?.() === 400,
        );
      assert.equal((await setupRow()).state, "blocked");
      const third = await signIn();
      assert.equal((await service.status(third)).state, "blocked");
      await assert.rejects(
        service.start(third),
        (e) => e.getStatus?.() === 409,
      );
      assert.equal((await setupRow()).request_id, restarted.requestId);
      // Simulate the ten-minute window passing; no other field changes.
      await pool.query(
        "update bank.authenticator_setup set expires_at=now()-interval '1 second' where customer_id=$1",
        [restartUser.id],
      );
      assert.equal((await service.status(third)).state, "not_set_up");
      const afterExpiry = await service.start(third);
      assert.equal(afterExpiry.revision, 3);
      assert.equal((await setupRow()).attempts, 0);
      const expiryFactors = await factorsOf(third);
      assert.equal(expiryFactors.length, 1);
      assert.notEqual(expiryFactors[0].id, afterRestart[0].id);

      stage = "restarted setup verifies";
      const restartedPair = await service.verify(third, {
        requestId: afterExpiry.requestId,
        code: generateTotp(afterExpiry.secret),
      });
      assert.equal(f.verifyAccessToken(restartedPair.accessToken).aal, "aal2");
      assert.equal((await service.status(third)).state, "ready");

      stage = "verified factor refuses restart";
      const fourth = await signIn();
      await pool.query(
        "update bank.authenticator_setup set state='pending',expires_at=now()-interval '1 second' where customer_id=$1",
        [restartUser.id],
      );
      const beforeRefusal = await setupRow();
      assert.equal((await service.status(fourth)).state, "blocked");
      await assert.rejects(
        service.start(fourth),
        (e) =>
          e.getStatus?.() === 409 &&
          JSON.stringify(e.getResponse()).includes("recovery support"),
      );
      assert.deepEqual(await setupRow(), beforeRefusal);
      assert.deepEqual(await factorsOf(fourth), [
        { id: expiryFactors[0].id, status: "verified", type: "totp" },
      ]);
      const restartRow = JSON.stringify(
        (
          await pool.query(
            "select * from bank.authenticator_setup where customer_id=$1",
            [restartUser.id],
          )
        ).rows,
      );
      for (const value of [
        abandonedSetup.secret,
        restarted.secret,
        afterExpiry.secret,
      ])
        assert.ok(!restartRow.includes(value));
      console.log(
        JSON.stringify({
          result: "passed",
          checks: [
            "officer denied",
            "initial status",
            "enrollment",
            "duplicate denied",
            "pending status",
            "wrong session denied",
            "invalid code retry",
            "verified pair",
            "ready status",
            "repeat verify denied",
            "lost-reply reconciliation",
            "no stored secret",
            "new session restarts abandoned setup",
            "AAL1 removed only the unverified factor",
            "abandoned request cannot verify",
            "same-session duplicate denied",
            "attempt limit blocks a new session",
            "expiry restarts attempt-blocked setup",
            "restarted setup verifies",
            "verified factor refuses restart unchanged",
            "no stored restart secrets",
          ],
        }),
      );
    } finally {
      globalThis.fetch = originalFetch;
      await pool.end();
    }
  });
  console.log("Owned fixture cleanup complete.");
} catch {
  console.error(JSON.stringify({ result: "failed", stage }));
  process.exitCode = 1;
}
