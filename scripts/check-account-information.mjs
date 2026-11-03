import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { DatabaseService } from "../backend/dist/database/database.service.js";
import { CustomersService } from "../backend/dist/customers/customers.service.js";
import { SavingsPolicyController } from "../backend/dist/accounts/savings-policy.controller.js";
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
      const password = randomBytes(24).toString("hex");
      await admin.query(
        `create role nene_api login password '${password}';create schema bank;grant usage on schema bank to nene_api;create table bank.user_profiles(id uuid primary key,role text,status text);grant select on bank.user_profiles to nene_api;create table bank.banking_accounts(id uuid primary key,owner_id uuid,type text,currency text,balance_minor bigint,status text,account_number bigint,created_at timestamptz default now());grant select on bank.banking_accounts to nene_api;`,
      );
      for (const role of ["anon", "authenticated", "service_role"])
        await admin.query(
          `DO $$ begin if not exists(select from pg_roles where rolname='${role}')then create role ${role};end if;end $$;`,
        );
      await admin.query(
        readFileSync(
          new URL(
            "../infrastructure/supabase/migrations/20261103000200_account_information.sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      const customer = { id: randomUUID(), role: "customer" },
        officer = { id: randomUUID(), role: "officer" },
        other = { id: randomUUID(), role: "customer" };
      for (const user of [customer, officer, other])
        await admin.query(
          "insert into bank.user_profiles values($1,$2,'active')",
          [user.id, user.role],
        );
      const accountIds = [randomUUID(), randomUUID(), randomUUID()];
      for (let i = 0; i < 3; i++)
        await admin.query(
          "insert into bank.banking_accounts(id,owner_id,type,currency,balance_minor,status,account_number) values($1,$2,$3,'VND',$4,'active',$5)",
          [
            accountIds[i],
            customer.id,
            ["checking", "saving", "mortgage"][i],
            i === 1 ? "10000000" : "0",
            100 + i,
          ],
        );
      await admin.query(
        "insert into bank.mortgage_schedule values($1,5000000,500000,'2026-12-01')",
        [accountIds[2]],
      );
      const url = new URL(f.databaseUrl);
      url.username = "nene_api";
      url.password = password;
      db = new DatabaseService({ database: { connectionString: url.href } });
      const accounts = new CustomersService(db, {}),
        policy = new SavingsPolicyController(db),
        req = { user: officer };
      stage = "role and policy";
      await assert.rejects(
        policy.edit(
          { user: customer },
          { annualRateBps: 600, revision: 1, reason: "fixture rate" },
        ),
      );
      await policy.edit(req, {
        annualRateBps: 600,
        revision: 1,
        reason: "fixture rate",
      });
      stage = "own information";
      const result = await accounts.ownAccounts(customer);
      assert.equal(result.accounts.length, 3);
      assert.equal(
        result.accounts.find((a) => a.type === "saving").monthlyProfitMinor,
        "50000",
      );
      assert.equal(
        result.accounts.find((a) => a.type === "mortgage").monthlyDueMinor,
        "500000",
      );
      assert.equal((await accounts.ownAccounts(other)).accounts.length, 0);
      stage = "concurrent policy edits";
      const settled = await Promise.allSettled([
        policy.edit(req, {
          annualRateBps: 700,
          revision: 2,
          reason: "concurrent A",
        }),
        policy.edit(req, {
          annualRateBps: 800,
          revision: 2,
          reason: "concurrent B",
        }),
      ]);
      assert.equal(settled.filter((x) => x.status === "fulfilled").length, 1);
      assert.equal(
        (
          await admin.query(
            "select count(*)::int as n from bank.savings_rate_audit",
          )
        ).rows[0].n,
        2,
      );
      stage = "least privilege";
      await assert.rejects(
        db.query("update bank.banking_accounts set balance_minor=1", []),
      );
      await assert.rejects(db.query("delete from bank.savings_rate_audit", []));
      await assert.rejects(
        db.query("update bank.mortgage_schedule set monthly_due_minor=1", []),
      );
      const before = (
        await admin.query(
          "select balance_minor::text from bank.banking_accounts order by account_number",
        )
      ).rows;
      assert.deepEqual(
        before.map((x) => x.balance_minor),
        ["0", "10000000", "0"],
      );
      console.log(
        JSON.stringify({
          result: "passed",
          checks: [
            "customer denied rate write",
            "officer rate audited",
            "three types read",
            "profit calculation",
            "mortgage schedule",
            "owner isolation",
            "one concurrent winner",
            "atomic audit",
            "balance write denied",
            "audit delete denied",
            "mortgage write denied",
            "balances unchanged",
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
