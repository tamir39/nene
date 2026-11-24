import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import { withIsolatedAuthFixture } from "./isolated-auth-fixture.mjs";
import { generateTotp } from "./totp-fixture.mjs";
import { DatabaseService } from "../../backend/dist/database/database.service.js";
import { SecurityService } from "../../backend/dist/security/security.service.js";
import { ConfirmationService } from "../../backend/dist/confirmation/confirmation.service.js";
const require = createRequire(
  new URL("../../backend/package.json", import.meta.url),
);
require("reflect-metadata");
const { Pool } = require("pg");
export async function withTransfers(work) {
  return withIsolatedAuthFixture(async (f) => {
    const admin = new Pool({ connectionString: f.databaseUrl, max: 1 });
    let db;
    const oldFetch = globalThis.fetch;
    globalThis.fetch = (url, init) =>
      oldFetch(
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
      const migrations = new URL(
        "../../infrastructure/supabase/migrations/",
        import.meta.url,
      );
      for (const name of readdirSync(migrations)
        .filter((n) => n.endsWith(".sql"))
        .sort())
        await admin.query(readFileSync(new URL(name, migrations), "utf8"));
      const password = randomBytes(24).toString("hex");
      await admin.query(`alter role nene_api login password '${password}'`);
      const url = new URL(f.databaseUrl);
      url.username = "nene_api";
      url.password = password;
      db = new DatabaseService({ database: { connectionString: url.href } });
      const env = {
        localTransfersEnabled: true,
        nodeEnv: "test",
        supabaseUrl: f.authOrigin,
        supabasePublishableKey: f.anonKey,
      };
      const security = new SecurityService(db, env),
        service = new ConfirmationService(db, security, env);
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
        const email = `transfer-${randomUUID()}@example.invalid`,
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
            "insert into bank.banking_accounts(id,owner_id,type,currency,is_demo) values($1,$2,'checking','VND',true) returning id,account_number::text number",
            [randomUUID(), user.id],
          )
        ).rows[0];
        const pair = await call("/token?grant_type=password", {
          email,
          password,
        });
        const req = {
          headers: { authorization: `Bearer ${pair.access_token}` },
          user: { id: user.id, role: "customer" },
        };
        const setup = await security.start(req),
          setupCode = generateTotp(setup.secret);
        const verified = await security.verify(req, {
          requestId: setup.requestId,
          code: setupCode,
        });
        req.headers.authorization = `Bearer ${verified.accessToken}`;
        return {
          req,
          account,
          user,
          email,
          password,
          setup,
          setupCode,
          pair: verified,
        };
      }
      async function reference(customer) {
        const id = randomUUID(),
          evidence = randomUUID();
        await admin.query(
          "insert into bank.identity_cases(id,customer_id,state,profile_name,notice_version,acknowledged_by,acknowledged_role,expires_at) values($1,$2,'draft','Synthetic fixture','reference-demo-v1',$2,'customer',now()+interval '1 day')",
          [id, customer.user.id],
        );
        await admin.query(
          "insert into bank.identity_evidence(id,case_id,revision,object_key,content_hash,content_type,byte_size,status,ready_at,expires_at) values($1::uuid,$2,1,$1::text,repeat('a',64),'image/png',1,'ready',now(),now()+interval '1 day')",
          [evidence, id],
        );
        await admin.query(
          "update bank.identity_cases set evidence_id=$2,state='reference_accepted',reviewed_by=customer_id,reviewed_at=now() where id=$1",
          [id, evidence],
        );
        return id;
      }
      await work({
        admin,
        db,
        security,
        service,
        env,
        customer,
        reference,
        call,
        fixture: f,
      });
    } finally {
      globalThis.fetch = oldFetch;
      await db?.onModuleDestroy();
      await admin.end();
    }
  });
}
