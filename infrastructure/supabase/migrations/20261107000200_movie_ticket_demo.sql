-- BR-04/12: fixed fictional movie offers reuse VNPay sandbox checkout.
-- No cinema inventory, seat reservation, real ticket or bank posting is added.
alter table bank.sandbox_payments add column service_snapshot jsonb;

-- Preserve the exact service details for orders issued before this migration.
update bank.sandbox_payments set service_snapshot=jsonb_build_object(
  'id',service_id,
  'name',case service_id
    when 'electricity' then 'Demo electricity bill'
    when 'water' then 'Demo water bill'
    when 'phone' then 'Demo phone top-up' end,
  'description',case service_id
    when 'electricity' then 'Fictional Nene electricity bill. No real bill will be paid.'
    when 'water' then 'Fictional Nene water bill. No real bill will be paid.'
    when 'phone' then 'Fictional phone account. No real phone account will be credited.' end,
  'amountMinor',amount_minor::text,
  'currency',currency
);
alter table bank.sandbox_payments alter column service_snapshot set not null;
alter table bank.sandbox_payments add constraint sandbox_payment_snapshot check(
  jsonb_typeof(service_snapshot)='object' and
  service_snapshot ?& array['id','name','description','amountMinor','currency'] and
  (service_snapshot-array['id','name','description','amountMinor','currency'])='{}'::jsonb and
  jsonb_typeof(service_snapshot->'id')='string' and
  jsonb_typeof(service_snapshot->'name')='string' and
  jsonb_typeof(service_snapshot->'description')='string' and
  jsonb_typeof(service_snapshot->'amountMinor')='string' and
  jsonb_typeof(service_snapshot->'currency')='string' and
  length(service_snapshot->>'id') between 1 and 32 and
  length(service_snapshot->>'name') between 1 and 120 and
  length(service_snapshot->>'description') between 1 and 600 and
  service_snapshot->>'id'=service_id and
  service_snapshot->>'amountMinor'=amount_minor::text and
  service_snapshot->>'currency'=currency
);

alter table bank.sandbox_payments drop constraint sandbox_payments_service_id_check;
alter table bank.sandbox_payments add constraint sandbox_payments_service_id_check
  check(service_id in ('electricity','water','phone','movie_matinee_v1','movie_evening_v1'));
alter table bank.sandbox_payments drop constraint sandbox_payment_amount;
alter table bank.sandbox_payments add constraint sandbox_payment_amount check(
  (service_id='electricity' and amount_minor=200000) or
  (service_id='water' and amount_minor=100000) or
  (service_id='phone' and amount_minor=50000) or
  (service_id='movie_matinee_v1' and amount_minor=90000) or
  (service_id='movie_evening_v1' and amount_minor=120000)
);

-- The existing unique index blocks awaiting_payment for each customer/offer.
-- Only electricity/water are paid-once fixtures; a later movie purchase needs
-- a new review and authorization, and cannot reuse a previous payment result.
-- Existing grants allow INSERT but no UPDATE of this immutable snapshot column.
comment on column bank.sandbox_payments.service_snapshot is 'Immutable reviewed fictional service details. Movie offers represent one demo admission; payment never creates a real ticket, reservation or service fulfillment.';
comment on table bank.sandbox_payments is 'External VNPay sandbox checkout for fictional utility/movie examples. No Nene balance effects or real service fulfillment; immutable reviewed details and authenticated provider result only.';
