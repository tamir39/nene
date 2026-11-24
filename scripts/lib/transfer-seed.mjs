// Used only by the explicit local CLI and its isolated test fixture.
export function transferSeedSql(source, recipient) {
  if (
    !/^\d{12}$/.test(source ?? "") ||
    !/^\d{12}$/.test(recipient ?? "") ||
    source === recipient
  )
    throw new Error("Two different 12-digit account numbers required");
  return `begin;
    do $$ declare s bank.banking_accounts%rowtype;d bank.banking_accounts%rowtype;begin
      perform 1 from bank.banking_accounts where account_number in(${source},${recipient}) order by id for update;
      select * into s from bank.banking_accounts where account_number=${source};select * into d from bank.banking_accounts where account_number=${recipient};
      if s.id is null or d.id is null or s.type<>'checking' or d.type<>'checking' or s.currency<>'VND' or d.currency<>'VND' or s.status<>'active' or d.status<>'active' then raise exception 'Synthetic checking accounts required';end if;
      if (select count(*) from bank.user_profiles where id in(s.owner_id,d.owner_id) and status='active' and role='customer' and email like '%@example.invalid') <> (case when s.owner_id=d.owner_id then 1 else 2 end) then raise exception 'Synthetic profiles required';end if;
      if exists(select 1 from bank.demo_transfer_seeds where source_id=s.id and recipient_id=d.id) then return;end if;
      if s.balance_minor<>0 or exists(select 1 from bank.account_history where account_id=s.id) or exists(select 1 from bank.demo_transfer_seeds where source_id=s.id) then raise exception 'Seed cannot reset or top up an account';end if;
      if not d.is_demo and (d.balance_minor<>0 or exists(select 1 from bank.account_history where account_id=d.id)) then raise exception 'Recipient must be an empty or prepared demo account';end if;
      update bank.banking_accounts set is_demo=true where id in(s.id,d.id);
      update bank.banking_accounts set balance_minor=3000000 where id=s.id;
      insert into bank.demo_transfer_seeds(source_id,recipient_id,amount_minor) values(s.id,d.id,3000000);
      update bank.local_transfer_settings set enabled=true where id;
    end $$;commit;`;
}
