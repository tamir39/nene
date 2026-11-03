import assert from "node:assert/strict";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { SecurityService } from "../backend/dist/security/security.service.js";
import { ConfirmationService } from "../backend/dist/confirmation/confirmation.service.js";
import { DatabaseService } from "../backend/dist/database/database.service.js";
const require = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
require("reflect-metadata");
const { Pool } = require("pg");
const checks = [];
let stage = "fixture";
const rejected = (work, status) =>
  assert.rejects(work, (e) => e.getStatus() === status);
try {
  await withIsolatedAuthFixture(async (f) => {
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
          `DO $$ begin if not exists(select from pg_roles where rolname='${role}') then create role ${role};end if;end $$;`,
        );
      await admin.query(
        "create schema storage;create table storage.buckets(id text,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(bucket_id text)",
      );
      for (const file of [
        "20261015000100_identity_foundation.sql",
        "20261020000100_customer_accounts.sql",
        "20261027000100_identity_reference.sql",
        "20261027000200_identity_reference_name_snapshot.sql",
        "20261103000100_authenticator_setup.sql",
        "20261103000200_account_information.sql",
        "20261103000300_demo_account_provisioning.sql",
        "20261103000400_account_history.sql",
        "20261103000500_authenticator_management.sql",
        "20261103000600_transaction_confirmation.sql",
        "20261103000700_local_transfers.sql",
      ]) {
        await admin.query(
          readFileSync(
            new URL(
              "../infrastructure/supabase/migrations/" + file,
              import.meta.url,
            ),
            "utf8",
          ),
        );
      }
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
      const service = new ConfirmationService(db, security),
        second = new ConfirmationService(db, security);
      const call = async (path, body, token) => {
        const response = await fetch(f.authOrigin + path, {
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
      async function customer() {
        const email = `confirmation-${randomUUID()}@example.invalid`,
          password = randomBytes(24).toString("base64url");
        const user = await call(
          "/admin/users",
          { email, password, email_confirm: true },
          f.adminToken,
        );
        await admin.query(
          "insert into bank.user_profiles(id,display_name,role,email) values($1,'Synthetic fixture','customer',$2)",
          [user.id, email],
        );
        const account = (
          await admin.query(
            "insert into bank.banking_accounts(id,owner_id,type,currency) values($1,$2,'checking','VND') returning id,account_number::text number",
            [randomUUID(), user.id],
          )
        ).rows[0];
        const login = await call("/token?grant_type=password", {
          email,
          password,
        });
        const req = {
          headers: { authorization: `Bearer ${login.access_token}` },
          user: { id: user.id, role: "customer" },
        };
        assert.equal(f.verifyAccessToken(login.access_token).sub, user.id);
        const setup = await security.start(req);
        const setupCode = generateTotp(setup.secret);
        const pair = await security.verify(req, {
          requestId: setup.requestId,
          code: setupCode,
        });
        req.headers.authorization = `Bearer ${pair.accessToken}`;
        return { req, account, setup, setupCode, pair, user, email, password };
      }
      stage = "review and real provider";
      const a = await customer(),
        b = await customer();
      const payload = {
        sourceAccountId: a.account.id,
        destinationAccountNumber: b.account.number,
        amountMinor: "100000",
      };
      const prepare = () => service.review(a.req, payload);
      stage = "first signed review";
      let review = await prepare();
      assert.equal(review.executionAvailable, false);
      assert.equal(review.sufficientFunds, false);
      assert.equal(
        (
          await admin.query(
            "select count(*)::int n from bank.transaction_confirmations",
          )
        ).rows[0].n,
        0,
      );
      checks.push(
        "review stores no transfer details or intent; zero balance is explicitly insufficient",
      );
      await rejected(
        service.review(
          { ...a.req, user: { ...a.req.user, role: "officer" } },
          payload,
        ),
        403,
      );
      await rejected(service.review(b.req, payload), 400);
      await rejected(
        service.review(a.req, {
          ...payload,
          destinationAccountNumber: a.account.number,
        }),
        400,
      );
      checks.push("officer, non-owner and same-account review denied");
      const parts = review.reviewToken.split("."),
        decoded = JSON.parse(Buffer.from(parts[0], "base64url"));
      decoded.amountMinor = "1";
      await rejected(
        service.confirm(a.req, {
          reviewToken:
            Buffer.from(JSON.stringify(decoded)).toString("base64url") +
            "." +
            parts[1],
          code: "123456",
        }),
        400,
      );
      await rejected(
        service.confirm(b.req, {
          reviewToken: review.reviewToken,
          code: "123456",
        }),
        403,
      );
      checks.push(
        "tampered amount and another customer cannot confirm signed review",
      );
      const differentLogin = await call("/token?grant_type=password", {
        email: a.email,
        password: a.password,
      });
      const differentSession = {
        ...a.req,
        headers: { authorization: `Bearer ${differentLogin.access_token}` },
      };
      await rejected(
        service.confirm(differentSession, {
          reviewToken: review.reviewToken,
          code: "123456",
        }),
        403,
      );
      checks.push("fresh login cannot inherit an earlier session review");
      const expiredData = {
        ...JSON.parse(
          Buffer.from(review.reviewToken.split(".")[0], "base64url"),
        ),
        expires: Date.now() - 1000,
      };
      const encoded = Buffer.from(JSON.stringify(expiredData)).toString(
        "base64url",
      );
      const key = (
        await admin.query("select secret from bank.security_proof_key")
      ).rows[0].secret;
      const expiredToken =
        encoded +
        "." +
        createHmac("sha256", key)
          .update("nene-review-v1\0" + encoded)
          .digest("base64url");
      await rejected(
        service.confirm(a.req, { reviewToken: expiredToken, code: "123456" }),
        409,
      );
      checks.push("expired signed review cannot reserve a proof");
      await admin.query(
        "update bank.banking_accounts set status='closed' where id=$1",
        [b.account.id],
      );
      await rejected(
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: "123456",
        }),
        400,
      );
      await admin.query(
        "update bank.banking_accounts set status='active' where id=$1",
        [b.account.id],
      );
      checks.push(
        "account eligibility is rechecked before provider verification",
      );
      await rejected(
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: a.setupCode,
        }),
        400,
      );
      assert.equal(
        (await service.status(a.req, review.requestId)).state,
        "rejected",
      );
      checks.push("enrollment proof cannot confirm a transaction review");
      review = await prepare();
      let fresh = generateTotp(a.setup.secret, {
        timestampSeconds: Math.floor(Date.now() / 1000) - 30,
      });
      if (fresh === a.setupCode)
        fresh = generateTotp(a.setup.secret, {
          timestampSeconds: Math.floor(Date.now() / 1000) + 30,
        });
      const concurrent = await Promise.all([
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: fresh,
        }),
        second.confirm(a.req, { reviewToken: review.reviewToken, code: fresh }),
      ]);
      const success = concurrent.find((x) => x.replay === false),
        repeat = concurrent.find((x) => x.replay === true);
      assert.ok(success);
      assert.ok(repeat);
      assert.equal(success.state, "factor_confirmed");
      assert.equal(repeat.accessToken, undefined);
      assert.equal(f.verifyAccessToken(success.accessToken).sub, a.user.id);
      a.req.headers.authorization = `Bearer ${success.accessToken}`;
      assert.equal(
        (await service.status(a.req, review.requestId)).state,
        "factor_confirmed",
      );
      checks.push(
        "real Auth proof is transaction-bound; concurrent duplicate never re-verifies or replays tokens",
      );
      await rejected(service.status(b.req, review.requestId), 404);
      const other = await prepare();
      await rejected(
        service.confirm(a.req, { reviewToken: other.reviewToken, code: fresh }),
        400,
      );
      checks.push("successful code cannot be replayed on another review");
      await admin.query(
        "update bank.authenticator_setup set state='restricted',revision=revision+1 where customer_id=$1",
        [a.user.id],
      );
      assert.equal(
        (await service.status(a.req, review.requestId)).state,
        "invalidated",
      );
      await rejected(
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: "123456",
        }),
        409,
      );
      checks.push(
        "security restriction and revision changes invalidate previous proof",
      );
      await admin.query(
        "update bank.authenticator_setup set state='ready' where customer_id=$1",
        [a.user.id],
      );
      // The remaining race cases use a controlled provider with the already validated fixture identity.
      // This isolates timing; the real GoTrue case above proves provider compatibility.
      const baseProvider = security.provider.bind(security);
      let verifyCalls = 0,
        counter = 200000;
      let onVerify = async () => {};
      security.provider = async (path, ...args) => {
        if (path.endsWith("/challenge")) return { id: randomUUID() };
        if (path.endsWith("/verify")) {
          verifyCalls++;
          await onVerify();
          return {
            access_token: success.accessToken,
            refresh_token: success.refreshToken,
          };
        }
        return baseProvider(path, ...args);
      };
      stage = "cancellation and late proof";
      review = await prepare();
      await service.cancel(a.req, { reviewToken: review.reviewToken });
      let before = verifyCalls;
      assert.equal(
        (
          await service.confirm(a.req, {
            reviewToken: review.reviewToken,
            code: String(counter++),
          })
        ).state,
        "cancelled",
      );
      assert.equal(verifyCalls, before);
      checks.push("cancel-before-confirm prevents provider dispatch");
      review = await prepare();
      onVerify = () =>
        service.cancel(a.req, { reviewToken: review.reviewToken });
      await rejected(
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: String(counter++),
        }),
        503,
      );
      assert.equal(
        (await service.status(a.req, review.requestId)).state,
        "cancelled",
      );
      checks.push("cancel wins over a late successful provider reply");
      stage = "factor change during provider";
      review = await prepare();
      onVerify = () =>
        admin.query(
          "update bank.authenticator_setup set revision=revision+1 where customer_id=$1",
          [a.user.id],
        );
      await rejected(
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: String(counter++),
        }),
        503,
      );
      assert.equal(
        (await service.status(a.req, review.requestId)).state,
        "invalidated",
      );
      checks.push("factor revision rechecked after provider verification");
      stage = "expiry at final write";
      review = await prepare();
      onVerify = () =>
        admin.query(
          "update bank.transaction_confirmations set expires_at=now()-interval '1 second' where id=$1",
          [review.requestId],
        );
      await rejected(
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: String(counter++),
        }),
        503,
      );
      assert.equal(
        (await service.status(a.req, review.requestId)).state,
        "expired",
      );
      checks.push("expiry at final database write prevents confirmation");
      stage = "provider uncertainty";
      review = await prepare();
      onVerify = async () => {
        throw new Error("Synthetic lost reply");
      };
      await rejected(
        service.confirm(a.req, {
          reviewToken: review.reviewToken,
          code: String(counter++),
        }),
        503,
      );
      before = verifyCalls;
      assert.equal(
        (
          await service.confirm(a.req, {
            reviewToken: review.reviewToken,
            code: String(counter++),
          })
        ).state,
        "unknown",
      );
      assert.equal(verifyCalls, before);
      checks.push("unknown provider outcome cannot be retried into success");
      stage = "balances history secrets and grants";
      assert.equal(
        (await admin.query("select count(*)::int n from bank.account_history"))
          .rows[0].n,
        0,
      );
      assert.equal(
        (
          await admin.query(
            "select sum(balance_minor)::text total from bank.banking_accounts",
          )
        ).rows[0].total,
        "0",
      );
      const rows = JSON.stringify(
        (await admin.query("select * from bank.transaction_confirmations"))
          .rows,
      );
      for (const secret of [
        a.setup.secret,
        success.accessToken,
        success.refreshToken,
        review.reviewToken,
        a.account.number,
        b.account.number,
      ])
        assert.ok(!rows.includes(secret));
      for (const role of ["anon", "authenticated", "service_role"])
        assert.equal(
          (
            await admin.query(
              "select has_table_privilege($1,'bank.transaction_confirmations','select') allowed",
              [role],
            )
          ).rows[0].allowed,
          false,
        );
      assert.equal(
        (
          await admin.query(
            "select has_column_privilege('nene_api','bank.banking_accounts','balance_minor','update') allowed",
          )
        ).rows[0].allowed,
        false,
      );
      checks.push(
        "no balance or history writes; no details, secrets or tokens stored",
        "client table access and API balance writes denied",
      );
      console.log(JSON.stringify({ result: "passed", checks }));
    } finally {
      globalThis.fetch = originalFetch;
      await db?.onModuleDestroy();
      await admin.end();
    }
  });
  console.log("Owned confirmation fixture cleaned.");
} catch (error) {
  console.error(
    JSON.stringify({
      result: "failed",
      stage,
      status: error?.getStatus?.(),
      kind: error?.constructor?.name,
    }),
  );
  process.exitCode = 1;
}
