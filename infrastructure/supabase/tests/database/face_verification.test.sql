-- BR-03/BR-04/BR-09 high-value transfer face checks. Synthetic rows only; no images.
-- The runner applies pending migrations inside this transaction, which rolls back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users (id, email) values
 ('f1000000-0000-4000-8000-000000000001', 'face-sender@example.invalid'),
 ('f1000000-0000-4000-8000-000000000002', 'face-recipient@example.invalid'),
 ('f1000000-0000-4000-8000-000000000003', 'face-officer@example.invalid'),
 ('f1000000-0000-4000-8000-000000000004', 'face-other@example.invalid');
insert into bank.user_profiles (id, display_name, role, email) values
 ('f1000000-0000-4000-8000-000000000001', 'Face sender', 'customer', 'face-sender@example.invalid'),
 ('f1000000-0000-4000-8000-000000000002', 'Face recipient', 'customer', 'face-recipient@example.invalid'),
 ('f1000000-0000-4000-8000-000000000003', 'Face officer', 'officer', 'face-officer@example.invalid'),
 ('f1000000-0000-4000-8000-000000000004', 'Face other', 'customer', 'face-other@example.invalid');
insert into bank.banking_accounts (id, owner_id, type, currency, balance_minor, is_demo) values
 ('f1100000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', 'checking', 'VND', 100000000, true),
 ('f1100000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002', 'checking', 'VND', 0, true),
 ('f1100000-0000-4000-8000-000000000004', 'f1000000-0000-4000-8000-000000000004', 'checking', 'VND', 100000000, true);
insert into bank.authenticator_setup (customer_id, request_id, session_id, factor_id, state, revision) values
 ('f1000000-0000-4000-8000-000000000001', 'f1600000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'f1500000-0000-4000-8000-000000000001', 'ready', 1);
insert into bank.identity_cases (id, customer_id, profile_name, notice_version, acknowledged_by, acknowledged_role) values
 ('f1200000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', 'Face sender', 'reference-demo-v2',
  'f1000000-0000-4000-8000-000000000001', 'customer');
insert into bank.identity_evidence (id, case_id, revision, object_key, content_hash, content_type, byte_size, status, ready_at, expires_at, profile_name) values
 ('f1300000-0000-4000-8000-000000000001', 'f1200000-0000-4000-8000-000000000001', 1, 'synthetic/face-test.png',
  repeat('f', 64), 'image/png', 100, 'ready', now(), now() + interval '7 days', 'Face sender');
update bank.identity_cases set state = 'reference_accepted', evidence_id = 'f1300000-0000-4000-8000-000000000001',
  reviewed_by = 'f1000000-0000-4000-8000-000000000003', reviewed_at = now()
  where id = 'f1200000-0000-4000-8000-000000000001';
update bank.local_transfer_settings set enabled = true;
update bank.local_interbank_settings set enabled = true;

-- A factor-confirmed proof for one review, as NestJS leaves it before posting.
create function pg_temp.proof(p_id uuid, p_purpose text) returns void language sql as $$
  insert into bank.transaction_confirmations (id, customer_id, session_id, review_digest, factor_id, security_revision,
    state, expires_at, confirmed_until, lease_until, purpose)
  values (p_id, 'f1000000-0000-4000-8000-000000000001', 'f1400000-0000-4000-8000-000000000001', 'digest-' || p_id,
    'f1500000-0000-4000-8000-000000000001', 1, 'factor_confirmed', clock_timestamp() + interval '10 minutes',
    clock_timestamp() + interval '2 minutes', clock_timestamp() + interval '30 seconds', p_purpose)
$$;
grant execute on function pg_temp.proof(uuid, text) to nene_api;

-- Access boundaries
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'bank.face_checks'::regclass),
  'Face checks force row security');
select ok((select bool_and(not has_table_privilege(r, 'bank.face_checks', 'SELECT,INSERT,UPDATE,DELETE'))
  from unnest(array['anon', 'authenticated', 'service_role']) r), 'Client and Auth service roles cannot reach face checks');
select ok(not has_table_privilege('nene_api', 'bank.face_checks', 'DELETE'), 'The API cannot erase face-check history');
select ok((select bool_and(not has_column_privilege('nene_api', 'bank.face_checks', c, 'UPDATE'))
  from unnest(array['used_at', 'expires_at', 'completed_at', 'customer_id', 'review_id', 'review_digest', 'purpose', 'threshold', 'liveness']) c),
  'The API cannot mark checks used, extend validity or rebind a check');
select ok((select bool_and(not has_column_privilege('nene_api', 'bank.face_checks', c, 'INSERT'))
  from unnest(array['outcome', 'score', 'used_at', 'expires_at', 'completed_at']) c),
  'New checks always start pending');
select ok(not has_column_privilege('nene_api', 'bank.banking_accounts', 'balance_minor', 'UPDATE'),
  'The API still cannot write balances directly');
select ok(to_regprocedure('bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid)') is null
  and to_regprocedure('bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid)') is null,
  'Posting entry points without the face-check argument are removed');
select ok(has_function_privilege('nene_api', 'bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid,uuid)', 'EXECUTE')
  and has_function_privilege('nene_api', 'bank.post_local_interbank(uuid,uuid,uuid,text,uuid,uuid,text,text,text,text,bigint,uuid,integer,integer,uuid,uuid)', 'EXECUTE')
  and has_function_privilege('nene_api', 'bank.transfer_face_check_required(uuid,bigint)', 'EXECUTE'),
  'The API can call the rule and the posting functions');
select ok((select bool_and(not has_function_privilege(r, 'bank.transfer_face_check_required(uuid,bigint)', 'EXECUTE')
  and not has_function_privilege(r, 'bank.post_local_transfer(uuid,uuid,uuid,text,uuid,uuid,bigint,uuid,integer,integer,uuid,uuid)', 'EXECUTE'))
  from unnest(array['anon', 'authenticated', 'service_role']) r), 'Client roles cannot call the rule or posting');

-- Amount bands with no posted transfers today
select is(bank.transfer_face_check_required('f1000000-0000-4000-8000-000000000001', 10000000), false, '10,000,000 VND alone needs no face check');
select is(bank.transfer_face_check_required('f1000000-0000-4000-8000-000000000001', 10000001), true, 'Above 10,000,000 VND needs a face check');
select is(bank.transfer_face_check_required(null, 1), true, 'Missing input fails closed');

-- Face-check rows as the API writes them
grant usage on schema extensions to nene_api;
set local role nene_api;
select lives_ok($$insert into bank.face_checks (id, customer_id, idempotency_key, review_id, review_digest, purpose, threshold, liveness)
  values ('f1700000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', 'f1800000-0000-4000-8000-000000000001',
    'f1900000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000001', 'local_transfer', 0.40,
    '{"blink":true,"turn":true}')$$, 'The API reserves a pending attempt');
select throws_ok($$insert into bank.face_checks (id, customer_id, idempotency_key, review_id, review_digest, purpose, threshold, liveness)
  values ('f1700000-0000-4000-8000-000000000009', 'f1000000-0000-4000-8000-000000000001', 'f1800000-0000-4000-8000-000000000001',
    'f1900000-0000-4000-8000-000000000001', 'x', 'local_transfer', 0.40, '{}')$$, '23505', null,
  'An idempotency key is used once per customer');
select throws_ok($$insert into bank.face_checks (id, customer_id, idempotency_key, review_id, review_digest, purpose, threshold, liveness)
  values ('f1700000-0000-4000-8000-000000000009', 'f1000000-0000-4000-8000-000000000001', 'f1800000-0000-4000-8000-000000000009',
    'f1900000-0000-4000-8000-000000000001', 'x', 'local_deposit', 0.40, '{}')$$, '23514', null,
  'Face checks bind only transfer purposes');
select throws_ok($$update bank.face_checks set outcome = 'matched' where id = 'f1700000-0000-4000-8000-000000000001'$$,
  '23514', null, 'A match requires a recorded score');
select lives_ok($$update bank.face_checks set outcome = 'matched', score = 0.6123, antispoof_score = 0.950
  where id = 'f1700000-0000-4000-8000-000000000001'$$, 'The API records a match');
select ok((select completed_at is not null and expires_at = completed_at + interval '5 minutes' and matched and used_at is null
  from bank.face_checks where id = 'f1700000-0000-4000-8000-000000000001'), 'The database stamps a five-minute validity');
select throws_ok($$update bank.face_checks set outcome = 'not_matched' where id = 'f1700000-0000-4000-8000-000000000001'$$,
  'P0001', 'Face check result is immutable', 'A completed result cannot be rewritten');
select throws_ok($$update bank.face_checks set used_at = now() where id = 'f1700000-0000-4000-8000-000000000001'$$,
  '42501', null, 'The API cannot mark a check used outside posting');
select lives_ok($$insert into bank.face_checks (id, customer_id, idempotency_key, review_id, review_digest, purpose, threshold, liveness)
  values ('f1700000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000001', 'f1800000-0000-4000-8000-000000000002',
    'f1900000-0000-4000-8000-000000000002', 'digest-f1900000-0000-4000-8000-000000000002', 'local_transfer', 0.40, '{}')$$,
  'A second attempt is reserved');
select lives_ok($$update bank.face_checks set outcome = 'not_matched', score = 0.1000 where id = 'f1700000-0000-4000-8000-000000000002'$$,
  'The API records a non-match');
select ok((select expires_at is null and not matched from bank.face_checks where id = 'f1700000-0000-4000-8000-000000000002'),
  'A non-match never becomes usable');
reset role;

-- Posting enforcement for a 12,000,000 VND same-bank transfer
select pg_temp.proof('f1900000-0000-4000-8000-000000000001', 'local_transfer');
select pg_temp.proof('f1900000-0000-4000-8000-000000000002', 'local_transfer');
set local role nene_api;
select throws_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000002', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 12000000, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', 'f1700000-0000-4000-8000-000000000002')$$, 'NF001', null,
  'A non-matched check cannot authorize a high-value transfer');
select throws_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 12000000, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', null)$$, 'NF001', null, 'A high-value transfer without a face check is refused');
select throws_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000002', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 12000000, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', 'f1700000-0000-4000-8000-000000000001')$$, 'NF001', null,
  'A matched check bound to another review cannot be borrowed');
select lives_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 12000000, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', 'f1700000-0000-4000-8000-000000000001')$$,
  'A matched, unused check bound to the same review posts the transfer');
select is((select balance_minor from bank.banking_accounts where id = 'f1100000-0000-4000-8000-000000000001'), 88000000::bigint,
  'The sender is debited once');
select ok((select used_at is not null from bank.face_checks where id = 'f1700000-0000-4000-8000-000000000001'),
  'Posting marks the face check used in the same transaction');
select is((select state from bank.transaction_confirmations where id = 'f1900000-0000-4000-8000-000000000001'), 'posted',
  'The proof is consumed with the posting');
select lives_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 12000000, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', 'f1700000-0000-4000-8000-000000000001')$$, 'An exact posted retry stays idempotent');
select is((select balance_minor from bank.banking_accounts where id = 'f1100000-0000-4000-8000-000000000001'), 88000000::bigint,
  'A retry does not debit again');
select throws_ok($$update bank.face_checks set used_at = null where id = 'f1700000-0000-4000-8000-000000000001'$$,
  '42501', null, 'A used check cannot be released by the API');
reset role;
select throws_ok($$update bank.face_checks set used_at = null where id = 'f1700000-0000-4000-8000-000000000001'$$,
  'P0001', 'Face check result is immutable', 'A used check stays used even for privileged writers');

-- Daily total: 12,000,000 VND is already posted today
select is(bank.transfer_face_check_required('f1000000-0000-4000-8000-000000000001', 8000000), false,
  'Reaching exactly 20,000,000 VND in a day needs no face check');
select is(bank.transfer_face_check_required('f1000000-0000-4000-8000-000000000001', 8000001), true,
  'Exceeding 20,000,000 VND in a day needs a face check');
select is(bank.transfer_face_check_required('f1000000-0000-4000-8000-000000000004', 10000000), false,
  'Another customer''s transfers are not counted');
select pg_temp.proof('f1900000-0000-4000-8000-000000000003', 'local_transfer');
set local role nene_api;
select throws_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000003', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000003', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 9000000, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', 'f1700000-0000-4000-8000-000000000001')$$, 'NF001', null,
  'A small transfer over the daily band needs its own unused check');
select lives_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000003', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000003', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 8000000, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', null)$$, 'A transfer that reaches exactly the daily band posts without a check');
reset role;

-- Interbank transfers count towards the same total and enforce the same rule
select pg_temp.proof('f1900000-0000-4000-8000-000000000004', 'local_interbank');
set local role nene_api;
select throws_ok($$select bank.post_local_interbank('f1900000-0000-4000-8000-000000000004', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000004', 'f1100000-0000-4000-8000-000000000001',
  '99000000-0000-4000-8000-000000000001', 'DEMO_A', 'Demo Bank A', '990000000001', 'Demo recipient A', 1000,
  'f1200000-0000-4000-8000-000000000001', 1, 1, 'f1300000-0000-4000-8000-000000000001', null)$$, 'NF001', null,
  'Other-bank transfers over the daily band need a face check');
select lives_ok($$insert into bank.face_checks (id, customer_id, idempotency_key, review_id, review_digest, purpose, threshold, liveness)
  values ('f1700000-0000-4000-8000-000000000004', 'f1000000-0000-4000-8000-000000000001', 'f1800000-0000-4000-8000-000000000004',
    'f1900000-0000-4000-8000-000000000004', 'digest-f1900000-0000-4000-8000-000000000004', 'local_interbank', 0.40, '{}')$$,
  'An other-bank attempt is reserved');
select lives_ok($$update bank.face_checks set outcome = 'matched', score = 0.5 where id = 'f1700000-0000-4000-8000-000000000004'$$,
  'The other-bank check matches');
select lives_ok($$select bank.post_local_interbank('f1900000-0000-4000-8000-000000000004', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000004', 'f1100000-0000-4000-8000-000000000001',
  '99000000-0000-4000-8000-000000000001', 'DEMO_A', 'Demo Bank A', '990000000001', 'Demo recipient A', 1000,
  'f1200000-0000-4000-8000-000000000001', 1, 1, 'f1300000-0000-4000-8000-000000000001', 'f1700000-0000-4000-8000-000000000004')$$,
  'A matched other-bank check posts the transfer');
reset role;
select is((select balance_minor from bank.banking_accounts where id = 'f1100000-0000-4000-8000-000000000001'), 79999000::bigint,
  'The sender balance reflects all three postings');
select is(bank.transfer_face_check_required('f1000000-0000-4000-8000-000000000001', 1), true,
  'Same-bank and other-bank totals are combined');

-- Cap and day boundary
select pg_temp.proof('f1900000-0000-4000-8000-000000000005', 'local_transfer');
set local role nene_api;
select throws_ok($$select bank.post_local_transfer('f1900000-0000-4000-8000-000000000005', 'f1000000-0000-4000-8000-000000000001',
  'f1400000-0000-4000-8000-000000000001', 'digest-f1900000-0000-4000-8000-000000000005', 'f1100000-0000-4000-8000-000000000001',
  'f1100000-0000-4000-8000-000000000002', 50000001, 'f1200000-0000-4000-8000-000000000001', 1, 1,
  'f1300000-0000-4000-8000-000000000001', null)$$, 'P0001', 'Unsupported transfer', 'Amounts above 50,000,000 VND are refused');
reset role;
select throws_ok($$insert into bank.local_transfers (id, customer_id, source_id, destination_id, amount_minor, currency)
  values ('f1900000-0000-4000-8000-000000000005', 'f1000000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000001',
    'f1100000-0000-4000-8000-000000000002', 50000001, 'VND')$$, '23514', null, 'The receipt table caps amounts at 50,000,000 VND');
select lives_ok($$insert into bank.local_transfers (id, customer_id, source_id, destination_id, amount_minor, currency, posted_at)
  values ('f1900000-0000-4000-8000-000000000005', 'f1000000-0000-4000-8000-000000000004', 'f1100000-0000-4000-8000-000000000004',
    'f1100000-0000-4000-8000-000000000002', 50000000, 'VND',
    (date_trunc('day', now() at time zone 'Asia/Ho_Chi_Minh') at time zone 'Asia/Ho_Chi_Minh') - interval '1 second')$$,
  'A 50,000,000 VND receipt fits the new cap');
select is(bank.transfer_face_check_required('f1000000-0000-4000-8000-000000000004', 10000000), false,
  'A transfer posted before UTC+07 midnight does not count today');

select * from finish();
rollback;
