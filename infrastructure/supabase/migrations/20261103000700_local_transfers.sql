-- BR-04/08/09: explicitly enabled synthetic local same-bank transfers only.
alter table bank.transaction_confirmations add column purpose text not null default 'preview' check(purpose in ('preview','local_transfer'));
alter table bank.transaction_confirmations drop constraint transaction_confirmations_state_check;
alter table bank.transaction_confirmations add constraint transaction_confirmations_state_check check(state in ('checking','factor_confirmed','rejected','unknown','cancelled','posted'));
comment on table bank.transaction_confirmations is 'Security metadata only. Preview purpose never authorizes money. Local-transfer purpose may be consumed atomically with an immutable receipt after verified TOTP; no provider tokens or review details are stored here.';
create table bank.local_transfer_settings(id boolean primary key check(id),enabled boolean not null default false);
insert into bank.local_transfer_settings values(true,false);
create table bank.demo_transfer_seeds(source_id uuid primary key references bank.banking_accounts(id),recipient_id uuid not null references bank.banking_accounts(id),amount_minor bigint not null check(amount_minor=3000000),created_at timestamptz not null default now());
create table bank.local_transfers(
  id uuid primary key references bank.transaction_confirmations(id),
  customer_id uuid not null references bank.user_profiles(id),
  source_id uuid not null references bank.banking_accounts(id),
  destination_id uuid not null references bank.banking_accounts(id),
  amount_minor bigint not null check(amount_minor>0 and amount_minor<5000000),
  currency text not null check(currency='VND'),
  posted_at timestamptz not null default clock_timestamp(),
  check(source_id<>destination_id)
);
revoke all on bank.local_transfer_settings,bank.demo_transfer_seeds,bank.local_transfers from public,anon,authenticated,service_role,nene_api;
grant select on bank.local_transfer_settings,bank.local_transfers to nene_api;
alter table bank.local_transfers enable row level security;
alter table bank.local_transfers force row level security;
create policy read_local_transfer on bank.local_transfers for select to nene_api using(true);

-- Only this narrowly scoped function may change financial balances/history.
-- It consumes a server-verified, non-preview proof and commits every write together.
create function bank.post_local_transfer(p_id uuid,p_customer uuid,p_session uuid,p_digest text,p_source uuid,p_destination uuid,p_amount bigint,p_case uuid,p_version integer,p_revision integer,p_evidence uuid)
returns void language plpgsql security definer set search_path=pg_catalog as $$
declare c bank.transaction_confirmations%rowtype; s bank.banking_accounts%rowtype; d bank.banking_accounts%rowtype; t timestamptz;
begin
  if not exists(select 1 from bank.local_transfer_settings where id and enabled) then raise exception 'Local transfers disabled'; end if;
  if p_amount<=0 or p_amount>=5000000 or p_source=p_destination then raise exception 'Unsupported transfer'; end if;
  select * into c from bank.transaction_confirmations where id=p_id for update;
  if not found or c.customer_id<>p_customer or c.session_id<>p_session or c.review_digest<>p_digest or c.purpose<>'local_transfer' then raise exception 'Invalid proof binding'; end if;
  if c.state='posted' then
    if not exists(select 1 from bank.local_transfers where id=p_id and source_id=p_source and destination_id=p_destination and amount_minor=p_amount) then raise exception 'Changed posted details';end if;
    return;
  end if;
  if c.state<>'factor_confirmed' or c.confirmed_until is null or c.confirmed_until<=clock_timestamp() or c.expires_at<=clock_timestamp() then raise exception 'Proof unavailable';end if;
  perform 1 from bank.authenticator_setup where customer_id=p_customer and state='ready' and factor_id=c.factor_id and revision=c.security_revision for update;
  if not found then raise exception 'Security changed';end if;
  -- Stable account order prevents opposing transfers from deadlocking.
  perform 1 from bank.banking_accounts where id in(p_source,p_destination) order by id for update;
  select * into s from bank.banking_accounts where id=p_source;
  select * into d from bank.banking_accounts where id=p_destination;
  if s.id is null or d.id is null or s.owner_id<>p_customer or not s.is_demo or not d.is_demo or s.type<>'checking' or d.type<>'checking' or s.currency<>'VND' or d.currency<>'VND' or s.status<>'active' or d.status<>'active' or s.balance_minor<p_amount or d.balance_minor>9223372036854775807-p_amount then raise exception 'Accounts or funds unavailable';end if;
  perform 1 from bank.user_profiles where id in(s.owner_id,d.owner_id) order by id for share;
  if exists(select 1 from bank.user_profiles where id in(s.owner_id,d.owner_id) and (status<>'active' or role<>'customer' or email is null or email not like '%@example.invalid')) then raise exception 'Synthetic profiles required';end if;
  perform 1 from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id join bank.user_profiles p on p.id=i.customer_id
    where i.id=p_case and i.customer_id=p_customer and i.version=p_version and i.revision=p_revision and i.evidence_id=p_evidence and i.state='reference_accepted' and i.profile_name=p.display_name and i.expires_at>clock_timestamp()
      and e.case_id=i.id and e.revision=i.revision and e.status='ready' and e.deleted_at is null and e.expires_at>clock_timestamp() for share of i,e;
  if not found then raise exception 'Reference unavailable';end if;
  -- Check time again after all potentially blocking locks.
  if not exists(select 1 from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id where i.id=p_case and i.expires_at>clock_timestamp() and e.expires_at>clock_timestamp()) then raise exception 'Reference expired';end if;
  if c.confirmed_until<=clock_timestamp() or c.expires_at<=clock_timestamp() or c.lease_until<=clock_timestamp() then raise exception 'Proof expired';end if;
  t:=clock_timestamp();
  update bank.banking_accounts set balance_minor=balance_minor-p_amount where id=p_source;
  update bank.banking_accounts set balance_minor=balance_minor+p_amount where id=p_destination;
  insert into bank.local_transfers(id,customer_id,source_id,destination_id,amount_minor,currency,posted_at) values(p_id,p_customer,p_source,p_destination,p_amount,'VND',t);
  insert into bank.account_history(id,account_id,operation_id,kind,direction,amount_minor,currency,posted_at) values
    (gen_random_uuid(),p_source,p_id,'transfer','debit',p_amount,'VND',t),
    (gen_random_uuid(),p_destination,p_id,'transfer','credit',p_amount,'VND',t);
  update bank.transaction_confirmations set state='posted' where id=p_id;
end $$;
revoke all on function bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid) from public,anon,authenticated,service_role;
grant execute on function bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid) to nene_api;
