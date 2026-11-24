import 'reflect-metadata';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { BadRequestException } from '@nestjs/common';
import type { PoolClient } from 'pg';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
import type { Environment } from '../src/config/environment.js';
import type { DatabaseService } from '../src/database/database.service.js';
import { SecurityService } from '../src/security/security.service.js';
import {
  paymentInput,
  PaymentsService,
  sandboxServices,
} from '../src/payments/payments.service.js';
import { VnpayCallbacksController } from '../src/payments/payments.controller.js';

const customer = '10000000-0000-4000-8000-000000000001';
const factor = '20000000-0000-4000-8000-000000000002';
const session = '30000000-0000-4000-8000-000000000003';
const challenge = '40000000-0000-4000-8000-000000000004';
const config = {
  terminalCode: 'TEST1234',
  hashSecret: 'synthetic-unit-test-signing-secret',
  returnUrl: 'https://example.test/api/v1/payments/vnpay/return',
};
const jwt = (id = customer, sid = session) =>
  `x.${Buffer.from(JSON.stringify({ sub: id, session_id: sid, aal: 'aal2' })).toString('base64url')}.x`;
const request = (id = customer, sid = session) =>
  ({
    user: { id, role: 'customer' },
    headers: { authorization: `Bearer ${jwt(id, sid)}` },
    socket: { remoteAddress: '127.0.0.1' },
  }) as unknown as AuthenticatedRequest;
const rejectStatus = (promise: Promise<unknown>, status: number) =>
  assert.rejects(
    promise,
    (e) => (e as { getStatus(): number }).getStatus() === status,
  );
type Data = Record<string, unknown>;

// In-memory SQL stand-in exercises service sequencing and response handling.
// It does not replace the separate PostgreSQL/Auth permission/concurrency check.
function fixture() {
  let attempt: Data | undefined, payment: Data | undefined;
  let ready = true,
    eligible = true,
    reference = true,
    verifyCalls = 0,
    providerCalls = 0;
  let afterVerify: (() => void) | undefined;
  const fingerprints = new Set<string>(),
    writes: string[] = [],
    queries: string[] = [];
  const execute = (sql: string, values: unknown[] = []): Data[] => {
    queries.push(sql);
    if (/update|insert|delete/.test(sql)) writes.push(sql);
    if (sql.startsWith('select secret'))
      return [{ secret: 'synthetic-review-secret' }];
    if (sql.startsWith('select factor_id'))
      return [
        {
          factor_id: factor,
          revision: 2,
          state: ready ? 'ready' : 'restricted',
        },
      ];
    if (sql.startsWith('select id from bank.user_profiles'))
      return eligible ? [{ id: customer }] : [];
    if (sql.startsWith('select i.id'))
      return reference
        ? [{ id: challenge, version: 1, revision: 1, evidence_id: factor }]
        : [];
    if (sql.startsWith('select id from bank.sandbox_payments'))
      return payment &&
        payment.customer_id === values[0] &&
        payment.service_id === values[1] &&
        (payment.state === 'awaiting_payment' ||
          (payment.state === 'paid' &&
            ['electricity', 'water'].includes(String(payment.service_id))))
        ? [{ id: payment.id }]
        : [];
    if (sql.startsWith('select (extract'))
      return [{ expires: Date.now() + 600000 }];
    if (
      sql.startsWith('select pg_advisory') ||
      sql.startsWith('delete from bank.security_proof')
    )
      return [];
    if (sql.startsWith('select count(*)')) return [{ n: fingerprints.size }];
    if (sql.startsWith('insert into bank.security_proof_reservations')) {
      const fingerprint = String(values[2]);
      if (fingerprints.has(fingerprint)) return [];
      fingerprints.add(fingerprint);
      return [{ customer_id: customer }];
    }
    if (
      sql.startsWith(
        'select id from bank.sandbox_payment_authorizations where customer_id',
      )
    )
      return attempt?.state === 'checking' ? [{ id: attempt.id }] : [];
    if (sql.startsWith('select * from bank.sandbox_payment_authorizations'))
      return attempt &&
        attempt.id === values[0] &&
        (values.length < 2 || attempt.customer_id === values[1])
        ? [{ ...attempt }]
        : [];
    if (sql.startsWith('insert into bank.sandbox_payment_authorizations')) {
      if (Number(values[6]) <= Date.now()) return [];
      attempt = {
        id: values[0],
        customer_id: values[1],
        session_id: values[2],
        review_digest: values[3],
        factor_id: values[4],
        security_revision: values[5],
        state: 'checking',
        expires_at: new Date(Number(values[6])),
        lease_until: new Date(Date.now() + 45000),
      };
      return [{ id: attempt.id }];
    }
    if (sql.startsWith('update bank.sandbox_payment_authorizations')) {
      if (attempt)
        attempt.state = sql.includes("state='issued'")
          ? 'issued'
          : sql.includes("state='rejected'")
            ? 'rejected'
            : values[1];
      return [];
    }
    if (sql.startsWith('select id from bank.sandbox_payment_authorizations')) {
      return attempt &&
        attempt.id === values[0] &&
        attempt.customer_id === values[1] &&
        attempt.state ===
          (sql.includes("state='issued'") ? 'issued' : 'checking')
        ? [{ id: attempt.id }]
        : [];
    }
    if (sql.startsWith('insert into bank.sandbox_payments')) {
      payment = {
        id: values[0],
        customer_id: values[1],
        service_id: values[2],
        amount_minor: values[3],
        currency: 'VND',
        provider_reference: values[4],
        terminal_code: values[5],
        order_info: values[6],
        ip_address: values[7],
        service_snapshot: JSON.parse(String(values[9])) as unknown,
        state: 'awaiting_payment',
        created_at: new Date(),
        expires_at: new Date(Date.now() + 900000),
        paid_at: null,
      };
      return [{ ...payment }];
    }
    if (
      sql.startsWith('select *,amount_minor::text from bank.sandbox_payments')
    ) {
      if (!payment) return [];
      if (sql.includes('provider_reference=$1'))
        return payment.provider_reference === values[0] ? [{ ...payment }] : [];
      if (sql.includes('id=$1 and customer_id=$2'))
        return payment.id === values[0] && payment.customer_id === values[1]
          ? [{ ...payment }]
          : [];
      return payment.customer_id === values[0] ? [{ ...payment }] : [];
    }
    if (sql.startsWith('update bank.sandbox_payments')) {
      if (payment) {
        payment.state = values[1];
        payment.paid_at = values[1] === 'paid' ? new Date() : null;
      }
      return [];
    }
    throw new Error('Unhandled fixture SQL: ' + sql);
  };
  const db = {
    query: async (sql: string, values: unknown[]) => execute(sql, values),
    transaction: async <T>(work: (client: PoolClient) => Promise<T>) =>
      work({
        query: async (sql: string, values: unknown[]) => ({
          rows: execute(sql, values),
        }),
      } as unknown as PoolClient),
  } as unknown as DatabaseService;
  const env = { nodeEnv: 'test', vnpaySandbox: config } as Environment;
  class TestSecurity extends SecurityService {
    override async provider(
      path: string,
      _token: string,
      body?: object,
    ): Promise<Record<string, unknown>> {
      providerCalls++;
      if (path === '/user')
        return {
          id: customer,
          factors: [{ id: factor, status: 'verified', factor_type: 'totp' }],
        };
      if (path.endsWith('/challenge')) return { id: challenge };
      if (path.endsWith('/verify')) {
        verifyCalls++;
        if ((body as { code: string }).code === '000000')
          throw new BadRequestException();
        afterVerify?.();
        return {
          access_token: jwt(),
          refresh_token: 'synthetic-rotated-refresh',
        };
      }
      throw new Error('Unhandled provider path');
    }
  }
  const security = new TestSecurity(db, env),
    service = new PaymentsService(db, security, env);
  return {
    service,
    db,
    security,
    env,
    get attempt() {
      return attempt;
    },
    get payment() {
      return payment;
    },
    get verifyCalls() {
      return verifyCalls;
    },
    get providerCalls() {
      return providerCalls;
    },
    writes,
    queries,
    restrict: () => {
      ready = false;
    },
    denyProfile: () => {
      eligible = false;
    },
    denyReference: () => {
      reference = false;
    },
    afterVerify: (action: () => void) => {
      afterVerify = action;
    },
  };
}

function ipn(payment: Data, changes: Record<string, string> = {}) {
  const fields: Record<string, string> = {
    vnp_Amount: (BigInt(String(payment.amount_minor)) * 100n).toString(),
    vnp_BankCode: 'NCB',
    vnp_OrderInfo: String(payment.order_info),
    vnp_PayDate: '20261106120000',
    vnp_ResponseCode: '00',
    vnp_TmnCode: config.terminalCode,
    vnp_TransactionNo: '123456',
    vnp_TransactionStatus: '00',
    vnp_TxnRef: String(payment.provider_reference),
    ...changes,
  };
  const encoded = Object.keys(fields)
    .sort()
    .map(
      (key) =>
        `${encodeURIComponent(key)}=${encodeURIComponent(fields[key]!).replace(/%20/g, '+')}`,
    )
    .join('&');
  return (
    encoded +
    '&vnp_SecureHash=' +
    createHmac('sha512', config.hashSecret).update(encoded).digest('hex')
  );
}
async function authorized(
  f = fixture(),
  serviceId = 'electricity',
  code = '123456',
) {
  const review = await f.service.review(request(), {
    serviceId,
  });
  const result = await f.service.confirm(request(), {
    reviewToken: review.reviewToken,
    code,
  });
  return { f, review, result };
}

void test('fixed synthetic services reject amounts, user references and unsupported purposes', () => {
  assert.deepEqual(
    sandboxServices.map((x) => [x.id, x.amountMinor]),
    [
      ['electricity', '200000'],
      ['water', '100000'],
      ['phone', '50000'],
      ['movie_matinee_v1', '90000'],
      ['movie_evening_v1', '120000'],
    ],
  );
  assert.equal(paymentInput({ serviceId: 'phone' }).amountMinor, '50000');
  for (const body of [
    { serviceId: 'transfer' },
    { serviceId: 'water', amountMinor: '1' },
    { serviceId: 'phone', phone: '0900123456' },
    { serviceId: 'electricity', customerId: customer },
  ])
    assert.throws(() => paymentInput(body));
});
void test('disabled/production checkout and officers fail closed before financial work', async () => {
  const f = fixture();
  const disabled = new PaymentsService(f.db, f.security, {
    nodeEnv: 'test',
  } as Environment);
  assert.equal(disabled.configuration(request()).enabled, false);
  await rejectStatus(disabled.review(request(), { serviceId: 'water' }), 409);
  const production = new PaymentsService(f.db, f.security, {
    ...f.env,
    nodeEnv: 'production',
  });
  await rejectStatus(production.review(request(), { serviceId: 'water' }), 409);
  const officer = {
    ...request(),
    user: { ...request().user, role: 'officer' },
  } as AuthenticatedRequest;
  await rejectStatus(f.service.review(officer, { serviceId: 'water' }), 403);
  await rejectStatus(f.service.status(officer, customer), 403);
  await rejectStatus(f.service.recent(officer), 403);
  assert.deepEqual(f.writes, []);
});
void test('review requires accepted reference, synthetic profile and ready authenticator', async () => {
  for (const [change, status] of [
    ['denyProfile', 403],
    ['denyReference', 400],
    ['restrict', 409],
  ] as const) {
    const f = fixture();
    f[change]();
    await rejectStatus(
      f.service.review(request(), { serviceId: 'water' }),
      status,
    );
    assert.equal(f.payment, undefined);
  }
});
void test('signed review rejects mutation, changed customer/session, extras and recovery codes', async () => {
  const f = fixture(),
    review = await f.service.review(request(), { serviceId: 'phone' });
  assert.equal(f.payment, undefined);
  const parts = review.reviewToken.split('.');
  const data = JSON.parse(
    Buffer.from(parts[0]!, 'base64url').toString(),
  ) as Data;
  data.amountMinor = '1';
  const changed =
    Buffer.from(JSON.stringify(data)).toString('base64url') + '.' + parts[1];
  await rejectStatus(
    f.service.confirm(request(), { reviewToken: changed, code: '123456' }),
    400,
  );
  await rejectStatus(
    f.service.confirm(request(challenge), {
      reviewToken: review.reviewToken,
      code: '123456',
    }),
    403,
  );
  await rejectStatus(
    f.service.confirm(request(customer, challenge), {
      reviewToken: review.reviewToken,
      code: '123456',
    }),
    403,
  );
  await rejectStatus(
    f.service.confirm(request(), {
      reviewToken: review.reviewToken,
      code: 'RECOVERY',
    }),
    400,
  );
  await rejectStatus(
    f.service.confirm(request(), {
      reviewToken: review.reviewToken,
      code: '123456',
      challengeId: challenge,
    }),
    400,
  );
  assert.equal(f.verifyCalls, 0);
});
void test('authorization rotates session once and creates exactly one external checkout without banking writes', async () => {
  const { f, review, result } = await authorized();
  assert.equal(result.replay, false);
  assert.equal(result.state, 'awaiting_payment');
  assert.equal(result.order?.fulfillment, 'not_available');
  assert.equal('purpose' in result && result.purpose, 'vnpay-checkout');
  assert.equal('accessToken' in result && result.accessToken, jwt());
  assert.ok(
    'checkoutUrl' in result &&
      result.checkoutUrl?.startsWith(
        'https://sandbox.vnpayment.vn/paymentv2/vpcpay.html?',
      ),
  );
  const replay = await f.service.confirm(request(), {
    reviewToken: review.reviewToken,
    code: '234567',
  });
  assert.equal(replay.replay, true);
  assert.equal('accessToken' in replay, false);
  assert.equal(f.verifyCalls, 1);
  assert.equal(
    f.writes.filter((s) => s.startsWith('insert into bank.sandbox_payments'))
      .length,
    1,
  );
  assert.ok(
    f.writes.every(
      (s) => !s.includes('banking_accounts') && !s.includes('account_history'),
    ),
  );
  await rejectStatus(
    f.service.status(request(challenge), review.requestId),
    404,
  );
  assert.equal(
    (await f.service.status(request(customer, challenge), review.requestId))
      .order?.id,
    review.requestId,
  );
});
void test('status recovers an order committed between its two database reads', async () => {
  const { f, review } = await authorized();
  let committed = false;
  const db = {
    query(sql: string) {
      const rows = sql.includes('from bank.sandbox_payment_authorizations')
        ? [{ ...f.attempt, state: committed ? 'issued' : 'checking' }]
        : committed
          ? [f.payment]
          : [];
      committed = true; // Concurrent confirmation commits after this snapshot.
      return Promise.resolve(rows);
    },
  } as unknown as DatabaseService;
  const status = await new PaymentsService(db, f.security, f.env).status(
    request(),
    review.requestId,
  );
  assert.equal(status.state, 'awaiting_payment');
  assert.equal(status.order?.id, review.requestId);
  assert.ok('checkoutUrl' in status && status.checkoutUrl);
});
void test('rejected proof cannot be retried under same review and reused code cannot authorize another payment', async () => {
  const f = fixture(),
    review = await f.service.review(request(), { serviceId: 'water' });
  await rejectStatus(
    f.service.confirm(request(), {
      reviewToken: review.reviewToken,
      code: '000000',
    }),
    400,
  );
  const rejected = await f.service.status(request(), review.requestId);
  assert.equal(rejected.state, 'rejected');
  assert.equal(rejected.order, null);
  const retry = await f.service.confirm(request(), {
    reviewToken: review.reviewToken,
    code: '123456',
  });
  assert.equal(retry.replay, true);
  assert.equal(f.verifyCalls, 1);
  const next = await f.service.review(request(), { serviceId: 'phone' });
  await rejectStatus(
    f.service.confirm(request(), {
      reviewToken: next.reviewToken,
      code: '000000',
    }),
    400,
  );
  assert.equal(f.verifyCalls, 1);
  assert.equal(f.payment, undefined);
});
void test('post-verification security/reference changes produce uncertain response and no checkout', async () => {
  for (const change of ['restrict', 'denyReference'] as const) {
    const f = fixture(),
      review = await f.service.review(request(), { serviceId: 'water' });
    f.afterVerify(f[change]);
    await rejectStatus(
      f.service.confirm(request(), {
        reviewToken: review.reviewToken,
        code: '123456',
      }),
      503,
    );
    assert.equal(f.verifyCalls, 1);
    assert.equal(f.payment, undefined);
  }
});
void test('pending same-service orders block duplicates and fixed bills stay paid; phone may repeat after settlement', async () => {
  const { f } = await authorized();
  await rejectStatus(
    f.service.review(request(), { serviceId: 'electricity' }),
    409,
  );
  assert.equal((await f.service.ipn(ipn(f.payment!))).RspCode, '00');
  await rejectStatus(
    f.service.review(request(), { serviceId: 'electricity' }),
    409,
  );
  const phone = fixture(),
    review = await phone.service.review(request(), { serviceId: 'phone' });
  await phone.service.confirm(request(), {
    reviewToken: review.reviewToken,
    code: '123456',
  });
  await rejectStatus(
    phone.service.review(request(), { serviceId: 'phone' }),
    409,
  );
  assert.equal((await phone.service.ipn(ipn(phone.payment!))).RspCode, '00');
  assert.equal(
    (await phone.service.review(request(), { serviceId: 'phone' })).service.id,
    'phone',
  );
});
void test('IPN validates signature/order/amount and records one authoritative result even after local expiry', async () => {
  const { f, review } = await authorized();
  const row = f.payment!;
  row.expires_at = new Date(Date.now() - 1000);
  const status = await f.service.status(request(), review.requestId);
  assert.ok(status.order);
  assert.equal(status.checkoutUrl, undefined);
  assert.equal((await f.service.ipn(ipn(row) + '&vnp_Amount=1')).RspCode, '97');
  assert.equal(
    (await f.service.ipn(ipn(row, { vnp_TxnRef: 'NOORDER' }))).RspCode,
    '01',
  );
  assert.equal(
    (await f.service.ipn(ipn(row, { vnp_Amount: '10000' }))).RspCode,
    '04',
  );
  assert.equal(row.state, 'awaiting_payment');
  assert.equal((await f.service.ipn(ipn(row))).RspCode, '00');
  assert.equal(row.state, 'paid');
  assert.equal((await f.service.ipn(ipn(row))).RspCode, '02');
  assert.equal(
    (
      await f.service.ipn(
        ipn(row, { vnp_ResponseCode: '24', vnp_TransactionStatus: '02' }),
      )
    ).RspCode,
    '02',
  );
  assert.equal(row.state, 'paid');
  assert.equal(
    f.writes.filter((s) => s.startsWith('update bank.sandbox_payments')).length,
    1,
  );
});
void test('IPN pending does not become failure; cancellation/failure is terminal and unsupported result stays uncertain', async () => {
  const { f } = await authorized(),
    row = f.payment!;
  assert.equal(
    (
      await f.service.ipn(
        ipn(row, { vnp_ResponseCode: '99', vnp_TransactionStatus: '01' }),
      )
    ).RspCode,
    '00',
  );
  assert.equal(row.state, 'awaiting_payment');
  assert.equal(
    (
      await f.service.ipn(
        ipn(row, { vnp_ResponseCode: '99', vnp_TransactionStatus: '07' }),
      )
    ).RspCode,
    '99',
  );
  assert.equal(row.state, 'awaiting_payment');
  assert.equal(
    (
      await f.service.ipn(
        ipn(row, { vnp_ResponseCode: '24', vnp_TransactionStatus: '02' }),
      )
    ).RspCode,
    '00',
  );
  assert.equal(row.state, 'failed');
  assert.equal((await f.service.ipn(ipn(row))).RspCode, '02');
  assert.equal(row.state, 'failed');
});
void test('return endpoint is static and cannot record payment; unavailable callback config requests retry', async () => {
  const f = fixture(),
    controller = new VnpayCallbacksController(f.service);
  assert.match(controller.returned(), /does not confirm payment/);
  assert.deepEqual(f.writes, []);
  const disabled = new PaymentsService(f.db, f.security, {
    nodeEnv: 'test',
  } as Environment);
  assert.equal((await disabled.ipn('fake')).RspCode, '99');
});

void test('movie preview works without setup and performs no authorization, provider or database work', async () => {
  const f = fixture();
  f.restrict();
  f.denyReference();
  const disabled = new PaymentsService(f.db, f.security, {
    nodeEnv: 'test',
  } as Environment);
  for (const serviceId of ['movie_matinee_v1', 'movie_evening_v1']) {
    const preview = disabled.preview(request(), { serviceId });
    assert.equal(preview.service.id, serviceId);
    assert.equal(preview.amountMinor, preview.service.amountMinor);
    assert.equal(preview.currency, 'VND');
    assert.equal(preview.previewOnly, true);
    assert.equal(preview.checkoutAvailable, false);
    assert.equal(preview.fulfillment, 'not_available');
    assert.match(
      preview.service.description,
      /One ticket.*fictional.*No real showing, seat reservation or admission/,
    );
    for (const key of [
      'reviewToken',
      'requestId',
      'order',
      'state',
      'checkoutUrl',
      'accessToken',
    ])
      assert.equal(key in preview, false);
  }
  assert.equal(
    f.service.preview(request(), { serviceId: 'movie_matinee_v1' })
      .checkoutAvailable,
    true,
  );
  assert.deepEqual(f.queries, []);
  assert.deepEqual(f.writes, []);
  assert.equal(f.providerCalls, 0);
  await rejectStatus(
    disabled.review(request(), { serviceId: 'movie_matinee_v1' }),
    409,
  );
  assert.equal(f.payment, undefined);
});

void test('movie preview rejects officers, unsupported choices and client-controlled offer details', async () => {
  const f = fixture();
  const officer = {
    ...request(),
    user: { ...request().user, role: 'officer' },
  } as AuthenticatedRequest;
  assert.throws(
    () => f.service.preview(officer, { serviceId: 'movie_matinee_v1' }),
    (e) => (e as { getStatus(): number }).getStatus() === 403,
  );
  for (const body of [
    null,
    {},
    { serviceId: 'real-cinema' },
    { serviceId: 'movie_matinee_v1', quantity: 2 },
    { serviceId: 'movie_matinee_v1', amountMinor: '1' },
    { serviceId: 'movie_matinee_v1', seat: 'A1' },
    { serviceId: 'movie_matinee_v1', serviceSnapshot: {} },
  ])
    assert.throws(() => f.service.preview(request(), body));
  const preview = f.service.preview(request(), {
    serviceId: 'movie_matinee_v1',
  });
  await rejectStatus(
    f.service.confirm(request(), { ...preview, code: '123456' }),
    400,
  );
  assert.deepEqual(f.queries, []);
  assert.equal(f.providerCalls, 0);
});

void test('signed movie offer binds all display details and refuses obsolete v1 reviews before verification', async () => {
  const f = fixture();
  const review = await f.service.review(request(), {
    serviceId: 'movie_matinee_v1',
  });
  const [encoded] = review.reviewToken.split('.');
  const source = JSON.parse(
    Buffer.from(encoded!, 'base64url').toString(),
  ) as Data;
  assert.deepEqual(source.serviceSnapshot, review.service);
  assert.equal(source.policy, 'vnpay-synthetic-services-v2');
  const sign = (data: Data) => {
    const text = Buffer.from(JSON.stringify(data)).toString('base64url');
    return `${text}.${createHmac('sha256', 'synthetic-review-secret')
      .update('nene-vnpay-review-v1\0' + text)
      .digest('base64url')}`;
  };
  for (const changed of [
    {
      ...source,
      serviceSnapshot: { ...review.service, name: 'Changed movie' },
    },
    {
      ...source,
      serviceSnapshot: { ...review.service, description: 'Different session' },
    },
    { ...source, serviceSnapshot: { ...review.service, quantity: 2 } },
    { ...source, serviceSnapshot: { ...review.service, amountMinor: '1' } },
    { ...source, policy: 'vnpay-synthetic-utilities-v1' },
  ])
    await rejectStatus(
      f.service.confirm(request(), {
        reviewToken: sign(changed),
        code: '123456',
      }),
      409,
    );
  assert.equal(f.verifyCalls, 0);
  assert.equal(f.payment, undefined);
});

void test('movie offer change during verification cannot create checkout', async () => {
  const f = fixture();
  const review = await f.service.review(request(), {
    serviceId: 'movie_evening_v1',
  });
  const offer = sandboxServices.find((s) => s.id === 'movie_evening_v1')!;
  const original = offer.name;
  f.afterVerify(() => {
    (offer as unknown as Data).name = 'Changed session';
  });
  try {
    await rejectStatus(
      f.service.confirm(request(), {
        reviewToken: review.reviewToken,
        code: '123456',
      }),
      503,
    );
    assert.equal(f.payment, undefined);
    assert.equal(f.verifyCalls, 1);
  } finally {
    (offer as unknown as Data).name = original;
  }
});

void test('movie orders persist reviewed snapshots and recover independently of catalog display changes', async () => {
  const { f, review, result } = await authorized(fixture(), 'movie_matinee_v1');
  assert.equal(result.state, 'awaiting_payment');
  assert.deepEqual(f.payment?.service_snapshot, review.service);
  const offer = sandboxServices.find((s) => s.id === 'movie_matinee_v1')!;
  const original = offer.description;
  (offer as unknown as Data).description = 'Changed catalog description';
  try {
    // JSONB can return keys in any order; property order is not offer identity.
    f.payment!.service_snapshot = Object.fromEntries(
      Object.entries(review.service).reverse(),
    );
    assert.deepEqual(
      (await f.service.status(request(), review.requestId)).order?.service,
      review.service,
    );
    assert.deepEqual(
      (await f.service.recent(request())).orders[0]?.service,
      review.service,
    );
    assert.equal((await f.service.ipn(ipn(f.payment!))).RspCode, '00');
    const paid = await f.service.status(request(), review.requestId);
    assert.equal(paid.state, 'paid');
    assert.equal(paid.order?.fulfillment, 'not_available');
    assert.deepEqual(paid.order?.service, review.service);
  } finally {
    (offer as unknown as Data).description = original;
  }
  for (const snapshot of [
    null,
    {},
    { ...review.service, amountMinor: '1' },
    { ...review.service, currency: 'USD' },
  ]) {
    f.payment!.service_snapshot = snapshot;
    await rejectStatus(f.service.status(request(), review.requestId), 503);
  }
});

void test('paid or failed movie orders may repeat with a new proof while pending orders and replay cannot charge again', async () => {
  for (const failed of [false, true]) {
    const { f, review } = await authorized(fixture(), 'movie_evening_v1');
    await rejectStatus(
      f.service.review(request(), { serviceId: 'movie_evening_v1' }),
      409,
    );
    assert.equal(
      (
        await f.service.ipn(
          ipn(
            f.payment!,
            failed
              ? { vnp_ResponseCode: '24', vnp_TransactionStatus: '02' }
              : {},
          ),
        )
      ).RspCode,
      '00',
    );
    const replay = await f.service.confirm(request(), {
      reviewToken: review.reviewToken,
      code: '234567',
    });
    assert.equal(replay.replay, true);
    assert.equal(f.verifyCalls, 1);
    const next = await f.service.review(request(), {
      serviceId: 'movie_evening_v1',
    });
    assert.notEqual(next.requestId, review.requestId);
    const second = await f.service.confirm(request(), {
      reviewToken: next.reviewToken,
      code: '234567',
    });
    assert.equal(second.state, 'awaiting_payment');
    assert.equal(second.order?.fulfillment, 'not_available');
    assert.equal(f.verifyCalls, 2);
    assert.equal(
      f.writes.filter((sql) =>
        sql.startsWith('insert into bank.sandbox_payments'),
      ).length,
      2,
    );
    assert.ok(
      f.writes.every(
        (sql) =>
          !sql.includes('banking_accounts') && !sql.includes('account_history'),
      ),
    );
  }
});
