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
      const service = new SecurityService(
        { query: async (sql, args) => (await pool.query(sql, args)).rows },
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
