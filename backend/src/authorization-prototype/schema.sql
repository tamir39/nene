-- DISPOSABLE EXPERIMENT ONLY. Not a migration and never applied to Nene's DB.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'bank') then
    raise exception 'Refusing to install authorization prototype beside banking data';
  end if;
end $$;
create schema authorization_prototype;
revoke all on schema authorization_prototype from public;

create table authorization_prototype.settings (
  singleton boolean primary key default true check (singleton),
  fingerprint_key_id text not null check (length(fingerprint_key_id) = 64)
);
create table authorization_prototype.principals (
  id uuid primary key,
  role text not null check (role in ('customer', 'officer')),
  active boolean not null default true,
  eligible boolean not null default true,
  factor_id uuid not null,
  policy_revision integer not null default 1 check (policy_revision > 0),
  lock_nonce boolean not null default false
);
create table authorization_prototype.operations (
  id uuid primary key,
  owner_id uuid not null references authorization_prototype.principals(id),
  version integer not null default 1 check (version > 0),
  source_id uuid not null,
  destination_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0),
  currency text not null check (currency = 'VND'),
  policy_revision integer not null default 1,
  requires_identity_comparison boolean not null default true,
  expires_at timestamptz not null default (clock_timestamp() + interval '10 minutes'),
  state text not null default 'awaiting_authorization'
    check (state in ('awaiting_authorization', 'authorized', 'consumed', 'cancelled')),
  authorization_id uuid unique,
  authorization_attempt_id uuid,
  authorized_until timestamptz,
  receipt_id uuid unique,
  receipt_request_key uuid,
  check (source_id <> destination_id)
);
create table authorization_prototype.attempts (
  id uuid primary key,
  operation_id uuid not null references authorization_prototype.operations(id),
  owner_id uuid not null references authorization_prototype.principals(id),
  operation_version integer not null,
  details_digest text not null,
  policy_revision integer not null,
  factor_id uuid not null,
  request_key uuid not null,
  challenge_id uuid unique,
  proof_digest text,
  state text not null check (state in ('challenge_pending', 'ready', 'verifying', 'verified', 'rejected', 'unknown', 'superseded')),
  created_at timestamptz not null default clock_timestamp(),
  deadline timestamptz not null default (clock_timestamp() + interval '30 seconds'),
  unique (owner_id, request_key)
);
create index on authorization_prototype.attempts(owner_id, created_at);
create index on authorization_prototype.attempts(operation_id);
create table authorization_prototype.proof_claims (
  owner_id uuid not null,
  factor_id uuid not null,
  proof_digest text not null,
  expires_at timestamptz not null default (clock_timestamp() + interval '120 seconds'),
  primary key (owner_id, factor_id, proof_digest)
);

-- The fixture runner creates this local role with a fresh password first.
grant usage on schema authorization_prototype to nene_authorization_fixture;
grant select, insert on authorization_prototype.settings to nene_authorization_fixture;
grant select on authorization_prototype.principals to nene_authorization_fixture;
grant update(lock_nonce) on authorization_prototype.principals to nene_authorization_fixture;
grant select on authorization_prototype.operations to nene_authorization_fixture;
grant update(state, authorization_id, authorization_attempt_id, authorized_until, receipt_id, receipt_request_key)
  on authorization_prototype.operations to nene_authorization_fixture;
grant select, insert on authorization_prototype.attempts to nene_authorization_fixture;
grant update(challenge_id, proof_digest, state, deadline) on authorization_prototype.attempts to nene_authorization_fixture;
grant select, insert, delete on authorization_prototype.proof_claims to nene_authorization_fixture;
