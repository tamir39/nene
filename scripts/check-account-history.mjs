import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { DatabaseService } from "../backend/dist/database/database.service.js";
import { AccountHistoryController } from "../backend/dist/accounts/account-history.controller.js";
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
      stage = "migrations";
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
        "20261103000400_account_history.sql",
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
      const customer = randomUUID(),
        other = randomUUID(),
        account = randomUUID(),
        empty = randomUUID(),
        foreign = randomUUID();
      for (const id of [customer, other]) {
        await admin.query("insert into auth.users(id) values($1)", [id]);
        await admin.query(
          "insert into bank.user_profiles(id,display_name,role) values($1,'Synthetic','customer')",
          [id],
        );
      }
      for (const [id, owner] of [
        [account, customer],
        [empty, customer],
        [foreign, other],
      ])
        await admin.query(
          "insert into bank.banking_accounts(id,owner_id,type,currency) values($1,$2,'checking','VND')",
          [id, owner],
        );
      async function seed(id, time, amount = "100", target = account) {
        await admin.query(
          "insert into bank.account_history(id,account_id,operation_id,kind,direction,amount_minor,currency,posted_at) values($1,$2,$3,'transfer','credit',$4,'VND',$5)",
          [id, target, randomUUID(), amount, time],
        );
      }
      const low = randomUUID(),
        high = randomUUID(),
        before = randomUUID(),
        after = randomUUID(),
        foreignEntry = randomUUID();
      await seed(low, "2026-10-31T17:00:00Z", "9007199254740993");
      await seed(high, "2026-11-30T16:59:59.999999Z");
      await seed(before, "2026-10-31T16:59:59.999999Z");
      await seed(after, "2026-11-30T17:00:00Z");
      await seed(foreignEntry, "2026-11-10T00:00:00Z", "777", foreign);
      const ties = [];
      for (let i = 0; i < 28; i++) {
        const id = randomUUID();
        ties.push(id);
        await seed(id, "2026-11-10T00:00:00.123456Z");
      }
      const url = new URL(f.databaseUrl);
      url.username = "nene_api";
      url.password = password;
      db = new DatabaseService({ database: { connectionString: url.href } });
      const api = new AccountHistoryController(db),
        req = { user: { id: customer, role: "customer" } };
      stage = "paging and month boundaries";
      const first = await api.read(req, account, { month: "2026-11" });
      assert.equal(first.entries.length, 25);
      assert.ok(first.nextCursor);
      const second = await api.read(req, account, {
        month: "2026-11",
        cursor: first.nextCursor,
      });
      assert.equal(second.entries.length, 5);
      assert.equal(second.nextCursor, null);
      const ids = [...first.entries, ...second.entries].map((x) => x.id);
      assert.deepEqual(ids, [high, ...ties.sort().reverse(), low]);
      assert.equal(new Set(ids).size, 30);
      assert.equal(second.entries.at(-1).amountMinor, "9007199254740993");
      assert.equal(first.entries[0].postedAt, "2026-11-30T16:59:59.999999Z");
      assert.deepEqual(
        await api.read(req, account, { month: "2026-11" }),
        first,
      );
      stage = "empty and isolation";
      assert.equal(
        (await api.read(req, empty, { month: "2026-11" })).entries.length,
        0,
      );
      assert.equal(
        (await api.read(req, account, { month: "2026-12" })).entries[0].id,
        after,
      );
      for (const id of [foreign, randomUUID()])
        await assert.rejects(
          api.read(req, id, { month: "2026-11" }),
          (e) => e.getStatus() === 404,
        );
      for (const cursor of [foreignEntry, before, randomUUID()])
        await assert.rejects(
          api.read(req, account, { month: "2026-11", cursor }),
          (e) => e.getStatus() === 400,
        );
      await assert.rejects(
        api.read({ user: { id: customer, role: "officer" } }, account, {
          month: "2026-11",
        }),
        (e) => e.getStatus() === 403,
      );
      stage = "read-only privileges";
      await assert.rejects(db.query("delete from bank.account_history", []));
      await assert.rejects(
        db.query("update bank.account_history set amount_minor=1", []),
      );
      await assert.rejects(
        db.query(
          "insert into bank.account_history(id,account_id,operation_id,kind,direction,amount_minor,currency,posted_at) values($1,$2,$3,'deposit','credit',1,'VND',now())",
          [randomUUID(), account, randomUUID()],
        ),
      );
      for (const role of ["anon", "authenticated", "service_role"])
        assert.equal(
          (
            await admin.query(
              "select has_table_privilege($1,'bank.account_history','select') allowed",
              [role],
            )
          ).rows[0].allowed,
          false,
        );
      assert.equal(
        (
          await admin.query(
            "select sum(balance_minor)::text amount from bank.banking_accounts",
          )
        ).rows[0].amount,
        "0",
      );
      console.log(
        JSON.stringify({
          result: "passed",
          checks: [
            "25-row pagination",
            "equal-timestamp UUID order",
            "no missing or duplicate rows",
            "UTC+07 month boundaries",
            "microsecond preservation",
            "large integer amount",
            "repeatable page read",
            "empty history",
            "different month",
            "owner isolation and indistinguishable missing account",
            "account/month-bound cursor",
            "officer denial",
            "insert/update/delete denied",
            "client roles denied",
            "balances unchanged",
          ],
        }),
      );
    } finally {
      await db?.onModuleDestroy();
      await admin.end();
    }
  });
  console.log("Owned history fixture cleaned.");
} catch {
  console.error(JSON.stringify({ result: "failed", stage }));
  process.exitCode = 1;
}
