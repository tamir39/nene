import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { withTransfers } from "./lib/transfer-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { ConfirmationService } from "../backend/dist/confirmation/confirmation.service.js";
import { transferSeedSql } from "./lib/transfer-seed.mjs";
let stage = "fixture";
const checks = [];
const rejected = (work, status) =>
  assert.rejects(work, (e) => e.getStatus() === status);
try {
  await withTransfers(async (f) => {
    const { admin, db, security, service } = f;
    const a = await f.customer(),
      b = await f.customer();
    const input = {
      sourceAccountId: a.account.id,
      destinationAccountNumber: b.account.number,
      amountMinor: "100000",
    };
    const prepare = (amount = input.amountMinor) =>
      service.review(a.req, { ...input, amountMinor: amount }, true);
    const balance = async () =>
      (
        await admin.query(
          "select account_number::text number,balance_minor::text balance from bank.banking_accounts order by account_number",
        )
      ).rows;
    stage = "configuration and rules";
    await rejected(prepare(), 409);
    await admin.query("update bank.local_transfer_settings set enabled=true");
    await rejected(
      new ConfirmationService(db, security).review(a.req, input, true),
      409,
    );
    await rejected(prepare(), 400);
    const reference = await f.reference(a);
    await rejected(prepare(), 400);
    await admin.query(
      "update bank.banking_accounts set balance_minor=3000000 where id=$1",
      [a.account.id],
    );
    await rejected(prepare("5000000"), 400);
    await rejected(prepare("5000001"), 400);
    // Prove the threshold itself, independently of insufficient funds.
    await admin.query(
      "update bank.banking_accounts set balance_minor=10000000 where id=$1",
      [a.account.id],
    );
    await prepare("4999999");
    await rejected(prepare("5000000"), 400);
    await admin.query(
      "update bank.banking_accounts set balance_minor=3000000 where id=$1",
      [a.account.id],
    );
    await rejected(service.review(b.req, input, true), 400);
    await rejected(
      service.review(
        { ...a.req, user: { ...a.req.user, role: "officer" } },
        input,
        true,
      ),
      403,
    );
    checks.push(
      "off by default; missing reference, insufficient funds, threshold and role/ownership denied",
    );
    stage = "preview isolation";
    const preview = await service.review(a.req, input);
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: preview.reviewToken, code: "123456" },
        true,
      ),
      409,
    );
    checks.push("preview cannot become a financial transfer");
    stage = "real provider atomic posting";
    let review = await prepare();
    let code = generateTotp(a.setup.secret, {
      timestampSeconds: Math.floor(Date.now() / 1000) - 30,
    });
    if (code === a.setupCode)
      code = generateTotp(a.setup.secret, {
        timestampSeconds: Math.floor(Date.now() / 1000) + 30,
      });
    const second = new ConfirmationService(db, security, f.env);
    const answers = await Promise.all([
      service.confirm(a.req, { reviewToken: review.reviewToken, code }, true),
      second.confirm(a.req, { reviewToken: review.reviewToken, code }, true),
    ]);
    const success = answers.find((x) => x.replay === false);
    assert.equal(success.state, "posted");
    assert.equal(success.sent, true);
    a.req.headers.authorization = `Bearer ${success.accessToken}`;
    assert.deepEqual(
      (await balance()).map((x) => x.balance),
      ["2900000", "100000"],
    );
    assert.equal(
      (await admin.query("select count(*)::int n from bank.account_history"))
        .rows[0].n,
      2,
    );
    assert.equal(
      (await admin.query("select count(*)::int n from bank.local_transfers"))
        .rows[0].n,
      1,
    );
    await rejected(
      service.cancel(a.req, { reviewToken: review.reviewToken }, true),
      409,
    );
    await rejected(service.status(b.req, review.requestId, true), 404);
    checks.push(
      "real TOTP atomically posts two balances, two history rows and one receipt; duplicate/cancel cannot repost or reverse",
    );
    stage = "lost reply recovery";
    const login = await f.call("/token?grant_type=password", {
      email: a.email,
      password: a.password,
    });
    const freshReq = {
      ...a.req,
      headers: { authorization: `Bearer ${login.access_token}` },
    };
    assert.equal((await service.recent(freshReq)).transfers[0].state, "posted");
    assert.equal(
      (await service.status(freshReq, review.requestId, true)).receipt
        .amountMinor,
      "100000",
    );
    checks.push(
      "fresh login recovers committed receipt without repeating proof",
    );
    // Controlled provider responses test database races independently of TOTP timing.
    const provider = security.provider.bind(security);
    let onVerify = async () => {};
    let nextCode = 300000;
    security.provider = async (path, ...args) => {
      if (path.endsWith("/challenge")) return { id: randomUUID() };
      if (path.endsWith("/verify")) {
        await onVerify();
        return {
          access_token: success.accessToken,
          refresh_token: success.refreshToken,
        };
      }
      return provider(path, ...args);
    };
    stage = "concurrent insufficient funds";
    await admin.query(
      "update bank.banking_accounts set balance_minor=300000 where id=$1",
      [a.account.id],
    );
    const r1 = await prepare("200000"),
      r2 = await prepare("200000");
    const raced = await Promise.allSettled([
      service.confirm(
        a.req,
        { reviewToken: r1.reviewToken, code: String(nextCode++) },
        true,
      ),
      second.confirm(
        a.req,
        { reviewToken: r2.reviewToken, code: String(nextCode++) },
        true,
      ),
    ]);
    assert.equal(
      raced.filter((x) => x.status === "fulfilled" && x.value.sent).length,
      1,
    );
    assert.deepEqual(
      (await balance()).map((x) => x.balance),
      ["100000", "300000"],
    );
    assert.equal(
      (await admin.query("select count(*)::int n from bank.account_history"))
        .rows[0].n,
      4,
    );
    checks.push("concurrent spending cannot overdraw or partially post");
    // Expire failed leases to permit the next independent scenario; normal app does not reset these.
    await admin.query(
      "update bank.transaction_confirmations set lease_until=now()-interval '1 second' where state='checking'",
    );
    stage = "history failure rolls back debit and credit";
    review = await prepare("12345");
    const before = await balance();
    await admin.query(
      "alter table bank.account_history add constraint synthetic_failure check(amount_minor<>12345)",
    );
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: review.reviewToken, code: String(nextCode++) },
        true,
      ),
      503,
    );
    await admin.query(
      "alter table bank.account_history drop constraint synthetic_failure",
    );
    assert.deepEqual(await balance(), before);
    assert.equal(
      (await admin.query("select count(*)::int n from bank.account_history"))
        .rows[0].n,
      4,
    );
    assert.notEqual(
      (await service.status(a.req, review.requestId, true)).state,
      "posted",
    );
    checks.push(
      "history write failure rolls back balances, receipt and proof consumption",
    );
    await admin.query(
      "update bank.transaction_confirmations set lease_until=now()-interval '1 second' where state='checking'",
    );
    stage = "reference changed during provider";
    review = await prepare("10000");
    onVerify = () =>
      admin.query(
        "update bank.identity_cases set version=version+1 where id=$1",
        [reference],
      );
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: review.reviewToken, code: String(nextCode++) },
        true,
      ),
      503,
    );
    assert.deepEqual(await balance(), before);
    checks.push("reference revision change during verification blocks posting");
    await admin.query(
      "update bank.transaction_confirmations set lease_until=now()-interval '1 second' where state='checking'",
    );
    stage = "factor changed during provider";
    review = await prepare("10000");
    onVerify = () =>
      admin.query(
        "update bank.authenticator_setup set revision=revision+1 where customer_id=$1",
        [a.user.id],
      );
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: review.reviewToken, code: String(nextCode++) },
        true,
      ),
      503,
    );
    assert.deepEqual(await balance(), before);
    checks.push("factor revision change during verification blocks posting");
    await admin.query(
      "update bank.transaction_confirmations set lease_until=now()-interval '1 second' where state='checking'",
    );
    stage = "cancellation race";
    review = await prepare("10000");
    onVerify = () =>
      service.cancel(a.req, { reviewToken: review.reviewToken }, true);
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: review.reviewToken, code: String(nextCode++) },
        true,
      ),
      503,
    );
    assert.deepEqual(await balance(), before);
    checks.push(
      "cancellation defeats a late provider success without moving funds",
    );
    stage = "reference expires during verification";
    review = await prepare("10000");
    onVerify = () =>
      admin.query(
        "update bank.identity_cases set expires_at=now()-interval '1 second' where id=$1",
        [reference],
      );
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: review.reviewToken, code: String(nextCode++) },
        true,
      ),
      503,
    );
    assert.deepEqual(await balance(), before);
    checks.push("reference expiry during verification blocks posting");

    stage = "one-time seed";
    security.provider = provider;
    // Fresh synthetic accounts, without changing the normal local demo.
    const c = await f.customer(),
      d = await f.customer();
    await admin.query(transferSeedSql(c.account.number, d.account.number));
    await admin.query(
      "update bank.banking_accounts set balance_minor=2000000 where id=$1",
      [c.account.id],
    );
    await admin.query(transferSeedSql(c.account.number, d.account.number));
    assert.equal(
      (
        await admin.query(
          "select balance_minor::text balance from bank.banking_accounts where id=$1",
          [c.account.id],
        )
      ).rows[0].balance,
      "2000000",
    );
    await assert.rejects(
      admin.query(transferSeedSql(c.account.number, b.account.number)),
    );
    await admin.query("rollback");
    assert.throws(() =>
      transferSeedSql("100000000001;drop table x", "100000000002"),
    );
    checks.push(
      "local opening seed is idempotent and cannot reset or top up a funded source",
    );
    stage = "database privileges";
    for (const role of ["anon", "authenticated", "service_role", "nene_api"])
      assert.equal(
        (
          await admin.query(
            "select has_column_privilege($1,'bank.banking_accounts','balance_minor','update') allowed",
            [role],
          )
        ).rows[0].allowed,
        false,
      );
    for (const role of ["anon", "authenticated", "service_role"])
      assert.equal(
        (
          await admin.query(
            "select has_function_privilege($1,'bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid)','execute') allowed",
            [role],
          )
        ).rows[0].allowed,
        false,
      );
    assert.equal(
      (
        await admin.query(
          "select has_table_privilege('nene_api','bank.local_transfers','insert') allowed",
        )
      ).rows[0].allowed,
      false,
    );
    checks.push(
      "only narrow posting function can change balances and receipts; client roles denied",
    );
    console.log(JSON.stringify({ result: "passed", checks }));
  });
  console.log("Owned local-transfer fixture cleaned.");
} catch (e) {
  console.error(
    JSON.stringify({
      result: "failed",
      stage,
      status: e?.getStatus?.(),
      kind: e?.constructor?.name,
      sqlState: e?.code,
    }),
  );
  process.exitCode = 1;
}
