import 'reflect-metadata';
import assert from 'node:assert/strict';
import { it } from 'node:test';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { Environment } from '../src/config/environment.js';
import { SecurityService } from '../src/security/security.service.js';
import { SecurityManagementService } from '../src/security/security-management.service.js';

const id = '11111111-1111-4111-8111-111111111111';
function request(role = 'customer', timestamp = Date.now() / 1000) {
  return {
    user: { id, role },
    headers: {
      authorization: `Bearer x.${Buffer.from(JSON.stringify({ sub: id, session_id: id, amr: [{ method: 'password', timestamp }] })).toString('base64url')}.x`,
    },
  } as AuthenticatedRequest;
}
function fixture() {
  let queries = 0,
    providerCalls = 0;
  const db = {
    query: async () => {
      queries++;
      return [];
    },
  } as unknown as DatabaseService;
  const security = new SecurityService(db, {} as Environment);
  security.provider = async () => {
    providerCalls++;
    throw new Error('Unexpected provider call');
  };
  return {
    service: new SecurityManagementService(db, security),
    calls: () => queries + providerCalls,
  };
}
void it('all management entry points deny officers before side effects', async () => {
  const { service, calls } = fixture(),
    req = request('officer');
  for (const action of [
    () => service.status(req),
    () => service.start(req, { purpose: 'recover' }),
    () => service.prove(req, { requestId: id, code: '12345678' }),
    () => service.enroll(req, { requestId: id }),
    () => service.verify(req, { requestId: id, code: '123456' }),
    () => service.issue(req, { requestId: id, code: '123456' }),
    () => service.finish(req, { requestId: id, saved: true }),
    () => service.cancel(req, { requestId: id }),
  ])
    await assert.rejects(
      action,
      (e) => (e as { getStatus(): number }).getStatus() === 403,
    );
  assert.equal(calls(), 0);
});
void it('refresh-time or stale/future password evidence cannot start management', async () => {
  const { service, calls } = fixture();
  for (const time of [0, Date.now() / 1000 - 301, Date.now() / 1000 + 3600])
    await assert.rejects(
      service.start(request('customer', time), { purpose: 'replace' }),
    );
  assert.equal(calls(), 0);
});
void it('caller-selected factors, revisions and invalid purposes cannot start management', async () => {
  const { service, calls } = fixture();
  for (const body of [
    { purpose: 'reset' },
    { purpose: 'replace', factorId: id },
    { purpose: 'recover', revision: 1 },
  ])
    await assert.rejects(service.start(request(), body));
  assert.equal(calls(), 0);
});
void it('malformed codes and missing save acknowledgement have no effects', async () => {
  const { service, calls } = fixture();
  await assert.rejects(
    service.verify(request(), { requestId: id, code: '123' }),
  );
  await assert.rejects(
    service.issue(request(), { requestId: id, code: '123456', factorId: id }),
  );
  await assert.rejects(
    service.finish(request(), { requestId: id, saved: false }),
  );
  assert.equal(calls(), 0);
});
void it('fresh password is required even to cancel an expired unverified change', async () => {
  const { service, calls } = fixture();
  await assert.rejects(
    service.cancel(request('customer', 0), { requestId: id }),
  );
  assert.equal(calls(), 0);
});
