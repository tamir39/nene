import 'reflect-metadata';
import assert from 'node:assert/strict';
import { it } from 'node:test';
import {
  biweeklyDue,
  monthlyProfit,
  withInformation,
} from '../src/accounts/account-information.js';
import {
  rateInput,
  SavingsPolicyController,
} from '../src/accounts/savings-policy.controller.js';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';
import type { DatabaseService } from '../src/database/database.service.js';
void it('monthly estimate uses integer arithmetic, zero and half-up rounding', () => {
  assert.equal(monthlyProfit('10000000', 600), '50000');
  assert.equal(monthlyProfit('0', 600), '0');
  assert.equal(monthlyProfit('100', 600), '1');
  assert.equal(monthlyProfit('99', 600), '0');
  assert.equal(monthlyProfit('9007199254740993000', 1200), '90071992547409930');
});
void it('invalid amounts and rate boundaries are rejected', () => {
  for (const rate of [-1, 2001, 1.5, NaN])
    assert.throws(() => monthlyProfit('100', rate));
  for (const balance of ['-1', '1.5', 'abc'])
    assert.throws(() => monthlyProfit(balance, 100));
  assert.equal(monthlyProfit('100', 0), '0');
});
void it('two-week equivalent spreads the yearly total over 26 payments, rounded up', () => {
  assert.equal(biweeklyDue('4250000'), '1961539');
  assert.equal(biweeklyDue('1000000'), '461539');
  assert.equal(biweeklyDue('333333'), '153846');
  assert.equal(biweeklyDue('13'), '6');
  assert.equal(biweeklyDue('1'), '1');
  assert.equal(biweeklyDue('0'), '0');
  for (let monthly = 0n; monthly <= 2000n; monthly++) {
    const twoWeek = BigInt(biweeklyDue(monthly.toString()));
    const shortfall = twoWeek * 26n - monthly * 12n;
    assert.ok(shortfall >= 0n && shortfall < 26n);
  }
});
void it('two-week equivalent keeps precision beyond 2^53 and rejects malformed input', () => {
  // Floating point would read 2^53 + 1 as 2^53 and yield ...535.
  assert.equal(biweeklyDue('9007199254740993'), '4157168886803536');
  assert.equal(biweeklyDue('999999999999999999999'), '461538461538461538462');
  for (const monthly of ['-1', '1.5', 'abc', '', ' 1'])
    assert.throws(() => biweeklyDue(monthly));
});
void it('mortgage information adds the two-week amount only alongside a monthly amount', () => {
  const mortgage = { type: 'mortgage', balanceMinor: '0' };
  assert.deepEqual(
    withInformation({ ...mortgage, monthlyDueMinor: '4250000' }),
    {
      ...mortgage,
      monthlyDueMinor: '4250000',
      biweeklyDueMinor: '1961539',
    },
  );
  assert.deepEqual(withInformation({ ...mortgage, monthlyDueMinor: null }), {
    ...mortgage,
    monthlyDueMinor: null,
    biweeklyDueMinor: null,
  });
  const checking = {
    type: 'checking',
    balanceMinor: '0',
    monthlyDueMinor: null,
  };
  assert.deepEqual(withInformation(checking), checking);
  assert.equal(
    'biweeklyDueMinor' in
      withInformation({
        type: 'saving',
        balanceMinor: '0',
        annualRateBps: 600,
      }),
    false,
  );
});
void it('rate input rejects forged fields and stale-shaped revisions', () => {
  assert.deepEqual(
    rateInput({ annualRateBps: 600, revision: 1, reason: ' annual review ' }),
    { annualRateBps: 600, revision: 1, reason: 'annual review' },
  );
  for (const patch of [
    { revision: 0 },
    { annualRateBps: 2001 },
    { reason: 'x' },
    { balanceMinor: '1000' },
  ])
    assert.throws(() =>
      rateInput({
        annualRateBps: 600,
        revision: 1,
        reason: 'annual review',
        ...patch,
      }),
    );
});
void it('customers cannot read or update officer policy routes', async () => {
  const controller = new SavingsPolicyController({
    query: () => {
      throw new Error('must not query');
    },
  } as unknown as DatabaseService);
  const req = { user: { role: 'customer' } } as AuthenticatedRequest;
  await assert.rejects(
    controller.read(req),
    (e) => (e as { getStatus(): number }).getStatus() === 403,
  );
  await assert.rejects(
    controller.edit(req, {}),
    (e) => (e as { getStatus(): number }).getStatus() === 403,
  );
});
