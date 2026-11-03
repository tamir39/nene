import 'reflect-metadata';
import assert from 'node:assert/strict';
import { it } from 'node:test';
import {
  AccountHistoryController,
  historyQuery,
} from '../src/accounts/account-history.controller.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
void it('history accepts explicit calendar months and rejects ambiguous filters', () => {
  assert.deepEqual(historyQuery({ month: '2026-11' }), {
    month: '2026-11',
    cursor: null,
  });
  for (const query of [
    {},
    { month: '2026-00' },
    { month: '2026-13' },
    { month: ['2026-11', '2026-12'] },
    { month: '2026-1' },
    { month: '1999-12' },
    { month: '2101-01' },
    { month: '2026-11', ownerId: 'other' },
    { month: '2026-11', cursor: 'bad' },
  ])
    assert.throws(() => historyQuery(query));
});
void it('history rejects officers before reading and hides unknown/other accounts', async () => {
  let reads = 0;
  const api = new AccountHistoryController({
    query: async () => {
      reads++;
      return [];
    },
  } as unknown as DatabaseService);
  const id = 'b3000000-0000-4000-8000-000000000001';
  await assert.rejects(
    api.read({ user: { role: 'officer' } } as AuthenticatedRequest, id, {
      month: '2026-11',
    }),
    (e) => (e as { getStatus(): number }).getStatus() === 403,
  );
  assert.equal(reads, 0);
  await assert.rejects(
    api.read({ user: { role: 'customer', id } } as AuthenticatedRequest, id, {
      month: '2026-11',
    }),
    (e) => (e as { getStatus(): number }).getStatus() === 404,
  );
  assert.equal(reads, 1);
});
