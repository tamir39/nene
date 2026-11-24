-- BR-01/BR-02 and partial BR-05: authorized customer records and initial accounts.
-- Opening a zero-balance account is not a deposit, eKYC, or transaction 2FA.
alter table bank.user_profiles
  alter column role set default 'customer',
  add column email text check (email is null or (char_length(email) between 3 and 254 and email = lower(email))),
  add column phone text check (phone is null or char_length(phone) between 5 and 32),
  add column address text check (address is null or char_length(btrim(address)) between 1 and 300);
create unique index user_profiles_email_unique on bank.user_profiles (email) where email is not null;
comment on column bank.user_profiles.email is
  'Provisioning email for officer lookup. Sign-in identity remains in Auth; email changes are not exposed.';
comment on column bank.user_profiles.updated_at is
  'Updated by authorized backend contact/name edits.';

grant insert (id, email, display_name, phone, address) on bank.user_profiles to nene_api;
grant update (display_name, phone, address, updated_at) on bank.user_profiles to nene_api;
create policy api_create_customers on bank.user_profiles for insert to nene_api
  with check (role = 'customer' and status = 'active');
create policy api_edit_customers on bank.user_profiles for update to nene_api
  using (role = 'customer' and status = 'active')
  with check (role = 'customer' and status = 'active');

create table bank.banking_accounts (
  id uuid primary key,
  owner_id uuid not null references bank.user_profiles (id) on delete restrict,
  account_number bigint generated always as identity (start with 100000000001) unique,
  type text not null check (type in ('checking', 'saving', 'mortgage')),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  balance_minor bigint not null default 0 check (balance_minor >= 0),
  status text not null default 'active' check (status in ('active', 'closed')),
  created_at timestamptz not null default now()
);
create index banking_accounts_owner on bank.banking_accounts (owner_id);
comment on column bank.banking_accounts.balance_minor is
  'Integer minor units. The first demo creates VND checking accounts at zero; no balance mutation API or grant exists.';

create table bank.customer_creation_requests (
  officer_id uuid not null references bank.user_profiles (id) on delete restrict,
  idempotency_key uuid not null,
  customer_id uuid not null unique,
  account_id uuid not null unique,
  fingerprint_salt text not null check (fingerprint_salt ~ '^[a-f0-9]{32}$'),
  payload_fingerprint text not null check (payload_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (officer_id, idempotency_key)
);
comment on table bank.customer_creation_requests is
  'Durable UUID reservation before Auth creation. Customer/account IDs intentionally have no FK until provisioning completes. Fingerprint is salted scrypt; no plaintext password is retained.';

create table bank.profile_edit_audit (
  id bigint generated always as identity primary key,
  actor_id uuid not null references bank.user_profiles (id) on delete restrict,
  customer_id uuid not null references bank.user_profiles (id) on delete restrict,
  request_reason text check (request_reason is null or char_length(btrim(request_reason)) between 5 and 500),
  fields text[] not null check (
    cardinality(fields) between 1 and 3 and fields <@ array['displayName', 'phone', 'address']::text[]
  ),
  created_at timestamptz not null default now()
);
comment on table bank.profile_edit_audit is
  'Append-only record of profile edits. Officer edits record the stated customer request; this is not identity verification.';

revoke all on bank.banking_accounts, bank.customer_creation_requests, bank.profile_edit_audit
  from public, anon, authenticated, service_role;
revoke all on sequence bank.banking_accounts_account_number_seq, bank.profile_edit_audit_id_seq
  from public, anon, authenticated, service_role;
grant select on bank.banking_accounts, bank.customer_creation_requests to nene_api;
grant insert (id, owner_id, type, currency) on bank.banking_accounts to nene_api;
grant insert (officer_id, idempotency_key, customer_id, account_id, fingerprint_salt, payload_fingerprint)
  on bank.customer_creation_requests to nene_api;
grant update (completed_at) on bank.customer_creation_requests to nene_api;
grant insert (actor_id, customer_id, request_reason, fields) on bank.profile_edit_audit to nene_api;
grant usage on sequence bank.banking_accounts_account_number_seq, bank.profile_edit_audit_id_seq to nene_api;

alter table bank.banking_accounts enable row level security;
alter table bank.banking_accounts force row level security;
alter table bank.customer_creation_requests enable row level security;
alter table bank.customer_creation_requests force row level security;
alter table bank.profile_edit_audit enable row level security;
alter table bank.profile_edit_audit force row level security;
create policy api_read_accounts on bank.banking_accounts for select to nene_api using (true);
create policy api_create_accounts on bank.banking_accounts for insert to nene_api with check (
  balance_minor = 0 and status = 'active' and exists (
    select 1 from bank.user_profiles where id = owner_id and role = 'customer' and status = 'active'
  )
);
create policy api_read_creation_requests on bank.customer_creation_requests for select to nene_api using (true);
create policy api_reserve_customer on bank.customer_creation_requests for insert to nene_api with check (
  exists (select 1 from bank.user_profiles where id = officer_id and role = 'officer' and status = 'active')
);
create policy api_complete_customer on bank.customer_creation_requests for update to nene_api
  using (exists (select 1 from bank.user_profiles where id = officer_id and role = 'officer' and status = 'active'))
  with check (exists (select 1 from bank.user_profiles where id = officer_id and role = 'officer' and status = 'active'));
create policy api_append_profile_audit on bank.profile_edit_audit for insert to nene_api with check (
  exists (select 1 from bank.user_profiles where id = customer_id and role = 'customer') and
  (
    (actor_id = customer_id and request_reason is null and fields <@ array['phone', 'address']::text[]) or
    (request_reason is not null and exists (
      select 1 from bank.user_profiles where id = actor_id and role = 'officer' and status = 'active'
    ))
  )
);
