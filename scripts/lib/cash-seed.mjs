// Explicit local test funding only; never called by customer routes/migrations.
export function cashSeedSql(account) {
  if (!/^\d{12}$/.test(account ?? ""))
    throw new Error("A 12-digit account number is required");
  return `begin;
    do $$ declare a bank.banking_accounts%rowtype;begin
      select * into a from bank.banking_accounts where account_number=${account} for update;
      if not found or a.type not in ('checking','saving') or a.currency<>'VND' or a.status<>'active' then raise exception 'Eligible account required';end if;
      perform 1 from bank.user_profiles where id=a.owner_id and role='customer' and status='active' and email like '%@example.invalid' for share;
      if not found then raise exception 'Synthetic customer required';end if;
      if not a.is_demo and (a.balance_minor<>0 or exists(select 1 from bank.account_history where account_id=a.id)) then raise exception 'Unprepared account already funded';end if;
      insert into bank.demo_cash_balances(customer_id,balance_minor) values(a.owner_id,3000000) on conflict(customer_id) do nothing;
      update bank.banking_accounts set is_demo=true where id=a.id;
      update bank.local_cash_settings set enabled=true where id;
    end $$;commit;`;
}
