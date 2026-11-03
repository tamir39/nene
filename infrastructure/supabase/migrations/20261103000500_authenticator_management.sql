-- BR-04 support: factor lifecycle only, never financial authorization.
alter table bank.authenticator_setup drop constraint authenticator_setup_state_check;
alter table bank.authenticator_setup add constraint authenticator_setup_state_check
  check(state in ('starting','pending','verifying','ready','blocked','restricted'));
alter table bank.authenticator_setup add column security_not_before timestamptz not null default 'epoch';
create table bank.security_management (
  id uuid primary key,
  customer_id uuid not null references bank.user_profiles(id),
  session_id uuid not null,
  revision integer not null,
  purpose text not null check(purpose in ('replace','recover','codes')),
  step text not null check(step in ('proof','proving','authorized','enrolling','pending','verifying','verified','issuing','codes_shown','finishing','cancelling','completed','cancelled')),
  old_factor_id uuid not null,
  new_factor_id uuid,
  lease_id uuid not null default gen_random_uuid(),
  attempts integer not null default 0 check(attempts between 0 and 5),
  expires_at timestamptz not null default now()+interval '10 minutes',
  created_at timestamptz not null default now()
);
create unique index one_security_management on bank.security_management(customer_id)
  where step not in ('completed','cancelled');
create table bank.security_proof_key (
  id boolean primary key default true check(id),
  secret text not null
);
-- Two independently generated UUIDs supply a private random HMAC key, not a TOTP secret.
insert into bank.security_proof_key(secret) values(replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''));
create table bank.security_proof_reservations (
  customer_id uuid not null references bank.user_profiles(id),
  factor_scope text not null,
  fingerprint text not null,
  purpose text not null,
  created_at timestamptz not null default now(),
  primary key(customer_id,factor_scope,fingerprint)
);
revoke all on bank.security_management,bank.security_proof_key,bank.security_proof_reservations from public,anon,authenticated,service_role;
grant select,insert,update on bank.security_management to nene_api;
grant select on bank.security_proof_key to nene_api;
grant select,insert,delete on bank.security_proof_reservations to nene_api;
alter table bank.security_management enable row level security;
alter table bank.security_management force row level security;
alter table bank.security_proof_key enable row level security;
alter table bank.security_proof_key force row level security;
alter table bank.security_proof_reservations enable row level security;
alter table bank.security_proof_reservations force row level security;
create policy management_api on bank.security_management to nene_api using(true) with check(true);
create policy proof_key_read on bank.security_proof_key for select to nene_api using(true);
create policy proof_api on bank.security_proof_reservations to nene_api using(true) with check(true);
