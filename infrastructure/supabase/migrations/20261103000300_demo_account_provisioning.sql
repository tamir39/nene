-- BR-02/05/07 demo support. No balance grant, disbursement or repayment.
alter table bank.banking_accounts add column is_demo boolean not null default false;
grant insert(is_demo) on bank.banking_accounts to nene_api;
create unique index one_demo_account_type on bank.banking_accounts(owner_id,type)
  where is_demo and type in ('saving','mortgage');
alter table bank.mortgage_schedule add column term_months integer check(term_months between 1 and 360);
grant insert(account_id,principal_remaining_minor,monthly_due_minor,next_due_on,term_months) on bank.mortgage_schedule to nene_api;
create policy demo_mortgage_insert on bank.mortgage_schedule for insert to nene_api with check(
  term_months is not null and principal_remaining_minor>0 and principal_remaining_minor<=1000000000000
  and principal_remaining_minor>=term_months
  and monthly_due_minor=principal_remaining_minor/term_months
  and exists(select 1 from bank.banking_accounts where id=account_id and type='mortgage' and is_demo and currency='VND' and balance_minor=0)
);
create table bank.demo_account_requests (
  officer_id uuid not null references bank.user_profiles(id),
  request_id uuid not null,
  customer_id uuid not null references bank.user_profiles(id),
  account_id uuid not null unique references bank.banking_accounts(id),
  payload jsonb not null,
  created_at timestamptz not null default now(),
  primary key(officer_id,request_id)
);
revoke all on bank.demo_account_requests from public,anon,authenticated,service_role;
grant select,insert on bank.demo_account_requests to nene_api;
alter table bank.demo_account_requests enable row level security;
alter table bank.demo_account_requests force row level security;
create policy demo_request_read on bank.demo_account_requests for select to nene_api using(true);
create policy demo_request_insert on bank.demo_account_requests for insert to nene_api with check(
  exists(select 1 from bank.user_profiles where id=officer_id and role='officer' and status='active')
  and exists(select 1 from bank.banking_accounts where id=account_id and owner_id=customer_id and is_demo and balance_minor=0)
);
