-- BR-08 read model. No posting API or write privilege is introduced.
create table bank.account_history (
  id uuid primary key,
  account_id uuid not null references bank.banking_accounts(id) on delete restrict,
  operation_id uuid not null,
  kind text not null check(kind in ('deposit','withdrawal','transfer','payment','interest','mortgage_repayment')),
  direction text not null check(direction in ('credit','debit')),
  amount_minor bigint not null check(amount_minor>0),
  currency text not null check(currency ~ '^[A-Z]{3}$'),
  posted_at timestamptz not null,
  unique(operation_id,account_id)
);
create index account_history_page on bank.account_history(account_id,posted_at desc,id desc);
revoke all on bank.account_history from public,anon,authenticated,service_role;
grant select on bank.account_history to nene_api;
alter table bank.account_history enable row level security;
alter table bank.account_history force row level security;
create policy api_read_history on bank.account_history for select to nene_api using(true);
comment on table bank.account_history is 'Posted entries only. Currently read-only; future posting must atomically change balances and append authorized entries. No seeded transactions in the normal demo.';
