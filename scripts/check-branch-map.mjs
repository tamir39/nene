// Disposable database evidence for BR-13; no live Nene data or location requests.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { DatabaseService } from "../backend/dist/database/database.service.js";
import { BranchesController } from "../backend/dist/branches/branches.controller.js";
const require = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
require("reflect-metadata");
const { Pool } = require("pg");
let stage = "fixture";
try {
  await withIsolatedAuthFixture(async (f) => {
    const admin = new Pool({ connectionString: f.databaseUrl, max: 1 });
    let db;
    try {
      stage = "migration";
      const password = randomBytes(24).toString("hex");
      await admin.query(
        `create role nene_api login password '${password}'; create schema bank; grant usage on schema bank to nene_api;`,
      );
      for (const role of ["anon", "authenticated", "service_role"])
        await admin.query(
          `do $$ begin if not exists(select from pg_roles where rolname='${role}') then create role ${role}; end if; end $$;`,
        );
      await admin.query(
        readFileSync(
          new URL(
            "../infrastructure/supabase/migrations/20261105000100_demo_branches.sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      const url = new URL(f.databaseUrl);
      url.username = "nene_api";
      url.password = password;
      db = new DatabaseService({ database: { connectionString: url.href } });
      const routes = {
        walk: async () => ({
          points: [],
          distanceMeters: 200,
          durationSeconds: 150,
        }),
      };
      const controller = new BranchesController(db, routes);
      const request = { user: { id: "synthetic-user", role: "customer" } };
      stage = "catalog and route selection";
      const catalog = await controller.read(request);
      assert.equal(catalog.branches.length, 3);
      assert.ok(catalog.branches.every((b) => b.isDemo));
      assert.equal(
        (await controller.route(request, catalog.demoOrigin)).branchId,
        "nene-tdtu-demo",
      );
      await assert.rejects(
        controller.route(request, { latitude: 0, longitude: 0 }),
      );
      stage = "least privilege";
      for (const sql of [
        "update bank.branches set name='Changed'",
        "delete from bank.branches",
        "insert into bank.branches values('extra','Extra','Fake',0,0,true)",
      ])
        await assert.rejects(db.query(sql, []));
      for (const role of ["anon", "authenticated", "service_role"]) {
        await admin.query(`set role ${role}`);
        try {
          await assert.rejects(admin.query("select * from bank.branches"));
        } finally {
          await admin.query("reset role");
        }
      }
      assert.equal((await controller.read(request)).branches.length, 3);
      console.log(
        JSON.stringify({
          result: "passed",
          checks: [
            "persisted fictional catalog",
            "nearest office",
            "out-of-area denial",
            "API read only",
            "client database access denied",
            "catalog unchanged",
          ],
        }),
      );
    } finally {
      await db?.onModuleDestroy();
      await admin.end();
    }
  });
  console.log("Owned branch fixture cleaned.");
} catch {
  console.error(JSON.stringify({ result: "failed", stage }));
  process.exitCode = 1;
}
