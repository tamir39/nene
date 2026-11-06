// Disposable PostgreSQL/Auth evidence only. No VNPay network request or real bill.
import assert from "node:assert/strict";
import { createHmac, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { withTransfers } from "./lib/transfer-fixture.mjs";
import { generateTotp } from "./lib/totp-fixture.mjs";
import {
  PaymentsService,
  sandboxServices,
} from "../backend/dist/payments/payments.service.js";

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
    stage = "credential-free preview has no financial or security effects";
    const previewService = new PaymentsService(f.db, f.security, f.env);
    const counts = async () =>
      (
        await f.admin.query(`select
      (select count(*)::int from bank.sandbox_payments) payments,
      (select count(*)::int from bank.sandbox_payment_authorizations) attempts,
      (select count(*)::int from bank.security_proof_reservations) proofs,
      (select count(*)::int from bank.account_history) history`)
      ).rows[0];
    const beforePreview = await counts();
    const providerBeforePreview = f.security.provider;
    f.security.provider = async () => {
      throw new Error("Preview must not dispatch to Auth");
    };
    try {
      for (const serviceId of ["movie_matinee_v1", "movie_evening_v1"]) {
        const preview = await previewService.preview(a.req, { serviceId });
        assert.equal(preview.previewOnly, true);
        assert.equal(preview.checkoutAvailable, false);
        assert.equal(preview.fulfillment, "not_available");
        assert.deepEqual(
          preview.service,
          sandboxServices.find((offer) => offer.id === serviceId),
        );
        assert.equal(preview.amountMinor, preview.service.amountMinor);
        assert.equal(preview.reviewToken, undefined);
        assert.equal(preview.requestId, undefined);
        assert.equal(preview.checkoutUrl, undefined);
      }
      await rejected(
        Promise.resolve().then(() =>
          previewService.preview(a.req, {
            serviceId: "movie_matinee_v1",
            quantity: 2,
          }),
        ),
        400,
      );
      await rejected(
        Promise.resolve().then(() =>
          previewService.preview(
            { ...a.req, user: { ...a.req.user, role: "officer" } },
            { serviceId: "movie_matinee_v1" },
          ),
        ),
        403,
      );
    } finally {
      f.security.provider = providerBeforePreview;
    }
    assert.deepEqual(await counts(), beforePreview);
    checks.push(
      "credential-free movie previews return fixed details without orders, authorization records, proof dispatch or financial history",
    );
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

    stage = "legacy payment snapshot backfill";
    // Reconstruct the previous layout inside a rollback-only transaction using
    // disposable rows; the actual migration must preserve all three old offers.
    await f.admin.query("begin");
    try {
      await f.admin.query(
        "alter table bank.sandbox_payments drop column service_snapshot",
      );
      await f.admin
        .query(`alter table bank.sandbox_payments drop constraint sandbox_payments_service_id_check;
        alter table bank.sandbox_payments add constraint sandbox_payments_service_id_check check(service_id in ('electricity','water','phone'));
        alter table bank.sandbox_payments drop constraint sandbox_payment_amount;
        alter table bank.sandbox_payments add constraint sandbox_payment_amount check(
          (service_id='electricity' and amount_minor=200000) or (service_id='water' and amount_minor=100000) or (service_id='phone' and amount_minor=50000));`);
      for (const [serviceId, amount] of [
        ["water", "100000"],
        ["phone", "50000"],
      ]) {
        const id = randomUUID();
        await f.admin.query(
          `insert into bank.sandbox_payment_authorizations(id,customer_id,session_id,review_digest,factor_id,security_revision,state,expires_at,lease_until)
          select $1,customer_id,session_id,review_digest,factor_id,security_revision,state,expires_at,lease_until from bank.sandbox_payment_authorizations where id=$2`,
          [id, review.requestId],
        );
        await f.admin.query(
          `insert into bank.sandbox_payments(id,customer_id,service_id,amount_minor,currency,provider_reference,terminal_code,order_info,ip_address,state,created_at,expires_at,paid_at)
          select $1,customer_id,$3,$4,currency,$5,terminal_code,$6,ip_address,state,created_at,expires_at,paid_at from bank.sandbox_payments where id=$2`,
          [
            id,
            review.requestId,
            serviceId,
            amount,
            "L" + id.replaceAll("-", ""),
            "Nene sandbox " + serviceId,
          ],
        );
      }
      await f.admin.query(
        readFileSync(
          new URL(
            "../infrastructure/supabase/migrations/20261107000200_movie_ticket_demo.sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      const legacy = (
        await f.admin.query(
          "select service_id,service_snapshot from bank.sandbox_payments order by service_id",
        )
      ).rows;
      assert.deepEqual(
        legacy.map((row) => row.service_id),
        ["electricity", "phone", "water"],
      );
      for (const row of legacy) {
        assert.deepEqual(
          row.service_snapshot,
          sandboxServices.find((offer) => offer.id === row.service_id),
        );
      }
    } finally {
      await f.admin.query("rollback");
    }
    checks.push(
      "forward migration preserves exact existing electricity/water/phone details without affecting historical payment state",
    );

    stage = "movie purchase authorization and independent pending offers";
    // The first checkout above uses real Supabase verification. Controlled
    // provider responses now isolate database behavior from TOTP clock windows.
    const provider = f.security.provider.bind(f.security);
    let verifies = 0;
    f.security.provider = async (path, ...args) => {
      if (path.endsWith("/challenge")) return { id: randomUUID() };
      if (path.endsWith("/verify")) {
        verifies++;
        return {
          access_token: result.accessToken,
          refresh_token: result.refreshToken,
        };
      }
      return provider(path, ...args);
    };
    let nextCode = 730001;
    const freshCode = () => {
      while ([a.setupCode, code].includes(String(nextCode))) nextCode++;
      return String(nextCode++);
    };
    const movieInput = { serviceId: "movie_matinee_v1" };
    const movieReview = await service.review(a.req, movieInput);
    const movieCode = freshCode();
    const movie = await service.confirm(a.req, {
      reviewToken: movieReview.reviewToken,
      code: movieCode,
    });
    const savedMovie = JSON.parse(JSON.stringify(movie.order.service));
    assert.equal(movie.state, "awaiting_payment");
    assert.equal(movie.order.service.id, "movie_matinee_v1");
    assert.equal(movie.order.amountMinor, "90000");
    assert.equal(movie.order.fulfillment, "not_available");
    assert.deepEqual(
      (
        await f.admin.query(
          "select service_snapshot from bank.sandbox_payments where id=$1",
          [movieReview.requestId],
        )
      ).rows[0].service_snapshot,
      savedMovie,
    );
    await rejected(service.review(a.req, movieInput), 409);
    await rejected(service.status(b.req, movieReview.requestId), 404);
    const eveningReviews = await Promise.all([
      service.review(a.req, { serviceId: "movie_evening_v1" }),
      second.review(a.req, { serviceId: "movie_evening_v1" }),
    ]);
    const eveningResults = await Promise.allSettled(
      eveningReviews.map((item, index) =>
        (index === 0 ? service : second).confirm(a.req, {
          reviewToken: item.reviewToken,
          code: freshCode(),
        }),
      ),
    );
    assert.equal(
      eveningResults.filter((answer) => answer.status === "fulfilled").length,
      1,
    );
    assert.equal(
      eveningResults.filter((answer) => answer.status === "rejected").length,
      1,
    );
    assert.equal(
      eveningResults
        .find((answer) => answer.status === "rejected")
        .reason.getStatus(),
      409,
    );
    const evening = eveningResults.find(
      (answer) => answer.status === "fulfilled",
    ).value;
    assert.equal(evening.order.amountMinor, "120000");
    await rejected(
      service.review(a.req, { serviceId: "movie_evening_v1" }),
      409,
    );
    checks.push(
      "each fictional movie offer is bound to its price and owner; concurrent distinct reviews issue one pending checkout per offer while the other offer remains independent",
    );

    stage = "immutable movie snapshot and database validation";
    const currentOffer = sandboxServices.find(
      (offer) => offer.id === "movie_matinee_v1",
    );
    const currentName = currentOffer.name;
    currentOffer.name = "Different future catalogue title";
    try {
      assert.deepEqual(
        (await service.status(fresh, movieReview.requestId)).order.service,
        savedMovie,
      );
      assert.deepEqual(
        (await service.recent(fresh)).orders.find(
          (order) => order.id === movieReview.requestId,
        ).service,
        savedMovie,
      );
    } finally {
      currentOffer.name = currentName;
    }
    for (const invalid of [
      null,
      [],
      {},
      { ...savedMovie, name: null },
      { ...savedMovie, amountMinor: 90000 },
      { ...savedMovie, currency: "USD" },
      { ...savedMovie, id: "movie_evening_v1" },
      { ...savedMovie, amountMinor: "1" },
      { ...savedMovie, quantity: 2 },
    ]) {
      await assert.rejects(
        f.admin.query(
          "update bank.sandbox_payments set service_snapshot=$2::jsonb where id=$1",
          [movieReview.requestId, JSON.stringify(invalid)],
        ),
      );
    }
    await assert.rejects(
      f.db.query(
        "update bank.sandbox_payments set service_snapshot=$2::jsonb where id=$1",
        [movieReview.requestId, JSON.stringify(savedMovie)],
      ),
    );
    checks.push(
      "historical receipts retain stored snapshots after catalogue changes; malformed/mismatched snapshots and API snapshot writes are rejected",
    );

    stage = "movie callbacks and fresh authorization for repeat purchase";
    const movieReference = new URL(movie.checkoutUrl).searchParams.get(
      "vnp_TxnRef",
    );
    const movieOrderInfo = new URL(movie.checkoutUrl).searchParams.get(
      "vnp_OrderInfo",
    );
    assert.equal(movieOrderInfo, "Nene sandbox movie-matinee-v1");
    const movieNotice = (overrides = {}) =>
      notification(movieReference, {
        vnp_Amount: "9000000",
        vnp_OrderInfo: movieOrderInfo,
        ...overrides,
      });
    assert.equal(
      (await service.ipn(movieNotice({ vnp_Amount: "12000000" }))).RspCode,
      "04",
    );
    const movieCallbacks = await Promise.all([
      service.ipn(movieNotice()),
      second.ipn(movieNotice()),
    ]);
    assert.deepEqual(movieCallbacks.map((answer) => answer.RspCode).sort(), [
      "00",
      "02",
    ]);
    assert.equal(
      (await service.status(fresh, movieReview.requestId)).state,
      "paid",
    );
    assert.equal(
      (await service.status(fresh, movieReview.requestId)).order.fulfillment,
      "not_available",
    );
    const verifyCountBeforeReplay = verifies;
    const movieReplay = await service.confirm(a.req, {
      reviewToken: movieReview.reviewToken,
      code: movieCode,
    });
    assert.equal(movieReplay.replay, true);
    assert.equal(movieReplay.accessToken, undefined);
    assert.equal(verifies, verifyCountBeforeReplay);
    const duplicateCodeReview = await service.review(a.req, movieInput);
    await rejected(
      service.confirm(a.req, {
        reviewToken: duplicateCodeReview.reviewToken,
        code: movieCode,
      }),
      400,
    );
    assert.equal(verifies, verifyCountBeforeReplay);
    const nextMovieReview = await service.review(a.req, movieInput);
    const nextMovie = await service.confirm(a.req, {
      reviewToken: nextMovieReview.reviewToken,
      code: freshCode(),
    });
    assert.notEqual(nextMovie.order.id, movie.order.id);
    assert.equal(nextMovie.state, "awaiting_payment");
    const nextReference = new URL(nextMovie.checkoutUrl).searchParams.get(
      "vnp_TxnRef",
    );
    assert.equal(
      (
        await service.ipn(
          notification(nextReference, {
            vnp_Amount: "9000000",
            vnp_OrderInfo: new URL(nextMovie.checkoutUrl).searchParams.get(
              "vnp_OrderInfo",
            ),
            vnp_ResponseCode: "24",
            vnp_TransactionStatus: "02",
          }),
        )
      ).RspCode,
      "00",
    );
    assert.equal(
      (await service.status(fresh, nextMovieReview.requestId)).state,
      "failed",
    );
    assert.equal(
      (await service.review(a.req, movieInput)).service.id,
      "movie_matinee_v1",
    );
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
      "signed movie callbacks settle only sandbox status; paid/failed movie allows a new purchase only with a new review/fresh proof; no real admission or bank effects",
    );

    stage = "database privileges";
    const privileges = (
      await f.admin.query(`select
      has_table_privilege('anon','bank.sandbox_payments','SELECT') anon_read,
      has_table_privilege('authenticated','bank.sandbox_payments','INSERT') client_insert,
      has_column_privilege('nene_api','bank.sandbox_payments','amount_minor','UPDATE') amount_update,
      has_column_privilege('nene_api','bank.sandbox_payments','service_snapshot','UPDATE') snapshot_update,
      has_column_privilege('nene_api','bank.banking_accounts','balance_minor','UPDATE') balance_update`)
    ).rows[0];
    assert.deepEqual(Object.values(privileges), [
      false,
      false,
      false,
      false,
      false,
    ]);
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
