import 'reflect-metadata';
import assert from 'node:assert/strict';
import { it } from 'node:test';
import { HttpException, ServiceUnavailableException } from '@nestjs/common';
import { SecurityService } from '../src/security/security.service.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { Environment } from '../src/config/environment.js';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
const id = '11111111-1111-4111-8111-111111111111';
function request(role = 'customer', time = Date.now() / 1000, session = id) {
  return {
    user: { id, role },
    headers: {
      authorization: `Bearer x.${Buffer.from(JSON.stringify({ sub: id, session_id: session, amr: [{ method: 'password', timestamp: time }] })).toString('base64url')}.x`,
    },
  } as AuthenticatedRequest;
}
function service(rows: object[] = []) {
  let calls = 0;
  const db = {
    query: async () => {
      calls++;
      return rows;
    },
  } as unknown as DatabaseService;
  return {
    value: new SecurityService(db, {} as Environment),
    calls: () => calls,
  };
}
void it('officers cannot read or enroll customer authenticators', async () => {
  const s = service();
  await assert.rejects(s.value.status(request('officer')));
  await assert.rejects(s.value.start(request('officer')));
  assert.equal(s.calls(), 0);
});
void it('stale password evidence cannot reserve enrollment', async () => {
  const s = service();
  await assert.rejects(s.value.start(request('customer', 1)));
  assert.equal(s.calls(), 0);
});
void it('future password evidence cannot reserve enrollment', async () => {
  const s = service();
  await assert.rejects(
    s.value.start(request('customer', Date.now() / 1000 + 3600)),
  );
  assert.equal(s.calls(), 0);
});
void it('status with no binding is not set up and returns no secret', async () => {
  assert.deepEqual(await service().value.status(request()), {
    state: 'not_set_up',
  });
});
void it('duplicate reservation makes no provider call', async () => {
  await assert.rejects(
    service().value.start(request()),
    (e) => (e as { getStatus(): number }).getStatus() === 409,
  );
});
void it('malformed proof and caller-selected factor are rejected before database', async () => {
  const s = service();
  await assert.rejects(
    s.value.verify(request(), { requestId: id, code: '123456', factorId: id }),
  );
  await assert.rejects(
    s.value.verify(request(), { requestId: id, code: '123' }),
  );
  assert.equal(s.calls(), 0);
});
void it('missing reservation cannot dispatch verification', async () => {
  await assert.rejects(
    service().value.verify(request(), { requestId: id, code: '123456' }),
    (e) => (e as { getStatus(): number }).getStatus() === 409,
  );
});

// Abandoned initial setup: a stateful fake of the setup row and Auth factors.
const other = '22222222-2222-4222-8222-222222222222';
const oldRequest = '33333333-3333-4333-8333-333333333333';
const oldFactor = '44444444-4444-4444-8444-444444444444';
const newFactor = '55555555-5555-4555-8555-555555555555';
const verifiedFactor = '66666666-6666-4666-8666-666666666666';
const phoneFactor = '77777777-7777-4777-8777-777777777777';
const secret = 'SYNTHETICRESTARTKEY234567';
type SetupRow = {
  customer_id: string;
  request_id: string;
  session_id: string;
  factor_id: string | null;
  state: string;
  revision: number;
  attempts: number;
  expires_at: Date;
  created_at: Date;
};
type FakeFactor = { id: string; factor_type: string; status: string };
const minutes = (n: number) => new Date(Date.now() + n * 60_000);
function setupRow(over: Partial<SetupRow> = {}): SetupRow {
  return {
    customer_id: id,
    request_id: oldRequest,
    session_id: other,
    factor_id: oldFactor,
    state: 'pending',
    revision: 1,
    attempts: 0,
    expires_at: minutes(-1),
    created_at: minutes(-11),
    ...over,
  };
}
const unverified = (factorId = oldFactor): FakeFactor => ({
  id: factorId,
  factor_type: 'totp',
  status: 'unverified',
});
function restartFixture(
  initial: SetupRow | null,
  factors: FakeFactor[],
  opts: {
    claimLoses?: boolean;
    failDelete?: boolean;
    bindLoses?: boolean;
    verifyAfterClaim?: boolean;
  } = {},
) {
  let row = initial ? { ...initial } : null;
  const log: string[] = [];
  const expired = (r: SetupRow) => r.expires_at.getTime() <= Date.now();
  const db = {
    query: async (sql: string, args: unknown[] = []) => {
      if (sql.startsWith('select *,expires_at<=now() as expired')) {
        log.push('select');
        return row ? [{ ...row, expired: expired(row) }] : [];
      }
      if (sql.startsWith('insert into bank.authenticator_setup')) {
        log.push('insert');
        return [];
      }
      if (sql.includes("set request_id=$2,session_id=$3,state='starting'")) {
        log.push('claim');
        const [customer, request, session, previous, state] = args;
        // Mirrors the SQL guard; the statement itself runs against PostgreSQL in
        // scripts/check-authenticator-setup.mjs.
        if (
          opts.claimLoses ||
          !row ||
          customer !== row.customer_id ||
          previous !== row.request_id ||
          state !== row.state ||
          !['starting', 'pending', 'verifying', 'blocked'].includes(
            row.state,
          ) ||
          !(
            expired(row) ||
            (row.session_id !== session &&
              ['starting', 'pending'].includes(row.state) &&
              row.attempts < 5)
          )
        )
          return [];
        row = {
          ...row,
          request_id: request as string,
          session_id: session as string,
          state: 'starting',
          factor_id: null,
          attempts: 0,
          revision: row.revision + 1,
          expires_at: minutes(10),
          created_at: new Date(),
        };
        if (opts.verifyAfterClaim)
          factors.find((f) => f.id === oldFactor)!.status = 'verified';
        return [{ ...row }];
      }
      if (sql.includes('set request_id=$3,session_id=$4')) {
        log.push('revert');
        if (row && row.request_id === args[1] && row.state === 'starting')
          row = {
            ...row,
            request_id: args[2] as string,
            session_id: args[3] as string,
            state: args[4] as string,
            factor_id: args[5] as string | null,
            attempts: args[6] as number,
            revision: args[7] as number,
            expires_at: args[8] as Date,
            created_at: args[9] as Date,
          };
        return [];
      }
      if (sql.includes("set factor_id=$2,state='pending'")) {
        log.push('bind');
        if (
          opts.bindLoses ||
          !row ||
          row.request_id !== args[2] ||
          row.state !== 'starting'
        )
          return [];
        row = { ...row, factor_id: args[1] as string, state: 'pending' };
        return [{ request_id: row.request_id }];
      }
      if (sql.includes("set state='verifying'")) {
        log.push('reserve-verify');
        return [];
      }
      if (sql.includes("set state='ready'")) {
        log.push('reconcile');
        return [];
      }
      throw new Error('Unexpected query');
    },
  } as unknown as DatabaseService;
  const value = new SecurityService(db, {} as Environment);
  const tokens: string[] = [];
  value.provider = async (path, token, body, method) => {
    const verb = method ?? (body ? 'POST' : 'GET');
    log.push(`${verb} ${path}`);
    tokens.push(token);
    if (verb === 'GET' && path === '/user')
      return factors.length
        ? { id, factors: factors.map((f) => ({ ...f })) }
        : { id };
    if (verb === 'DELETE' && path.startsWith('/factors/')) {
      const target = factors.findIndex((f) => `/factors/${f.id}` === path);
      // Auth: an AAL1 session cannot remove a verified factor.
      if (
        opts.failDelete ||
        target < 0 ||
        factors[target]!.status !== 'unverified'
      )
        throw new ServiceUnavailableException(
          'Authenticator request could not be confirmed. Check status before retrying.',
        );
      factors.splice(target, 1);
      return {};
    }
    if (verb === 'POST' && path === '/factors') {
      factors.push(unverified(newFactor));
      return { id: newFactor, totp: { secret } };
    }
    throw new Error('Unexpected provider call');
  };
  return { value, log, row: () => row, factors, tokens };
}
const conflict = (message: string) => (e: unknown) =>
  e instanceof HttpException &&
  e.getStatus() === 409 &&
  JSON.stringify(e.getResponse()).includes(message);
const provided = (log: string[]) =>
  log.some((x) => x.startsWith('DELETE') || x === 'POST /factors');

void it('expired unverified pending setup reports not_set_up', async () => {
  const f = restartFixture(setupRow({ session_id: id }), [unverified()]);
  assert.deepEqual(await f.value.status(request()), { state: 'not_set_up' });
});
void it('setup from another session reports not_set_up before expiry', async () => {
  const f = restartFixture(setupRow({ expires_at: minutes(5) }), [
    unverified(),
  ]);
  assert.deepEqual(await f.value.status(request()), { state: 'not_set_up' });
});
void it('same session within expiry remains pending', async () => {
  const f = restartFixture(
    setupRow({ session_id: id, expires_at: minutes(5) }),
    [unverified()],
  );
  assert.equal((await f.value.status(request())).state, 'pending');
  await assert.rejects(
    f.value.start(request()),
    conflict('Setup already exists'),
  );
  assert.ok(!f.log.includes('claim'));
});
void it('attempt-blocked or verifying setup waits for expiry even after a new sign-in', async () => {
  for (const over of [
    { state: 'blocked', attempts: 5 },
    { state: 'verifying', attempts: 2 },
    { state: 'pending', attempts: 5 },
  ]) {
    const live = restartFixture(setupRow({ ...over, expires_at: minutes(5) }), [
      unverified(),
    ]);
    assert.equal((await live.value.status(request())).state, 'blocked');
    await assert.rejects(
      live.value.start(request()),
      conflict('Setup already exists'),
    );
    assert.ok(!live.log.includes('claim'));
    const later = restartFixture(setupRow(over), [unverified()]);
    assert.equal((await later.value.status(request())).state, 'not_set_up');
  }
});
void it('a verified factor keeps verified-flow status unchanged', async () => {
  const verified = { ...unverified(verifiedFactor), status: 'verified' };
  const stale = restartFixture(setupRow(), [verified, unverified()]);
  assert.equal((await stale.value.status(request())).state, 'blocked');
  const ready = restartFixture(
    setupRow({ state: 'ready', factor_id: verifiedFactor }),
    [verified],
  );
  assert.equal((await ready.value.status(request())).state, 'ready');
  // A ready or restricted binding is never treated as an initial setup.
  const lost = restartFixture(setupRow({ state: 'ready' }), []);
  assert.equal((await lost.value.status(request())).state, 'blocked');
  const restricted = restartFixture(setupRow({ state: 'restricted' }), []);
  assert.deepEqual(await restricted.value.status(request()), {
    state: 'restricted',
  });
});
void it('start restarts an abandoned setup: claim, remove unverified TOTP, enroll', async () => {
  const phone = {
    id: phoneFactor,
    factor_type: 'phone',
    status: 'unverified',
  };
  const f = restartFixture(setupRow({ revision: 3, attempts: 4 }), [
    unverified(),
    phone,
  ]);
  const result = await f.value.start(request());
  assert.equal(result.secret, secret);
  assert.equal(result.revision, 4);
  assert.notEqual(result.requestId, oldRequest);
  assert.deepEqual(f.log, [
    'insert',
    'select',
    'GET /user',
    'claim',
    'GET /user',
    `DELETE /factors/${oldFactor}`,
    'POST /factors',
    'bind',
  ]);
  const row = f.row()!;
  assert.equal(row.request_id, result.requestId);
  assert.equal(row.session_id, id);
  assert.equal(row.state, 'pending');
  assert.equal(row.factor_id, newFactor);
  assert.equal(row.attempts, 0);
  assert.equal(row.revision, 4);
  assert.ok(row.expires_at > minutes(9));
  assert.deepEqual(
    f.factors.map((x) => x.id),
    [phoneFactor, newFactor],
  );
  assert.equal((await f.value.status(request())).state, 'pending');
});
void it('a verified factor refuses restart and changes nothing', async () => {
  const verified = { ...unverified(verifiedFactor), status: 'verified' };
  const initial = setupRow();
  const f = restartFixture(initial, [verified, unverified()]);
  await assert.rejects(
    f.value.start(request()),
    conflict('Existing factors require recovery support.'),
  );
  assert.deepEqual(f.row(), initial);
  assert.deepEqual(f.log, ['insert', 'select', 'GET /user']);
  assert.equal(f.factors.length, 2);
});
void it('a verification finishing after the claim restores the row', async () => {
  const initial = setupRow({ state: 'verifying', attempts: 2 });
  const f = restartFixture(initial, [unverified()], {
    verifyAfterClaim: true,
  });
  await assert.rejects(
    f.value.start(request()),
    conflict('Existing factors require recovery support.'),
  );
  assert.deepEqual(f.row(), initial);
  assert.ok(f.log.includes('revert'));
  assert.ok(!provided(f.log));
});
void it('restart without fresh password evidence has no effects', async () => {
  const f = restartFixture(setupRow(), [unverified()]);
  for (const time of [1, Date.now() / 1000 - 301, Date.now() / 1000 + 3600])
    await assert.rejects(
      f.value.start(request('customer', time)),
      (e) => e instanceof HttpException && e.getStatus() === 403,
    );
  assert.deepEqual(f.log, []);
});
void it('a concurrent start that wins the claim leaves this one with 409', async () => {
  const f = restartFixture(setupRow(), [unverified()], { claimLoses: true });
  await assert.rejects(
    f.value.start(request()),
    conflict('Check setup status.'),
  );
  assert.ok(!provided(f.log));
  assert.equal(f.factors.length, 1);
});
void it('an unenroll failure leaves the claimed row retryable', async () => {
  const f = restartFixture(setupRow(), [unverified()], { failDelete: true });
  await assert.rejects(
    f.value.start(request()),
    (e) => e instanceof HttpException && e.getStatus() === 503,
  );
  assert.equal(f.row()!.state, 'starting');
  assert.equal(f.row()!.factor_id, null);
  assert.ok(!f.log.includes('POST /factors'));
  // Same session before expiry stays paused, so a double tap cannot race.
  assert.equal((await f.value.status(request())).state, 'blocked');
  // Another sign-in (or expiry) makes it restartable again.
  const next = request('customer', undefined, other);
  assert.equal((await f.value.status(next)).state, 'not_set_up');
  const retry = restartFixture(f.row(), f.factors);
  const result = await retry.value.start(next);
  assert.equal(result.secret, secret);
  assert.deepEqual(
    retry.factors.map((x) => x.id),
    [newFactor],
  );
});
void it('a superseded setup never hands out its key', async () => {
  const f = restartFixture(setupRow(), [unverified()], { bindLoses: true });
  await assert.rejects(
    f.value.start(request()),
    (e) =>
      conflict('Check setup status.')(e) &&
      !JSON.stringify((e as HttpException).getResponse()).includes(secret),
  );
});
void it('restart errors and logs carry no secret, code or token', async () => {
  const captured: unknown[] = [];
  const methods = ['log', 'info', 'warn', 'error', 'debug'] as const;
  const originals = methods.map((m) => console[m]);
  for (const m of methods)
    console[m] = (...args: unknown[]) => void captured.push(args);
  const bodies: string[] = [];
  const req = request();
  const token = req.headers.authorization!.slice(7);
  const keep = (e: HttpException) =>
    void bodies.push(JSON.stringify(e.getResponse()));
  try {
    const failing = restartFixture(setupRow(), [unverified()], {
      failDelete: true,
    });
    await failing.value.start(req).catch(keep);
    const ok = restartFixture(setupRow(), [unverified()]);
    const result = await ok.value.start(req);
    await ok.value
      .verify(request('customer', undefined, other), {
        requestId: result.requestId,
        code: '246810',
      })
      .catch(keep);
    bodies.push(JSON.stringify(await ok.value.status(req)));
    assert.ok(failing.tokens.every((t) => t === token));
  } finally {
    methods.forEach((m, i) => (console[m] = originals[i]!));
  }
  assert.equal(bodies.length, 3);
  const text = JSON.stringify(captured) + bodies.join('\n');
  for (const value of [secret, '246810', token])
    assert.ok(!text.includes(value));
});
