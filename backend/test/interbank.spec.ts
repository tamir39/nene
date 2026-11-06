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
import { reserveSecurityProof } from '../src/security/security-proof.js';
import {
  ConfirmationService,
  interbankInput,
} from '../src/confirmation/confirmation.service.js';

const customer = '10000000-0000-4000-8000-000000000001';
const factor = '20000000-0000-4000-8000-000000000002';
const session = '30000000-0000-4000-8000-000000000003';
const challenge = '40000000-0000-4000-8000-000000000004';
const source = '50000000-0000-4000-8000-000000000005';
const other = '60000000-0000-4000-8000-000000000006';
const recipientId = '99000000-0000-4000-8000-000000000001';
const secret = 'synthetic-review-secret';
const body = {
  sourceAccountId: source,
  destinationBankCode: 'DEMO_A',
  destinationAccountNumber: '990000000001',
  amountMinor: '100000',
};
const jwt = (id = customer, sid = session) =>
  `x.${Buffer.from(JSON.stringify({ sub: id, session_id: sid, aal: 'aal2' })).toString('base64url')}.x`;
const request = (id = customer, sid = session) =>
  ({
    user: { id, role: 'customer' },
    headers: { authorization: `Bearer ${jwt(id, sid)}` },
  }) as unknown as AuthenticatedRequest;
const rejectStatus = (promise: Promise<unknown>, status: number) =>
  assert.rejects(
    promise,
    (e) => (e as { getStatus(): number }).getStatus() === status,
  );
type Data = Record<string, unknown>;

// This stand-in verifies service sequencing, proof isolation and response contracts.
// Atomic balances, locks and SQL permissions are covered by check-local-interbank.mjs.
function fixture() {
  let attempt: Data | undefined, receipt: Data | undefined;
  let ready = true,
    eligible = true,
    reference = true,
    dbEnabled = true,
    verifyCalls = 0;
  let providerFailure: 'rejected' | 'unknown' | undefined;
  let afterVerify: (() => void) | undefined;
  let amountAvailable = '1000000';
  const recipient = {
    id: recipientId,
    number: '990000000001',
    bankCode: 'DEMO_A',
    bankName: 'Demo Bank A',
    recipientName: 'Demo recipient A',
  };
  const fingerprints = new Set<string>();
  const posts: { sql: string; values: unknown[] }[] = [];
  const reservationPurposes: unknown[] = [];
  const sourceAccount = () => ({
    id: source,
    owner_id: customer,
    number: '100000000001',
    type: 'checking',
    currency: 'VND',
    status: 'active',
    profile_status: 'active',
    balance: amountAvailable,
  });
  const execute = (sql: string, values: unknown[] = []): Data[] => {
    if (sql.startsWith('select enabled from bank.'))
      return [{ enabled: dbEnabled }];
    if (sql.startsWith('select b.code'))
      return [
        {
          code: recipient.bankCode,
          name: recipient.bankName,
          accountNumber: recipient.number,
          recipientName: recipient.recipientName,
        },
      ];
    if (sql.startsWith('select secret')) return [{ secret }];
    if (
      sql.startsWith('select factor_id') ||
      sql.startsWith('select state,factor_id')
    )
      return [
        {
          factor_id: factor,
          revision: 2,
          state: ready ? 'ready' : 'restricted',
        },
      ];
    if (sql.startsWith('select customer_id from bank.authenticator_setup'))
      return [{ customer_id: customer }];
    if (sql.startsWith('select a.id,a.owner_id')) {
      if (!eligible || values[0] !== source) return [];
      if (sql.includes('a.owner_id=$2'))
        return values[1] === customer ? [sourceAccount()] : [];
      return [
        sourceAccount(),
        {
          ...sourceAccount(),
          id: other,
          owner_id: other,
          number: '100000000002',
        },
      ];
    }
    if (sql.startsWith('select a.id from bank.banking_accounts'))
      return [{ id: source }, { id: other }];
    if (sql.startsWith('select r.id,r.account_number'))
      return values[0] === recipient.bankCode && values[1] === recipient.number
        ? [{ ...recipient }]
        : [];
    if (
      sql.startsWith(
        'select balance_minor::text balance from bank.demo_cash_balances',
      )
    )
      return [{ balance: '1000000' }];
    if (sql.startsWith('select i.id'))
      return reference
        ? [{ id: challenge, version: 1, revision: 1, evidence_id: factor }]
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
      reservationPurposes.push(values[3]);
      return [{ customer_id: customer }];
    }
    if (sql.startsWith('select id from bank.transaction_confirmations')) {
      if (sql.includes("purpose<>'preview'"))
        return attempt?.state === 'checking' ? [{ id: attempt.id }] : [];
      return attempt &&
        attempt.customer_id === values[0] &&
        attempt.purpose === values[1]
        ? [{ id: attempt.id }]
        : [];
    }
    if (sql.startsWith('select * from bank.transaction_confirmations'))
      return attempt &&
        attempt.id === values[0] &&
        (values.length < 2 || attempt.customer_id === values[1])
        ? [{ ...attempt }]
        : [];
    if (sql.startsWith('insert into bank.transaction_confirmations')) {
      if (
        attempt?.state === 'posted' ||
        (!sql.includes("'cancelled'") && Number(values[6]) <= Date.now())
      )
        return [];
      attempt = {
        id: values[0],
        customer_id: values[1],
        session_id: values[2],
        review_digest: values[3],
        factor_id: values[4],
        security_revision: values[5],
        state: sql.includes("'cancelled'") ? 'cancelled' : 'checking',
        expires_at: new Date(Number(values[6])),
        lease_until: new Date(Date.now() + 45000),
        confirmed_until: null,
        purpose: values[7],
      };
      return [{ id: attempt.id }];
    }
    if (sql.startsWith('update bank.transaction_confirmations')) {
      if (!attempt || attempt.id !== values[0] || attempt.state !== 'checking')
        return [];
      attempt.state = sql.includes("state='factor_confirmed'")
        ? 'factor_confirmed'
        : sql.includes("state='rejected'")
          ? 'rejected'
          : values[1];
      return [{ id: attempt.id }];
    }
    if (sql.startsWith('select bank.post_local_')) {
      assert.equal(attempt?.state, 'factor_confirmed');
      posts.push({ sql, values });
      attempt!.state = 'posted';
      receipt = {
        id: values[0],
        sourceAccountId: source,
        destinationBankCode: values[6],
        destinationBankName: values[7],
        destinationAccountNumber: values[8],
        destinationRecipientName: values[9],
        amountMinor: values[10],
        currency: 'VND',
        simulated: true,
        postedAt: new Date(),
      };
      return [];
    }
    if (
      sql.includes('from bank.local_interbank_transfers') ||
      sql.includes('from bank.local_transfers') ||
      sql.includes('from bank.local_cash_operations')
    )
      return receipt ? [{ ...receipt }] : [];
    throw new Error('Unhandled fixture SQL: ' + sql);
  };
  const db = {
    query: async (sql: string, values: unknown[]) => execute(sql, values),
    transaction: async <T>(work: (client: PoolClient) => Promise<T>) => {
      const before = attempt ? { ...attempt } : undefined;
      try {
        return await work({
          query: async (sql: string, values: unknown[]) => ({
            rows: execute(sql, values),
          }),
        } as unknown as PoolClient);
      } catch (error) {
        attempt = before;
        throw error;
      }
    },
  } as unknown as DatabaseService;
  const env = {
    nodeEnv: 'test',
    localInterbankEnabled: true,
    localTransfersEnabled: true,
    localCashEnabled: true,
  } as Environment;
  class TestSecurity extends SecurityService {
    override async provider(path: string): Promise<Data> {
      if (path === '/user')
        return {
          id: customer,
          factors: [{ id: factor, status: 'verified', factor_type: 'totp' }],
        };
      if (path.endsWith('/challenge')) return { id: challenge };
      if (path.endsWith('/verify')) {
        verifyCalls++;
        if (providerFailure === 'rejected') throw new BadRequestException();
        if (providerFailure === 'unknown')
          throw new Error('Synthetic provider interruption');
        afterVerify?.();
        return {
          access_token: jwt(),
          refresh_token: 'synthetic-rotated-refresh',
        };
      }
      throw new Error('Unhandled provider path');
    }
  }
  const security = new TestSecurity(db, env);
  const service = new ConfirmationService(db, security, env);
  return {
    service,
    db,
    env,
    recipient,
    posts,
    reservationPurposes,
    get attempt() {
      return attempt;
    },
    get verifyCalls() {
      return verifyCalls;
    },
    restrict: () => {
      ready = false;
    },
    denySource: () => {
      eligible = false;
    },
    denyReference: () => {
      reference = false;
    },
    disableDatabase: () => {
      dbEnabled = false;
    },
    balance: (value: string) => {
      amountAvailable = value;
    },
    failProvider: (value: 'rejected' | 'unknown') => {
      providerFailure = value;
    },
    afterVerify: (action: () => void) => {
      afterVerify = action;
    },
  };
}

void test('interbank input accepts only exact fixed-bank and integer amount fields', () => {
  assert.deepEqual(interbankInput(body), {
    source,
    bankCode: 'DEMO_A',
    destinationNumber: '990000000001',
    amountMinor: '100000',
  });
  for (const extra of [
    { feeMinor: '0' },
    { currency: 'USD' },
    { recipientName: 'Attacker' },
    { simulated: false },
    { destinationRecipientId: recipientId },
  ])
    assert.throws(() => interbankInput({ ...body, ...extra }));
  for (const destinationBankCode of ['VCB', 'demo_a', '', undefined])
    assert.throws(() => interbankInput({ ...body, destinationBankCode }));
  for (const amountMinor of ['0', '-1', '0.5', '01', '1e6', 100])
    assert.throws(() => interbankInput({ ...body, amountMinor }));
  assert.throws(() =>
    interbankInput({ ...body, destinationAccountNumber: '123' }),
  );
});

void test('configuration labels fictional recipients and requires independent nonproduction gates', async () => {
  const f = fixture();
  const config = await f.service.configuration(request(), 'interbank');
  assert.equal(config.enabled, true);
  assert.equal(config.simulated, true);
  assert.deepEqual(config.banks, [
    {
      code: 'DEMO_A',
      name: 'Demo Bank A',
      recipients: [{ accountNumber: '990000000001', name: 'Demo recipient A' }],
    },
  ]);
  f.env.localInterbankEnabled = false;
  assert.equal(
    (await f.service.configuration(request(), 'interbank')).enabled,
    false,
  );
  assert.equal((await f.service.configuration(request(), true)).enabled, true);
  await rejectStatus(f.service.review(request(), body, 'interbank'), 409);
  f.env.localInterbankEnabled = true;
  f.env.nodeEnv = 'production';
  await rejectStatus(f.service.review(request(), body, 'interbank'), 409);
  f.env.nodeEnv = 'test';
  f.disableDatabase();
  await rejectStatus(f.service.review(request(), body, 'interbank'), 409);
});

void test('officers are denied before interbank data or proof access', async () => {
  const db = {
    query: () => {
      throw new Error('Must not reach data');
    },
  } as unknown as DatabaseService;
  const service = new ConfirmationService(
    db,
    new SecurityService(db, {} as Environment),
  );
  const req = {
    user: { role: 'officer' },
    headers: {},
  } as AuthenticatedRequest;
  for (const call of [
    () => service.configuration(req, 'interbank'),
    () => service.review(req, body, 'interbank'),
    () =>
      service.confirm(req, { reviewToken: 'x', code: '123456' }, 'interbank'),
    () => service.cancel(req, { reviewToken: 'x' }, 'interbank'),
    () => service.status(req, source, 'interbank'),
    () => service.recent(req, 'interbank'),
  ])
    await rejectStatus(call(), 403);
});

void test('review binds bank, recipient, reference and zero fee without moving funds', async () => {
  const f = fixture();
  const review = await f.service.review(request(), body, 'interbank');
  assert.equal(review.simulated, true);
  assert.equal(review.destinationBankName, 'Demo Bank A');
  assert.equal(review.destinationRecipientName, 'Demo recipient A');
  assert.equal(review.feeMinor, '0');
  assert.equal(review.identityCheck, 'not_implemented');
  const signed = JSON.parse(
    Buffer.from(review.reviewToken.split('.')[0]!, 'base64url').toString(),
  ) as Data;
  assert.equal(signed.policy, 'local-interbank-v1');
  assert.equal(signed.destination, recipientId);
  assert.equal(signed.destinationBankCode, 'DEMO_A');
  assert.equal(signed.destinationBankName, review.destinationBankName);
  assert.equal(
    signed.destinationRecipientName,
    review.destinationRecipientName,
  );
  assert.equal(f.posts.length, 0);
});

void test('review denies unavailable recipients, unowned/unprepared sources, references and insufficient funds', async () => {
  for (const change of [
    (f: ReturnType<typeof fixture>) => f.denySource(),
    (f: ReturnType<typeof fixture>) => f.denyReference(),
    (f: ReturnType<typeof fixture>) => f.balance('99999'),
  ]) {
    const f = fixture();
    change(f);
    await rejectStatus(f.service.review(request(), body, 'interbank'), 400);
    assert.equal(f.verifyCalls, 0);
    assert.equal(f.posts.length, 0);
  }
  const f = fixture();
  await rejectStatus(
    f.service.review(
      request(),
      { ...body, sourceAccountId: other },
      'interbank',
    ),
    400,
  );
  await rejectStatus(
    f.service.review(
      request(),
      { ...body, destinationBankCode: 'DEMO_B' },
      'interbank',
    ),
    400,
  );
  await rejectStatus(
    f.service.review(
      request(),
      { ...body, destinationAccountNumber: '100000000002' },
      'interbank',
    ),
    400,
  );
  f.balance('9000000');
  await rejectStatus(
    f.service.review(
      request(),
      { ...body, amountMinor: '5000000' },
      'interbank',
    ),
    400,
  );
});

void test('tampered and cross-purpose reviews cannot authorize another operation', async () => {
  const f = fixture();
  const review = await f.service.review(request(), body, 'interbank');
  const [encoded, signature] = review.reviewToken.split('.');
  const changed = JSON.parse(
    Buffer.from(encoded!, 'base64url').toString(),
  ) as Data;
  changed.destinationBankCode = 'DEMO_B';
  const modified =
    Buffer.from(JSON.stringify(changed)).toString('base64url') +
    '.' +
    signature;
  await rejectStatus(
    f.service.confirm(
      request(),
      { reviewToken: modified, code: '123456' },
      'interbank',
    ),
    400,
  );
  for (const operation of [false, true, 'deposit', 'withdrawal'] as const) {
    await rejectStatus(
      f.service.confirm(
        request(),
        { reviewToken: review.reviewToken, code: '123456' },
        operation,
      ),
      409,
    );
    await rejectStatus(
      f.service.cancel(
        request(),
        { reviewToken: review.reviewToken },
        operation,
      ),
      409,
    );
  }
  await rejectStatus(
    f.service.confirm(
      request(other),
      { reviewToken: review.reviewToken, code: '123456' },
      'interbank',
    ),
    403,
  );
  await rejectStatus(
    f.service.confirm(
      request(customer, other),
      { reviewToken: review.reviewToken, code: '123456' },
      'interbank',
    ),
    403,
  );
  assert.equal(f.verifyCalls, 0);
});

void test('recipient snapshot changes fail before TOTP and after verification', async () => {
  for (const field of ['bankName', 'recipientName'] as const) {
    const f = fixture();
    const review = await f.service.review(request(), body, 'interbank');
    f.recipient[field] = 'Changed';
    await rejectStatus(
      f.service.confirm(
        request(),
        { reviewToken: review.reviewToken, code: '123456' },
        'interbank',
      ),
      409,
    );
    assert.equal(f.verifyCalls, 0);
    const second = fixture();
    const next = await second.service.review(request(), body, 'interbank');
    second.afterVerify(() => {
      second.recipient[field] = 'Changed';
    });
    await rejectStatus(
      second.service.confirm(
        request(),
        { reviewToken: next.reviewToken, code: '123456' },
        'interbank',
      ),
      503,
    );
    assert.equal(second.posts.length, 0);
  }
});

void test('posting consumes bound proof and passes immutable snapshots to the atomic function', async () => {
  const f = fixture();
  const review = await f.service.review(request(), body, 'interbank');
  const result = (await f.service.confirm(
    request(),
    { reviewToken: review.reviewToken, code: '123456' },
    'interbank',
  )) as Data;
  assert.equal(result.state, 'posted');
  assert.equal(result.simulated, true);
  assert.equal(result.sent, true);
  assert.equal(result.purpose, 'interbank-transfer');
  assert.equal(result.replay, false);
  assert.equal(result.refreshToken, 'synthetic-rotated-refresh');
  assert.deepEqual(f.reservationPurposes, ['interbank-transfer']);
  assert.equal(f.attempt?.purpose, 'local_interbank');
  const posted = f.posts[0]!;
  assert.match(posted.sql, /post_local_interbank\(/);
  assert.deepEqual(posted.values.slice(4), [
    source,
    recipientId,
    'DEMO_A',
    'Demo Bank A',
    '990000000001',
    'Demo recipient A',
    '100000',
    challenge,
    1,
    1,
    factor,
  ]);
  const receipt = result.receipt as Data;
  assert.equal(receipt.destinationBankName, 'Demo Bank A');
  assert.equal(receipt.destinationRecipientName, 'Demo recipient A');
  assert.equal(receipt.simulated, true);
  f.recipient.bankName = 'Renamed after posting';
  const replay = (await f.service.confirm(
    request(),
    { reviewToken: review.reviewToken, code: '654321' },
    'interbank',
  )) as Data;
  assert.equal(replay.replay, true);
  assert.equal(replay.accessToken, undefined);
  assert.equal(replay.refreshToken, undefined);
  assert.equal((replay.receipt as Data).destinationBankName, 'Demo Bank A');
  assert.equal(f.verifyCalls, 1);
  assert.equal(f.posts.length, 1);
  const recent = await f.service.recent(request(), 'interbank');
  assert.equal(recent.transfers!.length, 1);
  assert.equal(recent.transfers![0]!.simulated, true);
  await rejectStatus(f.service.status(request(), review.requestId, true), 404);
  await rejectStatus(
    f.service.status(request(other), review.requestId, 'interbank'),
    404,
  );
});

void test('code attempted for another security purpose cannot be reused for interbank', async () => {
  const f = fixture();
  await reserveSecurityProof(
    f.db,
    customer,
    factor,
    '123456',
    'cash-withdrawal',
  );
  const review = await f.service.review(request(), body, 'interbank');
  await rejectStatus(
    f.service.confirm(
      request(),
      { reviewToken: review.reviewToken, code: '123456' },
      'interbank',
    ),
    400,
  );
  assert.equal(f.verifyCalls, 0);
  assert.equal(f.posts.length, 0);
  const status = await f.service.status(
    request(),
    review.requestId,
    'interbank',
  );
  assert.equal(status.state, 'rejected');
  assert.equal(status.simulated, true);
});

void test('cancelled reviews never invoke TOTP and every result remains labelled simulated', async () => {
  const f = fixture();
  const review = await f.service.review(request(), body, 'interbank');
  assert.equal(
    (
      await f.service.cancel(
        request(),
        { reviewToken: review.reviewToken },
        'interbank',
      )
    ).simulated,
    true,
  );
  const result = await f.service.confirm(
    request(),
    { reviewToken: review.reviewToken, code: '123456' },
    'interbank',
  );
  assert.equal(result.state, 'cancelled');
  assert.equal(result.simulated, true);
  assert.equal(result.replay, true);
  assert.equal(f.verifyCalls, 0);
  assert.equal(f.posts.length, 0);
});

void test('provider rejection and uncertainty do not post or leak a rotated pair', async () => {
  for (const failure of ['rejected', 'unknown'] as const) {
    const f = fixture();
    const review = await f.service.review(request(), body, 'interbank');
    f.failProvider(failure);
    await rejectStatus(
      f.service.confirm(
        request(),
        { reviewToken: review.reviewToken, code: '123456' },
        'interbank',
      ),
      failure === 'rejected' ? 400 : 503,
    );
    const status = await f.service.status(
      request(),
      review.requestId,
      'interbank',
    );
    assert.equal(status.state, failure);
    assert.equal(status.simulated, true);
    assert.equal(status.sent, false);
    assert.equal(f.posts.length, 0);
  }
});

void test('signed expired review and changed authenticator/reference cannot reserve a proof', async () => {
  for (const deny of [
    (f: ReturnType<typeof fixture>) => f.restrict(),
    (f: ReturnType<typeof fixture>) => f.denyReference(),
  ]) {
    const f = fixture();
    const review = await f.service.review(request(), body, 'interbank');
    deny(f);
    await assert.rejects(
      f.service.confirm(
        request(),
        { reviewToken: review.reviewToken, code: '123456' },
        'interbank',
      ),
    );
    assert.equal(f.verifyCalls, 0);
    assert.equal(f.posts.length, 0);
  }
  const f = fixture();
  const review = await f.service.review(request(), body, 'interbank');
  const expired = JSON.parse(
    Buffer.from(review.reviewToken.split('.')[0]!, 'base64url').toString(),
  ) as Data;
  expired.expires = Date.now() - 1000;
  const encoded = Buffer.from(JSON.stringify(expired)).toString('base64url');
  const token =
    encoded +
    '.' +
    createHmac('sha256', secret)
      .update('nene-review-v1\0' + encoded)
      .digest('base64url');
  await rejectStatus(
    f.service.confirm(
      request(),
      { reviewToken: token, code: '123456' },
      'interbank',
    ),
    409,
  );
  assert.equal(f.verifyCalls, 0);
});

void test('shared lifecycle retains preview, same-bank and cash purpose separation', async () => {
  for (const operation of [false, true, 'deposit', 'withdrawal'] as const) {
    const f = fixture();
    const cash = operation === 'deposit' || operation === 'withdrawal';
    const input = cash
      ? { accountId: source, amountMinor: '100000' }
      : {
          sourceAccountId: source,
          destinationAccountNumber: '100000000002',
          amountMinor: '100000',
        };
    const review = await f.service.review(request(), input, operation);
    assert.equal(review.simulated, undefined);
    const signed = JSON.parse(
      Buffer.from(review.reviewToken.split('.')[0]!, 'base64url').toString(),
    ) as Data;
    assert.equal(
      signed.policy,
      cash
        ? `local-cash-${operation}-v1`
        : operation
          ? 'local-vnd-under-5000000-v1'
          : 'same-bank-confirmation-only-v1',
    );
    await rejectStatus(
      f.service.confirm(
        request(),
        { reviewToken: review.reviewToken, code: '123456' },
        'interbank',
      ),
      409,
    );
    const result = (await f.service.confirm(
      request(),
      { reviewToken: review.reviewToken, code: '123456' },
      operation,
    )) as Data;
    assert.equal(
      result.purpose,
      cash
        ? `cash-${operation}`
        : operation
          ? 'same-bank-transfer'
          : 'transaction-confirmation',
    );
    assert.equal(
      f.attempt?.purpose,
      cash ? `local_${operation}` : operation ? 'local_transfer' : 'preview',
    );
    assert.equal(f.posts.length, operation ? 1 : 0);
    if (operation)
      assert.match(
        f.posts[0]!.sql,
        cash ? /post_local_cash\(/ : /post_local_transfer\(/,
      );
  }
});
