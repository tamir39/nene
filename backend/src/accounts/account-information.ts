/** Simple monthly estimate, nearest minor unit, half up. No interest posting. */
export function monthlyProfit(balance: string, annualBps: number): string {
  if (
    !/^\d+$/.test(balance) ||
    !Number.isInteger(annualBps) ||
    annualBps < 0 ||
    annualBps > 2000
  )
    throw new Error('Invalid savings calculation inputs.');
  return ((BigInt(balance) * BigInt(annualBps) + 60000n) / 120000n).toString();
}

export const informationColumns = `
  case when type='saving' then (select annual_rate_bps from bank.savings_policy where id) end as "annualRateBps",
  case when type='saving' then (select revision from bank.savings_policy where id) end as "rateRevision",
  case when type='mortgage' then (select principal_remaining_minor::text from bank.mortgage_schedule where account_id=banking_accounts.id) end as "principalRemainingMinor",
  case when type='mortgage' then (select monthly_due_minor::text from bank.mortgage_schedule where account_id=banking_accounts.id) end as "monthlyDueMinor",
  case when type='mortgage' then (select to_char(next_due_on,'YYYY-MM-DD') from bank.mortgage_schedule where account_id=banking_accounts.id) end as "nextDueOn"`;

export function withInformation<
  T extends {
    type: string;
    balanceMinor: string;
    annualRateBps?: number | null;
  },
>(account: T) {
  return account.type === 'saving' && account.annualRateBps != null
    ? {
        ...account,
        monthlyProfitMinor: monthlyProfit(
          account.balanceMinor,
          account.annualRateBps,
        ),
      }
    : account;
}
