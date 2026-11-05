// Disposable PostgreSQL/Auth evidence only. No VNPay network request or real bill.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { withTransfers } from "./lib/transfer-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import { PaymentsService } from "../backend/dist/payments/payments.service.js";

const config = {
  terminalCode: "TEST1234",
  hashSecret: "synthetic-payment-fixture-secret",
  returnUrl: "https://nene.example.com/api/v1/payments/vnpay/return",
};
const rejected = (promise, status) =>
  assert.rejects(promise, (e) => e.getStatus() === status);
const encode = (value) => encodeURIComponent(value).replace(/%20/g, "+");
function notification(reference, overrides = {}) {
  const values = {
    vnp_Amount: "20000000",
    vnp_BankCode: "NCB",
    vnp_OrderInfo: "Nene sandbox electricity",
    vnp_PayDate: "20261106140000",
    vnp_ResponseCode: "00",
    vnp_TmnCode: config.terminalCode,
    vnp_TransactionNo: "1357911",
    vnp_TransactionStatus: "00",
    vnp_TxnRef: reference,
    ...overrides,
  };
  const text = Object.keys(values)
    .sort()
    .map((key) => `${key}=${encode(values[key])}`)
    .join("&");
  return `${text}&vnp_SecureHash=${createHmac("sha512", config.hashSecret).update(text).digest("hex")}`;
}
let stage = "disposable fixture";
const checks = [];
try {
  await withTransfers(async (f) => {
    const env = { ...f.env, vnpaySandbox: config };
    const service = new PaymentsService(f.db, f.security, env);
    const a = await f.customer();
    const b = await f.customer();
    const input = { serviceId: "electricity" };
    stage = "configuration and authorization boundaries";
    assert.equal(
      new PaymentsService(f.db, f.security, f.env).configuration(a.req).enabled,
      false,
    );
    await rejected(
      new PaymentsService(f.db, f.security, f.env).review(a.req, input),
      409,
    );
    await rejected(service.review(a.req, input), 400);
    await f.reference(a);
    await rejected(service.review(a.req, { ...input, amountMinor: "1" }), 400);
    await rejected(
      service.review(
        { ...a.req, user: { ...a.req.user, role: "officer" } },
        input,
      ),
      403,
    );
    const review = await service.review(a.req, input);
    await rejected(
      service.confirm(b.req, {
        reviewToken: review.reviewToken,
        code: "123456",
      }),
      403,
    );
    const changed =
      review.reviewToken.slice(0, -1) +
      (review.reviewToken.endsWith("a") ? "b" : "a");
    await rejected(
      service.confirm(a.req, { reviewToken: changed, code: "123456" }),
      400,
    );
    assert.equal(
      (await f.admin.query("select count(*)::int n from bank.sandbox_payments"))
        .rows[0].n,
      0,
    );
    checks.push(
      "disabled configuration, missing reference, role, changed payload and ownership rejected before checkout",
    );

    stage = "real Auth confirmation and concurrent duplicate";
    let code = generateTotp(a.setup.secret, {
      timestampSeconds: Math.floor(Date.now() / 1000) - 30,
    });
    if (code === a.setupCode)
      code = generateTotp(a.setup.secret, {
        timestampSeconds: Math.floor(Date.now() / 1000) + 30,
      });
    const before = (
      await f.admin.query(
        "select id,balance_minor::text from bank.banking_accounts order by id",
      )
    ).rows;
    const second = new PaymentsService(f.db, f.security, env);
    const answers = await Promise.all([
      service.confirm(a.req, { reviewToken: review.reviewToken, code }),
      second.confirm(a.req, { reviewToken: review.reviewToken, code }),
    ]);
    const result = answers.find((answer) => answer.replay === false);
    assert.ok(result?.accessToken && result?.refreshToken);
    assert.equal(result.purpose, "vnpay-checkout");
    assert.equal(result.state, "awaiting_payment");
    assert.equal(result.order.fulfillment, "not_available");
    assert.equal(answers.filter((answer) => answer.replay === true).length, 1);
    assert.equal(
      (await f.admin.query("select count(*)::int n from bank.sandbox_payments"))
        .rows[0].n,
      1,
    );
    a.req.headers.authorization = `Bearer ${result.accessToken}`;
    const duplicate = await service.confirm(a.req, {
      reviewToken: review.reviewToken,
      code,
    });
    assert.equal(duplicate.replay, true);
    assert.equal(duplicate.accessToken, undefined);
    await rejected(service.review(a.req, input), 409);
    await rejected(service.status(b.req, review.requestId), 404);
    const checkout = new URL(result.checkoutUrl);
    assert.equal(checkout.origin, "https://sandbox.vnpayment.vn");
    const reference = checkout.searchParams.get("vnp_TxnRef");
    checks.push(
      "real TOTP issues one checkout across two instances; duplicates do not replay tokens; pending bill cannot be charged twice",
    );

    stage = "fresh session status and callback checks";
    const pair = await f.call("/token?grant_type=password", {
      email: a.email,
      password: a.password,
    });
    const fresh = {
      ...a.req,
      headers: { authorization: `Bearer ${pair.access_token}` },
    };
    assert.equal(
      (await service.status(fresh, review.requestId)).checkoutUrl,
      result.checkoutUrl,
    );
    assert.equal((await service.recent(fresh)).orders.length, 1);
    assert.equal((await service.ipn("vnp_TxnRef=forged")).RspCode, "97");
    assert.equal(
      (await service.ipn(notification(reference, { vnp_Amount: "100" })))
        .RspCode,
      "04",
    );
    assert.equal(
      (await service.ipn(notification(reference, { vnp_TxnRef: "Unknown123" })))
        .RspCode,
      "01",
    );
    assert.equal(
      (
        await service.ipn(
          notification(reference, { vnp_TransactionStatus: "09" }),
        )
      ).RspCode,
      "99",
    );
    assert.equal(
      (await service.status(fresh, review.requestId)).state,
      "awaiting_payment",
    );
    const callbacks = await Promise.all([
      service.ipn(notification(reference)),
      second.ipn(notification(reference)),
    ]);
    assert.deepEqual(callbacks.map((r) => r.RspCode).sort(), ["00", "02"]);
    const paid = await service.status(fresh, review.requestId);
    assert.equal(paid.state, "paid");
    assert.equal(paid.order.fulfillment, "not_available");
    assert.equal(paid.checkoutUrl, undefined);
    await rejected(service.review(fresh, input), 409);
    assert.deepEqual(
      (
        await f.admin.query(
          "select id,balance_minor::text from bank.banking_accounts order by id",
        )
      ).rows,
      before,
    );
    assert.equal(
      (await f.admin.query("select count(*)::int n from bank.account_history"))
        .rows[0].n,
      0,
    );
    checks.push(
      "fresh sign-in recovers status; forged/wrong amount/unknown/refund callbacks rejected; concurrent IPN records once; zero bank effects",
    );

    stage = "database privileges";
    const privileges = (
      await f.admin.query(`select
      has_table_privilege('anon','bank.sandbox_payments','SELECT') anon_read,
      has_table_privilege('authenticated','bank.sandbox_payments','INSERT') client_insert,
      has_column_privilege('nene_api','bank.sandbox_payments','amount_minor','UPDATE') amount_update,
      has_column_privilege('nene_api','bank.banking_accounts','balance_minor','UPDATE') balance_update`)
    ).rows[0];
    assert.deepEqual(Object.values(privileges), [false, false, false, false]);
    checks.push(
      "client-facing roles cannot read/write payment records; API cannot rewrite order amount or account balance",
    );
  });
  console.log(JSON.stringify({ status: "passed", checks }, null, 2));
} catch {
  // Do not print tokens, raw database errors or signed checkout URLs.
  console.error(
    `Sandbox-payment check failed at ${stage}. No VNPay request was made; inspect the isolated fixture prerequisites.`,
  );
  process.exitCode = 1;
}
