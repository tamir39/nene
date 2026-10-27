-- BR-01/BR-03/TR-03 reference enrollment integrity. No real identity images.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users (id, email) values
 ('d7000000-0000-4000-8000-000000000001', 'reference-officer@example.invalid'),
 ('d7000000-0000-4000-8000-000000000002', 'reference-customer@example.invalid'),
 ('d7000000-0000-4000-8000-000000000003', 'reference-other@example.invalid');
insert into bank.user_profiles (id, display_name, role) values
 ('d7000000-0000-4000-8000-000000000001', 'Reference officer', 'officer'),
 ('d7000000-0000-4000-8000-000000000002', 'Reference customer', 'customer'),
 ('d7000000-0000-4000-8000-000000000003', 'Other customer', 'customer');

select ok(
 (select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
  where oid in ('bank.identity_cases'::regclass, 'bank.identity_evidence'::regclass,
               'bank.identity_commands'::regclass, 'bank.identity_reviews'::regclass)),
 'All reference tables force row security'
);
select ok(
 (select bool_and(not has_table_privilege(r, t, 'SELECT,INSERT,UPDATE,DELETE'))
  from unnest(array['anon', 'authenticated', 'service_role']) r
  cross join unnest(array['bank.identity_cases', 'bank.identity_evidence', 'bank.identity_commands', 'bank.identity_reviews']) t),
 'Client and Auth service roles have no reference table grants'
);
select ok(not has_column_privilege('nene_api', 'bank.identity_cases', 'customer_id', 'UPDATE'), 'A case cannot be reassigned to another customer');
select ok(not has_column_privilege('nene_api', 'bank.identity_evidence', 'object_key', 'UPDATE'), 'A reserved object key is immutable');
select ok(not has_column_privilege('nene_api', 'bank.identity_evidence', 'content_hash', 'UPDATE'), 'A reserved content hash is immutable');
select ok(not has_column_privilege('nene_api', 'bank.identity_evidence', 'profile_name', 'UPDATE'), 'A reserved photo name snapshot is immutable');
select ok(not has_column_privilege('nene_api', 'bank.identity_evidence', 'expires_at', 'UPDATE'), 'Evidence retention cannot be extended by the API');
select ok(not has_column_privilege('nene_api', 'bank.identity_commands', 'payload_hash', 'UPDATE'), 'An idempotency payload cannot be replaced');
select ok(not has_table_privilege('nene_api', 'bank.identity_reviews', 'UPDATE'), 'Reference decisions are append-only');
select ok(not has_table_privilege('nene_api', 'bank.identity_cases', 'DELETE'), 'API cannot erase reference cases');
select ok(not has_column_privilege('nene_api', 'bank.user_profiles', 'status', 'UPDATE'), 'Reference enrollment grants no profile-status permission');
select ok(not has_column_privilege('nene_api', 'bank.banking_accounts', 'balance_minor', 'UPDATE'), 'Reference enrollment grants no balance permission');

grant usage on schema extensions to nene_api;
set local role authenticated;
select throws_ok($$select * from bank.identity_cases$$, '42501', null, 'Mobile clients cannot read reference state directly');
select throws_ok($$select * from bank.identity_evidence$$, '42501', null, 'Mobile clients cannot discover private object keys');
reset role;
set local role nene_api;

select lives_ok(
 $$insert into bank.identity_cases (id, customer_id, profile_name, notice_version, acknowledged_by, acknowledged_role)
   values ('d7100000-0000-4000-8000-000000000001', 'd7000000-0000-4000-8000-000000000002',
           'Reference customer', 'reference-v1', 'd7000000-0000-4000-8000-000000000002', 'customer')$$,
 'Customer acknowledgement creates a draft reference'
);
select is((select state from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 'draft', 'New reference is draft, not verified');
select is((select expires_at - created_at from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), interval '7 days', 'Demo case expiry defaults to seven days');
select throws_ok(
 $$insert into bank.identity_cases (id, customer_id, profile_name, notice_version, acknowledged_by, acknowledged_role)
   values ('d7100000-0000-4000-8000-000000000002', 'd7000000-0000-4000-8000-000000000003',
           'Other customer', 'reference-v1', 'd7000000-0000-4000-8000-000000000002', 'customer')$$,
 '42501', null, 'A customer acknowledgement cannot be attributed to another customer'
);
select lives_ok(
 $$insert into bank.identity_cases (id, customer_id, profile_name, notice_version, acknowledged_by, acknowledged_role)
   values ('d7100000-0000-4000-8000-000000000002', 'd7000000-0000-4000-8000-000000000003',
           'Other customer', 'reference-v1', 'd7000000-0000-4000-8000-000000000001', 'officer')$$,
 'Assisted enrollment records officer attribution'
);
select throws_ok(
 $$insert into bank.identity_cases (id, customer_id, profile_name, notice_version, acknowledged_by, acknowledged_role)
   values ('d7100000-0000-4000-8000-000000000003', 'd7000000-0000-4000-8000-000000000002',
           'Duplicate', 'reference-v1', 'd7000000-0000-4000-8000-000000000002', 'customer')$$,
 '23505', null, 'One current case per customer is enforced'
);
select throws_ok(
 $$update bank.identity_cases set state = 'verified' where id = 'd7100000-0000-4000-8000-000000000001'$$,
 '23514', null, 'A global verified state is not accepted'
);
select throws_ok(
 $$update bank.identity_cases set state = 'submitted' where id = 'd7100000-0000-4000-8000-000000000001'$$,
 '23514', null, 'Submission requires an evidence reference'
);
select lives_ok(
 $$insert into bank.identity_evidence (id, case_id, revision, object_key, content_hash, content_type, byte_size, expires_at, profile_name)
   values ('d7200000-0000-4000-8000-000000000001', 'd7100000-0000-4000-8000-000000000001', 1,
           'synthetic/reference-test.png', repeat('a',64), 'image/png', 100, now() + interval '7 days', 'Reference customer')$$,
 'An immutable pending evidence reservation can be recorded'
);
select throws_ok(
 $$insert into bank.identity_evidence (id, case_id, revision, object_key, content_hash, content_type, byte_size, expires_at)
   values ('d7200000-0000-4000-8000-000000000003', 'd7100000-0000-4000-8000-000000000001', 1,
           'synthetic/missing-name.png', repeat('c',64), 'image/png', 100, now() + interval '7 days')$$,
 '42501', null, 'New API reservations require an explicit name snapshot'
);
select throws_ok(
 $$update bank.identity_evidence set profile_name = 'Rewritten original name'
   where id = 'd7200000-0000-4000-8000-000000000001'$$,
 '42501', null, 'The API cannot rewrite a photo name snapshot'
);
select throws_ok(
 $$update bank.identity_evidence set status = 'ready' where id = 'd7200000-0000-4000-8000-000000000001'$$,
 '23514', null, 'Ready evidence requires a readiness timestamp'
);
select lives_ok(
 $$update bank.identity_evidence set status = 'ready', ready_at = now()
   where id = 'd7200000-0000-4000-8000-000000000001'$$,
 'A completed Storage upload can be acknowledged'
);
select throws_ok(
 $$update bank.identity_evidence set object_key = 'replacement.png'
   where id = 'd7200000-0000-4000-8000-000000000001'$$,
 '42501', null, 'Evidence cannot be replaced under its existing reservation'
);
select throws_ok(
 $$insert into bank.identity_evidence (id, case_id, revision, object_key, content_hash, content_type, byte_size, expires_at, profile_name)
   values ('d7200000-0000-4000-8000-000000000002', 'd7100000-0000-4000-8000-000000000001', 1,
           'synthetic/unsupported.svg', repeat('b',64), 'image/svg+xml', 100, now() + interval '7 days', 'Reference customer')$$,
 '23514', null, 'Only JPEG and PNG metadata is accepted'
);
select lives_ok(
 $$update bank.identity_cases set evidence_id = 'd7200000-0000-4000-8000-000000000001', state = 'submitted', version = 2
   where id = 'd7100000-0000-4000-8000-000000000001'$$,
 'Prepared reference can enter officer review'
);
select throws_ok(
 $$update bank.identity_cases set state = 'reference_accepted'
   where id = 'd7100000-0000-4000-8000-000000000001'$$,
 '23514', null, 'Acceptance requires reviewer attribution and time'
);
select throws_ok(
 $$insert into bank.identity_reviews (id, case_id, actor_id, revision, action)
   values ('d7300000-0000-4000-8000-000000000001', 'd7100000-0000-4000-8000-000000000001',
           'd7000000-0000-4000-8000-000000000002', 1, 'accept_reference')$$,
 '42501', null, 'A customer cannot be the accepting reviewer'
);
select throws_ok(
 $$insert into bank.identity_reviews (id, case_id, actor_id, revision, action)
   values ('d7300000-0000-4000-8000-000000000001', 'd7100000-0000-4000-8000-000000000001',
           'd7000000-0000-4000-8000-000000000001', 1, 'request_changes')$$,
 '23514', null, 'Correction requires a reason'
);
select lives_ok(
 $$insert into bank.identity_reviews (id, case_id, actor_id, revision, action)
   values ('d7300000-0000-4000-8000-000000000001', 'd7100000-0000-4000-8000-000000000001',
           'd7000000-0000-4000-8000-000000000001', 1, 'accept_reference')$$,
 'Officer reference decision is attributed'
);
select lives_ok(
 $$update bank.identity_cases set state = 'reference_accepted', version = 3,
        reviewed_by = 'd7000000-0000-4000-8000-000000000001', reviewed_at = now()
   where id = 'd7100000-0000-4000-8000-000000000001'$$,
 'Reviewed reference can be marked accepted'
);
select lives_ok(
 $$update bank.user_profiles set phone = '0901234567', address = 'Synthetic changed address'
   where id = 'd7000000-0000-4000-8000-000000000002'$$,
 'Contact edits remain permitted after reference acceptance'
);
select is((select version from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 3, 'Contact-only edits preserve the reference version');
select is((select state from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 'reference_accepted', 'Contact-only edits preserve acceptance');
select lives_ok(
 $$update bank.user_profiles set display_name = 'Corrected reference customer'
   where id = 'd7000000-0000-4000-8000-000000000002'$$,
 'Name edit and reference invalidation execute with restricted API grants'
);
select is((select state from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 'needs_changes', 'Name changes invalidate accepted references');
select is((select version from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 4, 'Name changes invalidate stale command versions');
select is((select revision from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 2, 'Name changes invalidate the photo revision');
select ok((select evidence_id is null and reviewed_by is null and reviewed_at is null from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 'Invalidation clears active evidence and reviewer fields');
select is((select profile_name from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 'Corrected reference customer', 'New name is bound to the next reference');
select is((select profile_name from bank.identity_evidence where id = 'd7200000-0000-4000-8000-000000000001'), 'Reference customer', 'Historical photo keeps its original name snapshot after a profile edit');
select is((select count(*) from bank.identity_reviews where case_id = 'd7100000-0000-4000-8000-000000000001' and action = 'name_changed' and actor_id is null), 1::bigint, 'Name invalidation appends a system record');
select is((select count(*) from bank.identity_evidence where id = 'd7200000-0000-4000-8000-000000000001'), 1::bigint, 'Invalidation retains evidence history for bounded cleanup');
select lives_ok(
 $$update bank.user_profiles set display_name = 'Corrected reference customer'
   where id = 'd7000000-0000-4000-8000-000000000002'$$,
 'Saving an unchanged name is harmless'
);
select is((select version from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000001'), 4, 'An unchanged name does not re-invalidate');
select lives_ok(
 $$update bank.user_profiles set display_name = 'Changed draft customer'
   where id = 'd7000000-0000-4000-8000-000000000003'$$,
 'Name changes also invalidate draft versions'
);
select is((select state from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000002'), 'draft', 'A draft stays draft after its name changes');
select is((select revision from bank.identity_cases where id = 'd7100000-0000-4000-8000-000000000002'), 2, 'A draft photo revision advances with the name');

select lives_ok(
 $$insert into bank.identity_commands (actor_id, idempotency_key, customer_id, action, payload_hash, case_id)
   values ('d7000000-0000-4000-8000-000000000002', 'd7400000-0000-4000-8000-000000000001',
           'd7000000-0000-4000-8000-000000000002', 'start', repeat('c',64), 'd7100000-0000-4000-8000-000000000001')$$,
 'A customer command is scoped to its actor and customer'
);
select throws_ok(
 $$insert into bank.identity_commands (actor_id, idempotency_key, customer_id, action, payload_hash)
   values ('d7000000-0000-4000-8000-000000000002', 'd7400000-0000-4000-8000-000000000002',
           'd7000000-0000-4000-8000-000000000003', 'start', repeat('c',64))$$,
 '42501', null, 'Customer command cannot be reserved against another customer'
);
select throws_ok(
 $$insert into bank.identity_commands (actor_id, idempotency_key, customer_id, action, payload_hash)
   values ('d7000000-0000-4000-8000-000000000002', 'd7400000-0000-4000-8000-000000000001',
           'd7000000-0000-4000-8000-000000000002', 'submit', repeat('d',64))$$,
 '23505', null, 'One actor/request key cannot identify two commands'
);
select throws_ok($$update bank.identity_commands set action = 'submit'$$, '42501', null, 'Recorded commands cannot be reassigned');
select throws_ok($$update bank.identity_reviews set reason = 'Rewritten decision'$$, '42501', null, 'Review history cannot be rewritten');
select throws_ok($$delete from bank.identity_reviews$$, '42501', null, 'Review history cannot be deleted');
select lives_ok(
 $$update bank.identity_evidence set deleted_at = now()
   where id = 'd7200000-0000-4000-8000-000000000001'$$,
 'Backend may acknowledge completed Storage deletion without deleting history'
);
reset role;

select * from finish();
rollback;
