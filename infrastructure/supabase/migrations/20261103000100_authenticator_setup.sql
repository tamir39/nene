-- BR-04 support only. No financial authorization or balances are stored here.
create table bank.authenticator_setup (
  customer_id uuid primary key references bank.user_profiles(id),
  request_id uuid not null unique,
  session_id uuid not null,
  factor_id uuid,
  state text not null check (state in ('starting','pending','verifying','ready','blocked')),
  revision integer not null default 1,
  attempts integer not null default 0 check (attempts between 0 and 5),
  expires_at timestamptz not null default now() + interval '10 minutes',
  created_at timestamptz not null default now()
);
alter table bank.authenticator_setup enable row level security;
revoke all on bank.authenticator_setup from public, anon, authenticated, service_role;
grant select, insert, update on bank.authenticator_setup to nene_api;
create policy authenticator_api on bank.authenticator_setup to nene_api using (true) with check (true);
