-- BR-05/06/07: read-only financial information and officer-controlled rates.
create table bank.savings_policy (
  id boolean primary key default true check(id),
  annual_rate_bps integer not null check(annual_rate_bps between 0 and 2000),
  revision integer not null default 1 check(revision>0),
  updated_at timestamptz not null default now()
);
insert into bank.savings_policy(id,annual_rate_bps) values(true,0);
create table bank.savings_rate_audit (
  id bigint generated always as identity primary key,
  officer_id uuid not null references bank.user_profiles(id),
  old_bps integer not null,
  new_bps integer not null,
  revision integer not null unique,
  reason text not null check(length(btrim(reason)) between 5 and 500),
  created_at timestamptz not null default now()
);
-- A schedule supplied by trusted account administration; no origination or repayment API.
create table bank.mortgage_schedule (
  account_id uuid primary key references bank.banking_accounts(id),
  principal_remaining_minor bigint not null check(principal_remaining_minor>=0),
  monthly_due_minor bigint not null check(monthly_due_minor>=0),
  next_due_on date not null
);
revoke all on bank.savings_policy, bank.savings_rate_audit, bank.mortgage_schedule from public,anon,authenticated,service_role;
revoke all on sequence bank.savings_rate_audit_id_seq from public,anon,authenticated,service_role;
grant select on bank.savings_policy, bank.mortgage_schedule to nene_api;
grant update(annual_rate_bps,revision,updated_at) on bank.savings_policy to nene_api;
grant insert(officer_id,old_bps,new_bps,revision,reason) on bank.savings_rate_audit to nene_api;
grant usage on sequence bank.savings_rate_audit_id_seq to nene_api;
alter table bank.savings_policy enable row level security;
alter table bank.savings_policy force row level security;
alter table bank.savings_rate_audit enable row level security;
alter table bank.savings_rate_audit force row level security;
alter table bank.mortgage_schedule enable row level security;
alter table bank.mortgage_schedule force row level security;
create policy savings_read on bank.savings_policy for select to nene_api using(true);
create policy savings_edit on bank.savings_policy for update to nene_api using(true) with check(true);
create policy savings_audit on bank.savings_rate_audit for insert to nene_api with check(exists(select 1 from bank.user_profiles where id=officer_id and role='officer' and status='active'));
create policy mortgage_read on bank.mortgage_schedule for select to nene_api using(true);
