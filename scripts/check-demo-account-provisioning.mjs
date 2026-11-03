import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { DatabaseService } from "../backend/dist/database/database.service.js";
import { CustomersService } from "../backend/dist/customers/customers.service.js";
import { DemoAccountController } from "../backend/dist/accounts/demo-account.controller.js";
const require = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
require("reflect-metadata");
const { Pool } = require("pg");
let stage = "fixture";
try {
  await withIsolatedAuthFixture(async (f) => {
    const admin = new Pool({ connectionString: f.databaseUrl });
    let db;
    try {
      stage = "migration chain";
      for (const role of ["anon", "authenticated", "service_role"])
        await admin.query(
          `DO $$ begin if not exists(select from pg_roles where rolname='${role}')then create role ${role};end if;end $$;`,
        );
      // Minimal Storage schema for the unchanged foundation's bucket policies.
      await admin.query(
        "create schema storage; create table storage.buckets(id text,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(bucket_id text);",
      );
      for (const file of [
        "20261015000100_identity_foundation.sql",
        "20261020000100_customer_accounts.sql",
        "20261103000200_account_information.sql",
        "20261103000300_demo_account_provisioning.sql",
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
      const password = randomBytes(24).toString("hex");
      await admin.query(`alter role nene_api login password '${password}'`);
      const officer = { id: randomUUID(), role: "officer" },
        customer = { id: randomUUID(), role: "customer" },
        other = { id: randomUUID(), role: "customer" },
        outside = { id: randomUUID(), role: "customer" };
      for (const user of [officer, customer, other, outside]) {
        await admin.query("insert into auth.users(id) values($1)", [user.id]);
        await admin.query(
          "insert into bank.user_profiles(id,display_name,role,email) values($1,'Synthetic fixture',$2,$3)",
          [
            user.id,
            user.role,
            user.id + (user === outside ? "@example.com" : "@example.invalid"),
          ],
        );
      }
      const url = new URL(f.databaseUrl);
      url.username = "nene_api";
      url.password = password;
      db = new DatabaseService({ database: { connectionString: url.href } });
      const controller = new DemoAccountController(db, {
        nodeEnv: "test",
        supabaseUrl: f.authOrigin,
      });
      const req = { user: officer },
        saving = {
          type: "saving",
          reason: "Fixture demo account",
          syntheticConfirmed: true,
        };
      const mortgage = {
        ...saving,
        type: "mortgage",
        principalMinor: "1000000",
        termMonths: 3,
        firstDueOn: "2026-12-01",
      };
      stage = "saving and replay";
      const key = randomUUID(),
        first = await controller.create(req, customer.id, key, saving);
      assert.deepEqual(
        await controller.create(req, customer.id, key, saving),
        first,
      );
      await assert.rejects(
        controller.create(req, customer.id, key, {
          ...saving,
          reason: "changed details",
        }),
        (e) => e.getStatus() === 409,
      );
      await assert.rejects(
        controller.create(req, other.id, key, saving),
        (e) => e.getStatus() === 409,
      );
      await assert.rejects(
        controller.create(req, customer.id, randomUUID(), saving),
        (e) => e.getStatus() === 409,
      );
      stage = "concurrent mortgage";
      const settled = await Promise.allSettled([
        controller.create(req, customer.id, randomUUID(), mortgage),
        controller.create(req, customer.id, randomUUID(), mortgage),
      ]);
      assert.equal(settled.filter((x) => x.status === "fulfilled").length, 1);
      assert.equal(
        settled.find((x) => x.status === "rejected").reason.getStatus(),
        409,
      );
      stage = "same-key concurrency";
      const same = randomUUID();
      const pair = await Promise.all([
        controller.create(req, other.id, same, saving),
        controller.create(req, other.id, same, saving),
      ]);
      assert.deepEqual(pair[0], pair[1]);
      stage = "synthetic boundary";
      await assert.rejects(
        controller.create(req, outside.id, randomUUID(), saving),
        (e) => e.getStatus() === 403,
      );
      await assert.rejects(
        controller.create(req, randomUUID(), randomUUID(), saving),
        (e) => e.getStatus() === 404,
      );
      await admin.query(
        "update bank.user_profiles set status='disabled' where id=$1",
        [outside.id],
      );
      await assert.rejects(
        controller.create(req, outside.id, randomUUID(), saving),
        (e) => e.getStatus() === 404,
      );
      stage = "read models and ownership";
      const service = new CustomersService(db, {}),
        result = await service.ownAccounts(customer);
      assert.equal(result.accounts.length, 2);
      assert.ok(
        result.accounts.every((x) => x.isDemo && x.balanceMinor === "0"),
      );
      assert.equal(
        result.accounts.find((x) => x.type === "saving").monthlyProfitMinor,
        "0",
      );
      const loan = result.accounts.find((x) => x.type === "mortgage");
      assert.equal(loan.monthlyDueMinor, "333333");
      assert.equal(loan.principalRemainingMinor, "1000000");
      assert.equal(loan.nextDueOn, "2026-12-01");
      assert.equal((await service.ownAccounts(other)).accounts.length, 1);
      assert.equal(
        (await service.detail(officer, customer.id)).accounts.length,
        2,
      );
      stage = "atomic rollback";
      await admin.query(
        "create function bank.reject_fixture_request() returns trigger language plpgsql as $$ begin raise exception 'fixture rollback';end $$;create trigger fixture_failure before insert on bank.demo_account_requests for each row execute function bank.reject_fixture_request();",
      );
      const rollbackKey = randomUUID();
      await assert.rejects(
        controller.create(req, other.id, rollbackKey, mortgage),
      );
      assert.equal(
        (
          await admin.query(
            "select count(*)::int n from bank.banking_accounts where owner_id=$1 and type='mortgage'",
            [other.id],
          )
        ).rows[0].n,
        0,
      );
      assert.equal(
        (
          await admin.query(
            "select count(*)::int n from bank.mortgage_schedule",
          )
        ).rows[0].n,
        1,
      );
      await admin.query(
        "drop trigger fixture_failure on bank.demo_account_requests;drop function bank.reject_fixture_request()",
      );
      await controller.create(req, other.id, rollbackKey, mortgage);
      stage = "least privilege";
      await assert.rejects(
        db.query("update bank.banking_accounts set balance_minor=1", []),
      );
      await assert.rejects(
        db.query("update bank.mortgage_schedule set monthly_due_minor=1", []),
      );
      await assert.rejects(
        db.query("delete from bank.demo_account_requests", []),
      );
      await assert.rejects(
        db.query(
          "insert into bank.banking_accounts(id,owner_id,type,currency,balance_minor) values($1,$2,'saving','VND',1)",
          [randomUUID(), customer.id],
        ),
      );
      for (const role of ["anon", "authenticated", "service_role"]) {
        const grants = await admin.query(
          "select has_table_privilege($1,'bank.demo_account_requests','select') allowed",
          [role],
        );
        assert.equal(grants.rows[0].allowed, false);
      }
      assert.equal(
        (
          await admin.query(
            "select sum(balance_minor)::text amount from bank.banking_accounts",
          )
        ).rows[0].amount,
        "0",
      );
      assert.equal(
        (
          await admin.query(
            "select count(*)::int n from bank.demo_account_requests",
          )
        ).rows[0].n,
        4,
      );
      console.log(
        JSON.stringify({
          result: "passed",
          checks: [
            "actual account migration chain",
            "idempotent replay",
            "changed key payload rejected",
            "cross-customer key rejected",
            "new-key duplicate rejected",
            "concurrent mortgage one winner",
            "same-key concurrent replay",
            "synthetic-only",
            "missing/disabled customer denied",
            "owner isolation",
            "officer detail",
            "zero saving estimate",
            "integer mortgage rounding",
            "transaction rollback and retry",
            "balance writes denied",
            "schedule updates denied",
            "audit deletion denied",
            "client-role audit access denied",
            "zero total balances",
            "one audit per created account",
          ],
        }),
      );
    } finally {
      await db?.onModuleDestroy();
      await admin.end();
    }
  });
  console.log("Owned fixture cleaned.");
} catch {
  console.error(JSON.stringify({ result: "failed", stage }));
  process.exitCode = 1;
}
