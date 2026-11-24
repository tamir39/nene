-- BR-04/08: bounded local cash simulation, not external settlement.
alter table bank.transaction_confirmations drop constraint transaction_confirmations_purpose_check;
alter table bank.transaction_confirmations add constraint transaction_confirmations_purpose_check
  check(purpose in ('preview','local_transfer','local_deposit','local_withdrawal'));

create table bank.local_cash_settings(id boolean primary key check(id), enabled boolean not null default false);
insert into bank.local_cash_settings values(true,false);
-- One simulated cash balance per customer, shared across all eligible accounts.
-- Explicit CLI preparation creates it once; the app cannot seed or top it up.
create table bank.demo_cash_balances(
  customer_id uuid primary key references bank.user_profiles(id),
  balance_minor bigint not null check(balance_minor>=0),
  opening_minor bigint not null default 3000000 check(opening_minor=3000000),
  created_at timestamptz not null default now()
);
create table bank.local_cash_operations(
  id uuid primary key references bank.transaction_confirmations(id),
  customer_id uuid not null references bank.user_profiles(id),
  account_id uuid not null references bank.banking_accounts(id),
  kind text not null check(kind in ('deposit','withdrawal')),
  amount_minor bigint not null check(amount_minor>0 and amount_minor<5000000),
  currency text not null check(currency='VND'),
  posted_at timestamptz not null default clock_timestamp()
);
revoke all on bank.local_cash_settings,bank.demo_cash_balances,bank.local_cash_operations from public,anon,authenticated,service_role,nene_api;
grant select on bank.local_cash_settings,bank.demo_cash_balances,bank.local_cash_operations to nene_api;
alter table bank.demo_cash_balances enable row level security;
alter table bank.demo_cash_balances force row level security;
create policy api_read_demo_cash on bank.demo_cash_balances for select to nene_api using(true);
alter table bank.local_cash_operations enable row level security;
alter table bank.local_cash_operations force row level security;
create policy api_read_cash_operations on bank.local_cash_operations for select to nene_api using(true);

create function bank.post_local_cash(p_id uuid,p_customer uuid,p_session uuid,p_digest text,p_account uuid,p_kind text,p_amount bigint,p_case uuid,p_version integer,p_revision integer,p_evidence uuid)
returns void language plpgsql security definer set search_path=pg_catalog as $$
declare c bank.transaction_confirmations%rowtype; a bank.banking_accounts%rowtype; cash bigint; t timestamptz;
begin
  if not exists(select 1 from bank.local_cash_settings where id and enabled) then raise exception 'Local cash disabled';end if;
  if p_kind is null or p_kind not in ('deposit','withdrawal') or p_amount is null or p_amount<=0 or p_amount>=5000000 then raise exception 'Unsupported operation';end if;
  select * into c from bank.transaction_confirmations where id=p_id for update;
  if not found or c.customer_id is distinct from p_customer or c.session_id is distinct from p_session or c.review_digest is distinct from p_digest or c.purpose is distinct from 'local_'||p_kind then raise exception 'Invalid proof binding';end if;
  if c.state='posted' then
    if not exists(select 1 from bank.local_cash_operations where id=p_id and account_id=p_account and kind=p_kind and amount_minor=p_amount) then raise exception 'Changed posted details';end if;
    return;
  end if;
  if c.state<>'factor_confirmed' or c.confirmed_until is null or c.confirmed_until<=clock_timestamp() or c.expires_at<=clock_timestamp() then raise exception 'Proof unavailable';end if;
  perform 1 from bank.authenticator_setup where customer_id=p_customer and state='ready' and factor_id=c.factor_id and revision=c.security_revision for update;
  if not found then raise exception 'Security changed';end if;
  select * into a from bank.banking_accounts where id=p_account for update;
  if not found or a.owner_id<>p_customer or not a.is_demo or a.type not in ('checking','saving') or a.currency<>'VND' or a.status<>'active' then raise exception 'Account unavailable';end if;
  perform 1 from bank.user_profiles where id=p_customer and status='active' and role='customer' and email like '%@example.invalid' for share;
  if not found then raise exception 'Synthetic profile required';end if;
  select balance_minor into cash from bank.demo_cash_balances where customer_id=p_customer for update;
  if not found then raise exception 'Cash simulation not prepared';end if;
  if (p_kind='deposit' and (cash<p_amount or a.balance_minor>9223372036854775807-p_amount)) or
     (p_kind='withdrawal' and (a.balance_minor<p_amount or cash>9223372036854775807-p_amount)) then raise exception 'Funds unavailable';end if;
  perform 1 from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id join bank.user_profiles p on p.id=i.customer_id
    where i.id=p_case and i.customer_id=p_customer and i.version=p_version and i.revision=p_revision and i.evidence_id=p_evidence and i.state='reference_accepted' and i.profile_name=p.display_name and i.expires_at>clock_timestamp()
      and e.case_id=i.id and e.revision=i.revision and e.status='ready' and e.deleted_at is null and e.expires_at>clock_timestamp() for share of i,e;
  if not found then raise exception 'Reference unavailable';end if;
  if not exists(select 1 from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id where i.id=p_case and i.expires_at>clock_timestamp() and e.expires_at>clock_timestamp()) then raise exception 'Reference expired';end if;
  if c.confirmed_until<=clock_timestamp() or c.expires_at<=clock_timestamp() or c.lease_until<=clock_timestamp() then raise exception 'Proof expired';end if;
  t:=clock_timestamp();
  update bank.banking_accounts set balance_minor=balance_minor+(case when p_kind='deposit' then p_amount else -p_amount end) where id=p_account;
  update bank.demo_cash_balances set balance_minor=balance_minor+(case when p_kind='deposit' then -p_amount else p_amount end) where customer_id=p_customer;
  insert into bank.local_cash_operations(id,customer_id,account_id,kind,amount_minor,currency,posted_at) values(p_id,p_customer,p_account,p_kind,p_amount,'VND',t);
  insert into bank.account_history(id,account_id,operation_id,kind,direction,amount_minor,currency,posted_at)
    values(gen_random_uuid(),p_account,p_id,p_kind,case when p_kind='deposit' then 'credit' else 'debit' end,p_amount,'VND',t);
  update bank.transaction_confirmations set state='posted' where id=p_id;
end $$;
revoke all on function bank.post_local_cash(uuid,uuid,uuid,text,uuid,text,bigint,uuid,integer,integer,uuid) from public,anon,authenticated,service_role;
grant execute on function bank.post_local_cash(uuid,uuid,uuid,text,uuid,text,bigint,uuid,integer,integer,uuid) to nene_api;
comment on table bank.demo_cash_balances is 'Bounded local simulation of cash outside bank accounts; not a wallet product or real funding/settlement provider.';
