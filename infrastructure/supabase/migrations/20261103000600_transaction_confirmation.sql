-- BR-04/09 support only: security metadata, not posted financial transactions.
-- Reviewed account numbers, amounts and tokens stay in the signed client review.
create table bank.transaction_confirmations (
  id uuid primary key,
  customer_id uuid not null references bank.user_profiles(id),
  session_id uuid not null,
  review_digest text not null,
  factor_id uuid not null,
  security_revision integer not null,
  state text not null check(state in ('checking','factor_confirmed','rejected','unknown','cancelled')),
  expires_at timestamptz not null,
  lease_until timestamptz not null default now()+interval '30 seconds',
  confirmed_until timestamptz,
  created_at timestamptz not null default now()
);
create index confirmation_owner on bank.transaction_confirmations(customer_id,created_at);
revoke all on bank.transaction_confirmations from public,anon,authenticated,service_role;
grant select,insert on bank.transaction_confirmations to nene_api;
grant update(state,confirmed_until) on bank.transaction_confirmations to nene_api;
alter table bank.transaction_confirmations enable row level security;
alter table bank.transaction_confirmations force row level security;
create policy confirmation_api on bank.transaction_confirmations to nene_api using(true) with check(true);
comment on table bank.transaction_confirmations is 'One security attempt per signed review. No financial execution, balances, transaction details or provider tokens. Not a consumable payment authorization.';
