-- BR-03/BR-04/BR-09: server-side face comparison for high-value demo transfers.
-- Coursework rule modelled on the Decision 2345/QD-NHNN bands: a same-bank or
-- other-bank demo transfer needs a matched face check when the amount exceeds
-- 10,000,000 VND, or when it would take the customer's posted outgoing transfers
-- for the current UTC+07 day above 20,000,000 VND. The per-transfer cap rises to
-- 50,000,000 VND. Cash and VNPay limits are unchanged.
-- This is not eKYC, not certified biometrics and not active liveness detection.
-- No data is rewritten: existing receipts are all below 5,000,000 VND and satisfy
-- the wider checks, which PostgreSQL validates without rewriting the tables.

alter table bank.local_transfers drop constraint local_transfers_amount_minor_check;
alter table bank.local_transfers add constraint local_transfers_amount_minor_check
  check(amount_minor>0 and amount_minor<=50000000);
alter table bank.local_interbank_transfers drop constraint local_interbank_transfers_amount_minor_check;
alter table bank.local_interbank_transfers add constraint local_interbank_transfers_amount_minor_check
  check(amount_minor>0 and amount_minor<=50000000);
create index local_transfers_customer_posted on bank.local_transfers(customer_id,posted_at);
create index local_interbank_customer_posted on bank.local_interbank_transfers(customer_id,posted_at);

-- The single definition of the rule. The API calls it for reviews and as an early
-- check; the posting functions call it again under the customer's authenticator
-- lock, which every transfer posting path holds, so concurrent transfers by the
-- same customer are counted.
create function bank.transfer_face_check_required(p_customer uuid,p_amount bigint)
returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare
  day_start timestamptz;
  total numeric;
begin
  if p_customer is null or p_amount is null then return true;end if;
  if p_amount>10000000 then return true;end if;
  day_start:=date_trunc('day',clock_timestamp() at time zone 'Asia/Ho_Chi_Minh') at time zone 'Asia/Ho_Chi_Minh';
  select coalesce(sum(amount_minor),0) into total from (
    select amount_minor from bank.local_transfers
      where customer_id=p_customer and posted_at>=day_start and posted_at<day_start+interval '1 day'
    union all
    select amount_minor from bank.local_interbank_transfers
      where customer_id=p_customer and posted_at>=day_start and posted_at<day_start+interval '1 day'
  ) posted;
  return total+p_amount>20000000;
end $$;
revoke all on function bank.transfer_face_check_required(uuid,bigint) from public,anon,authenticated,service_role;
grant execute on function bank.transfer_face_check_required(uuid,bigint) to nene_api;

-- One row per comparison attempt. The selfie, the reference image and embeddings
-- are never stored: only the outcome, scores, device-reported liveness flags,
-- the review binding and timestamps.
create table bank.face_checks (
  id uuid primary key,
  customer_id uuid not null references bank.user_profiles(id),
  idempotency_key uuid not null,
  review_id uuid not null,
  review_digest text not null check(length(review_digest) between 1 and 128),
  purpose text not null check(purpose in ('local_transfer','local_interbank')),
  outcome text not null default 'pending'
    check(outcome in ('pending','matched','not_matched','no_face','multiple_faces','error')),
  matched boolean generated always as (outcome='matched') stored,
  score numeric(5,4) check(score between -1 and 1),
  antispoof_score numeric(4,3) check(antispoof_score between 0 and 1),
  threshold numeric(4,3) not null check(threshold>0 and threshold<1),
  liveness jsonb not null check(jsonb_typeof(liveness)='object' and pg_column_size(liveness)<=256),
  created_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  expires_at timestamptz,
  used_at timestamptz,
  unique(customer_id,idempotency_key),
  check((outcome='pending')=(completed_at is null)),
  check((outcome='matched')=(expires_at is not null)),
  check(expires_at is null or expires_at<=completed_at+interval '5 minutes'),
  check(outcome<>'matched' or score is not null),
  check(used_at is null or outcome='matched')
);
create index face_checks_customer_created on bank.face_checks(customer_id,created_at);
create index face_checks_review on bank.face_checks(review_id);

-- Results are written once. The database, not the API, stamps completion and the
-- five-minute validity, and only the posting functions can mark a check used.
create function bank.face_checks_guard() returns trigger language plpgsql set search_path=pg_catalog as $$
begin
  if (new.id,new.customer_id,new.idempotency_key,new.review_id,new.review_digest,new.purpose,new.threshold,new.liveness,new.created_at)
     is distinct from (old.id,old.customer_id,old.idempotency_key,old.review_id,old.review_digest,old.purpose,old.threshold,old.liveness,old.created_at)
     then raise exception 'Face check binding is immutable';end if;
  if old.outcome<>'pending' then
    if (new.outcome,new.score,new.antispoof_score,new.completed_at,new.expires_at)
       is distinct from (old.outcome,old.score,old.antispoof_score,old.completed_at,old.expires_at)
       or (old.used_at is not null and new.used_at is distinct from old.used_at)
       then raise exception 'Face check result is immutable';end if;
    return new;
  end if;
  if new.used_at is not null then raise exception 'Pending face check cannot be used';end if;
  if new.outcome<>'pending' then
    new.completed_at:=clock_timestamp();
    new.expires_at:=case when new.outcome='matched' then new.completed_at+interval '5 minutes' end;
  else
    new.completed_at:=null;
    new.expires_at:=null;
  end if;
  return new;
end $$;
revoke all on function bank.face_checks_guard() from public,anon,authenticated,service_role;
create trigger face_checks_guard before update on bank.face_checks for each row execute function bank.face_checks_guard();

revoke all on bank.face_checks from public,anon,authenticated,service_role,nene_api;
grant select on bank.face_checks to nene_api;
grant insert(id,customer_id,idempotency_key,review_id,review_digest,purpose,threshold,liveness) on bank.face_checks to nene_api;
grant update(outcome,score,antispoof_score) on bank.face_checks to nene_api;
alter table bank.face_checks enable row level security;
alter table bank.face_checks force row level security;
create policy face_checks_api on bank.face_checks to nene_api using(true) with check(true);
comment on table bank.face_checks is
  'Server-side selfie-to-reference comparisons for high-value demo transfers. No images or embeddings. Anti-spoof score and device liveness flags are advisory only. Not eKYC or certified biometrics.';

-- Posting functions gain the face-check argument. The old signatures are dropped so
-- no entry point can post a transfer without the rule.
drop function bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid);
create function bank.post_local_transfer(p_id uuid,p_customer uuid,p_session uuid,p_digest text,p_source uuid,p_destination uuid,p_amount bigint,p_case uuid,p_version integer,p_revision integer,p_evidence uuid,p_face_check uuid)
returns void language plpgsql security definer set search_path=pg_catalog as $$
declare c bank.transaction_confirmations%rowtype; s bank.banking_accounts%rowtype; d bank.banking_accounts%rowtype; t timestamptz;
begin
  if not exists(select 1 from bank.local_transfer_settings where id and enabled) then raise exception 'Local transfers disabled'; end if;
  if p_amount is null or p_amount<=0 or p_amount>50000000 or p_source=p_destination then raise exception 'Unsupported transfer'; end if;
  select * into c from bank.transaction_confirmations where id=p_id for update;
  if not found or c.customer_id<>p_customer or c.session_id<>p_session or c.review_digest<>p_digest or c.purpose<>'local_transfer' then raise exception 'Invalid proof binding'; end if;
  if c.state='posted' then
    if not exists(select 1 from bank.local_transfers where id=p_id and source_id=p_source and destination_id=p_destination and amount_minor=p_amount) then raise exception 'Changed posted details';end if;
    return;
  end if;
  if c.state<>'factor_confirmed' or c.confirmed_until is null or c.confirmed_until<=clock_timestamp() or c.expires_at<=clock_timestamp() then raise exception 'Proof unavailable';end if;
  perform 1 from bank.authenticator_setup where customer_id=p_customer and state='ready' and factor_id=c.factor_id and revision=c.security_revision for update;
  if not found then raise exception 'Security changed';end if;
  -- The daily total is read while this customer's authenticator row is locked.
  if bank.transfer_face_check_required(p_customer,p_amount) then
    update bank.face_checks set used_at=clock_timestamp()
      where id=p_face_check and customer_id=p_customer and review_id=p_id and review_digest=p_digest
        and purpose='local_transfer' and outcome='matched' and used_at is null and expires_at>clock_timestamp();
    if not found then raise exception 'Face check required' using errcode='NF001';end if;
  end if;
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
revoke all on function bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid,uuid) to nene_api;

drop function bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid);
create function bank.post_local_interbank(
  p_id uuid,p_customer uuid,p_session uuid,p_digest text,p_source uuid,p_destination uuid,
  p_bank_code text,p_bank_name text,p_account_number text,p_recipient_name text,p_amount bigint,
  p_case uuid,p_version integer,p_revision integer,p_evidence uuid,p_face_check uuid
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
     p_amount<=0 or p_amount>50000000 then raise exception 'Unsupported transfer';end if;
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
  -- The daily total is read while this customer's authenticator row is locked.
  if bank.transfer_face_check_required(p_customer,p_amount) then
    update bank.face_checks set used_at=clock_timestamp()
      where id=p_face_check and customer_id=p_customer and review_id=p_id and review_digest=p_digest
        and purpose='local_interbank' and outcome='matched' and used_at is null and expires_at>clock_timestamp();
    if not found then raise exception 'Face check required' using errcode='NF001';end if;
  end if;
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
revoke all on function bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid,uuid) to nene_api;
