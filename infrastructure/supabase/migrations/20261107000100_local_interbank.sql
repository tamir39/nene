-- BR-04/08/09: local simulation of a transfer to a fictional other bank.
-- These recipients are NOT Nene banking accounts or a real payment network.
alter table bank.transaction_confirmations drop constraint transaction_confirmations_purpose_check;
alter table bank.transaction_confirmations add constraint transaction_confirmations_purpose_check
  check(purpose in ('preview','local_transfer','local_deposit','local_withdrawal','local_interbank'));
alter table bank.account_history drop constraint account_history_kind_check;
alter table bank.account_history add constraint account_history_kind_check
  check(kind in ('deposit','withdrawal','transfer','interbank_transfer','payment','interest','mortgage_repayment'));

create table bank.local_interbank_settings (
  id boolean primary key check(id),
  enabled boolean not null default false
);
insert into bank.local_interbank_settings values(true,false);
create table bank.demo_external_banks (
  code text primary key check(code ~ '^DEMO_[A-Z0-9_]+$'),
  name text not null check(name like 'Demo %'),
  active boolean not null default true
);
create table bank.demo_external_recipients (
  id uuid primary key,
  bank_code text not null references bank.demo_external_banks(code),
  account_number text not null check(account_number ~ '^99[0-9]{10}$'),
  recipient_name text not null check(recipient_name like 'Demo %'),
  active boolean not null default true,
  balance_minor bigint not null default 0 check(balance_minor>=0),
  unique(bank_code,account_number)
);
insert into bank.demo_external_banks(code,name) values
  ('DEMO_A','Demo Bank A'),('DEMO_B','Demo Bank B');
insert into bank.demo_external_recipients(id,bank_code,account_number,recipient_name) values
  ('99000000-0000-4000-8000-000000000001','DEMO_A','990000000001','Demo recipient A'),
  ('99000000-0000-4000-8000-000000000002','DEMO_B','990000000002','Demo recipient B');
create table bank.local_interbank_transfers (
  id uuid primary key references bank.transaction_confirmations(id),
  customer_id uuid not null references bank.user_profiles(id),
  source_account_id uuid not null references bank.banking_accounts(id),
  destination_recipient_id uuid not null references bank.demo_external_recipients(id),
  destination_bank_code text not null references bank.demo_external_banks(code),
  destination_bank_name text not null,
  destination_account_number text not null,
  destination_recipient_name text not null,
  amount_minor bigint not null check(amount_minor>0 and amount_minor<5000000),
  currency text not null check(currency='VND'),
  simulated boolean not null default true check(simulated),
  posted_at timestamptz not null default clock_timestamp()
);
revoke all on bank.local_interbank_settings,bank.demo_external_banks,bank.demo_external_recipients,bank.local_interbank_transfers
  from public,anon,authenticated,service_role,nene_api;
grant select on bank.local_interbank_settings,bank.demo_external_banks,bank.demo_external_recipients,bank.local_interbank_transfers to nene_api;
alter table bank.demo_external_banks enable row level security;
alter table bank.demo_external_banks force row level security;
create policy api_read_external_banks on bank.demo_external_banks for select to nene_api using(true);
alter table bank.demo_external_recipients enable row level security;
alter table bank.demo_external_recipients force row level security;
create policy api_read_external_recipients on bank.demo_external_recipients for select to nene_api using(true);
alter table bank.local_interbank_transfers enable row level security;
alter table bank.local_interbank_transfers force row level security;
create policy api_read_interbank_transfers on bank.local_interbank_transfers for select to nene_api using(true);

create function bank.post_local_interbank(
  p_id uuid,p_customer uuid,p_session uuid,p_digest text,p_source uuid,p_destination uuid,
  p_bank_code text,p_bank_name text,p_account_number text,p_recipient_name text,p_amount bigint,
  p_case uuid,p_version integer,p_revision integer,p_evidence uuid
) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare
  c bank.transaction_confirmations%rowtype;
  s bank.banking_accounts%rowtype;
  d bank.demo_external_recipients%rowtype;
  b bank.demo_external_banks%rowtype;
  t timestamptz;
begin
  perform 1 from bank.local_interbank_settings where id and enabled for share;
  if not found then raise exception 'Local other-bank simulation disabled';end if;
  if p_id is null or p_customer is null or p_session is null or p_digest is null or
     p_source is null or p_destination is null or p_bank_code is null or p_bank_name is null or
     p_account_number is null or p_recipient_name is null or p_amount is null or
     p_case is null or p_version is null or p_revision is null or p_evidence is null or
     p_amount<=0 or p_amount>=5000000 then raise exception 'Unsupported transfer';end if;
  select * into c from bank.transaction_confirmations where id=p_id for update;
  if not found or c.customer_id is distinct from p_customer or c.session_id is distinct from p_session or
     c.review_digest is distinct from p_digest or c.purpose is distinct from 'local_interbank'
     then raise exception 'Invalid proof binding';end if;
  if c.state='posted' then
    if not exists(select 1 from bank.local_interbank_transfers where id=p_id and customer_id=p_customer and
      source_account_id=p_source and destination_recipient_id=p_destination and
      destination_bank_code=p_bank_code and destination_bank_name=p_bank_name and
      destination_account_number=p_account_number and destination_recipient_name=p_recipient_name and
      amount_minor=p_amount and currency='VND' and simulated)
      then raise exception 'Changed posted details';end if;
    return;
  end if;
  if c.state is distinct from 'factor_confirmed' or c.confirmed_until is null or
     c.confirmed_until<=clock_timestamp() or c.expires_at<=clock_timestamp() or
     c.lease_until<=clock_timestamp() then raise exception 'Proof unavailable';end if;
  perform 1 from bank.authenticator_setup where customer_id=p_customer and state='ready' and
    factor_id=c.factor_id and revision=c.security_revision for update;
  if not found then raise exception 'Security changed';end if;
  -- Every financial path locks the source account before its balance is read.
  -- No second Nene account exists for this simulated external recipient.
  select * into s from bank.banking_accounts where id=p_source for update;
  if not found or s.owner_id is distinct from p_customer or s.is_demo is distinct from true or
     s.type is distinct from 'checking' or s.currency is distinct from 'VND' or
     s.status is distinct from 'active' or s.balance_minor<p_amount
     then raise exception 'Account or funds unavailable';end if;
  perform 1 from bank.user_profiles where id=p_customer and status='active' and role='customer' and
    email like '%@example.invalid' for share;
  if not found then raise exception 'Synthetic profile required';end if;
  select * into b from bank.demo_external_banks where code=p_bank_code for share;
  if not found or b.active is distinct from true or b.name is distinct from p_bank_name
    then raise exception 'Demo bank changed or unavailable';end if;
  select * into d from bank.demo_external_recipients where id=p_destination for update;
  if not found or d.active is distinct from true or d.bank_code is distinct from p_bank_code or
     d.account_number is distinct from p_account_number or d.recipient_name is distinct from p_recipient_name or
     d.balance_minor>9223372036854775807-p_amount
     then raise exception 'Demo recipient changed or unavailable';end if;
  perform 1 from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id
    join bank.user_profiles p on p.id=i.customer_id
    where i.id=p_case and i.customer_id=p_customer and i.version=p_version and i.revision=p_revision and
      i.evidence_id=p_evidence and i.state='reference_accepted' and i.profile_name=p.display_name and
      i.expires_at>clock_timestamp() and e.case_id=i.id and e.revision=i.revision and e.status='ready' and
      e.deleted_at is null and e.expires_at>clock_timestamp() for share of i,e;
  if not found then raise exception 'Reference unavailable';end if;
  -- Time is checked again after all potentially blocking locks.
  if not exists(select 1 from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id
    where i.id=p_case and i.expires_at>clock_timestamp() and e.expires_at>clock_timestamp())
    then raise exception 'Reference expired';end if;
  if c.confirmed_until<=clock_timestamp() or c.expires_at<=clock_timestamp() or c.lease_until<=clock_timestamp()
    then raise exception 'Proof expired';end if;
  t:=clock_timestamp();
  update bank.banking_accounts set balance_minor=balance_minor-p_amount where id=p_source;
  update bank.demo_external_recipients set balance_minor=balance_minor+p_amount where id=p_destination;
  insert into bank.local_interbank_transfers(id,customer_id,source_account_id,destination_recipient_id,
    destination_bank_code,destination_bank_name,destination_account_number,destination_recipient_name,
    amount_minor,currency,simulated,posted_at)
    values(p_id,p_customer,p_source,p_destination,p_bank_code,p_bank_name,p_account_number,p_recipient_name,
      p_amount,'VND',true,t);
  insert into bank.account_history(id,account_id,operation_id,kind,direction,amount_minor,currency,posted_at)
    values(gen_random_uuid(),p_source,p_id,'interbank_transfer','debit',p_amount,'VND',t);
  update bank.transaction_confirmations set state='posted' where id=p_id;
end $$;
revoke all on function bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid)
  from public,anon,authenticated,service_role;
grant execute on function bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid) to nene_api;
comment on table bank.demo_external_recipients is 'Fictional external recipients with local simulation balances only; not Nene accounts, real bank accounts, funding sources or a payment integration.';
comment on table bank.local_interbank_transfers is 'Immutable local simulation receipts. No external network, real beneficiary credit or settlement occurred.';
