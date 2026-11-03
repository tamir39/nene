import 'reflect-metadata';
import assert from 'node:assert/strict';
import { it } from 'node:test';
import {
  demoAccountInput,
  DemoAccountController,
} from '../src/accounts/demo-account.controller.js';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { Environment } from '../src/config/environment.js';
const saving = {
  type: 'saving',
  reason: ' demo view ',
  syntheticConfirmed: true,
};
const mortgage = {
  ...saving,
  type: 'mortgage',
  principalMinor: '1000000',
  termMonths: 3,
  firstDueOn: '2026-12-01',
};
void it('demo inputs normalize reasons and preserve exact integer principal', () => {
  assert.deepEqual(demoAccountInput(saving), {
    ...saving,
    reason: 'demo view',
  });
  assert.deepEqual(demoAccountInput(mortgage), {
    ...mortgage,
    reason: 'demo view',
  });
  assert.equal(
    demoAccountInput({ ...mortgage, firstDueOn: '2028-02-29' }).type,
    'mortgage',
  );
});
void it('demo inputs reject money injection, invalid dates and missing acknowledgement', () => {
  for (const patch of [
    { type: 'checking' },
    { balanceMinor: '1' },
    { syntheticConfirmed: false },
    { reason: 'x' },
    { reason: 'line\nbreak' },
  ])
    assert.throws(() => demoAccountInput({ ...saving, ...patch }));
  for (const patch of [
    { principalMinor: '0' },
    { principalMinor: '1', termMonths: 2 },
    { principalMinor: '01' },
    { principalMinor: 100 },
    { principalMinor: '1000000000001' },
    { principalMinor: '1.2' },
    { termMonths: 0 },
    { termMonths: 361 },
    { termMonths: 1.5 },
    { firstDueOn: '2026-02-29' },
    { firstDueOn: '2026-04-31' },
    { firstDueOn: '1999-12-31' },
    { firstDueOn: '2101-01-01' },
    { firstDueOn: 'bad' },
  ])
    assert.throws(() => demoAccountInput({ ...mortgage, ...patch }));
});
void it('demo endpoint denies customers, production and hosted Auth before touching the database', async () => {
  const db = {
    transaction: () => {
      throw new Error('must not access DB');
    },
  } as unknown as DatabaseService;
  for (const [role, nodeEnv, supabaseUrl] of [
    ['customer', 'development', 'http://127.0.0.1:45321'],
    ['officer', 'production', 'http://localhost:45321'],
    ['officer', 'development', 'https://example.supabase.co'],
  ]) {
    const api = new DemoAccountController(db, {
      nodeEnv,
      supabaseUrl,
    } as Environment);
    await assert.rejects(
      api.create({ user: { role } } as AuthenticatedRequest, 'bad', 'bad', {}),
      (e) => (e as { getStatus(): number }).getStatus() === 403,
    );
  }
});
