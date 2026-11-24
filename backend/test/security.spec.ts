import 'reflect-metadata';
import assert from 'node:assert/strict';
import { it } from 'node:test';
import { SecurityService } from '../src/security/security.service.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { Environment } from '../src/config/environment.js';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
const id = '11111111-1111-4111-8111-111111111111';
function request(role = 'customer', time = Date.now() / 1000) {
  return {
    user: { id, role },
    headers: {
      authorization: `Bearer x.${Buffer.from(JSON.stringify({ sub: id, session_id: id, amr: [{ method: 'password', timestamp: time }] })).toString('base64url')}.x`,
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
