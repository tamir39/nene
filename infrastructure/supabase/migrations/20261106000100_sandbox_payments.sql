-- BR-04/10/11: synthetic utility checkout using VNPay's external sandbox.
-- Security attempts are not completed payments; these tables never post to accounts.
create table bank.sandbox_payment_authorizations (
  id uuid primary key,
  customer_id uuid not null references bank.user_profiles(id),
  session_id uuid not null,
  review_digest text not null,
  factor_id uuid not null,
  security_revision integer not null check(security_revision>=0),
  state text not null check(state in ('checking','rejected','unknown','issued')),
  expires_at timestamptz not null,
  lease_until timestamptz not null default clock_timestamp()+interval '45 seconds',
  created_at timestamptz not null default clock_timestamp()
);
create index sandbox_payment_authorization_owner on bank.sandbox_payment_authorizations(customer_id,created_at);

create table bank.sandbox_payments (
  id uuid primary key references bank.sandbox_payment_authorizations(id),
  customer_id uuid not null references bank.user_profiles(id),
  service_id text not null check(service_id in ('electricity','water','phone')),
  amount_minor bigint not null check(amount_minor>0 and amount_minor<5000000),
  currency text not null check(currency='VND'),
  provider_reference text not null unique,
  terminal_code text not null,
  order_info text not null,
  ip_address inet not null,
  state text not null default 'awaiting_payment' check(state in ('awaiting_payment','paid','failed')),
  fulfillment text not null default 'not_available' check(fulfillment='not_available'),
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  paid_at timestamptz,
  provider_transaction_no text,
  provider_response_code text,
  provider_transaction_status text,
  constraint sandbox_payment_dates check(expires_at>created_at),
  constraint sandbox_payment_paid check((state='paid')=(paid_at is not null)),
  constraint sandbox_payment_amount check(
    (service_id='electricity' and amount_minor=200000) or
    (service_id='water' and amount_minor=100000) or
    (service_id='phone' and amount_minor=50000))
);
create index sandbox_payment_owner on bank.sandbox_payments(customer_id,created_at);
-- One outstanding checkout per service. Each fixture bill is payable once;
-- a completed phone top-up may be followed by a new, separately authorized one.
create unique index sandbox_payment_single_service on bank.sandbox_payments(customer_id,service_id)
  where state='awaiting_payment' or (state='paid' and service_id in ('electricity','water'));
revoke all on bank.sandbox_payment_authorizations,bank.sandbox_payments from public,anon,authenticated,service_role,nene_api;
grant select,insert on bank.sandbox_payment_authorizations,bank.sandbox_payments to nene_api;
grant update(state) on bank.sandbox_payment_authorizations to nene_api;
grant update(state,paid_at,provider_transaction_no,provider_response_code,provider_transaction_status) on bank.sandbox_payments to nene_api;
alter table bank.sandbox_payment_authorizations enable row level security;
alter table bank.sandbox_payment_authorizations force row level security;
alter table bank.sandbox_payments enable row level security;
alter table bank.sandbox_payments force row level security;
create policy sandbox_payment_authorization_api on bank.sandbox_payment_authorizations to nene_api using(true) with check(true);
create policy sandbox_payment_api on bank.sandbox_payments to nene_api using(true) with check(true);
comment on table bank.sandbox_payments is 'External VNPay sandbox checkout for fictional utility examples. No Nene balance effects, real bill settlement or phone credit; immutable reviewed details and authenticated provider result only.';
