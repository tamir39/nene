import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { setTimeout as delay } from "node:timers/promises";
import { withIsolatedAuthFixture } from "./lib/isolated-auth-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { AuthorizationPrototypeService } from "../backend/dist/authorization-prototype/authorization.service.js";
import { SupabaseFactorVerifier } from "../backend/dist/authorization-prototype/factor-verifier.js";

const requireBackend = createRequire(
  new URL("../backend/package.json", import.meta.url),
);
requireBackend("reflect-metadata");
const { Pool } = requireBackend("pg");
let stage = "disposable environment setup";
let checks = 0;
function passed(name) {
  console.log(`PASS ${name}`);
  checks++;
}
function denied(work, status) {
  return assert.rejects(work, (error) => error?.getStatus?.() === status);
}
function immediate(user, response = "verified") {
  return {
    calls: 0,
    challengeCalls: 0,
    async challenge() {
      this.challengeCalls++;
      return { challengeId: randomUUID() };
    },
    async verify() {
      this.calls++;
      return response === "verified"
        ? { status: "verified", userId: user.id }
        : { status: response };
    },
  };
}
function pending(user) {
  let start, finish;
  const started = new Promise((resolve) => {
    start = resolve;
  });
  const result = new Promise((resolve) => {
    finish = resolve;
  });
  return {
    started,
    finish: () => finish({ status: "verified", userId: user.id }),
    verifier: {
      async challenge() {
        return { challengeId: randomUUID() };
      },
      async verify() {
        start();
        return result;
      },
    },
  };
}

try {
  await withIsolatedAuthFixture(async (fixture) => {
    console.log(JSON.stringify({ fixture: fixture.runtime }));
    const rolePassword = randomBytes(32).toString("base64url");
    fixture.sql(
      `create role nene_authorization_fixture login password '${rolePassword}';`,
    );
    fixture.sql(
      readFileSync(
        new URL(
          "../backend/src/authorization-prototype/schema.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const connection = new URL(fixture.databaseUrl);
    connection.username = "nene_authorization_fixture";
    connection.password = rolePassword;
    const admin = new Pool({ connectionString: fixture.databaseUrl, max: 2 });
    const pools = [0, 1].map(
      () => new Pool({ connectionString: connection.href, max: 3 }),
    );
    for (const pool of [admin, ...pools]) pool.on("error", () => undefined);
    const key = randomBytes(32);
    const service = (provider, index = 0, fingerprintKey = key) =>
      new AuthorizationPrototypeService(pools[index], provider, fingerprintKey);
    const query = (sql, params = []) => admin.query(sql, params);
    function delayedWritePool(fragment, mark) {
      return {
        async connect() {
          const client = await pools[1].connect();
          return {
            release: () => client.release(),
            async query(text, ...values) {
              if (typeof text === "string" && text.includes(fragment)) {
                mark();
                await delay(1200);
              }
              return client.query(text, ...values);
            },
          };
        },
      };
    }
    async function actor({
      id = randomUUID(),
      factorId = randomUUID(),
      role = "customer",
      active = true,
      accessToken = "synthetic-session",
    } = {}) {
      await query(
        "insert into authorization_prototype.principals(id,factor_id,role,active) values($1,$2,$3,$4)",
        [id, factorId, role, active],
      );
      return { id, factorId, accessToken };
    }
    async function operation(user, highValue = false) {
      const id = randomUUID();
      await query(
        `insert into authorization_prototype.operations(id,owner_id,source_id,destination_id,amount_minor,currency,requires_identity_comparison)
        values($1,$2,$3,$4,1000,'VND',$5)`,
        [id, user.id, randomUUID(), randomUUID(), highValue],
      );
      return id;
    }
    const state = async (id) =>
      (
        await query(
          "select state from authorization_prototype.operations where id=$1",
          [id],
        )
      ).rows[0].state;
    const prepare = (svc, user, id) => svc.prepare(user, id, 1, randomUUID());
    try {
      stage = "fixture privileges and absence of banking data";
      assert.equal(
        (
          await query(
            "select count(*)::integer as n from pg_namespace where nspname='bank'",
          )
        ).rows[0].n,
        0,
      );
      assert.equal(
        (
          await pools[0].query(
            "select has_schema_privilege(current_user,'auth','usage') as allowed",
          )
        ).rows[0].allowed,
        false,
      );
      await assert.rejects(
        pools[0].query(
          "update authorization_prototype.principals set role='officer'",
        ),
        (error) => error.code === "42501",
      );
      await assert.rejects(
        pools[0].query(
          "update authorization_prototype.operations set amount_minor=1",
        ),
        (error) => error.code === "42501",
      );
      passed(stage);

      stage = "ownership roles active status and required identity gate";
      const owner = await actor(),
        other = await actor(),
        officer = await actor({ role: "officer" }),
        inactive = await actor({ active: false });
      const op = await operation(owner),
        svc = service(immediate(owner));
      await denied(() => svc.status(other, op, 1), 404);
      await denied(() => svc.status(officer, op, 1), 403);
      await denied(() => svc.status(inactive, op, 1), 403);
      // High-value requirement is never mocked as a passed face comparison.
      const high = await operation(owner, true);
      await denied(() => prepare(svc, owner, high), 409);
      passed(stage);

      stage = "simultaneous same-attempt confirmation across two pools";
      const a = await actor(),
        opA = await operation(a),
        verifierA = immediate(a);
      const s1 = service(verifierA),
        s2 = service(verifierA, 1);
      const requestKey = randomUUID();
      const ready = await s1.prepare(a, opA, 1, requestKey);
      assert.equal(ready.attemptState, "ready");
      assert.equal(
        (await s2.prepare(a, opA, 1, requestKey)).attemptId,
        ready.attemptId,
      );
      const pair = await Promise.all([
        s1.confirm(a, opA, 1, ready.attemptId, "123456"),
        s2.confirm(a, opA, 1, ready.attemptId, "123456"),
      ]);
      assert.equal(verifierA.calls, 1);
      assert.equal(await state(opA), "authorized");
      assert.ok(pair.some((r) => r.state === "authorized"));
      passed(stage);

      stage = "durable duplicate recovery after recreating service";
      const afterRestart = service(verifierA, 1);
      const replay = await afterRestart.confirm(
        a,
        opA,
        1,
        ready.attemptId,
        "123456",
      );
      assert.equal(replay.state, "authorized");
      assert.equal(verifierA.calls, 1);
      await denied(
        () => afterRestart.confirm(a, opA, 1, ready.attemptId, "654321"),
        409,
      );
      await denied(
        () => service(verifierA, 1, randomBytes(32)).status(a, opA, 1),
        503,
      );
      passed(stage);

      stage = "single synthetic consumption and exact receipt retry";
      const receiptKey = randomUUID();
      const consumption = await Promise.allSettled([
        s1.consume(a, opA, 1, replay.authorizationId, receiptKey),
        s2.consume(a, opA, 1, replay.authorizationId, randomUUID()),
      ]);
      assert.equal(
        consumption.filter((r) => r.status === "fulfilled").length,
        1,
      );
      const stored = (
        await query(
          "select receipt_id,receipt_request_key from authorization_prototype.operations where id=$1",
          [opA],
        )
      ).rows[0];
      const receipt = await s1.consume(
        a,
        opA,
        1,
        replay.authorizationId,
        stored.receipt_request_key,
      );
      assert.equal(receipt.syntheticReceiptId, stored.receipt_id);
      await query(
        "update authorization_prototype.operations set amount_minor=2000 where id=$1",
        [opA],
      );
      await denied(
        () =>
          s1.consume(
            a,
            opA,
            1,
            replay.authorizationId,
            stored.receipt_request_key,
          ),
        409,
      );
      passed(stage);

      stage = "cross-operation proof replay prevention across two pools";
      const b = await actor(),
        opB1 = await operation(b),
        opB2 = await operation(b),
        vb = immediate(b);
      const b1 = service(vb),
        b2 = service(vb, 1);
      const rb1 = await prepare(b1, b, opB1),
        rb2 = await prepare(b2, b, opB2);
      const cross = await Promise.allSettled([
        b1.confirm(b, opB1, 1, rb1.attemptId, "234567"),
        b2.confirm(b, opB2, 1, rb2.attemptId, "234567"),
      ]);
      assert.equal(cross.filter((r) => r.status === "fulfilled").length, 1);
      assert.equal(vb.calls, 1);
      const losingIndex = cross.findIndex(
        (result) => result.status === "rejected",
      );
      await denied(
        () =>
          b1.confirm(
            { ...b, id: b.id.toUpperCase() },
            [opB1, opB2][losingIndex],
            1,
            [rb1, rb2][losingIndex].attemptId,
            "234567",
          ),
        409,
      );
      assert.equal(vb.calls, 1);
      assert.equal(
        (
          await query(
            "select count(*)::integer as n from authorization_prototype.operations where owner_id=$1 and state='authorized'",
            [b.id],
          )
        ).rows[0].n,
        1,
      );
      await denied(() => b1.confirm(b, opB2, 1, rb1.attemptId, "234567"), 404);
      const reusedRequestKey = (
        await query(
          "select request_key from authorization_prototype.attempts where id=$1",
          [rb1.attemptId],
        )
      ).rows[0].request_key;
      await denied(() => b1.prepare(b, opB2, 1, reusedRequestKey), 409);
      passed(stage);

      stage =
        "provider cannot assert another user and direct checks cannot authorize";
      const c = await actor(),
        opC = await operation(c),
        vc = immediate(other),
        cs = service(vc);
      const rc = await prepare(cs, c, opC);
      assert.equal(
        (await cs.confirm(c, opC, 1, rc.attemptId, "345678")).attemptState,
        "unknown",
      );
      assert.equal(await state(opC), "awaiting_authorization");
      passed(stage);

      for (const mutation of [
        "cancel",
        "expire",
        "amount",
        "version",
        "factor",
        "policy",
        "eligibility",
        "role",
      ]) {
        stage = `late provider success after ${mutation}`;
        const u = await actor(),
          id = await operation(u),
          held = pending(u),
          s = service(held.verifier);
        const r = await prepare(s, u, id);
        const confirmation = s.confirm(u, id, 1, r.attemptId, "456789");
        await held.started;
        if (mutation === "cancel")
          await service(held.verifier, 1).cancel(u, id, 1);
        if (mutation === "expire")
          await query(
            "update authorization_prototype.operations set expires_at=clock_timestamp()-interval '1 second' where id=$1",
            [id],
          );
        if (mutation === "amount")
          await query(
            "update authorization_prototype.operations set amount_minor=2000 where id=$1",
            [id],
          );
        if (mutation === "version")
          await query(
            "update authorization_prototype.operations set version=2 where id=$1",
            [id],
          );
        if (mutation === "factor")
          await query(
            "update authorization_prototype.principals set factor_id=$2 where id=$1",
            [u.id, randomUUID()],
          );
        if (mutation === "policy")
          await query(
            "update authorization_prototype.principals set policy_revision=2 where id=$1",
            [u.id],
          );
        if (mutation === "eligibility")
          await query(
            "update authorization_prototype.principals set eligible=false where id=$1",
            [u.id],
          );
        if (mutation === "role")
          await query(
            "update authorization_prototype.principals set role='officer' where id=$1",
            [u.id],
          );
        held.finish();
        if (mutation === "version") await denied(() => confirmation, 409);
        else if (mutation === "role") await denied(() => confirmation, 403);
        else assert.notEqual((await confirmation).state, "authorized");
        assert.notEqual(await state(id), "authorized");
        passed(stage);
      }

      stage = "expired lease supersession defeats a late successful reply";
      const d = await actor(),
        opD = await operation(d),
        heldD = pending(d),
        ds = service(heldD.verifier);
      const rd = await prepare(ds, d, opD);
      const old = ds.confirm(d, opD, 1, rd.attemptId, "567890");
      await heldD.started;
      await query(
        "update authorization_prototype.attempts set deadline=clock_timestamp()-interval '1 second' where id=$1",
        [rd.attemptId],
      );
      const replacement = await prepare(service(immediate(d), 1), d, opD);
      heldD.finish();
      assert.equal((await old).attemptState, "superseded");
      await denied(
        () =>
          service(immediate(d)).confirm(
            d,
            opD,
            1,
            replacement.attemptId,
            "567890",
          ),
        409,
      );
      assert.equal(await state(opD), "awaiting_authorization");
      passed(stage);

      stage = "provider success followed by database rollback stays unusable";
      const e = await actor(),
        opE = await operation(e),
        ve = immediate(e),
        es = service(ve);
      const re = await prepare(es, e, opE);
      await query(
        "alter table authorization_prototype.attempts add constraint fixture_reject_verified check(state <> 'verified') not valid",
      );
      try {
        await denied(() => es.confirm(e, opE, 1, re.attemptId, "678901"), 503);
      } finally {
        await query(
          "alter table authorization_prototype.attempts drop constraint fixture_reject_verified",
        );
      }
      assert.equal(await state(opE), "awaiting_authorization");
      const unresolved = await service(ve, 1).confirm(
        e,
        opE,
        1,
        re.attemptId,
        "678901",
      );
      assert.equal(unresolved.attemptState, "verifying");
      assert.equal(ve.calls, 1);
      await query(
        "update authorization_prototype.attempts set deadline=clock_timestamp()-interval '1 second' where id=$1",
        [re.attemptId],
      );
      assert.equal(
        (await es.confirm(e, opE, 1, re.attemptId, "678901")).attemptState,
        "unknown",
      );
      const retryE = await prepare(es, e, opE);
      await denied(
        () => es.confirm(e, opE, 1, retryE.attemptId, "678901"),
        409,
      );
      assert.equal(
        (await es.confirm(e, opE, 1, retryE.attemptId, "789012")).state,
        "authorized",
      );
      passed(stage);

      stage = "unknown and unavailable provider replies never authorize";
      const f = await actor(),
        opF = await operation(f),
        vf = immediate(f, "unknown"),
        fs = service(vf);
      const rf = await prepare(fs, f, opF);
      assert.equal(
        (await fs.confirm(f, opF, 1, rf.attemptId, "890123")).attemptState,
        "unknown",
      );
      assert.equal(await state(opF), "awaiting_authorization");
      passed(stage);

      stage =
        "per-operation and customer-wide budgets cannot reset via new operations";
      const g = await actor(),
        vg = immediate(g, "rejected"),
        gs = service(vg);
      const opG = await operation(g);
      for (let i = 0; i < 5; i++) {
        const r = await prepare(gs, g, opG);
        assert.equal(
          (await gs.confirm(g, opG, 1, r.attemptId, String(100000 + i)))
            .attemptState,
          "rejected",
        );
      }
      await denied(() => prepare(gs, g, opG), 429);
      for (let i = 0; i < 5; i++) {
        const id = await operation(g);
        await prepare(gs, g, id);
      }
      const extra = await operation(g);
      const blocked = await Promise.allSettled([
        prepare(gs, g, extra),
        prepare(service(vg, 1), g, extra),
      ]);
      assert.ok(
        blocked.every(
          (r) => r.status === "rejected" && r.reason.getStatus() === 429,
        ),
      );
      passed(stage);

      stage =
        "expired and materially changed authorizations cannot be consumed";
      const h = await actor(),
        opH = await operation(h),
        hs = service(immediate(h)),
        rh = await prepare(hs, h, opH);
      const ah = await hs.confirm(h, opH, 1, rh.attemptId, "901234");
      await query(
        "update authorization_prototype.operations set authorized_until=clock_timestamp()-interval '1 second' where id=$1",
        [opH],
      );
      await denied(
        () => hs.consume(h, opH, 1, ah.authorizationId, randomUUID()),
        409,
      );
      await query(
        "update authorization_prototype.operations set destination_id=$2 where id=$1",
        [opH, randomUUID()],
      );
      await denied(() => hs.confirm(h, opH, 1, rh.attemptId, "901234"), 409);
      passed(stage);

      stage =
        "status distinguishes stored authorization from present usability";
      for (const change of ["factor", "policy", "eligible", "expiry"]) {
        const u = await actor(),
          id = await operation(u),
          v = immediate(u),
          s = service(v),
          r = await prepare(s, u, id);
        const result = await s.confirm(u, id, 1, r.attemptId, "112233");
        assert.equal(result.authorizationUsable, true);
        if (change === "factor")
          await query(
            "update authorization_prototype.principals set factor_id=$2 where id=$1",
            [u.id, randomUUID()],
          );
        if (change === "policy")
          await query(
            "update authorization_prototype.principals set policy_revision=2 where id=$1",
            [u.id],
          );
        if (change === "eligible")
          await query(
            "update authorization_prototype.principals set eligible=false where id=$1",
            [u.id],
          );
        if (change === "expiry")
          await query(
            "update authorization_prototype.operations set authorized_until=clock_timestamp()-interval '1 second' where id=$1",
            [id],
          );
        const current = await s.status(u, id, 1);
        assert.equal(current.state, "authorized");
        assert.equal(current.authorizationUsable, false);
        assert.equal(current.authorizationId, undefined);
        assert.equal(
          (await s.confirm(u, id, 1, r.attemptId, "112233"))
            .authorizationUsable,
          false,
        );
        await denied(
          () => s.consume(u, id, 1, result.authorizationId, randomUUID()),
          409,
        );
      }
      passed(stage);

      stage =
        "expiry is enforced on the final authorization and consumption writes";
      let delayed = 0;
      const boundaryUser = await actor(),
        boundaryOp = await operation(boundaryUser),
        boundaryProvider = immediate(boundaryUser);
      const normal = service(boundaryProvider),
        boundaryReady = await prepare(normal, boundaryUser, boundaryOp);
      await query(
        "update authorization_prototype.operations set expires_at=clock_timestamp()+interval '1 second' where id=$1",
        [boundaryOp],
      );
      const lateAuthorization = new AuthorizationPrototypeService(
        delayedWritePool("set state='authorized'", () => delayed++),
        boundaryProvider,
        key,
      );
      const lateResult = await lateAuthorization.confirm(
        boundaryUser,
        boundaryOp,
        1,
        boundaryReady.attemptId,
        "223344",
      );
      assert.equal(delayed, 1);
      assert.equal(lateResult.authorizationUsable, false);
      assert.equal(lateResult.attemptState, "superseded");
      const consumeUser = await actor(),
        consumeOp = await operation(consumeUser),
        consumeProvider = immediate(consumeUser),
        consumeService = service(consumeProvider);
      const consumeReady = await prepare(
        consumeService,
        consumeUser,
        consumeOp,
      );
      const consumeAuth = await consumeService.confirm(
        consumeUser,
        consumeOp,
        1,
        consumeReady.attemptId,
        "334455",
      );
      await query(
        "update authorization_prototype.operations set authorized_until=clock_timestamp()+interval '1 second' where id=$1",
        [consumeOp],
      );
      const lateConsume = new AuthorizationPrototypeService(
        delayedWritePool("set state='consumed'", () => delayed++),
        consumeProvider,
        key,
      );
      await denied(
        () =>
          lateConsume.consume(
            consumeUser,
            consumeOp,
            1,
            consumeAuth.authorizationId,
            randomUUID(),
          ),
        409,
      );
      assert.equal(delayed, 2);
      assert.equal(await state(consumeOp), "authorized");
      passed(stage);

      stage =
        "real Supabase factor through backend reservation and replay safeguards";
      async function authRequest(path, token, body) {
        const response = await fetch(`${fixture.authOrigin}${path}`, {
          method: "POST",
          redirect: "error",
          headers: {
            "Content-Type": "application/json",
            ...(token ? { Authorization: `Bearer ${token}` } : {}),
          },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(10000),
        });
        assert.equal(response.status, 200);
        return response.json();
      }
      const email = `authorization-${randomUUID()}@example.invalid`,
        password = randomBytes(24).toString("base64url");
      const authUser = await authRequest("/admin/users", fixture.adminToken, {
        email,
        password,
        email_confirm: true,
      });
      const login = await authRequest("/token?grant_type=password", null, {
        email,
        password,
      });
      const factor = await authRequest("/factors", login.access_token, {
        factor_type: "totp",
      });
      const real = await actor({
        id: authUser.id,
        factorId: factor.id,
        accessToken: login.access_token,
      });
      const provider = new SupabaseFactorVerifier(
        fixture.authOrigin,
        fixture.anonKey,
      );
      const counted = {
        calls: 0,
        challenge: (...args) => provider.challenge(...args),
        async verify(...args) {
          this.calls++;
          return provider.verify(...args);
        },
      };
      const real1 = service(counted),
        real2 = service(counted, 1);
      const rop1 = await operation(real),
        rop2 = await operation(real);
      const r1 = await prepare(real1, real, rop1),
        r2 = await prepare(real2, real, rop2);
      const code = generateTotp(factor.totp.secret);
      const realPair = await Promise.allSettled([
        real1.confirm(real, rop1, 1, r1.attemptId, code),
        real2.confirm(real, rop2, 1, r2.attemptId, code),
      ]);
      assert.equal(
        realPair.filter(
          (r) => r.status === "fulfilled" && r.value.state === "authorized",
        ).length,
        1,
      );
      assert.equal(counted.calls, 1);
      const winner = realPair.find((r) => r.status === "fulfilled").value;
      const repeated = await service(counted, 1).confirm(
        real,
        winner.operationId,
        1,
        winner.attemptId,
        code,
      );
      assert.equal(repeated.authorizationId, winner.authorizationId);
      assert.equal(counted.calls, 1);
      // Even a successful direct provider check does not write an authorization.
      const direct = await provider.challenge(real.accessToken, real.factorId);
      assert.equal(
        (
          await provider.verify(
            real.accessToken,
            real.factorId,
            direct.challengeId,
            code,
          )
        ).status,
        "verified",
      );
      const loserId = winner.operationId === rop1 ? rop2 : rop1;
      assert.equal(await state(loserId), "awaiting_authorization");
      passed(stage);

      stage = "no raw codes credentials or financial tables persisted";
      const serialized = JSON.stringify(
        (
          await query(
            "select row_to_json(a) as value from authorization_prototype.attempts a",
          )
        ).rows,
      );
      assert.equal(serialized.includes(login.access_token), false);
      assert.equal(serialized.includes(factor.totp.secret), false);
      assert.equal(
        (
          await query(
            "select count(*)::integer as n from information_schema.tables where table_schema='bank'",
          )
        ).rows[0].n,
        0,
      );
      passed(stage);
    } finally {
      key.fill(0);
      await Promise.all([admin, ...pools].map((pool) => pool.end()));
    }
  });
  console.log(
    `Completed ${checks} prototype checks; owned containers, network and ports released. No money moved.`,
  );
} catch (error) {
  // Do not print SQL, Auth bodies, assertion values, stack traces or credentials.
  console.error(
    `Prototype check failed during: ${stage}. Private details suppressed.`,
  );
  if (
    typeof error?.message === "string" &&
    /^(Two free Nene test ports|Isolated fixture Docker command failed|Isolated fixture readiness timed out|Owned fixture cleanup needs attention)/.test(
      error.message,
    )
  )
    console.error(error.message);
  if (
    typeof error?.code === "string" &&
    /^(E[A-Z]+|[0-9A-Z]{5})$/.test(error.code)
  )
    console.error(`Safe error classification: ${error.code}`);
  if (typeof error?.getStatus === "function")
    console.error(`Safe HTTP classification: ${error.getStatus()}`);
  process.exitCode = 1;
}
