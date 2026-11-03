import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { withTransfers } from "./lib/transfer-fixture.mjs";
import { cashSeedSql } from "./lib/cash-seed.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { ConfirmationService } from "../backend/dist/confirmation/confirmation.service.js";
let stage = "fixture";
const checks = [];
const rejected = (promise, status) =>
  assert.rejects(promise, (e) => e.getStatus?.() === status);
try {
  await withTransfers(async (f) => {
    const { admin, service, security, db } = f;
    const a = await f.customer(),
      b = await f.customer();
    const input = { accountId: a.account.id, amountMinor: "100000" };
    const review = (kind, amount = "100000", account = a.account.id) =>
      service.review(a.req, { accountId: account, amountMinor: amount }, kind);
    const balances = async () => ({
      accounts: (
        await admin.query(
          "select id,balance_minor::text balance from bank.banking_accounts order by id",
        )
      ).rows,
      cash: (
        await admin.query(
          "select customer_id,balance_minor::text balance from bank.demo_cash_balances order by customer_id",
        )
      ).rows,
      receipts: (
        await admin.query(
          "select count(*)::int n from bank.local_cash_operations",
        )
      ).rows[0].n,
      history: (
        await admin.query("select count(*)::int n from bank.account_history")
      ).rows[0].n,
    });
    stage = "gates and seed";
    await rejected(review("deposit"), 409);
    await admin.query(cashSeedSql(a.account.number));
    await rejected(review("deposit"), 409);
    f.env.localCashEnabled = true;
    await rejected(review("deposit"), 400);
    const reference = await f.reference(a);
    await rejected(review("withdrawal"), 400);
    await rejected(review("deposit", "3000001"), 400);
    await admin.query(
      "update bank.demo_cash_balances set balance_minor=6000000 where customer_id=$1",
      [a.user.id],
    );
    await review("deposit", "4999999");
    await rejected(review("deposit", "5000000"), 400);
    await admin.query(
      "update bank.demo_cash_balances set balance_minor=3000000 where customer_id=$1",
      [a.user.id],
    );
    await rejected(service.review(b.req, input, "deposit"), 400);
    await rejected(
      service.review(
        { ...a.req, user: { ...a.req.user, role: "officer" } },
        input,
        "deposit",
      ),
      403,
    );
    checks.push(
      "default-off gates; reference, cash/account funds, threshold and role/ownership enforced",
    );
    stage = "kind and details binding";
    let r = await review("deposit");
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: r.reviewToken, code: "123456" },
        "withdrawal",
      ),
      409,
    );
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: r.reviewToken, code: "123456" },
        true,
      ),
      409,
    );
    const parts = r.reviewToken.split(".");
    const altered = JSON.parse(Buffer.from(parts[0], "base64url"));
    altered.amountMinor = "200000";
    await rejected(
      service.confirm(
        a.req,
        {
          reviewToken:
            Buffer.from(JSON.stringify(altered)).toString("base64url") +
            "." +
            parts[1],
          code: "123456",
        },
        "deposit",
      ),
      400,
    );
    checks.push(
      "deposit proof cannot authorize withdrawal/transfer or changed amount",
    );
    stage = "real deposit duplicate";
    const used = new Set([a.setupCode]);
    const freshCode = () => {
      for (const offset of [-30, 0, 30]) {
        const code = generateTotp(a.setup.secret, {
          timestampSeconds: Math.floor(Date.now() / 1000) + offset,
        });
        if (!used.has(code)) {
          used.add(code);
          return code;
        }
      }
      throw Error("No unused test code");
    };
    const code = freshCode(),
      second = new ConfirmationService(db, security, f.env);
    const responses = await Promise.all([
      service.confirm(a.req, { reviewToken: r.reviewToken, code }, "deposit"),
      second.confirm(a.req, { reviewToken: r.reviewToken, code }, "deposit"),
    ]);
    let result = responses.find((x) => x.replay === false);
    assert.equal(result.state, "posted");
    assert.equal(result.receipt.operation, "deposit");
    a.req.headers.authorization = `Bearer ${result.accessToken}`;
    let snapshot = await balances();
    assert.equal(
      snapshot.accounts.find((x) => x.id === a.account.id).balance,
      "100000",
    );
    assert.equal(snapshot.cash[0].balance, "2900000");
    assert.equal(snapshot.history, 1);
    assert.equal(snapshot.receipts, 1);
    await rejected(
      service.cancel(a.req, { reviewToken: r.reviewToken }, "deposit"),
      409,
    );
    await rejected(service.status(a.req, r.requestId, "withdrawal"), 404);
    await rejected(service.status(b.req, r.requestId, "deposit"), 404);
    checks.push(
      "real Supabase TOTP deposit credits account, consumes cash and posts one receipt/history entry despite duplicate",
    );
    stage = "real withdrawal and shared replay guard";
    let withdrawal = await review("withdrawal", "40000");
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: withdrawal.reviewToken, code },
        "withdrawal",
      ),
      400,
    );
    withdrawal = await review("withdrawal", "40000");
    result = await service.confirm(
      a.req,
      { reviewToken: withdrawal.reviewToken, code: freshCode() },
      "withdrawal",
    );
    a.req.headers.authorization = `Bearer ${result.accessToken}`;
    snapshot = await balances();
    assert.equal(
      snapshot.accounts.find((x) => x.id === a.account.id).balance,
      "60000",
    );
    assert.equal(snapshot.cash[0].balance, "2940000");
    assert.equal(snapshot.history, 2);
    assert.deepEqual(
      (
        await admin.query(
          "select kind,direction,amount_minor::text amount from bank.account_history order by posted_at",
        )
      ).rows,
      [
        { kind: "deposit", direction: "credit", amount: "100000" },
        { kind: "withdrawal", direction: "debit", amount: "40000" },
      ],
    );
    checks.push(
      "real withdrawal debits account and returns simulated cash; deposit code cannot be reused for withdrawal",
    );
    stage = "seed and fresh login recovery";
    await admin.query(cashSeedSql(a.account.number));
    assert.deepEqual(await balances(), snapshot);
    const saving = (
      await admin.query(
        "insert into bank.banking_accounts(id,owner_id,type,currency,is_demo) values($1,$2,'saving','VND',true) returning id,account_number::text number",
        [randomUUID(), a.user.id],
      )
    ).rows[0];
    await admin.query(cashSeedSql(saving.number));
    assert.equal(
      (await admin.query("select count(*)::int n from bank.demo_cash_balances"))
        .rows[0].n,
      1,
    );
    const login = await f.call("/token?grant_type=password", {
      email: a.email,
      password: a.password,
    });
    const req = {
      ...a.req,
      headers: { authorization: `Bearer ${login.access_token}` },
    };
    assert.equal(
      (await service.recent(req, "deposit")).operations[0].state,
      "posted",
    );
    assert.equal(
      (await service.status(req, withdrawal.requestId, "withdrawal")).state,
      "posted",
    );
    checks.push(
      "one cash seed per customer cannot refill; new sign-in recovers typed receipts",
    );
    const provider = security.provider.bind(security);
    let hook = async () => {};
    let next = 410000;
    security.provider = async (path, ...args) => {
      if (path.endsWith("/challenge")) return { id: randomUUID() };
      if (path.endsWith("/verify")) {
        await hook();
        return {
          access_token: result.accessToken,
          refresh_token: result.refreshToken,
        };
      }
      return provider(path, ...args);
    };
    const send = async (kind, amount, account = a.account.id) => {
      const item = await review(kind, amount, account);
      return service.confirm(
        a.req,
        { reviewToken: item.reviewToken, code: String(next++) },
        kind,
      );
    };
    const expire = () =>
      admin.query(
        "update bank.transaction_confirmations set lease_until=now()-interval '1 second' where state='checking'",
      );
    stage = "savings and mortgage rule";
    await send("deposit", "10000", saving.id);
    await send("withdrawal", "5000", saving.id);
    assert.equal(
      (await balances()).accounts.find((x) => x.id === saving.id).balance,
      "5000",
    );
    const mortgage = (
      await admin.query(
        "insert into bank.banking_accounts(id,owner_id,type,currency,is_demo) values($1,$2,'mortgage','VND',true) returning id",
        [randomUUID(), a.user.id],
      )
    ).rows[0];
    await rejected(review("deposit", "100", mortgage.id), 400);
    await rejected(review("withdrawal", "100", mortgage.id), 400);
    checks.push(
      "savings deposits/withdrawals use same customer cash; mortgage accounts are denied",
    );
    stage = "concurrent cash spending";
    await admin.query(
      "update bank.demo_cash_balances set balance_minor=150000 where customer_id=$1",
      [a.user.id],
    );
    const r1 = await review("deposit", "100000"),
      r2 = await review("deposit", "100000", saving.id);
    const race = await Promise.allSettled([
      service.confirm(
        a.req,
        { reviewToken: r1.reviewToken, code: String(next++) },
        "deposit",
      ),
      second.confirm(
        a.req,
        { reviewToken: r2.reviewToken, code: String(next++) },
        "deposit",
      ),
    ]);
    assert.equal(
      race.filter((x) => x.status === "fulfilled" && x.value.sent).length,
      1,
    );
    assert.equal((await balances()).cash[0].balance, "50000");
    await expire();
    checks.push(
      "concurrent deposits across two accounts cannot overspend shared simulated cash",
    );
    stage = "withdrawal races transfer";
    await admin.query("update bank.local_transfer_settings set enabled=true");
    await admin.query(
      "update bank.banking_accounts set balance_minor=50000 where id=$1",
      [a.account.id],
    );
    const withdrawRace = await review("withdrawal", "40000");
    const transferRace = await service.review(
      a.req,
      {
        sourceAccountId: a.account.id,
        destinationAccountNumber: b.account.number,
        amountMinor: "40000",
      },
      true,
    );
    const spend = await Promise.allSettled([
      service.confirm(
        a.req,
        { reviewToken: withdrawRace.reviewToken, code: String(next++) },
        "withdrawal",
      ),
      second.confirm(
        a.req,
        { reviewToken: transferRace.reviewToken, code: String(next++) },
        true,
      ),
    ]);
    assert.equal(
      spend.filter((x) => x.status === "fulfilled" && x.value.sent).length,
      1,
    );
    const spent = await balances();
    assert.equal(
      spent.accounts.find((x) => x.id === a.account.id).balance,
      "10000",
    );
    assert.equal(
      BigInt(spent.cash[0].balance) +
        BigInt(spent.accounts.find((x) => x.id === b.account.id).balance),
      90000n,
    );
    await expire();
    checks.push(
      "concurrent withdrawal and transfer cannot spend the same account funds twice",
    );
    // Reset only the disposable fixture's attempt window between independent cases.
    await admin.query(
      "delete from bank.security_proof_reservations where customer_id=$1",
      [a.user.id],
    );
    stage = "history rollback";
    snapshot = await balances();
    await admin.query(
      "alter table bank.account_history add constraint cash_test_failure check(amount_minor<>12345)",
    );
    await rejected(send("deposit", "12345"), 503);
    assert.deepEqual(await balances(), snapshot);
    await admin.query(
      "alter table bank.account_history drop constraint cash_test_failure",
    );
    await expire();
    checks.push(
      "failed history insert rolls back cash, bank balance, receipt and proof consumption",
    );
    stage = "late cancellation";
    r = await review("withdrawal", "1000");
    hook = () =>
      service.cancel(a.req, { reviewToken: r.reviewToken }, "withdrawal");
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: r.reviewToken, code: String(next++) },
        "withdrawal",
      ),
      503,
    );
    assert.deepEqual(await balances(), snapshot);
    checks.push(
      "cancellation wins before posting without dispensing or debiting anything",
    );
    stage = "expired reference";
    hook = () =>
      admin.query(
        "update bank.identity_cases set expires_at=now()-interval '1 second' where id=$1",
        [reference],
      );
    await rejected(send("deposit", "1000"), 503);
    assert.deepEqual(await balances(), snapshot);
    await expire();
    await admin.query(
      "update bank.identity_cases set expires_at=now()+interval '1 day' where id=$1",
      [reference],
    );
    checks.push("reference expiry during verification blocks posting");
    stage = "changed security";
    hook = () =>
      admin.query(
        "update bank.authenticator_setup set revision=revision+1 where customer_id=$1",
        [a.user.id],
      );
    await rejected(send("withdrawal", "1000"), 503);
    assert.deepEqual(await balances(), snapshot);
    await expire();
    checks.push("factor revision change during verification blocks posting");
    stage = "uncertain provider";
    hook = async () => {
      throw Error("Synthetic timeout");
    };
    await rejected(send("deposit", "1000"), 503);
    assert.deepEqual(await balances(), snapshot);
    assert.equal(
      (await service.recent(a.req, "deposit")).operations[0].state,
      "unknown",
    );
    checks.push(
      "uncertain provider outcome creates no financial result and cannot auto-retry",
    );
    stage = "privileges";
    for (const role of ["anon", "authenticated", "service_role", "nene_api"]) {
      for (const table of ["demo_cash_balances", "local_cash_operations"])
        assert.equal(
          (
            await admin.query(
              "select has_table_privilege($1,$2,'insert,update,delete') allowed",
              [role, "bank." + table],
            )
          ).rows[0].allowed,
          false,
        );
    }
    for (const role of ["anon", "authenticated", "service_role"])
      assert.equal(
        (
          await admin.query(
            "select has_function_privilege($1,'bank.post_local_cash(uuid,uuid,uuid,text,uuid,text,bigint,uuid,integer,integer,uuid)','execute') allowed",
            [role],
          )
        ).rows[0].allowed,
        false,
      );
    checks.push(
      "client roles cannot post cash operations; API cannot directly seed/change cash or receipts",
    );
    console.log(JSON.stringify({ result: "passed", checks }));
  });
  console.log("Owned cash fixture cleaned.");
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
