import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { withTransfers } from "./lib/transfer-fixture.mjs";
import { transferSeedSql } from "./lib/transfer-seed.mjs";
import { cashSeedSql } from "./lib/cash-seed.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { ConfirmationService } from "../backend/dist/confirmation/confirmation.service.js";

// Disposable PostgreSQL + real local Supabase Auth only. This does not start the
// user's demo, provision a provider, fund normal accounts or contact a bank.
let stage = "fixture";
const checks = [];
const rejected = (promise, status) =>
  assert.rejects(promise, (error) => error.getStatus?.() === status);
const postSql =
  "select bank.post_local_interbank($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)";
const postSignature =
  "bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid)";

try {
  await withTransfers(async (f) => {
    const { admin, db, security, service } = f;
    const a = await f.customer();
    const b = await f.customer();
    const input = {
      sourceAccountId: a.account.id,
      destinationBankCode: "DEMO_A",
      destinationAccountNumber: "990000000001",
      amountMinor: "100000",
    };
    const review = (amount = "100000", changes = {}) =>
      service.review(
        a.req,
        { ...input, amountMinor: amount, ...changes },
        "interbank",
      );
    const snapshot = async () => ({
      accounts: (
        await admin.query(
          "select id,balance_minor::text balance from bank.banking_accounts order by id",
        )
      ).rows,
      recipients: (
        await admin.query(
          "select id,balance_minor::text balance from bank.demo_external_recipients order by id",
        )
      ).rows,
      cash: (
        await admin.query(
          "select customer_id,balance_minor::text balance from bank.demo_cash_balances order by customer_id",
        )
      ).rows,
      receipts: (
        await admin.query(
          "select id,amount_minor::text amount from bank.local_interbank_transfers order by id",
        )
      ).rows,
      history: (
        await admin.query(
          "select id,account_id,kind,direction,amount_minor::text amount from bank.account_history order by id",
        )
      ).rows,
    });
    const expireAttempts = () =>
      admin.query(
        "update bank.transaction_confirmations set lease_until=now()-interval '1 second' where state='checking'",
      );
    // Reset only the disposable fixture's rate window between independent cases.
    const clearWindow = () =>
      admin.query(
        "delete from bank.security_proof_reservations where customer_id=$1",
        [a.user.id],
      );

    stage = "independent gates and rules";
    assert.equal(
      (await service.configuration(a.req, "interbank")).enabled,
      false,
    );
    assert.deepEqual(
      (await snapshot()).recipients.map((r) => r.balance),
      ["0", "0"],
    );
    await rejected(review(), 409);
    await admin.query("update bank.local_interbank_settings set enabled=true");
    await rejected(review(), 409);
    f.env.localInterbankEnabled = true;
    await rejected(review(), 400);
    const reference = await f.reference(a);
    await rejected(review(), 400);
    await admin.query(transferSeedSql(a.account.number, b.account.number));
    const enabled = await service.configuration(a.req, "interbank");
    assert.equal(enabled.enabled, true);
    assert.equal(enabled.simulated, true);
    assert.deepEqual(
      enabled.banks.map((bank) => bank.code),
      ["DEMO_A", "DEMO_B"],
    );
    await rejected(
      new ConfirmationService(db, security, {
        ...f.env,
        nodeEnv: "production",
      }).review(a.req, input, "interbank"),
      409,
    );
    await rejected(service.review(b.req, input, "interbank"), 400);
    await rejected(
      service.review(
        { ...a.req, user: { ...a.req.user, role: "officer" } },
        input,
        "interbank",
      ),
      403,
    );
    await rejected(review("3000001"), 400);
    await admin.query(
      "update bank.banking_accounts set balance_minor=6000000 where id=$1",
      [a.account.id],
    );
    await review("4999999");
    await rejected(review("5000000"), 400);
    await admin.query(
      "update bank.banking_accounts set balance_minor=3000000 where id=$1",
      [a.account.id],
    );
    await rejected(review("1", { destinationBankCode: "DEMO_B" }), 400);
    await rejected(
      review("1", { destinationAccountNumber: b.account.number }),
      400,
    );
    await rejected(review("1", { destinationBankCode: "REAL_BANK" }), 400);
    checks.push(
      "separate default-off gates, synthetic checking ownership, funds, threshold and fixed bank/recipient allowlist enforced",
    );

    stage = "operation binding";
    // Enable the other financial purposes so rejection proves policy binding,
    // rather than only encountering a disabled feature gate.
    await admin.query("update bank.local_cash_settings set enabled=true");
    f.env.localCashEnabled = true;
    let r = await review();
    for (const operation of [false, true, "deposit", "withdrawal"])
      await rejected(
        service.confirm(
          a.req,
          { reviewToken: r.reviewToken, code: "123456" },
          operation,
        ),
        409,
      );
    const preview = await service.review(a.req, {
      sourceAccountId: a.account.id,
      destinationAccountNumber: b.account.number,
      amountMinor: "100000",
    });
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: preview.reviewToken, code: "123456" },
        "interbank",
      ),
      409,
    );
    const parts = r.reviewToken.split(".");
    const altered = JSON.parse(Buffer.from(parts[0], "base64url"));
    altered.destinationBankName = "Demo altered bank";
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
        "interbank",
      ),
      400,
    );
    checks.push(
      "signed review is bank/recipient-bound and cannot cross preview, ordinary transfer or cash purposes",
    );

    stage = "real Auth proof and duplicate posting";
    const used = new Set([a.setupCode]);
    let code;
    for (const offset of [-30, 0, 30]) {
      const candidate = generateTotp(a.setup.secret, {
        timestampSeconds: Math.floor(Date.now() / 1000) + offset,
      });
      if (!used.has(candidate)) {
        code = candidate;
        break;
      }
    }
    assert.ok(code, "unused real TOTP fixture code required");
    const second = new ConfirmationService(db, security, f.env);
    const replies = await Promise.all([
      service.confirm(a.req, { reviewToken: r.reviewToken, code }, "interbank"),
      second.confirm(a.req, { reviewToken: r.reviewToken, code }, "interbank"),
    ]);
    const success = replies.find((response) => response.replay === false);
    assert.equal(success.state, "posted");
    assert.equal(success.sent, true);
    assert.equal(success.receipt.simulated, true);
    assert.equal(success.receipt.destinationBankCode, "DEMO_A");
    a.req.headers.authorization = `Bearer ${success.accessToken}`;
    let saved = await snapshot();
    assert.equal(
      saved.accounts.find((row) => row.id === a.account.id).balance,
      "2900000",
    );
    assert.equal(
      saved.accounts.find((row) => row.id === b.account.id).balance,
      "0",
    );
    assert.equal(saved.recipients[0].balance, "100000");
    assert.equal(saved.receipts.length, 1);
    assert.equal(saved.history.length, 1);
    assert.equal(saved.history[0].kind, "interbank_transfer");
    assert.equal(saved.history[0].direction, "debit");
    await rejected(
      service.cancel(a.req, { reviewToken: r.reviewToken }, "interbank"),
      409,
    );
    await rejected(service.status(b.req, r.requestId, "interbank"), 404);
    await rejected(service.status(a.req, r.requestId, true), 404);
    const replayReview = await review();
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: replayReview.reviewToken, code },
        "interbank",
      ),
      400,
    );
    const crossPurpose = await service.review(
      a.req,
      {
        sourceAccountId: a.account.id,
        destinationAccountNumber: b.account.number,
        amountMinor: "1000",
      },
      true,
    );
    await rejected(
      service.confirm(
        a.req,
        { reviewToken: crossPurpose.reviewToken, code },
        true,
      ),
      400,
    );
    assert.deepEqual(await snapshot(), saved);
    checks.push(
      "real Supabase TOTP posts once: sender debit, separate simulated recipient credit, one labelled history row and immutable receipt; same-purpose and cross-purpose code reuse denied",
    );

    stage = "narrow function idempotency and null safety";
    const decoded = JSON.parse(
      Buffer.from(r.reviewToken.split(".")[0], "base64url"),
    );
    const proof = (
      await admin.query(
        "select * from bank.transaction_confirmations where id=$1",
        [r.requestId],
      )
    ).rows[0];
    const args = [
      r.requestId,
      a.user.id,
      proof.session_id,
      proof.review_digest,
      a.account.id,
      decoded.destination,
      "DEMO_A",
      "Demo Bank A",
      "990000000001",
      "Demo recipient A",
      "100000",
      decoded.reference.id,
      decoded.reference.version,
      decoded.reference.revision,
      decoded.reference.evidence_id,
    ];
    await db.query(postSql, args);
    assert.deepEqual(await snapshot(), saved);
    for (const index of [5, 6, 7, 8, 9, 10]) {
      const changed = [...args];
      changed[index] =
        index === 5 ? randomUUID() : index === 10 ? "100001" : "changed";
      await rejected(db.query(postSql, changed), 503);
    }
    for (let index = 0; index < args.length; index++) {
      const changed = [...args];
      changed[index] = null;
      await rejected(db.query(postSql, changed), 503);
    }
    await admin.query(
      "update bank.transaction_confirmations set purpose='preview' where id=$1",
      [r.requestId],
    );
    await rejected(db.query(postSql, args), 503);
    await admin.query(
      "update bank.transaction_confirmations set purpose='local_interbank' where id=$1",
      [r.requestId],
    );
    assert.deepEqual(await snapshot(), saved);
    checks.push(
      "posting function accepts only exact retry details; null arguments and preview purpose fail without writes",
    );

    stage = "fresh login receipt recovery";
    const login = await f.call("/token?grant_type=password", {
      email: a.email,
      password: a.password,
    });
    const freshReq = {
      ...a.req,
      headers: { authorization: `Bearer ${login.access_token}` },
    };
    assert.equal(
      (await service.status(freshReq, r.requestId, "interbank")).state,
      "posted",
    );
    assert.equal(
      (await service.recent(freshReq, "interbank")).transfers.find(
        (attempt) => attempt.requestId === r.requestId,
      )?.state,
      "posted",
    );
    checks.push(
      "new login recovers its existing simulation receipt without repeating authorization",
    );

    // Controlled provider responses isolate races from TOTP timing. The first
    // posting above uses the real Auth factor; these responses reuse its pair.
    const provider = security.provider.bind(security);
    let onVerify = async () => {};
    let nextCode = 610000;
    security.provider = async (path, ...rest) => {
      if (path.endsWith("/challenge")) return { id: randomUUID() };
      if (path.endsWith("/verify")) {
        await onVerify();
        return {
          access_token: success.accessToken,
          refresh_token: success.refreshToken,
        };
      }
      return provider(path, ...rest);
    };
    const confirm = (item, operation = "interbank", instance = service) =>
      instance.confirm(
        a.req,
        { reviewToken: item.reviewToken, code: String(nextCode++) },
        operation,
      );

    stage = "concurrent interbank and ordinary transfer";
    await clearWindow();
    await admin.query(
      "update bank.banking_accounts set balance_minor=50000 where id=$1",
      [a.account.id],
    );
    let first = await review("40000");
    let other = await service.review(
      a.req,
      {
        sourceAccountId: a.account.id,
        destinationAccountNumber: b.account.number,
        amountMinor: "40000",
      },
      true,
    );
    const beforeRace = await snapshot();
    let raced = await Promise.allSettled([
      confirm(first),
      confirm(other, true, second),
    ]);
    assert.equal(
      raced.filter(
        (response) => response.status === "fulfilled" && response.value.sent,
      ).length,
      1,
    );
    let afterRace = await snapshot();
    assert.equal(
      afterRace.accounts.find((row) => row.id === a.account.id).balance,
      "10000",
    );
    assert.equal(
      BigInt(
        afterRace.accounts.find((row) => row.id === b.account.id).balance,
      ) +
        BigInt(afterRace.recipients[0].balance) -
        BigInt(
          beforeRace.accounts.find((row) => row.id === b.account.id).balance,
        ) -
        BigInt(beforeRace.recipients[0].balance),
      40000n,
    );
    await expireAttempts();

    stage = "concurrent interbank and cash withdrawal";
    await admin.query(cashSeedSql(a.account.number));
    f.env.localCashEnabled = true;
    await admin.query(
      "update bank.banking_accounts set balance_minor=50000 where id=$1",
      [a.account.id],
    );
    first = await review("40000");
    other = await service.review(
      a.req,
      { accountId: a.account.id, amountMinor: "40000" },
      "withdrawal",
    );
    const beforeCashRace = await snapshot();
    raced = await Promise.allSettled([
      confirm(first),
      confirm(other, "withdrawal", second),
    ]);
    assert.equal(
      raced.filter(
        (response) => response.status === "fulfilled" && response.value.sent,
      ).length,
      1,
    );
    afterRace = await snapshot();
    assert.equal(
      afterRace.accounts.find((row) => row.id === a.account.id).balance,
      "10000",
    );
    assert.equal(
      BigInt(afterRace.cash[0].balance) +
        BigInt(afterRace.recipients[0].balance) -
        BigInt(beforeCashRace.cash[0].balance) -
        BigInt(beforeCashRace.recipients[0].balance),
      40000n,
    );
    await expireAttempts();
    checks.push(
      "concurrent ordinary transfers and cash withdrawals cannot spend funds already used by an other-bank simulation",
    );

    stage = "history rollback";
    await clearWindow();
    await admin.query(
      "update bank.banking_accounts set balance_minor=300000 where id=$1",
      [a.account.id],
    );
    r = await review("12345");
    saved = await snapshot();
    await admin.query(
      "alter table bank.account_history add constraint interbank_test_failure check(amount_minor<>12345)",
    );
    await rejected(confirm(r), 503);
    assert.deepEqual(await snapshot(), saved);
    assert.notEqual(
      (await service.status(a.req, r.requestId, "interbank")).state,
      "posted",
    );
    await admin.query(
      "alter table bank.account_history drop constraint interbank_test_failure",
    );
    await expireAttempts();
    checks.push(
      "history failure rolls back sender debit, simulated recipient credit, receipt and proof consumption",
    );

    const failDuringVerification = async (
      name,
      hook,
      restore = async () => {},
    ) => {
      stage = name;
      await clearWindow();
      const item = await review("1000");
      const before = await snapshot();
      onVerify = () => hook(item);
      try {
        await rejected(confirm(item), 503);
        assert.notEqual(
          (await service.status(a.req, item.requestId, "interbank")).state,
          "posted",
        );
      } finally {
        onVerify = async () => {};
        await restore();
        await expireAttempts();
      }
      assert.deepEqual(await snapshot(), before);
    };
    await failDuringVerification(
      "recipient changed after review",
      () =>
        admin.query(
          "update bank.demo_external_recipients set recipient_name='Demo changed recipient' where bank_code='DEMO_A'",
        ),
      () =>
        admin.query(
          "update bank.demo_external_recipients set recipient_name='Demo recipient A' where bank_code='DEMO_A'",
        ),
    );
    await failDuringVerification(
      "bank changed after review",
      () =>
        admin.query(
          "update bank.demo_external_banks set name='Demo changed bank' where code='DEMO_A'",
        ),
      () =>
        admin.query(
          "update bank.demo_external_banks set name='Demo Bank A' where code='DEMO_A'",
        ),
    );
    await failDuringVerification(
      "recipient deactivated",
      () =>
        admin.query(
          "update bank.demo_external_recipients set active=false where bank_code='DEMO_A'",
        ),
      () =>
        admin.query(
          "update bank.demo_external_recipients set active=true where bank_code='DEMO_A'",
        ),
    );
    await failDuringVerification(
      "bank deactivated",
      () =>
        admin.query(
          "update bank.demo_external_banks set active=false where code='DEMO_A'",
        ),
      () =>
        admin.query(
          "update bank.demo_external_banks set active=true where code='DEMO_A'",
        ),
    );
    const recipientBalance = (await snapshot()).recipients[0].balance;
    await failDuringVerification(
      "recipient overflow",
      () =>
        admin.query(
          "update bank.demo_external_recipients set balance_minor=9223372036854775807 where bank_code='DEMO_A'",
        ),
      () =>
        admin.query(
          "update bank.demo_external_recipients set balance_minor=$1 where bank_code='DEMO_A'",
          [recipientBalance],
        ),
    );
    await failDuringVerification("reference changed", () =>
      admin.query(
        "update bank.identity_cases set version=version+1 where id=$1",
        [reference],
      ),
    );
    await failDuringVerification(
      "reference expired",
      () =>
        admin.query(
          "update bank.identity_cases set expires_at=now()-interval '1 second' where id=$1",
          [reference],
        ),
      () =>
        admin.query(
          "update bank.identity_cases set expires_at=now()+interval '1 day' where id=$1",
          [reference],
        ),
    );
    await failDuringVerification(
      "profile name changed",
      () =>
        admin.query(
          "update bank.user_profiles set display_name='Changed fixture' where id=$1",
          [a.user.id],
        ),
      () =>
        admin.query(
          "update bank.user_profiles set display_name='Synthetic fixture' where id=$1",
          [a.user.id],
        ),
    );
    await failDuringVerification("factor revision changed", () =>
      admin.query(
        "update bank.authenticator_setup set revision=revision+1 where customer_id=$1",
        [a.user.id],
      ),
    );
    await failDuringVerification("authorization lease expired", (item) =>
      admin.query(
        "update bank.transaction_confirmations set lease_until=now()-interval '1 second' where id=$1",
        [item.requestId],
      ),
    );
    await failDuringVerification("late cancellation", (item) =>
      service.cancel(a.req, { reviewToken: item.reviewToken }, "interbank"),
    );
    await failDuringVerification("unknown provider outcome", async () => {
      throw Error("Synthetic timeout");
    });
    checks.push(
      "catalog changes/deactivation, overflow, reference/profile/security changes, expiry, cancellation and uncertain provider outcomes all prevent posting",
    );

    stage = "database expiry after lock wait";
    // An administrator constructs only this isolated SQL fixture proof, so this
    // case exercises the function's final check independently of API prechecks.
    const lockProofId = randomUUID();
    const latestReference = (
      await admin.query(
        "select id,version,revision,evidence_id from bank.identity_cases where id=$1",
        [reference],
      )
    ).rows[0];
    await admin.query(
      "insert into bank.transaction_confirmations(id,customer_id,session_id,review_digest,factor_id,security_revision,state,expires_at,confirmed_until,lease_until,purpose) select $1,$2,$3,'isolated-sql-fixture',factor_id,revision,'factor_confirmed',now()+interval '10 minutes',now()+interval '2 minutes',now()+interval '2 seconds','local_interbank' from bank.authenticator_setup where customer_id=$2",
      [lockProofId, a.user.id, proof.session_id],
    );
    const lockArgs = [
      lockProofId,
      a.user.id,
      proof.session_id,
      "isolated-sql-fixture",
      a.account.id,
      decoded.destination,
      "DEMO_A",
      "Demo Bank A",
      "990000000001",
      "Demo recipient A",
      "1000",
      latestReference.id,
      latestReference.version,
      latestReference.revision,
      latestReference.evidence_id,
    ];
    const beforeLock = await snapshot();
    const locker = await admin.connect();
    let pending;
    try {
      await locker.query("begin");
      await locker.query(
        "select id from bank.demo_external_recipients where id=$1 for update",
        [decoded.destination],
      );
      // Attach the rejection assertion immediately to avoid an unhandled promise.
      pending = rejected(db.query(postSql, lockArgs), 503);
      let waiting = false;
      for (let attempt = 0; attempt < 50 && !waiting; attempt++) {
        waiting = (
          await locker.query(
            "select exists(select 1 from pg_stat_activity where pid<>pg_backend_pid() and query like 'select bank.post_local_interbank%' and wait_event_type='Lock') waiting",
          )
        ).rows[0].waiting;
        if (!waiting) await new Promise((resolve) => setTimeout(resolve, 10));
      }
      assert.equal(
        waiting,
        true,
        "posting must reach the held recipient lock before expiry",
      );
      await locker.query("select pg_sleep(2.1)");
    } finally {
      await locker.query("rollback");
      locker.release();
      if (pending) await pending;
    }
    assert.deepEqual(await snapshot(), beforeLock);
    assert.equal(
      (
        await admin.query(
          "select state from bank.transaction_confirmations where id=$1",
          [lockProofId],
        )
      ).rows[0].state,
      "factor_confirmed",
    );
    checks.push(
      "authorization expiring during a held recipient lock cannot post after the lock is released",
    );

    stage = "database grants";
    for (const role of ["anon", "authenticated", "service_role", "nene_api"]) {
      for (const table of [
        "local_interbank_settings",
        "demo_external_banks",
        "demo_external_recipients",
        "local_interbank_transfers",
      ])
        assert.equal(
          (
            await admin.query(
              "select has_table_privilege($1,$2,'insert,update,delete') allowed",
              [role, "bank." + table],
            )
          ).rows[0].allowed,
          false,
        );
      assert.equal(
        (
          await admin.query(
            "select has_column_privilege($1,'bank.banking_accounts','balance_minor','update') allowed",
            [role],
          )
        ).rows[0].allowed,
        false,
      );
      assert.equal(
        (
          await admin.query(
            "select has_table_privilege($1,'bank.account_history','insert,update,delete') allowed",
            [role],
          )
        ).rows[0].allowed,
        false,
      );
      if (role !== "nene_api") {
        assert.equal(
          (
            await admin.query(
              "select has_function_privilege($1,$2,'execute') allowed",
              [role, postSignature],
            )
          ).rows[0].allowed,
          false,
        );
        assert.equal(
          (
            await admin.query(
              "select has_table_privilege($1,'bank.demo_external_recipients','select') allowed",
              [role],
            )
          ).rows[0].allowed,
          false,
        );
      }
    }
    await rejected(
      db.query("update bank.demo_external_recipients set balance_minor=0", []),
      503,
    );
    await rejected(
      db.query("update bank.local_interbank_transfers set amount_minor=1", []),
      503,
    );
    checks.push(
      "API cannot directly edit financial balances, receipts, history or gates; client roles cannot read recipients or execute posting",
    );
    console.log(JSON.stringify({ result: "passed", checks }));
  });
  console.log("Owned local-interbank fixture cleaned.");
} catch (error) {
  console.error(
    JSON.stringify({
      result: "failed",
      stage,
      status: error?.getStatus?.(),
      kind: error?.constructor?.name,
      sqlState: error?.code,
    }),
  );
  process.exitCode = 1;
}
