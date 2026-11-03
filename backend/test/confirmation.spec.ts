import 'reflect-metadata';
import assert from 'node:assert/strict';
import { it } from 'node:test';
import {
  transferInput,
  ConfirmationService,
} from '../src/confirmation/confirmation.service.js';
import { SecurityService } from '../src/security/security.service.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { Environment } from '../src/config/environment.js';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
const body = {
  sourceAccountId: '10000000-0000-4000-8000-000000000001',
  destinationAccountNumber: '100000000002',
  amountMinor: '100000',
};
void it('transfer review accepts only exact account and integer VND fields', () => {
  assert.equal(transferInput(body).amountMinor, '100000');
  for (const amountMinor of [
    '0',
    '-1',
    '1.5',
    '01',
    '1e6',
    '9000000000000001',
    1000,
  ])
    assert.throws(() => transferInput({ ...body, amountMinor }));
  for (const extra of [
    { factorId: body.sourceAccountId },
    { feeMinor: '0' },
    { currency: 'USD' },
    { customerId: body.sourceAccountId },
    { identityVerified: true },
  ])
    assert.throws(() => transferInput({ ...body, ...extra }));
  assert.throws(() =>
    transferInput({ ...body, destinationAccountNumber: '123' }),
  );
});
void it('officers cannot access confirmation review, status, cancel or proof', async () => {
  const db = {
    query: () => {
      throw new Error('Must not reach data');
    },
  } as unknown as DatabaseService;
  const security = new SecurityService(db, {} as Environment),
    service = new ConfirmationService(db, security);
  const req = {
    user: { role: 'officer' },
    headers: {},
  } as AuthenticatedRequest;
  for (const call of [
    () => service.review(req, body),
    () => service.status(req, body.sourceAccountId),
    () => service.cancel(req, { reviewToken: 'x' }),
    () => service.confirm(req, { reviewToken: 'x', code: '123456' }),
  ])
    await assert.rejects(
      call,
      (e) => (e as { getStatus(): number }).getStatus() === 403,
    );
});
void it('recovery codes and arbitrary challenges cannot confirm a transfer', async () => {
  const service = new ConfirmationService(
    {} as DatabaseService,
    {} as SecurityService,
  );
  const req = {} as AuthenticatedRequest;
  for (const input of [
    { reviewToken: 'x', code: 'BACKUP-CODE' },
    { reviewToken: 'x', code: '123456', challengeId: body.sourceAccountId },
  ])
    await assert.rejects(
      service.confirm(req, input),
      (e) => (e as { getStatus(): number }).getStatus() === 400,
    );
});
